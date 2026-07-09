#!/usr/bin/env bash
# run_qemu.sh — sboot-rehost 표준 QEMU 실행 인자.
# iter-loop.js workflow 가 회차마다 호출.
#
# 사용법:
#   run_qemu.sh <workdir> <machine_name> <bl3_path> <cmd> <run_n>
#
# 출력:
#   <workdir>/07_logs/console_<run_n>.txt   (UART 출력)
#   <workdir>/07_logs/run_<run_n>.log       (qemu -d 트레이스)
#   stdout: console=<path>, log=<path>, exceptions=<n>, console_size=<n>

set -e

WORKDIR="$1"
MACHINE="$2"
BL3="$3"
CMD="${4:-help}"
RUN_N="${5:-1}"

QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-8}"

if [[ -z "$WORKDIR" || -z "$MACHINE" || -z "$BL3" ]]; then
    echo "Usage: $0 <workdir> <machine_name> <bl3_path> <cmd> <run_n>" >&2
    exit 1
fi

if [[ ! -x "$QEMU" ]]; then
    echo "ERROR: QEMU 실행파일 없음: $QEMU" >&2
    exit 2
fi

mkdir -p "$WORKDIR/07_logs"
# 대용량 -d 트레이스는 WSL ext4 (쓰기 빠름). 기록/해결과정(콘솔·요약)은 로컬(Windows) 07_logs.
TRACE_DIR="${TRACE_DIR:-$HOME/rehost/_traces}"; mkdir -p "$TRACE_DIR"
OUT="$WORKDIR/07_logs/console_${RUN_N}.txt"        # 로컬: 콘솔 증거 (사용자 확인)
SUM="$WORKDIR/07_logs/run_${RUN_N}.summary.txt"    # 로컬: 핵심 fault 요약 (사용자 확인)
LOG="$TRACE_DIR/run_${RUN_N}.log"                  # WSL: 대용량 전체 트레이스

rm -f "$OUT" "$SUM" "$LOG"

timeout "$TIMEOUT" "$QEMU" \
    -M "$MACHINE" -m 512M -nographic \
    -kernel "$BL3" -append "$CMD" \
    -serial "file:$OUT" \
    -d int,in_asm,nochain -D "$LOG" \
    2>&1 | tail -3 || true

# 로컬 요약: 핵심 정지점 라인만 (사용자가 로컬에서 해결과정 확인)
grep -E "Taking exception|FAR|ELR|ESR|UPLOAD|E_SYNC|panic|abort|smc" "$LOG" 2>/dev/null | tail -60 > "$SUM" || true

EXC=$(grep -c "Taking exception" "$LOG" 2>/dev/null || echo 0)
CSZ=$(wc -c < "$OUT" 2>/dev/null || echo 0)

echo "console=$OUT"          # 로컬 (Windows)
echo "summary=$SUM"          # 로컬 (Windows) — 핵심 fault
echo "trace=$LOG"            # WSL — 대용량 전체 트레이스
echo "exceptions=$EXC"
echo "console_size=$CSZ"
