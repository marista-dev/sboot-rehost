#!/usr/bin/env bash
# check_env.sh - can this shell actually do the work?
#
# Why this exists:
#   The pipeline runs QEMU, ninja and python3 through the agent's Bash tool. On
#   native Windows that tool is Git Bash, which cannot see /mnt/c or run a Linux
#   QEMU, so every round fails for the same reason and the loop burns its whole
#   round budget without ever being able to make progress.
#
#   An environment that cannot execute the work at all is not a goal judgement
#   and not "moves exhausted" - it is a precondition failure. Detect it once,
#   before the loop, and stop with something actionable.
#
# Usage:
#   check_env.sh <workdir> [track]
#
# Output: JSON on stdout. ok=false means the run must not start.

set -u

WD="${1:-}"
TRACK="${2:-1}"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"

problems=""
add() { problems="${problems:+$problems|}$1"; }

KERNEL="$(uname -s 2>/dev/null || echo unknown)"

# --- 1. Is this a POSIX shell that can run Linux binaries? ---
case "$KERNEL" in
    MINGW*|MSYS*|CYGWIN*)
        add "이 세션의 Bash 도구가 Git Bash($KERNEL)입니다. Linux QEMU 를 실행할 수 없고 /mnt/c 도 보이지 않습니다. WSL 터미널에서 claude 를 실행하세요"
        ;;
    Linux|Darwin) ;;
    *)  add "알 수 없는 셸 환경($KERNEL)입니다" ;;
esac

# --- 2. Workspace reachable from this shell? ---
if [ -n "$WD" ] && [ ! -d "$WD" ]; then
    add "워크스페이스 경로가 이 셸에서 보이지 않습니다: $WD"
fi

# --- 3. Toolchain ---
if [ ! -x "$QEMU" ] && ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    add "qemu-system-aarch64 를 찾을 수 없습니다 (QEMU=$QEMU)"
fi
command -v python3 >/dev/null 2>&1 || add "python3 가 없습니다"
command -v ninja   >/dev/null 2>&1 || add "ninja 가 없습니다 (머신 재빌드에 필요)"
python3 -c 'import capstone' >/dev/null 2>&1 || add "python capstone 모듈이 없습니다 (정적 도출에 필요)"
if [ "$TRACK" = "2" ]; then
    command -v fdtdump >/dev/null 2>&1 || command -v dtc >/dev/null 2>&1 \
        || add "dtc/fdtdump 가 없습니다 (트랙 2 DTB 파싱에 필요)"
fi

emit_with_python() {
    python3 - "$KERNEL" "$problems" <<'PY'
import json, sys
kernel, raw = sys.argv[1], sys.argv[2]
problems = [p for p in raw.split("|") if p]
print(json.dumps({
    "ok": not problems,
    "os": kernel,
    "problems": problems,
    "hint": ("WSL 터미널에서 claude 를 실행하면 해결됩니다 — "
             "Claude Code 공식 문서도 Linux 툴체인을 쓸 때는 WSL 안에서 "
             "설치·실행하도록 안내합니다." if problems else ""),
}, ensure_ascii=False))
PY
}

# python3 자체가 없을 수도 있으므로 그때는 최소한의 JSON 이라도 낸다.
if ! emit_with_python 2>/dev/null; then
    printf '{"ok":false,"os":"%s","problems":["python3 가 없어 환경 점검조차 불가"],"hint":"WSL 터미널에서 claude 를 실행하세요"}\n' "$KERNEL"
fi
