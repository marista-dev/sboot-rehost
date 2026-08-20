#!/usr/bin/env bash
# check_env.sh - can this session actually do the work?
#
# Why this exists:
#   The pipeline runs QEMU, ninja and python3 through the agent's Bash tool. If
#   that shell cannot execute the work, every round fails for the same reason
#   and the loop burns its whole round budget without ever being able to make
#   progress. That is a precondition failure, not a goal judgement - so check it
#   once, before the loop, and stop with something actionable.
#
#   This is the one script that is bridge-aware rather than bridge-transparent.
#   The others source wsl_bridge.sh and simply wake up inside WSL; this one has
#   to report on the bridge itself, so it inspects the Windows side first and
#   only then hops over to probe the Linux toolchain.
#
# Usage:  check_env.sh <workdir> [track]
# Output: JSON on stdout. ok=false means the run must not start.

set -u

# --- Windows side: is there a bridge to cross? -------------------------------
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        if ! command -v wsl.exe >/dev/null 2>&1; then
            printf '{"ok":false,"os":"%s","bridged":false,"problems":[%s],"hint":"%s"}\n' \
                "$(uname -s)" \
                '"이 세션의 셸은 Windows(Git Bash)인데 wsl.exe 가 없어 Linux 로 건너갈 수 없습니다"' \
                'wsl --install -d Ubuntu-22.04 로 WSL 을 설치한 뒤 다시 시도하세요.'
            exit 0
        fi
        ;;
esac

# Hops into WSL when the caller's shell is Windows; no-op on Linux and macOS.
. "$(dirname "$0")/wsl_bridge.sh"

# --- Everything below runs on the Linux side ---------------------------------
WD="${1:-}"
# The unified flow walks one chain, so the environment it needs is the union of
# what the whole chain needs. DTB tooling was a track-2-only requirement; here
# the bootloader assembles a DTB for the kernel it loads, so it is needed
# whenever the target goes past the bootloader.
TARGET="$(printf '%s' "${2:-F2}" | tr '[:lower:]' '[:upper:]')"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"

problems=""
add() { problems="${problems:+$problems|}$1"; }

KERNEL="$(uname -s 2>/dev/null || echo unknown)"
WSL=false
grep -qi microsoft /proc/version 2>/dev/null && WSL=true

case "$KERNEL" in
    Linux|Darwin) ;;
    *) add "알 수 없는 셸 환경($KERNEL)입니다" ;;
esac

if [ -n "$WD" ] && [ ! -d "$WD" ]; then
    add "워크스페이스 경로가 이 셸에서 보이지 않습니다: $WD"
fi

if [ ! -x "$QEMU" ] && ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    add "qemu-system-aarch64 를 찾을 수 없습니다 (QEMU=$QEMU)"
fi
command -v python3 >/dev/null 2>&1 || add "python3 가 없습니다"
command -v ninja   >/dev/null 2>&1 || add "ninja 가 없습니다 (머신 재빌드에 필요)"
python3 -c 'import capstone' >/dev/null 2>&1 || add "python capstone 모듈이 없습니다 (정적 도출에 필요)"
if [ "$TARGET" != "F1" ]; then
    command -v fdtdump >/dev/null 2>&1 || command -v dtc >/dev/null 2>&1 \
        || add "dtc/fdtdump 가 없습니다 (DTB 파싱에 필요 — 목표 $TARGET 은 커널 구간을 포함합니다)"
fi

emit_with_python() {
    python3 - "$KERNEL" "$problems" "$WSL" <<'PY'
import json, sys
kernel, raw, wsl = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
problems = [p for p in raw.split("|") if p]
print(json.dumps({
    "ok": not problems,
    "os": kernel,
    "wsl": wsl,
    "problems": problems,
    "hint": ("필요한 도구는 /sboot-rehost:rehost-init 이 설치합니다. "
             "직접 설치하려면 scripts/setup_env.sh 를 참고하세요."
             if problems else ""),
}, ensure_ascii=False))
PY
}

if ! emit_with_python 2>/dev/null; then
    printf '{"ok":false,"os":"%s","wsl":%s,"problems":["python3 가 없어 환경 점검조차 불가"],"hint":"WSL 에 python3 를 설치하세요"}\n' \
        "$KERNEL" "$WSL"
fi
