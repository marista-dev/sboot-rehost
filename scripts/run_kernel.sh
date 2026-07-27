#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
. "$(dirname "$0")/fingerprint_lib.sh"
# run_kernel.sh - Track 2 (kernel + storage): one round of execution.
# Extracts the raw fingerprint and enforces the provenance gate.
# Called by workflows/pipeline.js once per round.
#
# Usage:
#   run_kernel.sh <workdir> <machine_name> <run_n>
# Required files (relative to workdir):
#   fw/Image.patched  fw/<soc>.dtb  fw/initramfs.cpio.gz
# Optional environment:
#   CMDLINE   kernel cmdline (default: use DTB /chosen)
#   SMP/MEM   core count / RAM (default 8 / 4G)
#   EUFS_LU_IMAGE / EUFS_LBS   K3 backing disk (read by the storage HCI model)
#
# Output files:
#   <workdir>/07_logs/kboot_<run_n>.txt          console        (local)
#   <workdir>/07_logs/kboot_<run_n>.summary.txt  key stop points (local)
#   <workdir>/07_logs/korigin_<run_n>.txt        originating exception block
#   <workdir>/fingerprint.json                   this round's fingerprint
#   ~/rehost/_traces/kboot_<run_n>.log           full trace     (WSL ext4)
#
# stdout: console= summary= trace= exceptions= console_size= far= elr= milestone=
#         injected= origin_far= origin_elr= console_uniq= run_failed=
#
# Provenance gate (honesty rule 7): a milestone line only counts when the KERNEL
# printed it. If the same text exists in the machine source, the milestone is
# dropped and injected=true is reported.

set -u

WORKDIR="$1"; MACHINE="$2"; RUN_N="${3:-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-200}"
CPU="${CPU:-cortex-a76}"; SMP="${SMP:-8}"; MEM="${MEM:-4G}"
# One extra, longer run - only when a hang has not moved since the last round.
TIMEOUT_PROBE="${TIMEOUT_PROBE:-1}"
PROBE_MULT="${PROBE_MULT:-2}"

[ -z "$WORKDIR" -o -z "$MACHINE" ] && { echo "Usage: $0 <workdir> <machine> <run_n>" >&2; exit 1; }
[ -x "$QEMU" ] || { echo "ERROR: QEMU 실행 파일을 찾을 수 없습니다: $QEMU" >&2; exit 2; }

FW="$WORKDIR/fw"
IMAGE="${IMAGE:-$FW/Image.patched}"
DTB="${DTB:-$(ls "$FW"/*.dtb 2>/dev/null | head -1)}"
INITRD="${INITRD:-$FW/initramfs.cpio.gz}"
[ -f "$IMAGE" ] || { echo "ERROR: $IMAGE 가 없습니다 (patch_kernel.py 를 먼저 실행하세요)" >&2; exit 3; }

mkdir -p "$WORKDIR/07_logs"
TRACE_DIR="${TRACE_DIR:-$HOME/rehost/_traces}"; mkdir -p "$TRACE_DIR"
OUT="$WORKDIR/07_logs/kboot_${RUN_N}.txt"
SUM="$WORKDIR/07_logs/kboot_${RUN_N}.summary.txt"
ORIGIN="$WORKDIR/07_logs/korigin_${RUN_N}.txt"
ERRF="$WORKDIR/07_logs/qemu_k${RUN_N}.stderr.txt"
LOG="$TRACE_DIR/kboot_${RUN_N}.log"
rm -f "$OUT" "$SUM" "$LOG" "$ORIGIN" "$ERRF"

PREV="$WORKDIR/fingerprint.prev.json"
[ -f "$WORKDIR/fingerprint.json" ] && cp "$WORKDIR/fingerprint.json" "$PREV" 2>/dev/null || true

python3 "$HERE/record.py" "$WORKDIR" start "kboot_${RUN_N}" >/dev/null 2>&1 || true

