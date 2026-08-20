#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# run_round.sh - execute one round and emit a SINGLE observation document.
#
# Why this exists:
#   The pipeline used to hand the agent two separate outputs - the run script's
#   key=value lines and the stop_conditions JSON - and ask it to merge them.
#   Transcribing `stop` wrongly there would weaken the stop backstop, which is
#   the one thing an LLM must not be able to soften. So the merge happens here,
#   deterministically, and the agent only relays one document it did not build.
#
# Usage:
#   run_round.sh <workdir> <machine> <run_n> <goal> <ladder> [container] [cmd] [surface]
#
# Output:
#   <workdir>/observation.json   (also printed to stdout)
#
# Steps: journal try-start -> change snapshot -> run -> stop conditions -> merge.

set -u

WD="${1:?workdir required}"
MACHINE="${2:?machine required}"
RUN_N="${3:?run number required}"
GOAL="${4:-}"
LADDER="${5:-}"
CONTAINER="${6:-}"      # bootloader container, loaded whole
CMD="${7:-help}"
SURFACE="${8:-shell}"   # the bootloader's interactive surface

HERE="$(cd "$(dirname "$0")" && pwd)"

bash "$HERE/journal.sh" "$WD" try-start "$RUN_N" "목표 $GOAL" >/dev/null 2>&1 || true
# The round number keeps the snapshot: a change proved wrong three rounds later
# can then actually be taken back out (revert_change.sh).
bash "$HERE/check_change.sh" "$WD" snapshot "$RUN_N" >/dev/null 2>&1 || true

# One chain, one run script. The bootloader loads what comes after it, so there
# is nothing to branch on here any more.
RUN_RC=0
bash "$HERE/run_full.sh" "$WD" "$MACHINE" "$CONTAINER" "$CMD" "$RUN_N" "$SURFACE" >/dev/null || RUN_RC=$?

STOP_TMP="$(mktemp)"
python3 "$HERE/stop_conditions.py" "$WD" --ladder "$LADDER" > "$STOP_TMP" 2>/dev/null || echo '{}' > "$STOP_TMP"

python3 - "$WD" "$GOAL" "$STOP_TMP" "$RUN_N" "$RUN_RC" <<'PY'
import json, os, sys

wd, goal, stop_path, run_n, run_rc = sys.argv[1:6]

def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default

fp = load(os.path.join(wd, "fingerprint.json"), {})
stop = load(stop_path, {})

gate = fp.get("source_gate") or {}
origin = fp.get("origin") or {}
inp = fp.get("input") or {}
observation = {
    "round": int(run_n),
    "goal": goal,
    "run_exit_code": int(run_rc),
    # A run that produced no fingerprint, or one the run script judged failed,
    # is not a round about the firmware. Reporting it as ok let eight rounds of
    # a QEMU that never started read as a stall and then as EXHAUSTED.
    "run_ok": bool(fp) and not fp.get("run_failed", False),
    "run_error": fp.get("run_error", ""),

    # raw observation from the run script
    "milestone": fp.get("milestone", "none"),
    # every rung cleared, so a ladder that skips rungs still advances correctly
    "milestones_reached": fp.get("milestones_reached", []),
    "injected": bool(gate.get("injected", False)),
    "injected_token": gate.get("token", ""),
    "exceptions": fp.get("exceptions", 0),
    "console_bytes": fp.get("console_bytes", 0),
    # Distinct console lines: depth of boot, which console bytes cannot show
    # because a retry loop prints the same line hundreds of thousands of times.
    "console_uniq": fp.get("console_uniq", 0),
    # The ORIGINATING exception - the stop point that actually needs a fix.
    # far/elr below are the last ones in the trace and under a nested abort they
    # are only where the recursion ran out of time.
    "origin_type": origin.get("type", "none"),
    "origin_esr": origin.get("esr", "none"),
    "origin_far": origin.get("far", "none"),
    "origin_elr": origin.get("elr", "none"),
    "origin_block": origin.get("block", ""),
    "far": fp.get("far", "none"),
    "elr": fp.get("elr", "none"),
    # What the input path did. Without these a round cannot separate "the gate
    # was never offered our bytes" from "the gate read them and the firmware
    # booted on", and the first one is not an observation about the firmware.
    "input_offered": bool(inp.get("offered", False)),
    "prompt_seen": bool(inp.get("prompt_seen", False)),
    "command_sent": bool(inp.get("command_sent", False)),
    "input_starved": bool(inp.get("starved", False)),
    "rx_reported": bool(inp.get("rx_reported", False)),
    "rx_served": inp.get("rx_served"),
    "rx_polls": inp.get("rx_polls"),
    "input_summary": inp.get("summary", ""),
    "input_log": inp.get("log", ""),
    # Could this run read the boot medium's partition table? "unknown" means the
    # boot never got that far, which is not the same as "missing" and must not
    # block anything.
    "storage_partition_table": (fp.get("storage") or {}).get("partition_table", "unknown"),
    "storage_token": (fp.get("storage") or {}).get("token", ""),
    # True when a longer run produced more console: the wall is our time budget,
    # not the firmware. null means the probe did not run, which is NOT the same
    # as false - reporting an unmeasured value as measured is what let a stalled
    # run look like a firmware wall for five rounds.
    "timeout_bound": fp.get("timeout_bound"),
    "probe_console_bytes": fp.get("probe_console_bytes", -1),
    "console": fp.get("console", ""),
    "summary": fp.get("summary", ""),
    "trace": fp.get("trace", ""),

    # deterministic stop conditions - copied verbatim, never re-derived
    "stop": bool(stop.get("stop", False)),
    "stop_reason": stop.get("stop_reason"),
    "stall_count": stop.get("stall_count", 0),
    "oscillating": bool(stop.get("oscillating", False)),
    "moves_exhausted": bool(stop.get("moves_exhausted", False)),
    "escalate_to_analyst": bool(stop.get("escalate_to_analyst", False)),
    "suspect_prior_bypass": bool(stop.get("suspect_prior_bypass", False)),
    "best_milestone": stop.get("best_milestone"),
    "best_progress": stop.get("best_progress", {}),
    "tried_changes": stop.get("tried_changes", []),
    # changes applied that moved nothing - the signal that the diagnosis is at
    # the wrong layer, which is the supervisor's judgement to make
    "futile_changes": stop.get("futile_changes", 0),
    "needs_layer_review": bool(stop.get("needs_layer_review", False)),
    "blockers": stop.get("blockers", []),
}

# A run that produced no fingerprint must not look like a clean round.
if not fp:
    observation["note"] = ("fingerprint.json 이 생성되지 않았습니다 — "
                           "QEMU 실행 자체가 실패했습니다")
elif fp.get("run_failed"):
    observation["note"] = ("실행이 실패했습니다 — " + str(fp.get("run_error", "")) +
                           " · 이것은 펌웨어 정지점이 아니라 하네스/환경 문제입니다")

out = os.path.join(wd, "observation.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump(observation, fh, ensure_ascii=False, indent=2)
print(json.dumps(observation, ensure_ascii=False, indent=2))
PY

rm -f "$STOP_TMP"
