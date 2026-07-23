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
#   run_round.sh <workdir> <track> <machine> <run_n> <goal> <ladder> [bootloader] [cmd] [surface]
#
# Output:
#   <workdir>/observation.json   (also printed to stdout)
#
# Steps: journal try-start -> change snapshot -> run -> stop conditions -> merge.

set -u

WD="${1:?workdir required}"
TRACK="${2:?track required}"
MACHINE="${3:?machine required}"
RUN_N="${4:?run number required}"
GOAL="${5:-}"
LADDER="${6:-}"
BL3="${7:-}"
CMD="${8:-help}"
SURFACE="${9:-shell}"   # track 1 interactive surface

HERE="$(cd "$(dirname "$0")" && pwd)"

bash "$HERE/journal.sh" "$WD" try-start "$RUN_N" "목표 $GOAL" >/dev/null 2>&1 || true
bash "$HERE/check_change.sh" "$WD" snapshot >/dev/null 2>&1 || true

RUN_RC=0
if [ "$TRACK" = "1" ]; then
    bash "$HERE/run_qemu.sh" "$WD" "$MACHINE" "$BL3" "$CMD" "$RUN_N" "$SURFACE" >/dev/null || RUN_RC=$?
else
    bash "$HERE/run_kernel.sh" "$WD" "$MACHINE" "$RUN_N" >/dev/null || RUN_RC=$?
fi

STOP_TMP="$(mktemp)"
python3 "$HERE/stop_conditions.py" "$WD" --ladder "$LADDER" > "$STOP_TMP" 2>/dev/null || echo '{}' > "$STOP_TMP"

python3 - "$WD" "$GOAL" "$STOP_TMP" "$RUN_N" "$TRACK" "$RUN_RC" <<'PY'
import json, os, sys

wd, goal, stop_path, run_n, track, run_rc = sys.argv[1:7]

def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default

fp = load(os.path.join(wd, "fingerprint.json"), {})
stop = load(stop_path, {})

gate = fp.get("source_gate") or {}
observation = {
    "round": int(run_n),
    "track": int(track),
    "goal": goal,
    "run_exit_code": int(run_rc),
    "run_ok": bool(fp),

    # raw observation from the run script
    "milestone": fp.get("milestone", "none"),
    # every rung cleared, so a ladder that skips rungs still advances correctly
    "milestones_reached": fp.get("milestones_reached", []),
    "injected": bool(gate.get("injected", False)),
    "injected_token": gate.get("token", ""),
    "exceptions": fp.get("exceptions", 0),
    "console_bytes": fp.get("console_bytes", 0),
    "far": fp.get("far", "none"),
    "elr": fp.get("elr", "none"),
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
                           "QEMU 실행 자체가 실패했을 수 있습니다")

out = os.path.join(wd, "observation.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump(observation, fh, ensure_ascii=False, indent=2)
print(json.dumps(observation, ensure_ascii=False, indent=2))
PY

rm -f "$STOP_TMP"
