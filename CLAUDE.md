# sboot-rehost — 항상 로드되는 컨텍스트

이 파일은 sboot-rehost 플러그인 작업 중 Claude Code 가 항상 컨텍스트에 로드한다.
모든 회차·도출·검증이 이 규칙에 따른다.

---

## 트랙 (목표 타깃 2종)

부팅 체인의 **어느 진입점부터 진짜 바이너리를 실행하느냐**로 트랙이 갈린다.
INPUT.md 의 `track` 슬롯 (1|2) 이 결정. 두 트랙은 별도 진입점 (한 체인으로 잇지 않음).

| 트랙 | 진입점 (체인) | 도달 지점 | 등급 | 방법론 |
|---|---|---|---|---|
| **1 부트로더** | 부트로더 (③) | 그 부트로더의 **인터랙티브 표면** — UART 셸(S-Boot) 또는 fastboot/USB(LK) | A/B/C | [instruction.md](methodology/instruction.md) |
| **2 커널** | 커널 EL1 (⑥⑦) | 커널 → rootfs 마운트 → 진짜 벤더 스토리지 드라이버 → Android 2단계 | K1/K2/K3 | [track2_kernel_storage.md](methodology/track2_kernel_storage.md) |

**트랙은 정체성이 아니라 인자다.** 루프 골격은 하나이고, 바뀌는 것은 목표 사다리·지식
테이블·실행 스크립트뿐이다. `workflows/pipeline.js` 하나가 `track` 인자로 둘 다 돈다.

### 트랙 1 등급 — 부트로더가 얼마나 진짜로 동작하나

목표는 "셸" 이 아니라 **그 부트로더에서 실제로 도달 가능한 인터랙티브 표면**이다.
표면은 `bl_surface` 가 정하고, 등급은 그 표면 위에서 **얼마나 깊이 동작하는가**다.

| 등급 | 뜻 | `shell` 표면 (S-Boot) | `fastboot` 표면 (LK) |
|---|---|---|---|
| **A** | 표면 도달 + 목록 명령 실행 | 프롬프트 + `help` 출력 | `getvar:` 수신·에코·dispatch |
| **B** | 다른 명령 핸들러가 실제로 동작 | `reset`·`printenv` 등이 일함 | `flash`·`reboot` 등이 일함 |
| **C** | 부트로더가 정상 부팅 흐름 진행 | autoboot 진행 | 부트모드 결정 → 커널 로드 |

사다리는 `A: [표면]` · `B: [표면, commands]` · `C: [표면, commands, autoboot]`.
각 단의 **관측 문자열은 static-analyzer 가 도출**해 `milestone_tokens.txt` 에 쓴다
(`<마일스톤>\t<토큰>` 형식) — 벤더 배너를 코드에 박지 않는다.

**표면이 없으면 등급도 없다.** 어느 표면에도 입력 경로가 없으면 `BLOCKED_NO_INPUT_PATH`
로 정직하게 정지한다. 명령 테이블이 바이너리에 있어도 dispatcher 가 그것을 참조하지
않으면 도달 불가이며, 트램폴린으로 출력을 강제하는 것은 **FORCED**다.

---

## 구성 요소 — LLM 5 + 결정론 5

> **측정은 스크립트, 해석·제어는 LLM, 정지의 입력값은 사실.**

### LLM 에이전트 (`agents/`)

| 이름 | 한 줄 | 수정 권한 |
|---|---|---|
| `static-analyzer` | 바이너리·자산 → 근거 있는 사실. 근거 없으면 "미확정" | ✗ (분석 문서만) |
| `supervisor` | 지문 + 정지 조건 → 라우팅·정지 + **층 판정** + **처방** + **우회 철회** | ✗ |
| `fault-classifier` | 로그 → 정지점 이름 + 담당 fixer 순위. 모르면 `unknown` | ✗ |
| `fixer-memory` `fixer-el3` `fixer-bootflow` `fixer-kernel` `fixer-storage` | 담당 오류를 **직접 수정** (회차당 하나) | **○** |
| `fixer-general` | **담당이 없을 때만** — 범위 무제한 (수정·빌드·실행) + 새 fixer 후보 기록 | **○** |
| `verifier` | 5/5 스크립트 측정을 2 차 재검증 | ✗ (VERIFICATION.md 만) |

