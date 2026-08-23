#!/usr/bin/env bash
# fingerprint_lib.sh - fingerprint extraction shared by run_full.sh and run_full.sh.
# Sourced, never executed.
#
# Why this file exists
# --------------------
# Both run scripts used to answer "where did it stop?" with `grep FAR | tail -1`.
# In a nested-abort storm that address is the LAST recursion victim, not the
# fault that started it: the exception handler faults on its own context save,
# so FAR walks down 0x20 per iteration for millions of iterations and stops
# wherever the wall clock happened to cut the run. The consequences were both
# analytic and mechanical:
#
#   - the classifier was handed the least informative end of the trace, so it
#     answered "unknown" or blamed the address the recursion had reached;
#   - the fingerprint moved every round even when nothing changed, so stall,
#     oscillation, exhaustion and layer review could never fire.
#
# The originating exception - the FIRST `Taking exception` block - is stable and
# is the actual stop point. Everything here exists to extract it.

# fp_origin <trace_log> <block_out>
#   Writes the first exception block to <block_out> and sets:
#     FP_ORIGIN_TYPE  exception name, e.g. "Data Abort"
#     FP_ORIGIN_ESR / FP_ORIGIN_FAR / FP_ORIGIN_ELR
#   All default to "none" when the trace has no exception at all (a hang).
fp_origin() {
    local log="$1" block="$2"
    FP_ORIGIN_TYPE="none"; FP_ORIGIN_ESR="none"
    FP_ORIGIN_FAR="none";  FP_ORIGIN_ELR="none"
    : > "$block"
    [ -s "$log" ] || return 0

    # The block is the first "Taking exception" line plus its continuation lines,
    # cut at the second one. QEMU prints ESR/FAR/ELR as `...with X 0x...` right
    # after, so a 12-line window covers it with room for format drift.
    awk '
        /Taking exception/ { if (seen) exit; seen = 1 }
        seen { print; if (++n >= 12) exit }
    ' "$log" > "$block" 2>/dev/null || true
    [ -s "$block" ] || return 0

    FP_ORIGIN_TYPE=$(sed -n 's/.*Taking exception [0-9]* \[\([^]]*\)\].*/\1/p' "$block" | head -1)
    [ -n "$FP_ORIGIN_TYPE" ] || FP_ORIGIN_TYPE="none"
    # ESR prints as `ESR 0x25/0x96000046` - both halves are part of the identity.
    FP_ORIGIN_ESR=$(grep -ohE "ESR 0x[0-9a-fA-Fx/]+" "$block" 2>/dev/null | head -1 | awk '{print $2}')
    FP_ORIGIN_FAR=$(grep -ohE "FAR 0x[0-9a-fA-F]+"   "$block" 2>/dev/null | head -1 | awk '{print $2}')
    FP_ORIGIN_ELR=$(grep -ohE "ELR 0x[0-9a-fA-F]+"   "$block" 2>/dev/null | head -1 | awk '{print $2}')
    FP_ORIGIN_ESR="${FP_ORIGIN_ESR:-none}"
    FP_ORIGIN_FAR="${FP_ORIGIN_FAR:-none}"
    FP_ORIGIN_ELR="${FP_ORIGIN_ELR:-none}"
    return 0
}

# fp_console_uniq <console_file>  -> echoes the count of distinct non-blank lines
#
# Console BYTES cannot tell "the boot got further" from "a retry loop printed the
# same line 200,000 times" - one run in the S921N log spent 394 KB on a single
# repeated I2C error. Distinct lines can, so this is the progress measure the
# loop reports and the stop report quotes when no milestone was ever reached.
fp_console_uniq() {
    local out="$1"
    if [ -s "$out" ]; then
        LC_ALL=C sort -u "$out" 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# fp_run_verdict <rc> <trace_log> <console_bytes> <stderr_file>
#   Sets FP_RUN_FAILED (0|1) and FP_RUN_ERROR.
#
# A QEMU that never started used to look exactly like a clean round: the pipe to
# `tail` swallowed its exit code, and the fingerprint was written as all zeros.
# All-zero fingerprints are perfectly stable, so the stop conditions read them as
# a stall and declared EXHAUSTED - "structurally unreachable" - after eight
# rounds that had never run anything. A harness failure must never be reported as
# a verdict about the firmware.
fp_run_verdict() {
    local rc="$1" log="$2" csz="$3" errf="${4:-}"
    FP_RUN_FAILED=0; FP_RUN_ERROR=""
    # 124/137 are `timeout` killing the guest, which is how every round ends.
    case "$rc" in
        0|124|137) ;;
        *)
            FP_RUN_FAILED=1
            FP_RUN_ERROR="QEMU 종료코드 ${rc}"
            if [ -n "$errf" ] && [ -s "$errf" ]; then
                FP_RUN_ERROR="$FP_RUN_ERROR: $(tr '\n' ' ' < "$errf" | tail -c 200)"
            fi
            return 0
            ;;
    esac
    if [ ! -s "$log" ] && [ "${csz:-0}" -eq 0 ]; then
        FP_RUN_FAILED=1
        FP_RUN_ERROR="트레이스와 콘솔이 모두 0바이트 — QEMU 가 실제로 실행되지 않았습니다 (경로·인자 확인)"
    fi
    return 0
}

# fp_prev_stuck <prev_fingerprint_json> <console_bytes>  -> echoes yes|no
#
# "The previous round ended at exactly this console size." That is the signature
# of a boot that has not moved, and the only case where spending one longer run
# to separate a firmware wall from the wall-clock budget is worth it.
#
# It also demanded zero exceptions once. A firmware can sit at the same console
# size for rounds while its trace still carries a handful of exceptions - the
# S921N run did exactly that for five rounds at 82,639 bytes with 8/8/8/5/2 - and
# that extra condition skipped the probe on precisely the rounds it was for.
fp_prev_stuck() {
    local prev="$1" csz="$2"
    [ -f "$prev" ] || { echo no; return 0; }
    python3 - "$prev" "$csz" <<'PY' 2>/dev/null || echo no
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("no"); raise SystemExit
print("yes" if int(d.get("console_bytes", -1)) == int(sys.argv[2]) else "no")
PY
}

# fp_json_escape <text>  -> stdout, safe to embed between JSON quotes
fp_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'
}
