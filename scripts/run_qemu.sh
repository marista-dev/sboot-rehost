#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
. "$(dirname "$0")/fingerprint_lib.sh"
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
#   <workdir>/07_logs/origin_<run_n>.txt       originating exception block
#   <workdir>/fingerprint.json                 this round's fingerprint
#   ~/rehost/_traces/run_<run_n>.log           full trace       (WSL ext4)
#
# stdout: console= summary= trace= exceptions= console_size= far= elr= milestone=
#         injected= origin_far= origin_elr= console_uniq= run_failed=
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
# One extra run, only when the round looks like a hang that has not moved. See
# the probe block below for why a fixed wall-clock budget needs a second look.
TIMEOUT_PROBE="${TIMEOUT_PROBE:-1}"
PROBE_MULT="${PROBE_MULT:-4}"

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
ORIGIN="$WORKDIR/07_logs/origin_${RUN_N}.txt"
INLOG="$WORKDIR/07_logs/input_${RUN_N}.txt"
ERRF="$WORKDIR/07_logs/qemu_${RUN_N}.stderr.txt"
LOG="$TRACE_DIR/run_${RUN_N}.log"
rm -f "$OUT" "$SUM" "$LOG" "$ORIGIN" "$ERRF" "$INLOG"

# The console token that means the surface is up. static-analyzer derives it into
# milestone_tokens.txt; the harness stops trying to interrupt autoboot once it
# appears and sends the command instead.
PROMPT_TOKEN=""
if [ -s "$WORKDIR/milestone_tokens.txt" ]; then
    PROMPT_TOKEN=$(awk -F'\t' -v s="$SURFACE" 'NF>1 && $1==s {print $2; exit}' \
                   "$WORKDIR/milestone_tokens.txt")
fi
# An array, not ${VAR:+...}: a prompt token contains spaces ("S-BOOT # ") and the
# unquoted form word-splits it, so the harness would look for the wrong string.
PROMPT_ARGS=()
[ -n "$PROMPT_TOKEN" ] && PROMPT_ARGS=(--prompt-token "$PROMPT_TOKEN")

# Keep the previous round's fingerprint: the timeout probe below needs to know
# whether the console has stopped growing across rounds.
PREV="$WORKDIR/fingerprint.prev.json"
[ -f "$WORKDIR/fingerprint.json" ] && cp "$WORKDIR/fingerprint.json" "$PREV" 2>/dev/null || true

python3 "$HERE/record.py" "$WORKDIR" start "run_${RUN_N}" >/dev/null 2>&1 || true

# Input comes from OUTSIDE the machine (honesty rule 7). uart_harness.py owns the
# guest console: it repeats the derived autoboot-interrupt pattern while the gate
# may be open, sends the command once the surface answers, and logs every byte it
# typed. `-serial stdio` hands the console to its pipes; the machine is not given
# a command line to seed itself from.
#
# The exit code matters: piping it into `tail` threw it away, so a QEMU that
# never started reported success and the round looked clean.
RUN_RC=0
python3 "$HERE/uart_harness.py" \
    --console "$OUT" --input-log "$INLOG" \
    --plan "$WORKDIR/input_plan.json" \
    --timeout "$TIMEOUT" --cmd "$CMD" --surface "$SURFACE" \
    ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"} \
    -- "$QEMU" \
    -M "$MACHINE" -m 512M -display none -serial stdio \
    -kernel "$BL3" \
    -d int,in_asm,nochain -D "$LOG" \
    2> "$ERRF" || RUN_RC=$?
tail -3 "$ERRF" 2>/dev/null || true

# --- Fingerprint: raw observations only, never a classification ---
# NOTE: grep -c exits 1 when the count is zero while still printing "0".
# Using `|| echo 0` would emit TWO lines and corrupt the JSON below, so assign
# first and fall back only on a non-zero exit.
EXC=$(grep -c "Taking exception" "$LOG" 2>/dev/null) || EXC=0
[ -n "$EXC" ] || EXC=0
if [ -f "$OUT" ]; then CSZ=$(wc -c < "$OUT" | tr -d ' '); else CSZ=0; fi
CUNIQ=$(fp_console_uniq "$OUT")

