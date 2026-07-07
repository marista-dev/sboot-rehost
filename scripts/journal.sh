#!/usr/bin/env bash
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
  *) echo "journal: unknown op '$OP'" >&2; exit 1;;
esac