**트랙 1 에는 `fixer-kernel`·`fixer-storage` 가 오르지 않는다.** 부트로더 단계는 스토리지
컨트롤러 구현으로 가지 않으며, 이는 프롬프트 권고가 아니라 파이프라인이 후보 목록과
지식 테이블을 트랙으로 갈라 집행한다.

**`fixer-general` 은 최후수단이다.** 전문가가 전부 반려했을 때만 도달하며 순위로는 못
오른다. 범위가 무제한이므로 "새로 시도할 변경 없음" 이 잘 안 나오는데, 이를 대비해
`stop_conditions.py` 가 **지문을 못 움직인 변경은 수(手)로 세지 않는다** (`futile_spent`).
그 기록은 `<workdir>/fixer_candidates.md` 에 쌓이고, 정식 fixer 승격은 사람이 커밋한다 —
에이전트 레지스트리는 세션 시작 스냅샷이라 런타임 생성 파일은 그 회차에 로드되지 않는다.

**fixer 만 코드를 고친다.** 나머지 LLM 은 읽기만 한다. 분류하는 쪽과 고치는 쪽이 같으면
"고칠 게 있어야 하니까" 없는 병명을 지어내기 때문이다.

### 결정론 컴포넌트 (`scripts/`, `workflows/`)

| 이름 | 한 줄 | 집행하는 불변 |
|---|---|---|
| `workflows/pipeline.js` | 루프 배선 + 단계 제어 | 사실 정지를 LLM 이 못 뒤집게 강제 |
| `run_round.sh` | 한 회차 통째 수행 → **관측 문서 1개** (`observation.json`) | LLM 이 `stop` 을 조립하지 못하게 함 |
| `run_qemu.sh` / `run_kernel.sh` | 실행 → **지문 추출 + 출처 게이트 + 실행실패 판정** | §7 자가주입 금지 (매 회차) |
| `fingerprint_lib.sh` | **최초 예외 추출** · 콘솔 고유줄 · 실행실패 판정 (두 run 스크립트 공용) | 재귀 말미가 아니라 원인을 지문으로 |
| `sync_machine.sh` | 06_machine 소스를 QEMU 트리로 반영 | **고친 소스가 실제로 빌드된다** |
| `revert_change.sh` | 반증된 우회를 **그 회차 변경만** 역패치로 제거 | 틀린 모델 위에 쌓지 않기 |
| `static_rotate.py` | 도출 기록이 커지면 근거는 보관, **표는 유지** | 회차 비용 상승 차단 |
| `wsl_bridge.sh` | 셸이 Windows 면 WSL 로 건너뜀 (scripts 공통 가드) | 실행은 Linux, 기록은 Windows |
| `check_env.sh` | 루프 전 실행 환경 선행 검사 | 못 도는 셸에서 회차 소모 금지 |
| `check_change.sh` | 한 변경 검문 (diff · 우회 4항목) + 회차별 스냅샷 | 회차 = 한 변경 · 되돌릴 수 있음 |
| `derived_facts.py` | 도출표의 **새 정지점 수 측정** (시그니처 dedup) | 도출 자기신고 금지 |
| `stop_conditions.py` | 정지 조건 계산 | 무한 진동 차단 |
| `verify.py` | 5/5 **측정** | §6 실증거 |
| `record.py` | 측정치 JSONL 기록 | 추적 가능성 |

### 데이터 (지식 / 프로세스 분리)

`fixers/registry.yaml` (오류 → 담당 fixer) · `knowledge/*.md` (정지점 테이블) ·
`profiles/*.yaml` (SoC 탐색 힌트 — **값이 아니라 "어디를 볼지"**).
**새 정지점 = 테이블 한 줄. 새 fixer = 파일 하나 + 등록부 몇 줄.** 프롬프트는 안 고친다.

---