# The last FAR/ELR in the log. Kept for continuity of the record, NOT used as
# the identity of the stop point: under a nested abort it is wherever the
# recursion happened to be when the clock ran out.
FAR=$(grep -ohE "FAR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
ELR=$(grep -ohE "ELR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
FAR="${FAR:-none}"; ELR="${ELR:-none}"

# The originating exception - the one that actually needs a fix.
fp_origin "$LOG" "$ORIGIN"

fp_run_verdict "$RUN_RC" "$LOG" "$CSZ" "$ERRF"

# The summary is what the classifier reads. It leads with the originating
# exception; the tail is kept below it because the end of the trace still shows
# how the run died.
{
    echo "=== 최초 예외 (첫 Taking exception 블록) ==="
    if [ -s "$ORIGIN" ]; then cat "$ORIGIN"; else echo "(예외 없음 — 폴링 hang 또는 정상 종료)"; fi
    echo
    echo "=== 마지막 60줄 (트레이스 마지막 — 근본 원인이 아닐 수 있음) ==="
    grep -E "Taking exception|FAR|ELR|ESR|UPLOAD|E_SYNC|panic|abort|smc" "$LOG" 2>/dev/null | tail -60
} > "$SUM" 2>/dev/null || true

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

# milestone_tokens.txt lines are "<milestone>\t<token>"; a line with no tab is a
# token for the surface rung. static-analyzer writes the strings it derived, so
# grades B/C (commands, autoboot) can be observed on any bootloader.
REACHED=""
TAB="$(printf '\t')"

scan_token() {   # $1 = milestone, $2 = console token
    grep -qF "$2" "$OUT" 2>/dev/null || return 0
    if grep -qF "$2" "$SRC_DIR"/*.c 2>/dev/null; then
        INJECTED="true"
        INJECTED_TOKEN="${INJECTED_TOKEN:+$INJECTED_TOKEN, }$2"
    else
        case " $REACHED " in *" $1 "*) ;; *) REACHED="$REACHED $1";; esac
    fi
}

TOKEN_FILE="$WORKDIR/milestone_tokens.txt"
if [ -s "$TOKEN_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *"$TAB"*) scan_token "${line%%$TAB*}" "${line#*$TAB}" ;;
            *)        scan_token "$SURFACE" "$line" ;;
        esac
    done < "$TOKEN_FILE"
elif [ "$SURFACE" = "fastboot" ]; then
    for t in "fastboot: processing commands" "fastboot_init(" "command buf"; do
        scan_token "$SURFACE" "$t"
    done
else
    for t in "S-BOOT" "Following commands"; do
        scan_token "$SURFACE" "$t"
    done
fi

# Injection is dominant: a contaminated console credits nothing at all.
[ "$INJECTED" = "true" ] && REACHED=""

# Highest rung wins, in track 1 ladder order.
for m in "$SURFACE" commands autoboot; do
    case " $REACHED " in *" $m "*) MILESTONE="$m" ;; esac
done
MILESTONES_JSON=$(python3 -c 'import sys,json;print(json.dumps(sys.argv[1].split()))' "$REACHED")

# --- Timeout probe -----------------------------------------------------------
# TIMEOUT is a fixed wall-clock budget, so "the firmware hung" and "we killed a
# boot that was still working" produce the same observation: no exception, no new
# console. When the round looks like that AND the previous round ended at exactly
# the same console size, one longer run answers which it was. The probe never
# touches the fingerprint - it only reports timeout_bound, so the supervisor can
# tell a harness wall from a firmware wall instead of spending rounds on it.
TIMEOUT_BOUND="false"; PROBE_BYTES=-1
if [ "$TIMEOUT_PROBE" != "0" ] && [ "$MILESTONE" = "none" ] && [ "$EXC" -eq 0 ] \
   && [ "$FP_RUN_FAILED" -eq 0 ] && [ -f "$PREV" ]; then
    if [ "$(fp_prev_stuck "$PREV" "$CSZ")" = "yes" ]; then
        PROBE_OUT="$WORKDIR/07_logs/probe_${RUN_N}.txt"
        PROBE_LOG="$TRACE_DIR/probe_${RUN_N}.log"
        rm -f "$PROBE_OUT" "$PROBE_LOG"
        python3 "$HERE/uart_harness.py" \
            --console "$PROBE_OUT" --input-log "${INLOG}.probe" \
            --plan "$WORKDIR/input_plan.json" \
            --timeout $((TIMEOUT * PROBE_MULT)) --cmd "$CMD" --surface "$SURFACE" \
            ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"} \
            -- "$QEMU" \
            -M "$MACHINE" -m 512M -display none -serial stdio \
            -kernel "$BL3" \
            -d int,nochain -D "$PROBE_LOG" \
            >/dev/null 2>&1 || true
        if [ -f "$PROBE_OUT" ]; then PROBE_BYTES=$(wc -c < "$PROBE_OUT" | tr -d ' '); else PROBE_BYTES=0; fi
        [ "$PROBE_BYTES" -gt "$CSZ" ] && TIMEOUT_BOUND="true"
        rm -f "$PROBE_LOG"
    fi
fi

INJECTED_TOKEN_JSON="$(fp_json_escape "$INJECTED_TOKEN")"
RUN_ERROR_JSON="$(fp_json_escape "$FP_RUN_ERROR")"
ORIGIN_TYPE_JSON="$(fp_json_escape "$FP_ORIGIN_TYPE")"

cat > "$WORKDIR/fingerprint.json" <<JSON
{
  "round": ${RUN_N},
  "track": 1,
  "exceptions": ${EXC},
  "far": "${FAR}",
  "elr": "${ELR}",
  "origin": {
    "type": "${ORIGIN_TYPE_JSON}",
    "esr": "${FP_ORIGIN_ESR}",
    "far": "${FP_ORIGIN_FAR}",
    "elr": "${FP_ORIGIN_ELR}",
    "block": "${ORIGIN}"
  },
  "console_bytes": ${CSZ},
  "console_uniq": ${CUNIQ},
  "milestone": "${MILESTONE}",
  "milestones_reached": ${MILESTONES_JSON},
  "source_gate": { "injected": ${INJECTED}, "token": "${INJECTED_TOKEN_JSON}" },
  "run_failed": $([ "$FP_RUN_FAILED" -eq 1 ] && echo true || echo false),
  "run_error": "${RUN_ERROR_JSON}",
  "timeout_bound": ${TIMEOUT_BOUND},
  "probe_console_bytes": ${PROBE_BYTES},
  "console": "${OUT}",
  "summary": "${SUM}",
  "trace": "${LOG}"
}
JSON

python3 "$HERE/record.py" "$WORKDIR" metric \
    phase=Run round="${RUN_N}" event=run_end timer="run_${RUN_N}" \
    exceptions="${EXC}" console_bytes="${CSZ}" console_uniq="${CUNIQ}" \
    origin_far="${FP_ORIGIN_FAR}" origin_elr="${FP_ORIGIN_ELR}" \
    milestone="${MILESTONE}" injected="${INJECTED}" \
    run_failed="$([ "$FP_RUN_FAILED" -eq 1 ] && echo true || echo false)" >/dev/null 2>&1 || true

if [ "$INJECTED" = "true" ]; then
    echo "★ 출처 게이트: '${INJECTED_TOKEN}' 문자열이 머신 소스에 있습니다 — 우리가 찍은 것이므로 도달로 인정하지 않습니다." >&2
fi
if [ "$FP_RUN_FAILED" -eq 1 ]; then
    echo "★ 실행 실패: ${FP_RUN_ERROR}" >&2
fi
if [ "$TIMEOUT_BOUND" = "true" ]; then
    echo "★ 타임아웃 한계: ${TIMEOUT}s 로는 끊겼지만 $((TIMEOUT * PROBE_MULT))s 에서는 콘솔이 더 나왔습니다 (${CSZ}B → ${PROBE_BYTES}B). 펌웨어 정지점이 아니라 실행 시간이 벽입니다." >&2
fi

echo "console=$OUT"
echo "summary=$SUM"
echo "trace=$LOG"
echo "exceptions=$EXC"
echo "console_size=$CSZ"
echo "console_uniq=$CUNIQ"
echo "far=$FAR"
echo "elr=$ELR"
echo "origin_far=$FP_ORIGIN_FAR"
echo "origin_elr=$FP_ORIGIN_ELR"
echo "origin_esr=$FP_ORIGIN_ESR"
echo "milestone=$MILESTONE"
echo "injected=$INJECTED"
echo "run_failed=$FP_RUN_FAILED"
echo "timeout_bound=$TIMEOUT_BOUND"
