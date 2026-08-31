#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
. "$(dirname "$0")/fingerprint_lib.sh"

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
#         injected= origin_far= origin_elr= console_uniq= run_failed= run_fault=
#
# run_full.sh - one round of the unified chain, from the first stage onward.
#
# Derived from run_qemu.sh and deliberately keeps its honesty machinery intact:
# the external input harness, the provenance gate, the origin-exception
# fingerprint and the run-failure verdict. What changes is what the machine is
# given - the whole container instead of a carved stage, and a boot medium the
# firmware reads the next stage from rather than a kernel handed to it by QEMU.
#
# There is no -kernel/-dtb/-initrd for the Linux image on purpose. The bootloader
# loads it itself; handing it over would make this run indistinguishable from
# loading a kernel directly, which is the thing this flow exists not to do.
#
# Provenance gate (honesty rule 7 - no self-injection, enforced every round):
#   Even if a goal string appears on the console, if that same string exists in the
#   machine source (.c) then WE printed it, not the firmware. Such a milestone is
#   dropped and injected=true is reported.

set -u

WORKDIR="$1"
MACHINE="$2"
CONTAINER="$3"        # the bootloader container, loaded whole
CMD="${4:-help}"
RUN_N="${5:-1}"
SURFACE="${6:-shell}"      # shell (UART console) | fastboot (USB dispatch)
# The goal ladder, comma-separated, lowest rung first. Without it the "highest
# rung reached" pick could only see the bootloader-side rungs, so a run that
# reached scsi_attach or kernel_alive still reported milestone=none.
LADDER="${7:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"
# Wall-clock budget for one round. The S921N shell prompt appeared between 5.2s
# and 8.0s of wall time under full tracing, so the old default of 8 left no
# margin at all: a slightly slower host turned the same firmware into "did not
# reach". The pipeline can override this (INPUT.md run_timeout_s).
# A round here can walk the whole chain, so the budget is the kernel-boot scale
# rather than the seconds it takes to reach a shell prompt. Too small a budget
# reports "did not reach" for a boot that was still progressing.
TIMEOUT="${TIMEOUT:-200}"
# One extra run, only when the round looks like a hang that has not moved. See
# the probe block below for why a fixed wall-clock budget needs a second look.
TIMEOUT_PROBE="${TIMEOUT_PROBE:-1}"
PROBE_MULT="${PROBE_MULT:-4}"

if [[ -z "$WORKDIR" || -z "$MACHINE" || -z "$CONTAINER" ]]; then
    echo "Usage: $0 <workdir> <machine_name> <container_path> <cmd> <run_n> [surface]" >&2
    exit 1
fi

# The synthesised boot medium. Absent is not fatal: the first rungs are reached
# before anything reads it, and saying so beats refusing to run at all.
MEDIUM="${MEDIUM:-$WORKDIR/fw/lu0.img}"
MEDIUM_ARGS=()
if [ -s "$MEDIUM" ]; then
    # snapshot=on by default: the bootloader really writes to PARAM and the DDI
    # area, so without it a round inherits whatever the previous round left on
    # disk. The round loop compares fingerprints assuming the machine source is
    # the only variable; accumulated disk state breaks that, and reverting a
    # change no longer reverts the run. Set MEDIUM_WRITABLE=1 for the rare round
    # that needs to observe those writes - and record that it was set.
    if [ "${MEDIUM_WRITABLE:-0}" = "1" ]; then
        MEDIUM_ARGS=(-drive "file=$MEDIUM,if=none,format=raw,id=lu0")
        echo "run_full: 매체를 쓰기 가능으로 엽니다 — 이 회차는 멱등하지 않습니다" >&2
    else
        MEDIUM_ARGS=(-drive "file=$MEDIUM,if=none,format=raw,id=lu0,snapshot=on")
    fi
else
    echo "run_full: 부팅 매체가 없습니다 ($MEDIUM) — 매체를 읽는 칸은 이 회차에서 도달 불가" >&2
fi

# DRAM plus the bootloader's own load window has to fit, and that window sits far
# above the DRAM base on some SoCs. 512M was enough for a carved stage; it is not
# enough for a container placed at its real addresses.
MEM="${MEM:-2G}"
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
TRACE_STATS="$WORKDIR/07_logs/trace_${RUN_N}.json"

