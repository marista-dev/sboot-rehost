#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# journal.sh — /rehost* 실행 기록기. 모든 시각은 실제 date (조작·추정 금지, 정직성).
# <workdir>/JOURNAL.md 에 세션 + 시행착오(원인/분석/해결)를 시작·완료 시각과 함께 append.
# 시작 epoch 는 <workdir>/08_docs/.journal/ 에 보관 → 완료 시 소요시간 계산.
#
# 사용법:
#   journal.sh <workdir> session-start "<command>" "<track/target/meta>"
#   journal.sh <workdir> session-end   "<command>" "<result>"
#   journal.sh <workdir> try-start "<id>" "<title>"
#   journal.sh <workdir> try-end   "<id>" "<원인>" "<분석>" "<해결>" ["<증거>"]
#   journal.sh <workdir> phase "<phase-name>"        # 단계 경계 표시
#   journal.sh <workdir> decision "<지점>" "<선택>" "<근거>"   # 자율 자동결정
#   journal.sh <workdir> note  "<message>"
#
# 멈췄을 때 되짚기 위한 3 종 (기계 판독본은 record.py 의 prompts/resolutions.jsonl):
#   journal.sh <workdir> prompt "<사용자 입력 원문>" ["<phase>"] ["<round>"]
#       사용자가 실제로 친 것을 **요약하지 않고** 그대로 남긴다. 여러 줄 가능.
#   journal.sh <workdir> hypothesis "<가설>" "<검증 방법>"
#       시도 전에 남긴다. 틀린 가설도 지우지 않는다 — 무엇을 배제했는지가 기록이다.
#   journal.sh <workdir> resolution "<정지점>" "<시도들>" "<해결>" "<근거>"
#       정지점이 풀린 경위. 해결만 남기면 왜 그게 통했는지가 사라진다.
set -e
WD="$1"; OP="$2"; shift 2 2>/dev/null || { echo "usage: journal.sh <workdir> <op> ..." >&2; exit 1; }
[ -n "$WD" ] || { echo "journal: workdir 필요" >&2; exit 1; }
J="$WD/JOURNAL.md"; S="$WD/08_docs/.journal"; mkdir -p "$S"

now(){ date +%Y-%m-%dT%H:%M:%S%z; }
ep(){ date +%s; }
dur(){ local d=$(( $(ep) - ${1:-$(ep)} )); printf '%dh%02dm%02ds' $((d/3600)) $(((d%3600)/60)) $((d%60)); }
init(){ [ -f "$J" ] || {
  echo "# JOURNAL — 실행 기록 ($WD)"
  echo
  echo "> 모든 시각은 실제 \`date\` 출력 (조작 금지). /rehost* 세션 + 시행착오(원인/분석/해결)를"
  echo "> 시작·완료 시각과 함께 기록. scripts/journal.sh 가 append."
  echo; } > "$J"; }

case "$OP" in
  session-start)
    init; echo "$(ep)" > "$S/session.epoch"
    { echo; echo "---"; echo; echo "## [SESSION] $1 — ${2:-}"; echo "- 시작: $(now)"; echo "- 시행착오:"; } >> "$J"
    echo "journal: session-start '$1' @ $(now)";;
  session-end)
    { echo "- 완료: $(now)  (소요 $(dur "$(cat "$S/session.epoch" 2>/dev/null)"))"; echo "- 결과: ${2:-}"; } >> "$J"
    echo "journal: session-end '$1' @ $(now)";;
  try-start)
    init; echo "$(ep)" > "$S/try_$1.epoch"
    { echo "  - ### try #$1 — ${2:-}"; echo "    - 시작: $(now)"; } >> "$J"
    echo "journal: try-start #$1 @ $(now)";;
  try-end)
    { echo "    - 완료: $(now)  (소요 $(dur "$(cat "$S/try_$1.epoch" 2>/dev/null)"))"
      echo "    - 원인: ${2:-}"; echo "    - 분석: ${3:-}"; echo "    - 해결: ${4:-}"
      [ -n "${5:-}" ] && echo "    - 증거: $5"; } >> "$J"
    echo "journal: try-end #$1 @ $(now)";;
  phase)
    init; { echo; echo "  **[PHASE] $1** — $(now)"; } >> "$J"; echo "journal: phase '$1'";;
  decision)
    init; echo "  - 자동결정($(now)): ${1:-} → ${2:-} (근거: ${3:-})" >> "$J"
    echo "journal: decision '${1:-}' → '${2:-}'";;
  note)
    init; echo "  - 메모($(now)): ${1:-}" >> "$J"; echo "journal: note";;
  prompt)
    # 원문 그대로. 요약하면 왜 그 방향으로 틀었는지가 사라진다.
    # 펜스 블록에 넣는 이유: 프롬프트 안의 마크다운·별표·백틱이 문서를 망가뜨리지 않게.
    init
    { echo "  - **[PROMPT]** $(now)${2:+  phase=$2}${3:+ round=$3}"
      echo '    ```text'
      printf '%s\n' "${1:-}" | sed 's/^/    /'
      echo '    ```'; } >> "$J"
    echo "journal: prompt @ $(now)";;
  hypothesis)
    init
    { echo "  - 가설($(now)): ${1:-}"; echo "    - 검증 방법: ${2:-}"; } >> "$J"
    echo "journal: hypothesis";;
  resolution)
    init
    { echo "  - **[RESOLVED]** ${1:-} — $(now)"
      echo "    - 시도: ${2:-}"; echo "    - 해결: ${3:-}"; echo "    - 근거: ${4:-}"; } >> "$J"
    echo "journal: resolution '${1:-}'";;
  *) echo "journal: unknown op '$OP'" >&2; exit 1;;
esac
