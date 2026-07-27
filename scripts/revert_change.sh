#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# revert_change.sh - take a bypass back out of the machine sources.
#
# Usage:
#   revert_change.sh <workdir> <round> "<reason>"
#
# Why this exists
# ---------------
# A bypass is a hypothesis about the hardware. When a later round disproves it -
# the fingerprint does not move, or the mechanism it assumed is contradicted -
# the loop had no way to remove it. `suspect_prior_bypass` only told the
# classifier to be suspicious; the wrong model stayed in the machine and every
# later change was built on top of it. By the end of a long run the machine can
# carry a dozen bypasses, several of them known to be wrong, and the bypass list
# that verification item 5 reports is no longer an honest account.
#
# The undo is the reverse of exactly that round's diff, not a rollback to that
# round. Rolling back would also throw away every correct change made since.
# If a later round edited the same lines the reverse patch will not apply, and
# this refuses rather than guessing - that refusal is a real answer for the
# supervisor, which then has to treat the interaction instead of pretending.
#
# stdout: one JSON object. Exit 0 on success, 4 when the revert cannot be done.

set -u

WD="${1:?workdir required}"
ROUND="${2:?round number required}"
REASON="${3:-사유 미기재}"

SRC="$WD/06_machine"
ROUNDS="$WD/08_docs/.record/rounds"
OLD="$ROUNDS/$ROUND"
NEW="$ROUNDS/$((ROUND + 1))"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }
fail() { printf '{"reverted":false,"round":%s,"reason":"%s"}\n' "$ROUND" "$(json_escape "$1")"; exit 4; }

[ -d "$OLD" ] || fail "회차 ${ROUND} 의 변경 전 스냅샷이 없습니다 (그 회차가 이 워크스페이스에서 돌지 않았습니다)"

# The state right after round N's change: the next round's snapshot if the run
# got that far, otherwise the sources as they stand now.
AFTER="$NEW"
[ -d "$AFTER" ] || AFTER="$SRC"

HAVE_PATCH=0
command -v patch >/dev/null 2>&1 && HAVE_PATCH=1

CHANGED=""; TOUCHED=0
for old in "$OLD"/*; do
    [ -f "$old" ] || continue
    base="$(basename "$old")"
    after="$AFTER/$base"
    cur="$SRC/$base"
    [ -f "$after" ] || continue
    [ -f "$cur" ]   || continue
    cmp -s "$old" "$after" && continue        # this round did not touch the file

    if [ "$AFTER" = "$SRC" ] || cmp -s "$after" "$cur"; then
        # Nothing was changed after this round, so restoring the file IS the
        # reverse of this round's change.
        cp "$old" "$cur" || fail "$base 복원 실패"
    elif [ "$HAVE_PATCH" -eq 1 ]; then
        if ! diff -u "$old" "$after" 2>/dev/null | patch -R -s -p0 "$cur" >/dev/null 2>&1; then
            fail "$base 의 역패치가 적용되지 않습니다 — 이후 회차가 같은 자리를 고쳤습니다. 되돌리기 대신 그 상호작용을 처치해야 합니다"
        fi
    else
        fail "patch 명령이 없어 오래된 회차는 되돌릴 수 없습니다 (마지막 변경만 되돌릴 수 있습니다)"
    fi
    CHANGED="${CHANGED:+$CHANGED, }$base"
    TOUCHED=$((TOUCHED + 1))
done

[ "$TOUCHED" -gt 0 ] || fail "회차 ${ROUND} 이 소스를 바꾸지 않았습니다 (되돌릴 것이 없습니다)"

# The withdrawal is itself a bypass-record entry: the four fields keep the record
# complete, and verification item 5 must show what was taken out as well as what
# was put in.
BF="$SRC/bypasses.md"
[ -f "$BF" ] || BF="$SRC/우회_패치_목록.md"
[ -f "$BF" ] || BF="$SRC/bypasses.md"
{
    printf '\n### 우회 철회 — 회차 %s\n' "$ROUND"
    printf -- '- **대상**: 회차 %s 에서 넣은 변경 (%s)\n' "$ROUND" "$CHANGED"
    printf -- '- **이유**: %s\n' "$REASON"
    printf -- '- **방법**: 회차 %s 스냅샷 기준 역패치로 그 변경만 제거 (이후 회차 변경은 유지)\n' "$ROUND"
    printf -- '- **알려진 부작용**: 그 회차가 넘겼던 정지점이 다시 나타날 수 있습니다 — 그것이 정직한 상태입니다\n'
} >> "$BF"

printf '{"reverted":true,"round":%s,"files":"%s","change_key":"revert:%s","bypass_doc":"%s"}\n' \
    "$ROUND" "$(json_escape "$CHANGED")" "$ROUND" "$(json_escape "$BF")"