# 디스크가 차면 회차가 아니라 기계가 죽는다. 15회차가 각 10~12 GB 를 남겨 281 GB 를
# 채우고 WSL 이 재시작된 적이 있으므로, 남은 공간을 회차 전에 확인한다.
FREE_MB=$(df -Pm "$TRACE_DIR" 2>/dev/null | awk 'NR==2{print $4}')
MIN_FREE_MB="${MIN_FREE_MB:-4096}"
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    echo "run_full: 디스크 여유가 ${FREE_MB} MB 뿐입니다 (최소 ${MIN_FREE_MB} MB) — 회차를 시작하지 않습니다" >&2
    echo "run_failed=1"
    exit 3
fi

# 지난 회차 트레이스는 최근 것만 남긴다. 필터를 거치므로 각각 수 MB 지만,
# 회차가 백 단위로 늘면 그것도 쌓인다.
TRACE_KEEP="${TRACE_KEEP:-10}"
ls -1t "$TRACE_DIR"/run_*.log 2>/dev/null | tail -n +$((TRACE_KEEP + 1)) | xargs -r rm -f 2>/dev/null || true
# What the harness did, machine-readable. Without it a round cannot say whether
# the interrupt pattern ever got in front of the gate, and a harness failure is
# recorded as a verdict about the firmware.
INSUM="$WORKDIR/input_summary.json"
rm -f "$OUT" "$SUM" "$LOG" "$ORIGIN" "$ERRF" "$INLOG" "$INSUM"

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
# The trace goes through a filter, not straight to disk. `-d int,in_asm,nochain`
# writes 10-12 GB on a firmware that faults in a loop, and none of that volume is
# read: the pipeline consumes the exception count, the FIRST exception block, the
# last FAR/ELR, and whether each stage entry PC appeared. trace_filter.py keeps
# exactly that in bounded space, so the log stays a few MB however long the run.
WATCH=$(python3 - "$WORKDIR/stage_map.json" <<'PYW' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
pcs = []
for st in d.get("stages", []):
    base = st.get("base")
    if st.get("state") == "exec" and isinstance(base, int):
        pcs.append(hex(base))
print(",".join(pcs))
PYW
)

FIFO="$(mktemp -u "${TMPDIR:-/tmp}/sboot_trace.XXXXXX")"
FILTER_PID=""
if mkfifo "$FIFO" 2>/dev/null; then
    python3 "$HERE/trace_filter.py" --out "$LOG" --stats "$TRACE_STATS" \
        --watch "$WATCH" < "$FIFO" &
    FILTER_PID=$!
    # 쓰기 쪽 FD 를 셸이 잡고 있어야 한다. QEMU 가 -D 를 아예 열지 않는 경우
    # (실행 실패, 인자 오류) 필터가 EOF 를 못 받아 wait 가 영원히 멈춘다.
    exec 9>"$FIFO"
    TRACE_TARGET="$FIFO"
else
    # 필터를 못 걸면 원본을 그대로 쓴다. 용량은 커지지만 회차를 잃지는 않는다.
    echo "run_full: FIFO 를 만들지 못해 트레이스를 그대로 씁니다 (용량 주의)" >&2
    TRACE_TARGET="$LOG"
fi

RUN_RC=0
python3 "$HERE/uart_harness.py" \
    --console "$OUT" --input-log "$INLOG" --summary "$INSUM" \
    --plan "$WORKDIR/input_plan.json" \
    --timeout "$TIMEOUT" --cmd "$CMD" --surface "$SURFACE" \
    ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"} \
    -- "$QEMU" \
    -M "$MACHINE" -m "$MEM" -display none -serial stdio \
    -kernel "$CONTAINER" ${MEDIUM_ARGS[@]+"${MEDIUM_ARGS[@]}"} \
    -d int,in_asm,nochain -D "$TRACE_TARGET" \
    2> "$ERRF" || RUN_RC=$?

if [ -n "$FILTER_PID" ]; then
    exec 9>&-                       # 마지막 쓰기 쪽을 닫아 필터에 EOF 를 준다
    wait "$FILTER_PID" 2>/dev/null || true
    rm -f "$FIFO" 2>/dev/null || true
fi
tail -3 "$ERRF" 2>/dev/null || true

# --- What the input path actually did ------------------------------------
# `milestone=none` has two very different causes and they used to be the same
# observation: the gate polled and our bytes were not there (a harness failure),
# or the gate read them and the firmware booted on (a firmware observation).
# Sending a fixer after the first one spends a round on a fault that does not
# exist, so the round has to be able to tell them apart.
eval "$(python3 - "$INSUM" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
def b(key):
    return "true" if d.get(key) else "false"
def n(key):
    v = d.get(key)
    return "null" if v is None else str(int(v))
