#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# check_change.sh - enforce "one round, one change" by counting the diff.
#
# A fixer edits sources directly and only what passes this gate gets built.
# The rule is enforced by counting the diff, not by asking the prompt nicely.
#
# Usage:
#   check_change.sh <workdir> snapshot   # before the fixer edits - capture the baseline
#   check_change.sh <workdir> verify     # after the fixer edits - gate (JSON on stdout)
#   check_change.sh <workdir> restore    # on violation - roll back to the baseline
#
# Checks:
#   1. exactly one source file changed  (several files at once means a batched change)
#   2. hunks within MAX_HUNKS           (default 3, a realistic ceiling for one change)
#   3. the bypass record has all four fields (대상 / 이유 / 방법 / 부작용)
#
# The reason field is surfaced to the user, so it is written in Korean.
#
# Environment:
#   MAX_HUNKS   allowed hunk count (default 3)
set -u

WD="${1:-}"; OP="${2:-}"; ROUND="${3:-}"
[ -n "$WD" ] && [ -n "$OP" ] || { echo "usage: check_change.sh <workdir> snapshot [round]|verify|restore" >&2; exit 1; }

SRC="$WD/06_machine"
PRE="$WD/08_docs/.record/pre"
# Per-round snapshots. Without them a bypass whose mechanism is later disproven
# can only be argued about: there is no record of the sources as they stood
# before it, so nothing can take it back out and the wrong model keeps
# accumulating for the rest of the run.
ROUNDS="$WD/08_docs/.record/rounds"
MAX_HUNKS="${MAX_HUNKS:-3}"

# Prefer the current name, still accept the legacy one in older workspaces.
bypass_file() {
    if   [ -f "$SRC/bypasses.md" ];       then echo "$SRC/bypasses.md"
    elif [ -f "$SRC/우회_패치_목록.md" ];  then echo "$SRC/우회_패치_목록.md"
    else echo ""
    fi
}

case "$OP" in
  snapshot)
    rm -rf "$PRE"; mkdir -p "$PRE"
    # Only machine sources are snapshotted; the bypass record is checked separately.
    find "$SRC" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) \
        -exec cp {} "$PRE/" \; 2>/dev/null || true
    if [ -n "$ROUND" ]; then
        rm -rf "$ROUNDS/$ROUND"; mkdir -p "$ROUNDS/$ROUND"
        cp "$PRE"/* "$ROUNDS/$ROUND/" 2>/dev/null || true
    fi
    echo "check_change: snapshot $(find "$PRE" -type f 2>/dev/null | wc -l | tr -d ' ') files${ROUND:+ (round $ROUND)}"
    ;;

  verify)
    [ -d "$PRE" ] || { echo '{"pass":false,"reason":"스냅샷이 없습니다 — 수정 전에 snapshot 을 먼저 실행하세요"}'; exit 1; }

    changed_files=0; total_hunks=0; changed_list=""
    for cur in "$SRC"/*.c "$SRC"/*.h; do
        [ -f "$cur" ] || continue
        base="$(basename "$cur")"
        old="$PRE/$base"
        if [ ! -f "$old" ]; then
            # A brand new source file also counts as one change.
            changed_files=$((changed_files + 1))
            total_hunks=$((total_hunks + 1))
            changed_list="$changed_list $base(new)"
            continue
        fi
        h=$(diff -u "$old" "$cur" 2>/dev/null | grep -c '^@@' || true)
        if [ "$h" -gt 0 ]; then
            changed_files=$((changed_files + 1))
            total_hunks=$((total_hunks + h))
            changed_list="$changed_list $base($h)"
        fi
    done

    # Field names appear with markdown emphasis (`**대상**:`) and a list marker in
    # real workspaces, and the last one is often written "알려진 부작용".
    # Matching the bare literal `대상:` scored a compliant file as zero fields.
    count_field() {   # $1 = field regex
        grep -cE "^[[:space:]>*+-]*\**[[:space:]]*$1[[:space:]]*\**[[:space:]]*[:：]" "$2" 2>/dev/null || echo 0
    }

    BF="$(bypass_file)"
    if [ -n "$BF" ]; then
        n_target=$(count_field '대상' "$BF")
        n_reason=$(count_field '이유' "$BF")
        n_method=$(count_field '방법' "$BF")
        n_effect=$(count_field '(알려진[[:space:]]*)?부작용' "$BF")
    else
        n_target=0; n_reason=0; n_method=0; n_effect=0
    fi

    bypass_ok=true
    if [ "$n_target" -eq 0 ] \
       || [ "$n_target" -ne "$n_reason" ] \
       || [ "$n_target" -ne "$n_method" ] \
       || [ "$n_target" -ne "$n_effect" ]; then
        bypass_ok=false
    fi

    pass=true; reason=""
    if [ "$changed_files" -eq 0 ]; then
        pass=false; reason="변경된 소스가 없습니다 (fixer 가 아무것도 고치지 않았습니다)"
    elif [ "$changed_files" -gt 1 ]; then
        pass=false; reason="소스 파일 ${changed_files} 개를 동시에 고쳤습니다 — 한 회차 한 변경 위반입니다"
    elif [ "$total_hunks" -gt "$MAX_HUNKS" ]; then
        pass=false; reason="변경 hunk 가 ${total_hunks} 개로 상한(${MAX_HUNKS})을 넘었습니다 — 여러 변경을 묶은 것으로 보입니다"
    elif [ "$bypass_ok" != true ]; then
        pass=false; reason="우회 기록 4 항목이 갖춰지지 않았습니다 (대상=$n_target 이유=$n_reason 방법=$n_method 부작용=$n_effect)"
    fi

    printf '{"pass":%s,"changed_files":%d,"total_hunks":%d,"changed":"%s","bypass_entries":%d,"bypass_ok":%s,"reason":"%s"}\n' \
        "$pass" "$changed_files" "$total_hunks" "$(echo "$changed_list" | sed 's/^ //')" \
        "$n_target" "$bypass_ok" "$reason"

    [ "$pass" = true ] || exit 2
    ;;

  restore)
    [ -d "$PRE" ] || { echo "check_change: 되돌릴 스냅샷이 없습니다" >&2; exit 1; }
    for old in "$PRE"/*; do
        [ -f "$old" ] || continue
        cp "$old" "$SRC/$(basename "$old")"
    done
    echo "check_change: 위반한 변경을 스냅샷으로 되돌렸습니다"
    ;;

  *) echo "check_change: unknown op '$OP'" >&2; exit 1;;
esac
