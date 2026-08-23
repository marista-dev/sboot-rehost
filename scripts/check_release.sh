#!/usr/bin/env bash
# check_release.sh — 버전을 올리지 않고 내용을 내보내는 것을 막는다.
#
# 플러그인은 plugin.json 의 version 이 **올라갔을 때만** 사용자에게 전달된다.
# 같은 번호로 내용을 바꾸면, 그 번호를 이미 받아간 환경은 수정을 영원히 못 받는다.
# 0.19.0 에서 실제로 그렇게 됐다 — 버전을 박은 커밋 뒤로 62개 파일이 같은 번호로 나갔다.
#
# 검사 2가지:
#   1) plugin.json 과 marketplace.json 의 version 일치
#      (카탈로그가 낮으면 클라이언트가 갱신을 보지 못한다)
#   2) 현재 version 을 박은 커밋 이후로 **동작 표면**이 바뀌지 않았는가
#
# 동작 표면 = 사용자 환경에서 실제로 실행·해석되는 것. 문서·시험은 제외한다
# (오타 하나 고칠 때마다 릴리스를 강요하면 규칙이 지켜지지 않는다).
#
# 종료코드: 0 통과 · 1 위반 · 2 판정 불가(깃 아님 등, 막지 않음)
set -u
# REPO 오버라이드는 이 검문 자체를 시험하기 위한 것이다 (check_version.sh 의 REGISTRY 와 같은 방식)
cd "${REPO:-$(dirname "$0")/..}" || exit 2

SURFACE="agents fixers hooks knowledge profiles scripts skills templates workflows CLAUDE.md .claude-plugin"

ver() { python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
print(d.get('version') or (d.get('plugins') or [{}])[0].get('version',''))
" "$1" 2>/dev/null; }

V=$(ver .claude-plugin/plugin.json)
C=$(ver .claude-plugin/marketplace.json)

[ -n "$V" ] || { echo "check_release: plugin.json 의 version 을 읽지 못했습니다"; exit 2; }

fail=0
if [ "$V" != "$C" ]; then
  echo "check_release: plugin.json($V) 과 marketplace.json($C) 의 버전이 다릅니다"
  echo "  카탈로그가 낮으면 갱신이 사용자에게 전달되지 않습니다."
  fail=1
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "check_release: 깃 저장소가 아니라 이력 검사를 건너뜁니다"; exit $([ $fail -eq 0 ] && echo 2 || echo 1); }

# 이 버전 문자열을 plugin.json 에 넣은 커밋. 아직 커밋 전이면(= 지금 올리는 중) 비어 있다.
STAMP=$(git log -1 --format=%H -S"\"version\": \"$V\"" -- .claude-plugin/plugin.json 2>/dev/null)

if [ -z "$STAMP" ]; then
  echo "check_release: $V 는 아직 커밋되지 않았습니다 — 지금 올리는 중으로 봅니다"
  exit $fail
fi

CHANGED=$(git diff --name-only "$STAMP"..HEAD -- $SURFACE 2>/dev/null)

if [ -n "$CHANGED" ]; then
  N=$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')
  echo "check_release: 버전 $V 를 박은 커밋(${STAMP:0:7}) 이후 동작 표면 $N 개 파일이 바뀌었습니다."
  echo "  같은 번호로 내보내면 $V 를 이미 받은 환경은 이 변경을 받지 못합니다."
  echo "  plugin.json 과 marketplace.json 의 version 을 올리고 CHANGELOG 에 항목을 추가하십시오."
  echo
  printf '%s\n' "$CHANGED" | sed 's/^/    /' | head -20
  [ "$N" -gt 20 ] && echo "    … 외 $((N-20))개"
  exit 1
fi

echo "check_release: $V — 동작 표면이 버전과 일치합니다"
exit $fail
