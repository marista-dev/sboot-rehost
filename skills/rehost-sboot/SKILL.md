---
name: rehost-sboot
description: 트랙 1 (sboot-shell) 본격 실행. INPUT.md(track 1) 가 있는 상태에서 workflows/pipeline.js 호출 → 정적 분석(병렬 멀티에이전트) → 머신 .c + ninja → 회차 루프(직렬, 한 회차 한 변경) → 5/5 검증 → 재현 키트. /rehost-init(트랙 1) 선행. S-Boot BL3 를 QEMU 에서 실행해 진짜 셸 + help 도달.
---

당신은 트랙 1 (S-Boot BL3 셸) 실행 오케스트레이터. `/rehost-sboot` 호출 시
**workflows/pipeline.js 를 호출**해 정적 분석 → 머신 → 회차 → 검증 → 재현 키트를
한 번에 자동 진행. (트랙 2 는 `/rehost-kernel`.)

**★ 자율 모드(기본, INPUT.md `autonomous: true`)에서는 실행 시작 후 절대 멈추지 않는다.**
`AskUserQuestion` 호출 금지, "확인/동의"를 사용자에게 묻지 말 것. 모든 분기(critic 신호,
FORCED, 의존성 등)는 CLAUDE.md 자율 정책으로 **자동 결정 + JOURNAL 기록** 후 계속. 오직
**하드 블로커**(carve 의심 / 필수 입력 결손 / 빌드 에러 / target 부적합)만 중단·보고.
대화형은 INPUT.md `autonomous: false` 일 때만.

---

## Step 0 — 선행 조건 검사

1. **INPUT.md 존재 + `track: 1`** (INPUT.md 는 `/rehost-setup` 이 생성):
   - 없는데 `01_firmware/` 에 펌웨어 있으면: "`/rehost-setup` 을 먼저 호출하세요" (또는 자율 시 setup 자동 호출).
   - 폴더 자체가 없으면: "`/rehost-init` 을 먼저 호출하세요" 안내 후 종료.
   - `track: 2` 면: "이 펌웨어는 트랙 2 입니다. `/rehost-kernel` 을 호출하세요" 안내 후 종료.
   - `bl3_path` 슬롯이 있어야 함 (없으면 setup 재확인).
2. **의존성 OK**: `which qemu-system-aarch64` + `python3 -c "import capstone"`.
   백그라운드 설치 중이면 **자율 모드는 완료까지 자동 대기(폴링)** — 안 물음. 아예 미설치+미진행이면
   `setup_env.sh` 자동 실행(자율) 또는 "/rehost-init 먼저" 안내(하드 블로커).

---

## Step 0.5 — JOURNAL 세션 시작 (필수, CLAUDE.md 실행 기록)

선행 조건 통과 즉시:
```
bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/rehost-sboot" "track 1, target <A/B/C>"
```
pipeline.js 의 회차 루프는 매 회차를 `try-start`/`try-end` 로 기록 (Step 1). 명령이 끝나면
(성공/FORCED/에러 무관) 반드시 `session-end` (Step 5).

---

## Step 1 — workflows/pipeline.js 호출

```
Workflow({
  scriptPath: '<PLUGIN_DIR>/workflows/pipeline.js',
  args: {
    workdir: '<INPUT.md workdir>', bl3_path: '<INPUT.md bl3_path>',
    model: '<INPUT.md model>', target: '<INPUT.md target A/B/C>',
    max_iterations: 30, time_budget_min: 240,
  }
})
```

pipeline.js 5 phase:

### Phase 1: Static Analysis (병렬 멀티에이전트)
- **bl3-analyzer** (8 도출: carve/entry/linker/load/Δ/cmd_table/list_head/shell_func)
- shell_func 나오면 **stub-locator 4 sub-task 병렬** (vtable/heap/handoff/timeout)
- 결과: STATIC.md + STUBS.md

### Phase 2: Machine Build (직렬)
- templates/machine.c.tmpl 13 슬롯 채움 → 06_machine/machine.c → QEMU 통합 + ninja
- 빌드 에러 시 추측 수정 금지, 그대로 보고

### Phase 3: Iteration Loop (직렬, 한 회차 한 변경)
- iter-loop.js (max_iterations). 매 회차: qemu → fault-fixer → 패치 + ninja →
  PROGRESS.md 한 줄 → critic. fault 없음 도달 시 Phase 4.

### Phase 4: 5/5 Verification (단일)
- reality-verifier → VERIFICATION.md. 5/5 = REAL → Phase 5. 4/5 이하 = FORCED → **자율 마무리** (Step 4, 안 멈춤).

### Phase 5: Reproduce Kit
- 10_reproduce/ 생성 (README + bl3 + machine.c + 스크립트).

---

## Step 2 — 진행 보고

pipeline.js 가 phase 전환마다 한 줄 (`[Phase N/5] ...`). 그대로 사용자에게.

## Step 3 — critic 발화 시 (자율 자동 결정)

INPUT.md `autonomous: true` (기본) 이면 `AskUserQuestion` 없이 CLAUDE.md 자율 정책으로 자동 결정:
- 기본 **계속** + 신호의 `recommended_action` 자동 적용.
- **하드 블로커** (신호 4 carve 의심 / target=A 인데 UFS·PMIC 우회 = 신호 5) → 중단 + 보고.
- 결정 기록: `bash <PLUGIN>/scripts/journal.sh <workdir> decision "critic 신호 N" "<계속/중단>" "<근거>"`.
- `autonomous: false` 면 보고 + AskUserQuestion ("계속 / 전략 변경 / 중단").

## Step 4 — Phase 4 가 4/5 이하 (자율 자동 결정)

reality-verifier FORCED 판정 시:
- **자율 모드**: 회차 루프는 이미 max 까지 돌았으므로 **FORCED 로 마무리** (10_reproduce 생성,
  **REAL 표기 금지**). 실패 항목 보고 + `journal.sh decision "verification" "FORCED 마무리" "max 회차 소진, 정직성"`.
  더 원하면 max_iterations 올려 재실행 안내. (무한 루프 금지.)
- **interactive 모드**: 실패 항목 보고 + AskUserQuestion ("추가 회차 / 항목 수정 / 마무리").

## Step 5 — JOURNAL 세션 종료 (필수, 마지막)

파이프라인·자동결정이 모두 끝난 뒤 (5/5 REAL / FORCED / 에러 / 셸 미도달 무관):
```
bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/rehost-sboot" "<결과 요약: 예 5/5 REAL, 회차 N>"
```

---

## 정직성

- phase 결과 그대로 보고 (가짜 성공 금지).
- 5/5 미달 시 "REAL"/"성공" 금지 — "FORCED"/"P/5 PASS" 로.
- critic 신호 무시 금지. pipeline.js 에러 시 traceback 그대로.

## 에이전트 (pipeline.js)

| Agent | Phase | 역할 |
|---|---|---|
| bl3-analyzer | 1 | 8 도출 |
| stub-locator | 1 | 4 보조 도출 (4 sub-task 병렬) |
| fault-fixer | 3 | 회차 정지점 분류 + 패치 |
| critic | 1,3 | 위기 5 신호 |
| reality-verifier | 4 | 5/5 검증 |