print(f'FP_INPUT_OFFERED={b("input_offered")}')
print(f'FP_PROMPT_SEEN={b("prompt_seen")}')
print(f'FP_COMMAND_SENT={b("command_sent")}')
print(f'FP_COMMAND_BLIND={b("command_blind")}')
print(f'FP_INPUT_STARVED={b("input_starved")}')
print(f'FP_SUPPLY_CAPPED={b("supply_capped")}')
print(f'FP_RX_REPORTED={b("rx_reported")}')
print(f'FP_RX_SERVED={n("rx_served")}')
print(f'FP_RX_POLLS={n("rx_polls")}')
print(f'FP_BYTES_SENT={n("bytes_sent")}')
PY
)"
# An absent summary means the harness itself did not finish; report it as unknown
# rather than as "no input was offered", which would be a claim we cannot make.
: "${FP_INPUT_OFFERED:=false}" "${FP_PROMPT_SEEN:=false}" "${FP_COMMAND_SENT:=false}"
: "${FP_COMMAND_BLIND:=false}" "${FP_INPUT_STARVED:=false}" "${FP_SUPPLY_CAPPED:=false}"
: "${FP_RX_REPORTED:=false}" "${FP_RX_SERVED:=null}" "${FP_RX_POLLS:=null}"
: "${FP_BYTES_SENT:=null}"

# --- Fingerprint: raw observations only, never a classification ---
# NOTE: grep -c exits 1 when the count is zero while still printing "0".
# Using `|| echo 0` would emit TWO lines and corrupt the JSON below, so assign
# first and fall back only on a non-zero exit.
# 필터가 원본 전체를 세므로 잘린 로그를 grep 하지 않는다. 필터를 못 걸었을 때만
# 로그에서 직접 센다.
EXC=$(python3 -c "
import json,sys
try: print(json.load(open('$TRACE_STATS'))['exceptions'])
except Exception: sys.exit(1)" 2>/dev/null) \
  || EXC=$(grep -c "Taking exception" "$LOG" 2>/dev/null) || EXC=0
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
# A goal is reached when the console shows text the FIRMWARE owns, on
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

# Highest rung wins, in ladder order. The ladder is derived per firmware, so it
# is passed in rather than hard-coded - the previous list named only the
# bootloader rungs, which meant a kernel-side milestone was matched into
# REACHED and then never selected as THE milestone.
RUNG_ORDER="${LADDER//,/ }"
[ -n "$RUNG_ORDER" ] || RUNG_ORDER="$SURFACE commands autoboot"
for m in $RUNG_ORDER; do
    case " $REACHED " in *" $m "*) MILESTONE="$m" ;; esac
done
MILESTONES_JSON=$(python3 -c 'import sys,json;print(json.dumps(sys.argv[1].split()))' "$REACHED")

# --- Storage readiness (partition table) -------------------------------------
# Grade C means the bootloader carries on into a normal boot, which requires
# reading the boot medium. The medium is modelled here, so
# an absent table means the synthesised image is wrong, not that the firmware
# failed. Recording which one it was keeps the loop from prescribing memory
# windows for a partition table that was never going to come.
#
# The strings are vendor-specific, so static-analyzer derives them into
# storage_tokens.txt as "<ok|missing><TAB><token>".
#
# ABSENCE IS NOT EVIDENCE. A round that died before storage init has printed
# neither token; calling that "missing" would block a grade on a boot that never
# got there. Unknown stays unknown, and unknown blocks nothing.
STORAGE="unknown"; STORAGE_TOKEN=""
SFILE="$WORKDIR/storage_tokens.txt"
if [ -s "$SFILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *"$TAB"*) ;; *) continue ;; esac
        s_state="${line%%$TAB*}"; s_token="${line#*$TAB}"
        [ -n "$s_token" ] || continue
        grep -qF "$s_token" "$OUT" 2>/dev/null || continue
        case "$s_state" in
            # A failed integrity check is decisive: the firmware looked and said no.
            missing) STORAGE="missing"; STORAGE_TOKEN="$s_token"; break ;;
            ok)      if [ "$STORAGE" = "unknown" ]; then
                         STORAGE="ok"; STORAGE_TOKEN="$s_token"
                     fi ;;
        esac
    done < "$SFILE"
fi
STORAGE_TOKEN_JSON="$(fp_json_escape "$STORAGE_TOKEN")"

