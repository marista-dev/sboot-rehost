# wsl_bridge.sh - run this script inside WSL when the caller's shell is Windows.
#
# Sourced (not executed) as the first line of every scripts/*.sh:
#
#     . "$(dirname "$0")/wsl_bridge.sh"
#
# Why a guard inside the scripts rather than a wrapper at the call sites:
#   the call sites are pipeline.js, six skills and four agent prompts. Three of
#   those are prose, so a "remember to prefix the command" rule would be a
#   convention rather than a mechanism, and conventions rot silently. Every path
#   into this plugin ends at scripts/, so guarding here covers all of them and
#   the callers keep saying `bash .../run_full.sh` exactly as before.
#
# Why `wsl.exe -e` and not `wsl.exe -lc "..."`:
#   -e passes argv straight through, so nothing is re-parsed by a second shell.
#   A -lc form would re-expand strings that already carry shq() quoting, which
#   is how quoting bugs get reintroduced.
#
# On Linux and macOS this is a no-op: the guard returns before doing anything.

case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;   # Windows shell (Git Bash) - bridge below
    *) return 0 2>/dev/null || exit 0 ;;
esac

# Already bridged once? Then we are inside WSL and uname lied. Never recurse.
[ -n "${REHOST_BRIDGED:-}" ] && { return 0 2>/dev/null || exit 0; }

if ! command -v wsl.exe >/dev/null 2>&1; then
    echo "BLOCKED_ENV: 이 셸은 Windows(Git Bash)인데 wsl.exe 를 찾을 수 없습니다." >&2
    echo "  WSL 을 설치하거나(wsl --install -d Ubuntu-22.04)," >&2
    echo "  WSL 터미널에서 claude 를 실행하세요." >&2
    exit 78   # EX_CONFIG
fi

# Windows path -> WSL path. Handles the three forms that reach us:
#   C:\dir\file  /  C:/dir/file   (Windows, from CLAUDE_PLUGIN_ROOT and cwd)
#   /c/dir/file                   (Git Bash's own drive mapping)
# Anything else - flags, key=value pairs, already-Linux paths - passes through.
__to_wsl() {
    case "$1" in
        /mnt/*|/home/*|/root/*|/usr/*|/tmp/*|/var/*)
            printf '%s' "$1" ;;
        [A-Za-z]:[/\\]*)
            __drive=$(printf '%s' "${1%%:*}" | tr 'A-Z' 'a-z')
            __rest=${1#*:}
            printf '/mnt/%s%s' "$__drive" "$(printf '%s' "$__rest" | tr '\\' '/')" ;;
        /[A-Za-z]/*)
            printf '/mnt%s' "$1" ;;
        *)
            printf '%s' "$1" ;;
    esac
}

# Translate this script's own path plus every argument. Arguments are rebuilt
# one at a time through the positional parameters so that argument boundaries
# survive: "C:\Users\me\My Folder\bl.bin" must stay one argument, not three.
__self=$(__to_wsl "$0")
__count=$#
while [ "$__count" -gt 0 ]; do
    __a=$1; shift
    set -- "$@" "$(__to_wsl "$__a")"
    __count=$((__count - 1))
done

# `-d` only when the caller pinned a distribution; otherwise use the default.
if [ -n "${REHOST_WSL_DISTRO:-}" ]; then
    REHOST_BRIDGED=1 exec wsl.exe -d "$REHOST_WSL_DISTRO" -e bash "$__self" "$@"
else
    REHOST_BRIDGED=1 exec wsl.exe -e bash "$__self" "$@"
fi