ARGS=( -M "$MACHINE" -cpu "$CPU" -smp "$SMP" -m "$MEM" -nographic -kernel "$IMAGE" )
[ -n "$DTB" ]        && ARGS+=( -dtb "$DTB" )
# -s, not -f: system-as-root firmware ships a zero-byte initramfs placeholder
# (boot.img ramdisk_size=0). Passing an empty -initrd to QEMU is not harmless.
[ -s "$INITRD" ]     && ARGS+=( -initrd "$INITRD" )
[ -n "${CMDLINE:-}" ] && ARGS+=( -append "$CMDLINE" )
ARGS+=( -serial "file:$OUT" -d "${DFLAGS:-unimp,guest_errors,int}" -D "$LOG" )

# The exit code matters: piping it into `tail` threw it away, so a QEMU that
# never started reported success and the round looked clean.
RUN_RC=0
timeout "$TIMEOUT" "$QEMU" "${ARGS[@]}" </dev/null > "$ERRF" 2>&1 || RUN_RC=$?
tail -3 "$ERRF" 2>/dev/null || true

# --- Fingerprint: raw observations only ---
# grep -c exits 1 on a zero count, so assign first and fall back on failure.
EXC=$(grep -hcE "Taking exception|Internal error|Kernel panic" "$LOG" "$OUT" 2>/dev/null \
      | awk '{s+=$1} END{print s+0}') || EXC=0
