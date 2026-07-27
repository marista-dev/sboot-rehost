#!/usr/bin/env python3
"""stop_conditions.py - compute the stop conditions deterministically.

"Structurally unreachable" is the ONLY reason to stop.
Round count and elapsed time are never stop reasons; there is no round limit.

  BLOCKED_*   a hard blocker recorded as fact in blockers.jsonl
              (carve / missing assets / missing K3 vendor .ko / build error / TEE)
  EXHAUSTED   moves exhausted - only when ALL THREE hold at once:
                fingerprint stalled or oscillating
                AND the static-analyzer escalation produced zero new facts
                AND every assigned fixer reported "no new change to try"

The supervisor agent CANNOT overturn this. If it routes past stop=true the
pipeline force-stops, so sunk cost never beats honesty.

Escalation fires one step BEFORE exhaustion (stall 2 vs stall 3) so the analyst
always gets a chance to produce new facts before we declare the moves spent.

Usage:
  stop_conditions.py <workdir> [--stall-threshold N] [--ladder a,b,c]

Output: JSON on stdout
"""
import argparse
import json
import os
import sys

FINGERPRINT_KEYS = ("fp_exc", "fp_far", "fp_elr", "fp_milestone", "fp_bytes")
ORIGIN_KEYS = ("fp_origin_esr", "fp_origin_far", "fp_origin_elr")


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue          # skip corrupt lines; the log stays append-only
    return rows


def exc_bucket(value):
    """Order of magnitude of the exception count, not the count itself.

    A nested-abort storm runs until the wall clock cuts it, so the same stop
    point produces 2,868,589 exceptions one round and 2,878,514 the next. Those
    are the same observation; comparing them literally made every round look new.
    """
    try:
        count = int(str(value).strip() or 0)
    except (TypeError, ValueError):
        return "?"
    if count <= 0:
        return "0"
    return f"1e{len(str(count)) - 1}"


def fingerprint(row):
    """The identity of a stop point, built to be stable when nothing changed.

    Identity comes from the ORIGINATING exception plus how far the console got.
    The last FAR in the trace is not identity: under a nested abort it walks
    0x20 per iteration and lands wherever the run was killed, which made stall,
    oscillation, exhaustion and layer review unreachable for a whole run.

    Rows written before origin extraction existed fall back to the old keys, so
    a resumed workspace still compares like with like instead of collapsing its
    history into one identical-looking block.
    """
    if any(row.get(k) is not None for k in ORIGIN_KEYS):
        parts = [str(row.get(k)) for k in ORIGIN_KEYS]
        parts.append(str(row.get("fp_milestone")))
        parts.append(str(row.get("fp_bytes")))
        parts.append(str(row.get("fp_uniq")))
        parts.append(exc_bucket(row.get("fp_exc")))
        return "|".join(parts)
    legacy = [str(row.get(k)) for k in FINGERPRINT_KEYS if k != "fp_exc"]
    return "legacy|" + "|".join(legacy) + "|" + exc_bucket(row.get("fp_exc"))


def trailing_stall(fingerprints):
    """How many times the newest fingerprint repeats back-to-back (2 in a row -> 1)."""
    if not fingerprints:
        return 0
    last = fingerprints[-1]
    count = 0
    for fp in reversed(fingerprints[:-1]):
        if fp != last:
            break
        count += 1
    return count


def is_oscillating(fingerprints):
    """True when an A->B->A->B cycle repeats, i.e. fixes keep undoing each other."""
    if len(fingerprints) < 4:
        return False
    a, b, c, d = fingerprints[-4:]
    return a == c and b == d and a != b


def futile_changes(rows, fingerprints):
    """Trailing count of applied changes that left the fingerprint untouched.

    A change recorded in round i shows its effect in round i+1's fingerprint. If
    the fingerprint is identical, that treatment did nothing. This is the
    strongest available evidence that the diagnosis is wrong - the loop is
    treating a symptom - and nothing consumed it before, so a run could apply
    band-aid after band-aid without any signal that the layer was wrong.
    """
    count = 0
    for i in range(len(rows) - 2, -1, -1):
        if rows[i].get("effect") != "applied":
            continue
        if fingerprints[i + 1] == fingerprints[i]:
            count += 1
        else:
            break                  # a change that moved the fingerprint ends it
    return count


