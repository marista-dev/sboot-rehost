#!/usr/bin/env bash
# run_qemu.sh - Track 1 (bootloader shell): one round of execution.
# Extracts the raw fingerprint and enforces the provenance gate.
# Called by workflows/pipeline.js once per round.
#
# Usage:
#   run_qemu.sh <workdir> <machine_name> <bootloader_path> <cmd> <run_n> [surface]
#
# Output files:
#   <workdir>/07_logs/console_<run_n>.txt      UART output      (local)
#   <workdir>/07_logs/run_<run_n>.summary.txt  key stop points  (local)
#   <workdir>/fingerprint.json                 this round's fingerprint
#   ~/rehost/_traces/run_<run_n>.log           full trace       (WSL ext4)
#
# stdout: console= summary= trace= exceptions= console_size= far= elr= milestone= injected=
#
# Provenance gate (honesty rule 7 - no self-injection, enforced every round):
#   Even if a goal string appears on the console, if that same string exists in the
#   machine source (.c) then WE printed it, not the firmware. Such a milestone is
#   dropped and injected=true is reported.

set -u

WORKDIR="$1"
MACHINE="$2"
BL3="$3"
CMD="${4:-help}"
RUN_N="${5:-1}"
SURFACE="${6:-shell}"      # shell (UART console) | fastboot (USB dispatch)

HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-8}"

if [[ -z "$WORKDIR" || -z "$MACHINE" || -z "$BL3" ]]; then
    echo "Usage: $0 <workdir> <machine_name> <bootloader_path> <cmd> <run_n> [surface]" >&2
    exit 1
fi
if [[ ! -x "$QEMU" ]]; then
    echo "ERROR: QEMU 실행 파일을 찾을 수 없습니다: $QEMU" >&2
    exit 2
fi

mkdir -p "$WORKDIR/07_logs"
TRACE_DIR="${TRACE_DIR:-$HOME/rehost/_traces}"; mkdir -p "$TRACE_DIR"
OUT="$WORKDIR/07_logs/console_${RUN_N}.txt"
SUM="$WORKDIR/07_logs/run_${RUN_N}.summary.txt"
LOG="$TRACE_DIR/run_${RUN_N}.log"
rm -f "$OUT" "$SUM" "$LOG"

python3 "$HERE/record.py" "$WORKDIR" start "run_${RUN_N}" >/dev/null 2>&1 || true

timeout "$TIMEOUT" "$QEMU" \
    -M "$MACHINE" -m 512M -nographic \
    -kernel "$BL3" -append "$CMD" \
    -serial "file:$OUT" \
    -d int,in_asm,nochain -D "$LOG" \
    2>&1 | tail -3 || true

grep -E "Taking exception|FAR|ELR|ESR|UPLOAD|E_SYNC|panic|abort|smc" "$LOG" 2>/dev/null \
    | tail -60 > "$SUM" || true

# --- Fingerprint: raw observations only, never a classification ---
# NOTE: grep -c exits 1 when the count is zero while still printing "0".
# Using `|| echo 0` would emit TWO lines and corrupt the JSON below, so assign
# first and fall back only on a non-zero exit.
EXC=$(grep -c "Taking exception" "$LOG" 2>/dev/null) || EXC=0
[ -n "$EXC" ] || EXC=0
if [ -f "$OUT" ]; then CSZ=$(wc -c < "$OUT" | tr -d ' '); else CSZ=0; fi
FAR=$(grep -ohE "FAR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
ELR=$(grep -ohE "ELR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
FAR="${FAR:-none}"; ELR="${ELR:-none}"

# --- Milestone + provenance gate ---
# Track 1 reaches its goal when the console shows text the BOOTLOADER owns, on
# whichever interactive surface this firmware actually has.
#
# The tokens are data, not a constant: a UART shell prints a prompt and a command
# list, while a fastboot surface prints its own dispatch lines. Encoding one
# vendor's banner here would strand every other bootloader. static-analyzer
# derives the real strings and writes them to milestone_tokens.txt; the built-in
# lists below are only a fallback.
#
# Injection is dominant: if ANY milestone token also lives in the machine source,
# the console is contaminated and nothing is credited, even when another token
# looks clean. Crediting the clean one would let a machine that fakes the prompt
# claim the surface. A false "not reached" costs extra rounds; a false "reached"
# produces a fake success, and this project always takes the former.
MILESTONE="none"; INJECTED="false"; INJECTED_TOKEN=""
SRC_DIR="$WORKDIR/06_machine"
CONSOLE_HIT="false"

TOKEN_FILE="$WORKDIR/milestone_tokens.txt"
if [ -s "$TOKEN_FILE" ]; then
    TOKENS=()
    while IFS= read -r line; do
        [ -n "$line" ] && TOKENS+=("$line")
    done < "$TOKEN_FILE"
elif [ "$SURFACE" = "fastboot" ]; then
    TOKENS=("fastboot: processing commands" "fastboot_init(" "command buf")
else
    TOKENS=("S-BOOT" "autoboot" "Following commands")
fi

for token in "${TOKENS[@]}"; do
    grep -qF "$token" "$OUT" 2>/dev/null || continue
    if grep -qF "$token" "$SRC_DIR"/*.c 2>/dev/null; then
        INJECTED="true"
        INJECTED_TOKEN="${INJECTED_TOKEN:+$INJECTED_TOKEN, }$token"
    else
        CONSOLE_HIT="true"
    fi
done
MILESTONES_JSON="[]"
if [ "$CONSOLE_HIT" = "true" ] && [ "$INJECTED" = "false" ]; then
    MILESTONE="$SURFACE"
    MILESTONES_JSON="[\"$SURFACE\"]"
fi

# Escape anything that could break the JSON document below.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }
INJECTED_TOKEN_JSON="$(json_escape "$INJECTED_TOKEN")"

cat > "$WORKDIR/fingerprint.json" <<JSON
{
  "round": ${RUN_N},
  "track": 1,
  "exceptions": ${EXC},
  "far": "${FAR}",
  "elr": "${ELR}",
  "console_bytes": ${CSZ},
  "milestone": "${MILESTONE}",
  "milestones_reached": ${MILESTONES_JSON},
  "source_gate": { "injected": ${INJECTED}, "token": "${INJECTED_TOKEN_JSON}" },
  "console": "${OUT}",
  "summary": "${SUM}",
  "trace": "${LOG}"
}
JSON

python3 "$HERE/record.py" "$WORKDIR" metric \
    phase=Run round="${RUN_N}" event=run_end timer="run_${RUN_N}" \
    exceptions="${EXC}" console_bytes="${CSZ}" milestone="${MILESTONE}" \
    injected="${INJECTED}" >/dev/null 2>&1 || true

if [ "$INJECTED" = "true" ]; then
    echo "★ 출처 게이트: '${INJECTED_TOKEN}' 문자열이 머신 소스에 있습니다 — 우리가 찍은 것이므로 도달로 인정하지 않습니다." >&2
fi

echo "console=$OUT"
echo "summary=$SUM"
echo "trace=$LOG"
echo "exceptions=$EXC"
echo "console_size=$CSZ"
echo "far=$FAR"
echo "elr=$ELR"
echo "milestone=$MILESTONE"
echo "injected=$INJECTED"