[ -n "$EXC" ] || EXC=0
if [ -f "$OUT" ]; then CSZ=$(wc -c < "$OUT" | tr -d ' '); else CSZ=0; fi
CUNIQ=$(fp_console_uniq "$OUT")
# Last FAR/ELR in the log: kept for the record, not used as the stop point's
# identity - under a nested abort it is only where the recursion ran out of time.
FAR=$(grep -ohE "FAR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
ELR=$(grep -ohE "ELR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
FAR="${FAR:-none}"; ELR="${ELR:-none}"

# The originating exception - the one that actually needs a fix.
fp_origin "$LOG" "$ORIGIN"
fp_run_verdict "$RUN_RC" "$LOG" "$CSZ" "$ERRF"

{
    echo "=== 최초 예외 (첫 Taking exception 블록) ==="
    if [ -s "$ORIGIN" ]; then cat "$ORIGIN"; else echo "(예외 없음 — hang 또는 정상 진행)"; fi
    echo
    echo "=== 마지막 60줄 (트레이스 마지막 — 근본 원인이 아닐 수 있음) ==="
    grep -E "Taking exception|Internal error|Kernel panic|Run /init|erofs: \(device dm-|] sda: sda|Power mode|smc" \
        "$LOG" "$OUT" 2>/dev/null | tail -60
} > "$SUM" 2>/dev/null || true

# --- Milestone ladder + provenance gate ---
# Checked from lowest to highest; the last one that passes is the reached milestone.
SRC_DIR="$WORKDIR/06_machine"
MILESTONE="none"; INJECTED="false"; INJECTED_TOKEN=""; REACHED=""

check_milestone() {   # $1 = milestone name, $2 = regex the KERNEL must print
    local name="$1" pattern="$2" line
    line=$(grep -hoE "$pattern" "$OUT" "$LOG" 2>/dev/null | head -1)
    [ -n "$line" ] || return 1
    if grep -qF "$line" "$SRC_DIR"/*.c 2>/dev/null; then
        INJECTED="true"; INJECTED_TOKEN="$line"
        return 1
    fi
    MILESTONE="$name"          # highest rung cleared so far
    REACHED="$REACHED $name"   # every rung cleared, for ladders that skip rungs
    return 0
}

# Wording differs by firmware: EROFS over dm-linear on a super image, or plain
# ext4 on a raw block device; ufshcd core or the vendor glue driver. Encoding
# one device's shape here would strand every firmware with another shape.
check_milestone userspace     "Run /init|init: init first stage started"
check_milestone rootfs        "erofs: \(device dm-[0-9]+\): mounted|EXT4-fs \([^)]+\): mounted filesystem|VFS: Mounted root \([a-z0-9]+ filesystem\)"
check_milestone link_up       "scsi host[0-9]+: ufshcd|UFS link established"
check_milestone power_mode    "Power mode change\([0-9]+\)"
check_milestone scsi_attach   "\[sda\] Attached SCSI disk"
check_milestone partitions_up "sda: sda[0-9]"
check_milestone super_mounted "supermount: SUCCESS"

# Injection is dominant: once any milestone line is found in the machine source
# the console is contaminated, so nothing is credited even if a higher rung looks
# clean. A false "not reached" costs rounds; a false "reached" fakes success.
# On an innocent match, rename the string in the machine source - the warning
# below names the exact line.
if [ "$INJECTED" = "true" ]; then
    MILESTONE="none"; REACHED=""
fi

# Report EVERY rung cleared, not just the highest. A goal ladder may skip rungs
# (K3 has no `rootfs`), and reporting only the top one would hide a lower rung
# that the ladder does contain, stranding the loop on a goal already met.
MILESTONES_JSON=$(python3 -c 'import sys,json;print(json.dumps(sys.argv[1].split()))' "$REACHED")

# --- Timeout probe -----------------------------------------------------------
# A kernel that is still booting and a kernel that hung look identical once the
# wall clock kills the run. One longer run, taken only when the previous round
# ended at exactly the same console size with no exception, tells them apart.
TIMEOUT_BOUND="false"; PROBE_BYTES=-1
if [ "$TIMEOUT_PROBE" != "0" ] && [ "$MILESTONE" = "none" ] && [ "$EXC" -eq 0 ] \
   && [ "$FP_RUN_FAILED" -eq 0 ] && [ "$(fp_prev_stuck "$PREV" "$CSZ")" = "yes" ]; then
    PROBE_OUT="$WORKDIR/07_logs/kprobe_${RUN_N}.txt"
    PROBE_ARGS=()
    for a in "${ARGS[@]}"; do
        case "$a" in
            "file:$OUT") PROBE_ARGS+=( "file:$PROBE_OUT" );;
            "$LOG")      PROBE_ARGS+=( "/dev/null" );;
            *)           PROBE_ARGS+=( "$a" );;
        esac
    done
    rm -f "$PROBE_OUT"
    timeout $((TIMEOUT * PROBE_MULT)) "$QEMU" "${PROBE_ARGS[@]}" </dev/null >/dev/null 2>&1 || true
    if [ -f "$PROBE_OUT" ]; then PROBE_BYTES=$(wc -c < "$PROBE_OUT" | tr -d ' '); else PROBE_BYTES=0; fi
    [ "$PROBE_BYTES" -gt "$CSZ" ] && TIMEOUT_BOUND="true"
fi

INJECTED_TOKEN_JSON="$(fp_json_escape "$INJECTED_TOKEN")"
RUN_ERROR_JSON="$(fp_json_escape "$FP_RUN_ERROR")"
ORIGIN_TYPE_JSON="$(fp_json_escape "$FP_ORIGIN_TYPE")"

cat > "$WORKDIR/fingerprint.json" <<JSON
{
  "round": ${RUN_N},
  "track": 2,
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
    phase=Run round="${RUN_N}" event=kboot_end timer="kboot_${RUN_N}" \
    exceptions="${EXC}" console_bytes="${CSZ}" console_uniq="${CUNIQ}" \
    origin_far="${FP_ORIGIN_FAR}" origin_elr="${FP_ORIGIN_ELR}" \
    milestone="${MILESTONE}" injected="${INJECTED}" \
    run_failed="$([ "$FP_RUN_FAILED" -eq 1 ] && echo true || echo false)" >/dev/null 2>&1 || true

if [ "$INJECTED" = "true" ]; then
    echo "★ 출처 게이트: '${INJECTED_TOKEN}' 문자열이 머신 소스에 있습니다 — 커널이 아니라 우리가 찍은 것이므로 도달로 인정하지 않습니다." >&2
fi
if [ "$FP_RUN_FAILED" -eq 1 ]; then
    echo "★ 실행 실패: ${FP_RUN_ERROR}" >&2
fi
if [ "$TIMEOUT_BOUND" = "true" ]; then
    echo "★ 타임아웃 한계: ${TIMEOUT}s 로는 끊겼지만 $((TIMEOUT * PROBE_MULT))s 에서는 콘솔이 더 나왔습니다 (${CSZ}B → ${PROBE_BYTES}B)." >&2
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
