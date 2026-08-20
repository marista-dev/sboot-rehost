#!/usr/bin/env bash
# check_version.sh - refuse to run a stale copy of this plugin.
#
# ★ Deliberately does NOT source wsl_bridge.sh. The plugin registry lives where
#   Claude Code runs, not on the Linux side, so hopping into WSL would read the
#   wrong ~/.claude and report "no registration" on every Windows session.
#
# Why this exists: a Claude Code session loads its skills and agents ONCE, at
# start. Pulling a newer plugin afterwards does not change what the running
# session uses. The result is the worst kind of failure - the loop runs, the
# logs look normal, and the behaviour is the old version's. The user then debugs
# a bug that was fixed two releases ago.
#
# Three versions matter and they can all disagree:
#   running     the copy these scripts live in    (plugin_dir/.claude-plugin)
#   registered  what the session actually loaded  (installed_plugins.json)
#   available   the newest copy on this machine   (plugins/cache/**)
#
# Usage: check_version.sh <plugin_dir>
# Prints one JSON object. ok=false means: stop, tell the user, do not run.
set -u

PLUGIN_DIR="${1:-}"
MARKET="${MARKET:-sboot-rehost-marketplace}"
NAME="${NAME:-sboot-rehost}"
CACHE_ROOT="${CACHE_ROOT:-$HOME/.claude/plugins/cache/$MARKET/$NAME}"
REGISTRY="${REGISTRY:-$HOME/.claude/plugins/installed_plugins.json}"

python3 - "$PLUGIN_DIR" "$CACHE_ROOT" "$REGISTRY" "$NAME" <<'PY'
import json, os, re, sys

plugin_dir, cache_root, registry, name = sys.argv[1:5]
problems, notes = [], []


def semver(v):
    parts = re.findall(r"\d+", v or "")
    return tuple(int(x) for x in (parts + ["0", "0", "0"])[:3])


def read_version(d):
    path = os.path.join(d, ".claude-plugin", "plugin.json")
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh).get("version")
    except (OSError, json.JSONDecodeError):
        return None


running = read_version(plugin_dir) if plugin_dir else None

registered, install_path = None, None
try:
    with open(registry, encoding="utf-8") as fh:
        data = json.load(fh)
    for key, entries in (data.get("plugins") or {}).items():
        if name not in key:
            continue
        for e in entries or []:
            # Highest registered entry wins; a user-scope and a project-scope
            # entry can both exist and only the newer one is what loads.
            if registered is None or semver(e.get("version")) > semver(registered):
                registered, install_path = e.get("version"), e.get("installPath")
except (OSError, json.JSONDecodeError):
    notes.append(f"설치 등록부를 읽지 못했습니다 ({registry})")

cached = []
if os.path.isdir(cache_root):
    cached = sorted((d for d in os.listdir(cache_root)
                     if os.path.isdir(os.path.join(cache_root, d))), key=semver)
else:
    notes.append(f"플러그인 캐시가 없습니다 ({cache_root})")

# "Available" is the newest thing on this machine, including the working copy
# these scripts came from - a dev checkout ahead of the cache is still the newest.
candidates = [v for v in cached if v] + ([running] if running else [])
available = max(candidates, key=semver) if candidates else None

is_dev = bool(plugin_dir) and os.path.abspath(cache_root) not in os.path.abspath(plugin_dir)

state = "unknown"
if running and available:
    if semver(running) < semver(available):
        state = "stale"
        problems.append(
            f"실행 중인 버전 {running} 보다 새 버전 {available} 이 이 컴퓨터에 있습니다")
    else:
        state = "dev" if is_dev else "current"

# The session's skills and agents come from the REGISTERED copy, not from
# wherever these scripts happen to live. A registry pointing at an older
# version is the drift that actually changes behaviour.
if registered and available and semver(registered) < semver(available):
    state = "stale"
    problems.append(
        f"세션이 로드한 버전은 {registered} 인데 이 컴퓨터의 최신은 {available} 입니다"
        f" — 스킬·에이전트가 옛 버전 것입니다")
if running and registered and semver(running) != semver(registered):
    problems.append(
        f"스크립트가 있는 버전({running})과 세션이 로드한 버전({registered})이 다릅니다"
        f" — 스크립트와 프롬프트가 서로 다른 세대일 수 있습니다")

if not running:
    notes.append("plugin.json 을 찾지 못해 실행 버전을 확인하지 못했습니다")

hint = (
    "고치는 순서:\n"
    "  1) /plugin marketplace update sboot-rehost-marketplace\n"
    "  2) /plugin install sboot-rehost@sboot-rehost-marketplace   (등록을 최신으로)\n"
    "  3) /reload-plugins   또는 Claude Code 재시작\n"
    "  4) 그래도 안 되면  rm -rf ~/.claude/plugins/cache  후 재설치\n"
    "확인: /sboot-rehost:rehost-full 이 명령 목록에 보이면 최신이 로드된 것입니다."
)

print(json.dumps({
    "ok": not problems,
    "state": state,
    "running": running,
    "registered": registered,
    "available": available,
    "cached": cached,
    "install_path": install_path,
    "dev_checkout": is_dev,
    "problems": problems,
    "notes": notes,
    "hint": hint,
}, ensure_ascii=False))
PY