def best_progress(rows):
    """How far the firmware ever got, measured in distinct console lines.

    A track-1 grade-A ladder has a single rung, so `best_milestone` stays null
    for a whole run even while the boot walks from 0 to PMIC to storage init.
    With no other measure of depth the loop could not tell progress from
    stagnation, and the stop report had nothing honest to say about how far it
    got. Distinct lines - not bytes - because a retry loop can print 394 KB of
    one repeated error and that is not progress.
    """
    best = {"uniq": 0, "round": None, "bytes": 0}
    for row in rows:
        try:
            uniq = int(row.get("fp_uniq") or 0)
        except (TypeError, ValueError):
            uniq = 0
        if uniq > best["uniq"]:
            best = {"uniq": uniq, "round": row.get("round"),
                    "bytes": row.get("fp_bytes", 0)}
    return best


def best_milestone(rows, ladder):
    reached = [r.get("fp_milestone") for r in rows
               if r.get("fp_milestone") and r.get("fp_milestone") != "none"]
    if not reached:
        return None
    if not ladder:
        return reached[-1]
    ranked = [m for m in reached if m in ladder]
    return max(ranked, key=ladder.index) if ranked else reached[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workdir")
    parser.add_argument("--stall-threshold", type=int, default=3,
                        help="consecutive identical fingerprints before exhaustion is considered")
    parser.add_argument("--ladder", default="", help="comma separated milestone ladder")
    parser.add_argument("--dry-window", type=int, default=3,
                        help="how many trailing rounds must all be dry before exhaustion")
    parser.add_argument("--futile-threshold", type=int, default=2,
                        help="applied changes that moved nothing before a layer review is due")
    parser.add_argument("--futile-exhaust", type=int, default=6,
                        help="applied changes that moved nothing before they stop counting as moves")
    args = parser.parse_args()

    ladder = [s for s in args.ladder.split(",") if s]
    rounds = read_jsonl(os.path.join(args.workdir, "rounds.jsonl"))
    blockers = read_jsonl(os.path.join(args.workdir, "blockers.jsonl"))

    fingerprints = [fingerprint(r) for r in rounds]
    stall_count = trailing_stall(fingerprints)
    oscillating = is_oscillating(fingerprints)

    # Dryness over a window, never from the last row alone. Reading only
    # rounds[-1] let a single round with one new signature erase sixty rounds of
    # stalling, so exhaustion could not be reached while an agent kept producing
    # one nominally-new item per round.
    window = rounds[-args.dry_window:] if rounds else []
    analyst_dry = bool(window) and all(
        r.get("analyst_new_facts") == 0 for r in window)
    fixers_dry = bool(window) and all(
        r.get("fixer_no_new_change") is True for r in window)

    futile = futile_changes(rounds, fingerprints)

    # A change that moves nothing is not a move. `fixer-general` has no domain
    # boundary, so it can nearly always answer "I have another idea"; without
    # this, fixers_dry would never become true and exhaustion would be
    # unreachable no matter how long the run went. It requires analyst_dry too:
    # while derivation is still producing stop points, the next change may be the
    # one that lands.
    futile_spent = futile >= args.futile_exhaust
    stuck = stall_count >= args.stall_threshold or oscillating
    moves_exhausted = bool(stuck and analyst_dry and (fixers_dry or futile_spent))

    stop_reason = None
    if blockers:
        stop_reason = blockers[0].get("code", "BLOCKED_UNKNOWN")
    elif moves_exhausted:
        stop_reason = "EXHAUSTED"

    # Escalate one step earlier than exhaustion so the analyst gets a real turn.
    escalate_at = max(1, args.stall_threshold - 1)
    escalate = (stall_count >= escalate_at or oscillating) and not analyst_dry

    result = {
        "rounds": len(rounds),
        "fingerprint": fingerprints[-1] if fingerprints else None,
        "stall_count": stall_count,
        "oscillating": oscillating,
        "analyst_dry": analyst_dry,
        "fixers_dry": fixers_dry,
        "moves_exhausted": moves_exhausted,
        "blockers": blockers,
        "stop": stop_reason is not None,
        "stop_reason": stop_reason,
        "best_milestone": best_milestone(rounds, ladder),
        # Depth of boot, for ladders whose only rung is the goal itself.
        "best_progress": best_progress(rounds),
        "tried_changes": sorted({r["change_key"] for r in rounds if r.get("change_key")}),
        "escalate_to_analyst": bool(escalate),
        "suspect_prior_bypass": stall_count >= 2,
        # Treatments are being applied and changing nothing. The loop can only
        # edit one place in the machine sources, so when that keeps failing the
        # question is no longer "which fixer" but "is this fixable in the loop at
        # all" - which is the supervisor's judgement to make, not a script's.
        "futile_changes": futile,
        "futile_spent": futile_spent,
        "needs_layer_review": futile >= args.futile_threshold,
        "dry_window": args.dry_window,
    }

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
