#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
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
#   <workdir>/fingerprint.json                   this round's fingerprint
#   ~/rehost/_traces/kboot_<run_n>.log           full trace     (WSL ext4)
#
# stdout: console= summary= trace= exceptions= console_size= far= elr= milestone= injected=
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
LOG="$TRACE_DIR/kboot_${RUN_N}.log"
rm -f "$OUT" "$SUM" "$LOG"

python3 "$HERE/record.py" "$WORKDIR" start "kboot_${RUN_N}" >/dev/null 2>&1 || true

ARGS=( -M "$MACHINE" -cpu "$CPU" -smp "$SMP" -m "$MEM" -nographic -kernel "$IMAGE" )
[ -n "$DTB" ]        && ARGS+=( -dtb "$DTB" )
# -s, not -f: system-as-root firmware ships a zero-byte initramfs placeholder
# (boot.img ramdisk_size=0). Passing an empty -initrd to QEMU is not harmless.
[ -s "$INITRD" ]     && ARGS+=( -initrd "$INITRD" )
[ -n "${CMDLINE:-}" ] && ARGS+=( -append "$CMDLINE" )
ARGS+=( -serial "file:$OUT" -d "${DFLAGS:-unimp,guest_errors,int}" -D "$LOG" )

timeout "$TIMEOUT" "$QEMU" "${ARGS[@]}" </dev/null 2>&1 | tail -3 || true

grep -E "Taking exception|Internal error|Kernel panic|Run /init|erofs: \(device dm-|] sda: sda|Power mode|smc" \
    "$LOG" "$OUT" 2>/dev/null | tail -60 > "$SUM" || true

# --- Fingerprint: raw observations only ---
# grep -c exits 1 on a zero count, so assign first and fall back on failure.
EXC=$(grep -hcE "Taking exception|Internal error|Kernel panic" "$LOG" "$OUT" 2>/dev/null \
      | awk '{s+=$1} END{print s+0}') || EXC=0
[ -n "$EXC" ] || EXC=0
if [ -f "$OUT" ]; then CSZ=$(wc -c < "$OUT" | tr -d ' '); else CSZ=0; fi
FAR=$(grep -ohE "FAR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
ELR=$(grep -ohE "ELR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
FAR="${FAR:-none}"; ELR="${ELR:-none}"

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

# The injected token comes from log text, so it must be escaped before it lands in JSON.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }
INJECTED_TOKEN_JSON="$(json_escape "$INJECTED_TOKEN")"

cat > "$WORKDIR/fingerprint.json" <<JSON
{
  "round": ${RUN_N},
  "track": 2,
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
    phase=Run round="${RUN_N}" event=kboot_end timer="kboot_${RUN_N}" \
    exceptions="${EXC}" console_bytes="${CSZ}" milestone="${MILESTONE}" \
    injected="${INJECTED}" >/dev/null 2>&1 || true

if [ "$INJECTED" = "true" ]; then
    echo "★ 출처 게이트: '${INJECTED_TOKEN}' 문자열이 머신 소스에 있습니다 — 커널이 아니라 우리가 찍은 것이므로 도달로 인정하지 않습니다." >&2
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
