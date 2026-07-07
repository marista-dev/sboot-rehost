#!/usr/bin/env bash
# run_kernel.sh — 트랙 2 표준 커널 직부팅 실행 인자 (Path A).
# pipeline_kernel.js 가 회차마다 호출.
#
# 사용법:
#   run_kernel.sh <workdir> <machine_name> <run_n>
# 필요 파일 (workdir 기준, INPUT.md 에서 경로 확인):
#   fw/Image.patched  fw/<soc>.dtb  fw/initramfs.cpio.gz
# 환경변수 (선택):
#   CMDLINE   커널 cmdline (기본: DTB /chosen 사용)
#   SMP/MEM   코어 수 / RAM (기본 8 / 4G)
#   EUFS_LU_IMAGE / EUFS_LBS   K3 백킹 디스크 (있으면 스토리지 HCI 로 전달)
#
# 출력:
#   <workdir>/07_logs/kboot_<run_n>.txt   (콘솔)
#   <workdir>/07_logs/kboot_<run_n>.log   (qemu 트레이스)
set -e
WORKDIR="$1"; MACHINE="$2"; RUN_N="${3:-1}"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-200}"
CPU="${CPU:-cortex-a76}"; SMP="${SMP:-8}"; MEM="${MEM:-4G}"

[ -z "$WORKDIR" -o -z "$MACHINE" ] && { echo "Usage: $0 <workdir> <machine> <run_n>" >&2; exit 1; }
[ -x "$QEMU" ] || { echo "ERROR: QEMU 없음: $QEMU" >&2; exit 2; }

FW="$WORKDIR/fw"
IMAGE="${IMAGE:-$FW/Image.patched}"; DTB="${DTB:-$(ls "$FW"/*.dtb 2>/dev/null | head -1)}"
INITRD="${INITRD:-$FW/initramfs.cpio.gz}"
[ -f "$IMAGE" ] || { echo "ERROR: $IMAGE 없음 (patch_kernel.py 먼저)" >&2; exit 3; }

mkdir -p "$WORKDIR/07_logs"
OUT="$WORKDIR/07_logs/kboot_${RUN_N}.txt"; LOG="$WORKDIR/07_logs/kboot_${RUN_N}.log"
rm -f "$OUT" "$LOG"

ARGS=( -M "$MACHINE" -cpu "$CPU" -smp "$SMP" -m "$MEM" -nographic
       -kernel "$IMAGE" )
[ -n "$DTB" ]    && ARGS+=( -dtb "$DTB" )
[ -f "$INITRD" ] && ARGS+=( -initrd "$INITRD" )
[ -n "$CMDLINE" ] && ARGS+=( -append "$CMDLINE" )
ARGS+=( -serial "file:$OUT" -d unimp,guest_errors,int -D "$LOG" )

# EUFS_* 는 환경변수로 그대로 QEMU 프로세스에 상속 (스토리지 HCI 모델이 getenv)
timeout "$TIMEOUT" "$QEMU" "${ARGS[@]}" </dev/null 2>&1 | tail -3 || true

EXC=$(grep -cE "Taking exception|Internal error|Kernel panic" "$LOG" "$OUT" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
MNT=$(grep -cE "erofs: \(device dm-|] sda: sda" "$OUT" 2>/dev/null || echo 0)
echo "console=$OUT"
echo "log=$LOG"
echo "faults=$EXC"
echo "storage_progress=$MNT"
