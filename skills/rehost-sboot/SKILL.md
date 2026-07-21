---
name: rehost-sboot
description: 트랙 1 (bootloader shell) 실행. active(또는 workdir=<id>) 워크스페이스의 INPUT.md(track 1) 로 workflows/pipeline.js 를 track=1 로 호출 → static-analyzer 사전 도출 → machine.c + ninja → (실행·분류·한 변경)* 루프 → 검증 5/5 (스크립트 측정 + verifier 재검증) → 재현 키트. /sboot-rehost:rehost-setup 선행. 진짜 S-Boot BL3 를 QEMU 에서 실행해 셸 + help 도달.
disable-model-invocation: true
---

당신은 트랙 1 (bootloader shell) 실행 오케스트레이터. `/sboot-rehost:rehost-sboot` 호출 시
**workflows/pipeline.js 를 `track: 1` 로 호출**한다. (트랙 2 는 `/sboot-rehost:rehost-kernel`.)

**★ 실행은 자율이다. 시작하면 사용자에게 다시 묻지 않는다.**
`AskUserQuestion` 호출 금지. "계속할까요 / 확인해주세요" 류 질문 자체가 규칙 위반이다.

**★ 회차 수·소요 시간은 멈출 이유가 아니다.** 시도할 수(手)가 남아 있는 한 계속한다.
멈추는 경우는 **구조상 목표에 도달할 수 없을 때뿐**이며, 그 판정은 pipeline 의
결정론 정지 조건(`scripts/stop_conditions.py`)이 소유한다.

---

## Step 0 — 워크스페이스 확정 + 선행 조건

1. `WORKROOT = <cwd>/rehost_workspaces`.
   - `workdir=<id>` 인자가 있으면 그 워크스페이스, 없으면 `WORKROOT/.active` 의 id.
   - 워크스페이스나 INPUT.md 가 없으면 "먼저 `/sboot-rehost:rehost-setup <이름>`" 안내 후 종료.
   - 이하 `<workdir>` = `WORKROOT/<id>`.
2. **INPUT.md `track: 1`** 확인. `track: 2` 면 "이 펌웨어는 트랙 2 — `/sboot-rehost:rehost-kernel`"
   안내 후 종료. `bl3_path` 슬롯 필요.
3. 의존성(`qemu-system-aarch64`, `capstone`)은 setup 에서 설치됨. 진행 중이면 **자동 대기** — 안 묻는다.

## Step 0.5 — JOURNAL 세션 시작 (필수)

```
bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/sboot-rehost:rehost-sboot" "track 1, target <A/B/C>"
```

## Step 1 — pipeline.js 호출

```
Workflow({
  scriptPath: '<PLUGIN_DIR>/workflows/pipeline.js',
  args: {
    workdir: '<workdir>',
    track: 1,
    target: '<INPUT.md target A/B/C>',
    model: '<INPUT.md model>',
    bl3_path: '<INPUT.md bl3_path>',
    plugin_dir: '<PLUGIN_DIR>',
    // runtime_round_cap 은 목표 판정이 아니라 런타임 한계(재개 가능). 기본 120.
  }
})
```

### 파이프라인 단계

| 단계 | 하는 일 |
|---|---|
| **Analyze** | `static-analyzer` 사전 도출 (carve 판정 → entry → linker/load → Δ → cmd 테이블 → shell 함수 → vtable/heap/handoff/timeout) → `STATIC.md`. carve 의심이면 **하드 블로커로 정지** |
| **Build** | `templates/machine.c.tmpl` 채움 → `06_machine/machine.c` → QEMU 통합 + ninja. 빌드 에러는 **그대로 보고 후 정지** (추측 수정 금지) |
| **Loop** | 회차마다: `check_change snapshot` → `run_qemu.sh`(지문 + **출처 게이트**) → `stop_conditions.py` → `supervisor` 라우팅 → `fault-classifier` 분류·fixer 순위 → **1 순위 fixer 가 한 변경** → `check_change verify` → ninja |
| **Verify** | `verify.py` 5/5 측정 → `verifier` 2 차 재검증 (낮추기 자유, 올리기는 byte 증거 필요) → `VERIFICATION.md` |
| **Package** | `10_reproduce/` 재현 키트 |

### 기록 (자동)

| 파일 | 내용 |
|---|---|
| `JOURNAL.md` | 사람이 읽는 세션·회차 기록 (실제 시각 + 원인/분석/해결) |
| `PROGRESS.md` | 회차 한 줄 이력 |
| `metrics.jsonl` | **시간·토큰 등 측정치** (단계마다 그때그때) |
| `rounds.jsonl` | 회차 1건 = 1줄 (지문/분류/fixer/효과) — 정지 조건·memoization 근거 |
| `blockers.jsonl` | 사실로 감지된 하드 블로커 |

## Step 2 — 진행 보고

pipeline 이 단계·회차마다 한 줄을 log 한다. 그대로 사용자에게 전달한다.

## Step 3 — 정지했을 때 (자율 처리, 묻지 않음)

pipeline 이 `stopped: true` 를 반환하면 그 자체가 결론이다. **되묻지 말고 보고**한다:

| stop_reason | 의미 | 보고 |
|---|---|---|
| `BLOCKED_CARVE` | BL3 가 carve | 자산 재확보 필요. 미완 |
| `BLOCKED_BUILD` | ninja 실패 | 에러 원문 그대로 |
| `EXHAUSTED` | 무브 소진 (정체·진동 + 새 사실 0 + 새 시도 0) | 최고 마일스톤·시도한 변경 목록과 함께 **정직한 미완** |

모두 `success=false`. **REAL·성공 표기 금지.** 같은 명령으로 재실행하면 이어서 진행된다.

## Step 4 — 검증 결과

- **5/5 = REAL** → "5/5 통과, REAL 판정" 까지만 보고. "성공했습니다" 같은 단정 금지.
- **4/5 이하 = FORCED** → 실패 항목을 그대로 보고. "거의 완료" 금지.
  자율 모드에서 되묻지 않고 FORCED 로 마무리한다 (재현 키트는 생성, **REAL 표기 금지**).

## Step 5 — JOURNAL 세션 종료 (필수, 마지막)

```
bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/sboot-rehost:rehost-sboot" "<결과: 예 5/5 REAL, 회차 N>"
```

---

## 구성 요소

| 이름 | 정체 | 역할 |
|---|---|---|
| `static-analyzer` | LLM | 사전 도출 + 미지 정지점 에스컬레이션 |
| `supervisor` | LLM | 회차 라우팅·정지 (정지 조건은 뒤집을 수 없음) |
| `fault-classifier` | LLM | 정지점 분류 + 담당 fixer 순위 ("unknown" 이 정상 답) |
| `fixer-memory` / `fixer-el3` / `fixer-bootflow` | LLM | 담당 오류를 직접 수정 (회차당 하나) |
| `verifier` | LLM | 5/5 2 차 재검증 (비대칭 override) |
| `run_qemu.sh` · `check_change.sh` · `stop_conditions.py` · `verify.py` · `record.py` | 스크립트 | 실행·검문·정지·측정 (판정의 입력값 소유) |

## 정직성

- 결과를 그대로 보고 (가짜 성공 금지).
- 5/5 미달 시 "REAL"/"성공" 금지 — "FORCED"/"P/5 PASS" 로.
- 출처 게이트에 걸린 도달(자가주입)은 도달이 아니다.
- pipeline 에러 시 traceback 그대로.
