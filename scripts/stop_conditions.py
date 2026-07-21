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


def fingerprint(row):
    return "|".join(str(row.get(k)) for k in FINGERPRINT_KEYS)


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
    args = parser.parse_args()

    ladder = [s for s in args.ladder.split(",") if s]
    rounds = read_jsonl(os.path.join(args.workdir, "rounds.jsonl"))
    blockers = read_jsonl(os.path.join(args.workdir, "blockers.jsonl"))

    fingerprints = [fingerprint(r) for r in rounds]
    stall_count = trailing_stall(fingerprints)
    oscillating = is_oscillating(fingerprints)

    last = rounds[-1] if rounds else {}
    analyst_dry = last.get("analyst_new_facts") == 0
    fixers_dry = last.get("fixer_no_new_change") is True

    stuck = stall_count >= args.stall_threshold or oscillating
    moves_exhausted = bool(stuck and analyst_dry and fixers_dry)

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
        "tried_changes": sorted({r["change_key"] for r in rounds if r.get("change_key")}),
        "escalate_to_analyst": bool(escalate),
        "suspect_prior_bypass": stall_count >= 2,
    }

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