## 도출은 기록으로 남아야 쓰인다

**펌웨어당 기록은 하나다** — `STATIC.md`(트랙 1) / `KERNEL_STATIC.md`(트랙 2).
static-analyzer 는 **덮어쓰지 않고 append** 하며, 루프 안의 재도출도 여기에 쌓는다.

```
[사전 도출]  static-analyzer → STATIC.md      → Build 가 읽어 머신을 만든다
[재도출]     static-analyzer → STATIC.md 의
                              `## 도출된 정지점` 표 한 줄
                                               → fault-classifier 가 매칭
                                               → fixer 가 그 줄의 "시도할 변경" 적용
                                               → check_change → ninja 재빌드
```

**답변에만 있는 사실은 아무에게도 안 닿는다.** 분류기도 fixer 도 표를 읽지 에이전트의
답을 읽지 않으므로, 기록되지 않은 도출은 없는 것과 같다. 메커니즘이 미확정이면
줄을 쓰지 않는다 — 근거 없는 줄은 fixer 를 틀린 가지로 보내므로 §1 위반이다.

## Flow

```
[static-analyzer] 사전 도출 → (하드 블로커면 ★ 정지)
   ↓
(Build) machine 소스 + ninja → (빌드 에러면 ★ 정지)
   ↓
┌── LOOP (목표 사다리마다) ────────────────────────────────────┐
│ (run_round.sh) snapshot + 실행 + 지문 + 출처게이트 + 정지조건  │
│                → 관측 문서 1개 (observation.json)             │
│ [supervisor] 라우팅 + 층 판정                                 │
│   ├ 목표 도달 → 검증으로 / 사다리 다음 칸                      │
│   ├ ★ 정지 (구조상 도달 불가)                                  │
│   ├ **Build 층 문제 → 머신 재생성 (rebuild)**                  │
│   ├ **우회가 반증됨 → 그 회차 변경만 철회 (revert)**           │
│   ├ **담당 fixer 없음 → fixer-general 직행 (처방 동반)**       │
│   ├ 미지·정체 → [static-analyzer] 재도출                       │
│   └ [fault-classifier] 분류 + fixer 순위                       │
│        → [1→2→3 순위 fixer] 한 변경 (전원 반려 시 general)     │
│        → (check_change) → (sync_machine) → (ninja)             │
└──────────────────────────────────────────────────────────────┘
   ↓