# --- Timeout probe -----------------------------------------------------------
# TIMEOUT is a fixed wall-clock budget, so "the firmware hung" and "we killed a
# boot that was still working" produce the same observation: the console stopped
# growing. When the previous round ended at exactly the same console size, one
# longer run answers which it was. The probe never touches the fingerprint - it
# only reports timeout_bound, so the supervisor can tell a harness wall from a
# firmware wall instead of spending rounds on it.
#
# It used to also require zero exceptions. On S921N rounds 12-16 the console was
# byte-identical at 82,639 for five rounds while the trace carried 8/8/8/5/2
# exceptions, so the probe was skipped every time - and `false` was written as
# though it had been measured. An unmeasured value that reads as a measurement
# is worse than no value, so a skipped probe now reports null.
TIMEOUT_BOUND="null"; PROBE_BYTES=-1
if [ "$TIMEOUT_PROBE" != "0" ] && [ "$MILESTONE" = "none" ] \
   && [ "$FP_RUN_FAILED" -eq 0 ] && [ -f "$PREV" ]; then
    if [ "$(fp_prev_stuck "$PREV" "$CSZ")" = "yes" ]; then
        PROBE_OUT="$WORKDIR/07_logs/probe_${RUN_N}.txt"
        PROBE_LOG="$TRACE_DIR/probe_${RUN_N}.log"
        rm -f "$PROBE_OUT" "$PROBE_LOG"
        python3 "$HERE/uart_harness.py" \
            --console "$PROBE_OUT" --input-log "${INLOG}.probe" \
            --summary "${INSUM}.probe" \
            --plan "$WORKDIR/input_plan.json" \
            --timeout $((TIMEOUT * PROBE_MULT)) --cmd "$CMD" --surface "$SURFACE" \
            ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"} \
            -- "$QEMU" \
            -M "$MACHINE" -m "$MEM" -display none -serial stdio \
            -kernel "$CONTAINER" ${MEDIUM_ARGS[@]+"${MEDIUM_ARGS[@]}"} \
            -d int,nochain -D "$PROBE_LOG" \
            >/dev/null 2>&1 || true
        if [ -f "$PROBE_OUT" ]; then PROBE_BYTES=$(wc -c < "$PROBE_OUT" | tr -d ' '); else PROBE_BYTES=0; fi
        if [ "$PROBE_BYTES" -gt "$CSZ" ]; then TIMEOUT_BOUND="true"; else TIMEOUT_BOUND="false"; fi
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
  "run_fault": $([ "${FP_RUN_FAULT:-0}" -eq 1 ] && echo true || echo false),
  "run_fault_line": $(printf '%s' "${FP_RUN_FAULT_LINE:-}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),
  "run_error": "${RUN_ERROR_JSON}",
  "input": {
    "offered": ${FP_INPUT_OFFERED},
    "prompt_seen": ${FP_PROMPT_SEEN},
    "command_sent": ${FP_COMMAND_SENT},
    "command_blind": ${FP_COMMAND_BLIND},
    "starved": ${FP_INPUT_STARVED},
    "supply_capped": ${FP_SUPPLY_CAPPED},
    "rx_reported": ${FP_RX_REPORTED},
    "rx_served": ${FP_RX_SERVED},
    "rx_polls": ${FP_RX_POLLS},
    "bytes_sent": ${FP_BYTES_SENT},
    "summary": "${INSUM}",
    "log": "${INLOG}"
  },
  "storage": {
    "partition_table": "${STORAGE}",
    "token": "${STORAGE_TOKEN_JSON}"
  },
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
if [ "$FP_INPUT_STARVED" = "true" ]; then
    echo "★ 입력 굶음: 펌웨어가 콘솔을 ${FP_RX_POLLS} 회 폴링했는데 우리 바이트를 한 번도 읽지 않았습니다 (${INSUM}). 하니스 문제이며 펌웨어 정지점이 아닙니다." >&2
fi
if [ "$MILESTONE" = "none" ] && [ "$FP_PROMPT_SEEN" = "false" ] && [ "$FP_RX_REPORTED" = "true" ] \
   && [ "$FP_RX_SERVED" != "null" ] && [ "$FP_RX_SERVED" -gt 0 ]; then
    echo "· 입력 경로 확인: 펌웨어가 우리 바이트 ${FP_RX_SERVED} 개를 읽었고 그래도 표면이 안 열렸습니다 — 이것은 펌웨어 관측입니다." >&2
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
echo "run_fault=${FP_RUN_FAULT:-0}"
echo "timeout_bound=$TIMEOUT_BOUND"
echo "storage_partition_table=$STORAGE"
echo "input_offered=$FP_INPUT_OFFERED"
echo "prompt_seen=$FP_PROMPT_SEEN"
echo "command_sent=$FP_COMMAND_SENT"
echo "input_starved=$FP_INPUT_STARVED"
echo "rx_reported=$FP_RX_REPORTED"
echo "rx_served=$FP_RX_SERVED"
echo "rx_polls=$FP_RX_POLLS"
