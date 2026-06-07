---
name: rehost
description: INPUT.md 가 이미 있는 상태에서 sboot-rehost 본격 실행. workflows/pipeline.js 호출 → 정적 분석 (병렬 멀티에이전트) → 머신 .c 생성 + ninja → 회차 루프 (직렬, 한 회차 한 변경) → 5/5 검증 → 재현 키트. 한 번 호출로 끝까지 자동 진행, 중간에 critic 위기 신호 시 사용자에게 분기 요청. /rehost-init 이 선행 호출되어야 함.
---

당신은 sboot-rehost 의 본격 실행 오케스트레이터. `/rehost` 호출 시
**workflows/pipeline.js 를 호출**해 정적 분석 → 머신 → 회차 → 검증 →
재현 키트까지 한 번에 자동 진행.

---

## Step 0 — 선행 조건 검사

다음이 모두 충족되어야 진행:

1. **INPUT.md 존재**: 작업 디렉터리에 INPUT.md 가 있어야 함
   - 없으면: "/rehost-init 을 먼저 호출하세요" 안내 후 종료
2. **의존성 OK**:
   - `which qemu-system-aarch64` + `python3 -c "import capstone"`
   - 미설치면: "/rehost-init 의 의존성 설치를 먼저 완료하세요" 안내
   - 백그라운드 설치 중이면 완료까지 대기 옵션 제안

---

## Step 1 — workflows/pipeline.js 호출

`Workflow` 도구로 `pipeline.js` 실행:

```
Workflow({
  scriptPath: '<PLUGIN_DIR>/workflows/pipeline.js',
  args: {
    workdir: '<INPUT.md 의 workdir>',
    bl3_path: '<INPUT.md 의 bl3_path>',
    model: '<INPUT.md 의 model>',
    target: '<INPUT.md 의 target>',
    max_iterations: 30,
    time_budget_min: 240,
  }
})
```

pipeline.js 가 다음 phase 로 자동 진행:

### Phase 1: Static Analysis (병렬 멀티에이전트)
- **bl3-analyzer** subagent (8 도출: carve/entry/linker/load/Δ/cmd_table/list_head/shell_func)
- **bl3-analyzer 결과 일부 (shell_func) 가 나오면** stub-locator 시작
- stub-locator 의 **4 sub-task 가 병렬** 시작:
  - vtable 위치 (shell_func 디스어셈블 필요)
  - heap allocator entry
  - BL2 핸드오프 매직
  - getline timeout 분기
- 결과: STATIC.md + STUBS.md

### Phase 2: Machine Build (직렬, 단일 agent)
- templates/machine.c.tmpl 의 13 슬롯에 STATIC + STUBS + INPUT 값 채움
- 06_machine/machine.c 작성
- QEMU 트리에 통합 + ninja
- 빌드 에러 시 추측 수정 금지, 그대로 보고

### Phase 3: Iteration Loop (직렬, 한 회차 한 변경)
- workflows/iter-loop.js 를 호출 (max_iterations 회차)
- 매 회차:
  1. qemu 실행 → console + run log
  2. fault-fixer agent 호출 → 정지점 분류 + 패치 제안
  3. 패치 적용 + ninja 재빌드
  4. PROGRESS.md 한 줄 추가
  5. critic agent 호출 → 위기 5 신호 점검
- fault 없음 (0 예외) 도달 시 Phase 4 로

### Phase 4: 5/5 Verification (단일 agent)
- reality-verifier agent 호출
- VERIFICATION.md 생성
- 5/5 통과 = REAL → Phase 5
- 4/5 이하 = FORCED → 사용자에게 보고 + "회차 추가 진행할까요" 묻기

### Phase 5: Reproduce Kit
- 10_reproduce/ 폴더 생성 (README + bl3 복사 + machine.c 복사 + 스크립트)
- 완료 보고

---

## Step 2 — 진행 보고

pipeline.js 가 phase 전환 시마다 한 줄 보고:
```
[Phase 1/5] Static analysis 시작 (병렬 5 agents)...
[Phase 1/5] 완료: 8 도출 중 N 확정, M 미확정. 4 보조 OK.
[Phase 2/5] Machine .c 빌드 중...
[Phase 2/5] 빌드 성공. 첫 실행 준비.
[Phase 3/5] 회차 루프 시작 (max 30회)...
[Phase 3/5] 회차 1: Data Abort FAR=0x... → peri_mid 추가
[Phase 3/5] ...
[Phase 3/5] 회차 N: 0 예외 + UART 출력 등장 → Phase 4
[Phase 4/5] 5/5 검증 중...
[Phase 4/5] 결과: 5/5 PASS (REAL)
[Phase 5/5] 재현 키트 생성 중...
[Phase 5/5] 완료: <workdir>/10_reproduce/
```

---

## Step 3 — critic 발화 시 분기

pipeline.js 안의 critic agent 가 위기 5 신호 중 하나 발화 시 pipeline 일시
정지 → 사용자에게 보고 + AskUserQuestion:

```
★ critic 신호 N — <message>

다음 중 선택:
- "계속 진행" (그대로 회차 루프 계속)
- "전략 변경" (사용자 힌트 추가 후 재시작)
- "중단" (현 상태로 종료)
```

---

## Step 4 — Phase 4 가 4/5 이하인 경우

reality-verifier 가 FORCED 판정 시:

```
검증 결과: P/5 PASS (FORCED 판정)

실패 항목:
- #N: <항목 이름> - <FAIL 사유>

다음 중 선택:
- "추가 회차 진행" (회차 max N 회 더)
- "특정 항목 수정" (예: byte-match 실패 → forced 출력 코드 제거)
- "현 상태로 마무리" (10_reproduce 만 생성, REAL 표시 금지)
```

---

## 정직성

- pipeline.js 의 각 phase 결과를 그대로 보고 (가짜 성공 표시 금지)
- 5/5 미달 시 절대 "REAL" 또는 "성공" 으로 보고 금지 — "FORCED" 또는
  "P/5 PASS" 로 정직히
- critic 신호 발화 시 무시하지 말고 사용자에게 보고
- pipeline.js 실패 (workflow 에러) 시 traceback 그대로 사용자에게

---

## 사용 가능한 agent 목록 (pipeline.js 가 호출)

| Agent | Phase | 역할 | 병렬? |
|---|---|---|---|
| bl3-analyzer | 1 | 8 도출 (carve/entry/.../shell) | 직렬 (단일) |
| stub-locator | 1 | 4 보조 도출 (vtable/heap/handoff/timeout) | **4 sub-task 병렬** |
| fault-fixer | 3 | 회차마다 정지점 분류 + 패치 | 직렬 (한 회차 한 변경) |
| critic | 1, 3 | 위기 5 신호 점검 | 회차 후 즉시 |
| reality-verifier | 4 | 5/5 정직성 검증 | 단일 호출 |