(verify.py 측정) → [verifier 재검증] → REAL | FORCED → 재현 키트
```

---

## 실행 기록 — 필수

**모든 `/sboot-rehost:rehost-*` 명령은 기록해야 한다. 기록 없이 완료 보고 금지.**
시각은 반드시 실제 `date` 출력 (조작·추정 금지, 정직성 §6 확장).

### 사람이 읽는 기록 — `JOURNAL.md` (`scripts/journal.sh`, append-only)

| 시점 | 명령 |
|---|---|
| 명령 시작 | `journal.sh <wd> session-start "<cmd>" "<track/target>"` |
| 명령 완료 | `journal.sh <wd> session-end "<cmd>" "<결과>"` |
| 회차 시작 | `journal.sh <wd> try-start "<N>" "<목표/정지점>"` |
| 회차 완료 | `journal.sh <wd> try-end "<N>" "<원인>" "<분석>" "<해결>" "<증거>"` |
| 단계 경계 | `journal.sh <wd> phase "<phase>"` |
| 자동 결정 | `journal.sh <wd> decision "<지점>" "<선택>" "<근거>"` |

### 기계가 읽는 측정치 — JSONL (`scripts/record.py`, append-only)

| 파일 | 내용 | 쓰임 |
|---|---|---|
| `metrics.jsonl` | **시간·토큰 등 측정 이벤트** (단계마다 그때그때) | 소요·비용 집계 |
| `rounds.jsonl` | 회차 1건 = 1줄 (지문/분류/fixer/change_key/효과) | 정지 조건 계산 · 같은 변경 재시도 방지 · fixer 분화 근거 |
| `blockers.jsonl` | **사실로 감지된** 하드 블로커 | LLM 이 부정할 수 없는 정지 입력값 |

```
python3 scripts/record.py <wd> start   <timer>
python3 scripts/record.py <wd> metric  phase=Run round=12 timer=run_12 tokens_total=124300
python3 scripts/record.py <wd> round   round=12 goal=link_up fp_far=0x… category=… effect=progress
python3 scripts/record.py <wd> blocker code=BLOCKED_KO detail="…"
```

---

## 자율 실행 — 기본 켜짐

**실행 명령(`/sboot-rehost:rehost-bootloader`·`/sboot-rehost:rehost-kernel`)은 시작하면
끝까지 자율이다.** `AskUserQuestion` 호출 금지 — "계속할까요 / 확인해주세요" 류 질문
자체가 규칙 위반이다. 모든 분기는 자동 결정하고 `journal.sh decision` 으로 남긴다.

**예외**: `/sboot-rehost:rehost-setup` 의 트랙·등급 프롬프트는 허용 (실행 루프 중
멈춤이 아니라 세팅 시점의 사용자 결정). 인자로 미리 주면 프롬프트 생략.

### ★ 정지 정책 — "구조상 도달 불가" 만

**회차 수·소요 시간은 정지 사유가 아니다.** 회차 상한이 없다. 시도할 수(手)가 남아
있는 한 50 회차든 200 회차든 계속한다.

| 코드 | 조건 | 감지 |
|---|---|---|
| `BLOCKED_CARVE` | 부트로더 이미지가 carve | static-analyzer 도출 (사실) |
| `BLOCKED_ASSET` | 부팅 자산 없음 | 파일 체크 |
| `BLOCKED_KO` | K3 인데 **`.ko` 부재 AND 커널 빌트인도 아님** | static-analyzer 도출 |
| `BLOCKED_BUILD` | ninja 실패 | 빌드 결과 (추측 수정 금지) |
| `BLOCKED_ENV` | **실행 환경 미비** (WSL 부재 · QEMU/capstone 미설치) | `check_env.sh` 선행 검사 |
| `BLOCKED_TEE` | vold/Keymint/TEEGRIS 시큐어월드 | 범위 밖 — 미달로 정직 기록 |
| `EXHAUSTED` | **무브 소진** | `stop_conditions.py` |

**무브 소진**은 회차 카운트가 아니라 가능한 수의 소진이다. 셋이 **동시** 성립할 때만:

```
(지문 정체 또는 A↔B 진동)
AND static-analyzer 에스컬레이션이 새 사실 0
AND 담당 fixer 전원이 "새로 시도할 변경 없음"
```

**dryness 는 마지막 한 줄이 아니라 최근 창(기본 3회차)으로 판정한다.** 한 회차의
반짝임이 수십 회차의 정체를 지우면 소진은 영원히 성립하지 않는다.

**두 입력 모두 사실이어야 한다.** "새 사실 0" 은 분석가가 세는 숫자가 아니라
`derived_facts.py` 가 **도출표에 늘어난 줄을 센 값**이다 (같은 시그니처 재도출 = 0).
"fixer 소진" 도 **실제로 물어본 fixer 의 답**이어야 한다 — 아무도 안 부른 회차를
전원 포기로 기록하면 소진 조건이 거짓으로 성립한다.

**정지 판정은 LLM 이 뒤집을 수 없다.** `stop=true` 인데 supervisor 가 계속을 내면
pipeline 이 강제 정지하고 모순을 JOURNAL 에 기록한다. 매몰비용("한 번만 더")이
정직성을 이기지 못하게 하는 장치다.

정지 산출물: 최고 마일스톤 · **최고 부팅 깊이** · 마지막 지문 · 시도한 변경 목록 ·
**재개 안내**. `success=false`, **REAL 표기 금지.** 정지는 포기가 아니라 정직한
인계이며 재개 가능하다.

`runtime_round_cap`(기본 120)은 **목표 판정이 아니라 런타임 한계**다. 도달하면
"런타임 한계 — 재개 가능" 으로 보고하지, "도달 불가" 라고 하지 않는다.

---

## 지문은 최초 예외로 잡는다 — 정지·에스컬레이션·층판정의 입력값

```
지문 = (최초 예외의 ESR/FAR/ELR, 마일스톤, 콘솔 바이트, 콘솔 고유줄, 예외 수 자릿수)
```

핸들러가 자기 컨텍스트 세이브에서 다시 폴트하면 abort 가 중첩되어 FAR 이 매 반복
0x20 씩 걷다가 **타임아웃이 끊은 자리**에서 멈춘다. 그래서 트레이스의 **마지막 FAR
은 재귀의 위치이지 원인이 아니고, 같은 정지점인데도 회차마다 다르다.**

그 값을 지문에 쓰면 두 가지가 동시에 죽는다 — 분류기는 실재하지 않는 정지점을
이름 붙이고(그 처방은 매핑을 늘려도 sweep 이 옮겨갈 뿐 수렴 불가), `stall_count`
는 영원히 0 이라 소진·에스컬레이션·층 재검토가 **한 번도 발화하지 않는다.**

- 원인은 `fingerprint.json` 의 `origin` (블록 전문은 `07_logs/origin_N.txt`).
- 마지막 FAR/ELR 은 `far`/`elr` 로 따로 보존한다 — 기록이지 진단 입력이 아니다.
- 예외 수는 **자릿수**로 비교한다 (2.86M 과 2.88M 은 같은 관측).

### 부팅 깊이 — 사다리가 한 칸일 때의 유일한 전진 신호

등급 A 사다리는 `[표면]` 한 칸이라, 부팅이 PMIC 를 지나 스토리지 초기화까지 걸어가도
`best_milestone` 은 계속 null 이다. `best_progress.uniq`(**콘솔 고유 줄 수**)가 그
깊이를 센다. 바이트가 아니라 고유 줄인 이유는 재시도 루프가 같은 에러 한 줄로 394KB
를 찍기 때문이다 — 그건 전진이 아니다.

`timeout_bound=true` 는 **더 오래 돌리니 콘솔이 더 나왔다**는 뜻이다. 그 벽은 펌웨어가
아니라 우리 실행 시간이므로 fixer 를 보내지 않는다.

### 실행되지 않은 회차는 회차가 아니다

QEMU 가 시작조차 못 하면 지문은 전부 0 으로 완벽히 안정되고, 그건 정체로 읽혀
`EXHAUSTED`(구조상 도달 불가)가 된다 — 실행된 적 없는 펌웨어에 대해서. 그래서
`run_qemu.sh`/`run_kernel.sh` 는 종료코드와 트레이스·콘솔 0바이트를 검사해
`run_failed` 를 세우고, 파이프라인은 그 회차에 `BLOCKED_ENV` 로 **정지**한다.
하네스 문제를 펌웨어 판정으로 바꾸지 않기 위해서다.

### 고친 소스가 실제로 빌드되는가

fixer 는 `06_machine/machine.c` 를 고치고 ninja 는 QEMU 트리의 `hw/arm/` 사본을
빌드한다. 둘을 잇는 것이 `sync_machine.sh` 이며 **회차 적용·rebuild·general fixer
모두 ninja 앞에 이것을 부른다.** 없으면 검문을 통과하고 빌드도 성공하는데 이전
바이너리를 측정하게 되고, 그 회차는 "무효 변경" 으로 기록된다.

---

## 층 — 루프가 못 고치는 것이 있다

fixer 는 **이미 있는 머신 소스의 한 곳**을 고친다. 머신이 **무엇을 전제로 만들어졌는지**는
못 고친다 — `has_el3`, 진입 EL, 진입 PC, 로드/링크 주소, 메모리 골격, CPU 타입.

| 층 | 예 | 고치는 주체 |
|---|---|---|
| **loop** | 미매핑 MemoryRegion, 미처리 SMC id, 안 끝나는 폴링, 틀린 분기 | fixer (회차당 한 변경) |
| **build** | `has_el3`, 진입 EL, 진입 PC, 로드 주소, 메모리 골격 | **rebuild — 어떤 fixer 도 못 닿는다** |

전제가 틀리면 fixer 는 증상만 처치한다. 벡터 베이스를 망가뜨리는 명령을 NOP 하는 것은,
이미지를 틀린 EL 로 진입시킨 게 원인일 때 다음 증상을 남겨둘 뿐이다. **한 지문으로
수십 회차를 보내는 런어웨이가 이렇게 생긴다.**

`futile_changes`(변경했는데 지문 불변)가 임계를 넘으면 `needs_layer_review` 가 서고,
supervisor 는 **라우팅 전에 머신 소스를 읽고 층을 판정**한다. Build 층이면 `rebuild` 로
구체적 전제 수정을 지정한다. 같은 `change_key` 의 재시도는 거부된다 — rebuild 가 무한
공급이면 소진이 성립할 수 없기 때문이다.

## 정직성 규칙 7 항 (어기는 변경은 무효)

1. **추측 stub 금지.** 특히 적응형 토글 (예: "12회 read=0, 그 뒤 0xFFFFFFFF 교대").
   펌웨어를 잘못된 분기로 보내 "우연한 통과" 로 끝난다.
2. **우회는 우회로 명시.** 펌웨어 패치를 정상 모델처럼 표현 금지. 매 우회는
   `[대상 / 이유 / 방법 / 부작용]` 4 항으로 문서화 (`06_machine/bypasses.md`).
3. **모든 주소·구조·바이트열은 분석으로 도출.** 도구는 둘뿐 —
   디스어셈블(capstone) / 실행관찰(`qemu -d exec,int,unimp,guest_errors`).
4. **하드코딩을 분석처럼 위장 금지.** 미확정은 "미확정 — N단계에서 확정" 으로.
5. **못 간 지점은 못 갔다고 기록.** 가짜 통과 금지.
6. **성공은 실제 트레이스/콘솔/메모리 캡처로만 판정.** 문자열 regex 단독 = 불인정.
7. **머신 안 입력 자가주입 금지.** 우리가 찍은 문자열을 도달로 세지 않는다.

### 집행 주체 (규칙은 프롬프트 권고가 아니라 구조)

| 규칙 | 집행 |
|---|---|
| 자가주입 금지 (§7) | `run_*.sh` **출처 게이트** — 매 회차 자동 |
| 실증거로만 판정 (§6) | `verify.py` 측정 + verifier 비대칭 override |
| 추측 stub 금지 (§1) | `fault-classifier` `unknown` → `static-analyzer` 도출 |
| 회차 = 한 변경 | `check_change.sh` diff 검문 |
| 우회 4항목 | `check_change.sh` (없으면 되돌림) |
| pre-image 검증 | `patch_kernel.py` (불일치면 적용 거부) |
| 무한 루프 금지 | `stop_conditions.py` |
| 값 차용 금지 | `static-analyzer` (모든 값에 이 펌웨어 근거) |

---

## 검증 5/5 — 2 단, 방향 비대칭

```
1 단계 (스크립트)  verify.py → verdict_script.json      ← 측정
2 단계 (verifier)  원시 로그·바이트로 재검증            ← 최종 판정
```

| 방향 | 규칙 |
|---|---|
| **낮추기** REAL→FORCED | verifier 가 **무조건 우선.** 의심스러우면 낮춘다 |
| **올리기** FORCED→REAL | **byte-level 증거를 제시할 때만.** 못 대면 스크립트 판정 유지 |

**5/5 = REAL. 4/5 이하 = FORCED (성공 표시 금지).** 부분 점수 없음.

### 트랙 1 (Table G)

| # | 항목 | 통과 조건 |
|---|---|---|
| 1 | PC 트레이스 | shell 함수 + exec_command 진입 PC 가 `-d in_asm` 로그에 등장 |
| 2 | 출력 byte-match | 콘솔 출력 모든 토큰이 BL3 binary 에 file offset 으로 존재 |
| 3 | 소스 negative | 머신 C 소스에 동일 출력 문자열 0 개 |
| 4 | UART 단일 경로 | `qemu_chr_fe_write_all` 호출 단 1 자리 |
| 5 | 우회 목록 | `[대상/이유/방법/부작용]` 4 항으로 N 개 우회 기재 |

### 트랙 2

| # | 항목 | 통과 조건 |
|---|---|---|
| 1 | 부팅 진행 | `Run /init` (K1) 이 콘솔·트레이스에 등장 |
| 2 | 커널 메시지 증거 | `erofs: (device dm-N): mounted` (K2) / `sda: sda1…`·`Power mode change` (K3) — **머신 아닌 커널이 찍은 줄** |
| 3 | 소스 negative | 머신 C 에 그 마운트/파티션 문자열 0 개 |
| 4 | 드라이버 진짜 구동 (K3) | 트랜잭션 로그에 UTRD/Query/SCSI, `.ko` 는 원본 + 문서화된 우회만 |
| 5 | 우회 목록 | 커널 패치 + `.ko` 패치 + SMC 셤 전부 4 항목 |

**K3 = 트랙 2 의 본령 — "컨트롤러를 구현하면서 리호스팅".** 목표는 rootfs 마운트가 아니라
**진짜 벤더 UFS 컨트롤러를 실제로 구동시키는 것**이고, 마일스톤은 그 완성도의 눈금이다.

| 단계 | 마일스톤 | 뜻 |
|---|---|---|
| — | `link_up` → `power_mode` → `scsi_attach` | 진행 중 (컨트롤러 미완성) |
| **K3a** | **`partitions_up`** (`sda: sda1…`) | **최소 완료** — 커널이 파티션을 열거 |
| **K3b** | `super_mounted` | **캡스톤 = 완전한 UFS 컨트롤러** |

**`partitions_up` 미도달 = UFS 컨트롤러 미완성.** 최고 마일스톤을 "미완" 으로 정직 보고하고
success·REAL 금지.

**캡스톤은 토폴로지가 정한다.** `super.img`(dm-linear, 보통 EROFS)가 있는 펌웨어만
`super_mounted` 에 도달할 수 있다. system/vendor 가 분리된 raw(ext4) 펌웨어는 구조상 그 줄을
찍을 수 없으므로 **K3a 가 완료**이며, 사다리에 캡스톤을 넣지 않는다(`has_super`).

### ★ `.ko` 부재 ≠ K3 불가 (K3\*)

벤더 드라이버가 커널에 빌트인(`CONFIG_SCSI_UFS_*=y`)이면 `.ko` 는 **설계상 존재하지 않는다.**
그래도 진짜 벤더 드라이버는 커널 안에 있고, HCI 를 모델링하면 그 드라이버가 구동한다.

| 사실 | 판정 |
|---|---|
| 벤더 `.ko` 있음 | **K3** — 진짜 모듈 로드 |
| `.ko` 없지만 `Image` 에 드라이버 심볼·문자열 있음 | **K3\*** — 빌트인 드라이버가 모델을 구동 |
| `.ko` 없고 `Image` 에도 없음 | **`BLOCKED_KO`** — 진짜 도달 불가 |

`.ko` 부재만 보고 블로커를 내면 **도달 가능한 실행을 거부**하는 것이다.

---

## 회차 기록 형식 (PROGRESS.md)

```
| run N | <정지점 신호> | <한 변경> |
```

한 회차 = 한 변경 = 한 줄. 여러 변경 묶기 금지 — `check_change.sh` 가 diff 로 막는다.

---

## 사용 가능한 슬래시 명령

- **`/sboot-rehost:rehost-init`** — 설치 후 1회. `rehost_workspaces/` + `_inbox/` 생성 + 의존성 설치.
- **`/sboot-rehost:rehost-setup <이름>`** — `_inbox/` 펌웨어 자동 인식 + 격리 워크스페이스
  생성(★ 덮어쓰기 금지) + 언팩·WSL 이동 + 트랙·등급 프롬프트 → INPUT.md + `.active`.
- **`/sboot-rehost:rehost-bootloader`** — 트랙 1 실행 → `pipeline.js({track: 1})`.
  S-Boot·LK·aboot 등 **벤더 구현체가 달라도 같은 단계이므로 같은 명령**이다.
- **`/sboot-rehost:rehost-kernel`** — 트랙 2 실행 → `pipeline.js({track: 2})`
- **`/sboot-rehost:rehost-status`** — 워크스페이스 목록 + 진행/검증/정지 요약
- **`/sboot-rehost:rehost-export`** — **목표 완료 확인 후** "빌드 없이 실행" 키트 조립 →
  `rehost_exports/<model>_<build>/track<N>/`. ★ 항상 gitignore, 미완이면 export 금지.

흐름: **install → `rehost-init` → `_inbox/` 드롭 → `rehost-setup <이름>` →
`rehost-bootloader`|`rehost-kernel`(자율) → (완료) `rehost-export`**.

---

## 작업 디렉터리 구조

```
<cwd>/rehost_workspaces/          ← 작업 루트 (Windows cwd 밑)
├── _inbox/                       ← 펌웨어 드롭
├── .active                       ← 실행 기본 대상 id
└── <id>/  (= <workdir>)
    ├── INPUT.md                   0차 입력 (track 슬롯 포함)
    ├── PROGRESS.md                회차 한 줄 이력 (사람)
    ├── JOURNAL.md                 ★ 세션·시행착오 기록 (사람, append-only)
    ├── metrics.jsonl              ★ 시간·토큰 측정 (기계)
    ├── rounds.jsonl               ★ 회차 지문/분류/fixer/효과 (기계)
    ├── blockers.jsonl             ★ 사실 하드 블로커 (기계)
    ├── fingerprint.json           마지막 회차 지문 (run 스크립트 원시 관측)
    ├── observation.json           마지막 회차 관측 문서 (지문 + 정지 조건 병합)
    ├── verdict_script.json        5/5 스크립트 1차 측정
    ├── VERIFICATION.md            verifier 2차 최종 판정
    ├── 06_machine/                machine 소스 + bypasses.md
    ├── 07_logs/                   회차별 콘솔 + 요약 + origin_N.txt (최초 예외)
    ├── 08_docs/                   분석 메모 · static_archive.md (이관된 도출 근거)
    │                              (+ .record/ 타이머 · rounds/N/ 회차별 소스 스냅샷)
    ├── 10_reproduce/              재현 키트
    ├── (트랙 1) STATIC.md · milestone_tokens.txt · 01_firmware/ 02_unpacked/
    │            03_bootloader/ 04_static-analysis/
    └── (트랙 2) KERNEL_STATIC.md · fw/ (Image.patched, *.dtb, initramfs, super)

WSL ext4 (대용량):
  ~/rehost/<id>/       펌웨어 실행 사본
  ~/rehost/_traces/    회차별 전체 `-d` 트레이스
```

**기록 위치 원칙**: 사용자가 보는 기록·해결과정은 **로컬 Windows cwd**,
대용량 쓰기(실행 사본·전체 트레이스)는 **WSL ext4**.

**세션은 어느 쪽에서 띄워도 된다.** WSL 안에서 띄우면 그대로 돌고, Windows 에서 띄우면
`scripts/*` 의 `wsl_bridge.sh` 가드가 `wsl.exe -e` 로 건너간다 (`-e` 는 argv 를 그대로
넘기므로 인용 계층이 늘지 않는다). 파일 배치는 두 경우 모두 같다 — 폴더·문서는 Windows,
실행·트레이스는 WSL.

---

## 사용자 의도 파악

- "다시 검증해줘 / 진짜야?" → `verifier` 즉시 호출 (필요하면 `verify.py` 부터)
- "방향 맞아?" → `stop_conditions.py` 결과 + `rounds.jsonl` 분류 분포로 사실 보고
- "9820 / 다른 분석가 자료 참고" → `methodology/worked_example.md` 재읽기

사용자가 명시적으로 다른 명령을 주지 않는 한 실행 명령(트랙 1 `/sboot-rehost:rehost-bootloader`,
트랙 2 `/sboot-rehost:rehost-kernel`)의 파이프라인을 따른다.
