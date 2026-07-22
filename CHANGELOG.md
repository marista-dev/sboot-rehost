# 변경 이력

이 플러그인은 `.claude-plugin/plugin.json` 의 `version` 을 올렸을 때만 사용자에게
업데이트가 전달된다. 각 버전에 무엇이 들어갔는지 여기에 기록한다.

업데이트 방법은 [README 2. 업데이트](README.md#2-업데이트) 참조.

---

## 0.10.4 — 2026-07-22

**실행 환경 선행 검사 — 못 도는 셸에서 회차를 태우지 않는다 (`BLOCKED_ENV`).**

네이티브 Windows 에서 실행하면 에이전트의 Bash 도구가 **Git Bash** 라서 `/mnt/c` 가
보이지 않고 Linux QEMU 도 돌지 않는다. 그런데 파이프라인은 이걸 평범한 정지점으로
취급해, 같은 이유로 매 회차 실패하면서 **런타임 한계(120회)까지 헛돌았다.**

실행 자체가 불가능한 셸은 목표 판정의 문제가 아니라 **선행 조건의 문제**다.

- `scripts/check_env.sh` 신설 — 셸 종류(`uname -s` 가 `MINGW*`/`MSYS*`/`CYGWIN*` 인지),
  워크스페이스 가시성, QEMU·python3·ninja·capstone(트랙 2 는 dtc)까지 한 번에 점검하고
  JSON 으로 낸다.
- `workflows/pipeline.js` 가 **Analyze 맨 앞**에서 호출한다. 실패하면 `record.py blocker`
  로 `BLOCKED_ENV` 를 사실로 남기고 **루프에 들어가기 전에** 정지한다.
- 보고 문구는 원인과 해결을 같이 준다 — "WSL 터미널에서 claude 를 실행하세요".
  Claude Code 공식 문서도 Linux 툴체인을 쓸 때는 WSL 안에서 설치·실행하도록 안내한다.
- **이것은 도달 불가 판정이 아니다.** 환경만 갖추면 같은 워크스페이스·`INPUT.md` 로
  그대로 재개된다.

스모크 테스트 5건 추가 (Git Bash 위장 셸, 안 보이는 워크스페이스) — 총 57건 통과.

---

## 0.10.3 — 2026-07-22

**`rehost-sboot` 별칭 제거 — 트랙 1 명령을 `rehost-bootloader` 하나로 통합.**

0.10.0 에서 개명하며 하위 호환용 별칭을 남겼는데, 같은 일을 하는 명령이 두 개 보이면
어느 것이 정본인지 모호하다. 통합이 목적이었으므로 별칭을 지운다.

- `skills/rehost-sboot/` 삭제 → 트랙 1 명령은 **`/sboot-rehost:rehost-bootloader`** 하나
- `scripts/setup_env.sh` 의 완료 안내, `examples/` README, `CLAUDE.md` 의 별칭 문구 정리

**이전에 `rehost-sboot` 을 쓰던 분은 `rehost-bootloader` 로 바꿔 부르면 됩니다.**
동작은 완전히 같습니다 (`pipeline.js` 를 `track: 1` 로 호출).

## 0.10.2 — 2026-07-22

전체 플로우 재검토에서 **표면·등급이 끝까지 이어지지 않는 지점 4곳**을 찾아 고쳤다.

- **`milestone_tokens.txt` 에 생산자가 없었다.** `run_qemu.sh` 가 읽기만 하고 아무도
  만들지 않아, 등급 B·C 를 목표로 잡아도 관측이 불가능했다. static-analyzer 체크리스트에
  작성 절차를 추가 (도출한 문자열만 쓸 것 — 머신에도 있으면 자가주입으로 처리된다).
- **표면 정정이 자율 계약을 어겼다.** static-analyzer 가 표면을 정정하면 파이프라인이
  "INPUT.md 를 고치고 재실행하라" 며 멈췄다. 표면 정정은 **도출된 사실**이지 구조적
  불가가 아니므로, 이제 사다리를 바꿔 그대로 계속하고 JOURNAL 에 결정만 남긴다.
  (사다리를 `goalsFor(surface)` 함수로 바꿔 실행 중 재계산 가능하게 했다.)
- **fault-classifier 가 신규 마일스톤을 몰랐다** — `fastboot`·`commands`·`autoboot` 이
  목록에 없어 도달을 보고할 수 없었다.
- **워크스페이스 폴더 이름 불일치** — setup 은 `03_bootloader` 를 만드는데 CLAUDE.md 는
  `03_bl3` 로 적혀 있었다.

### 문서
- `docs/components.md` 에 **"트랙 1 의 목표 — 부트로더의 인터랙티브 표면"** 절 신설.
  트랙 2 목표 절만 있고 트랙 1 은 없어, 표면·등급이 컴포넌트 문서에 0건이었다.
  LK 사례(명령 테이블은 실재하나 도달 불가)와 표면별 검증 항목 4 차이를 포함.
- 벤더 종속 표현 정리 (`BL3 가 carve` → `부트로더 이미지가 carve`).

## 0.10.1 — 2026-07-22

**등급을 실제 목표로 만들었다.** 다른 펌웨어를 세팅할 때 도달 수준을 고를 수 있어야
하는데, 트랙 1 의 A/B/C 가 정의도 없고 사다리에 반영되지도 않고 있었다.

### 유실됐던 등급 정의 복원 + 표면별 일반화
0.9.0 재작성 때 구 CLAUDE.md 의 `A=help / B=명령 핸들러 / C=autoboot` 정의가 사라져,
문서가 "A/B/C" 라고만 쓰고 뜻을 말하지 않고 있었다. 복원하면서 표면에 맞춰 일반화:

| 등급 | 뜻 | `shell` (S-Boot) | `fastboot` (LK) |
|---|---|---|---|
| **A** | 표면 도달 + 목록 명령 실행 | 프롬프트 + `help` | `getvar:` 수신·dispatch |
| **B** | 다른 명령 핸들러가 실제로 동작 | `reset`·`printenv` | `flash`·`reboot` |
| **C** | 부트로더가 정상 부팅 흐름 진행 | autoboot | 부트모드 결정 → 커널 로드 |

### 등급이 사다리를 결정한다
`LADDERS[1]` 이 등급과 무관하게 `[표면]` 하나였다 — A·B·C 를 골라도 같은 목표였다.
이제 `A: [표면]` · `B: [표면, commands]` · `C: [표면, commands, autoboot]`.

- `milestone_tokens.txt` 가 `<마일스톤>\t<토큰>` 형식을 지원한다. static-analyzer 가
  도출한 문자열을 쓰므로 **벤더 배너를 코드에 박지 않고도** B/C 단을 관측한다.
- 파일이 없으면 표면 기본 토큰만 쓰이므로 등급 A 만 관측 가능하다는 점을 명시.
- setup 의 등급 질문이 **판별한 표면에 맞춰 설명을 바꿔** 제시한다.

### 회귀
52 케이스 (등급 사다리 2 케이스 추가).

## 0.10.0 — 2026-07-22

**벤더 중립화.** MediaTek(SM-A136U / MT6833) 실제 산출물과 대조해, 트랙 1 이 Samsung
S-Boot 한 종류를 전제하고 있던 것을 부트로더 **단계** 전반으로 넓혔다.

### 명령 개명 — `rehost-sboot` → `rehost-bootloader`
`S-Boot` 은 삼성 Exynos 의 부트로더 **구현체 이름**이라 MediaTek LK·Qualcomm aboot 에
쓰면 틀린 이름이었다. 명령을 가르는 축은 **부팅 체인의 진입점**이지 벤더가 아니므로,
명령은 2개(부트로더 / 커널)를 유지하고 이름만 단계 이름으로 바꿨다.
`rehost-sboot` 은 별칭으로 남겼다 (→ **0.10.3 에서 제거**, 아래 참조).

### 목표를 "인터랙티브 표면" 으로 일반화
부트로더마다 사용자 명령을 받는 경로가 다르다. 목표는 셸이 아니라 **그 부트로더에서
실제로 도달 가능한 표면**이다.

| 표면 | 도달 증거 | 대표 |
|---|---|---|
| `shell` | 프롬프트 + `help` 출력 | Samsung S-Boot |
| `fastboot` | `getvar:` 수신·에코·dispatch | MediaTek LK |

- `bl_surface` 인자로 사다리·검증이 결정된다. setup 은 힌트만 주고 **static-analyzer 가
  사실로 확정**한다 (UART 수신 경로 유무, USB dispatcher 가 명령 테이블을 참조하는가).
- 검증 항목 4 가 표면별로 달라진다 — `shell` 은 **UART 단일 경로**, `fastboot` 은
  **입력이 외부에서 옴**(머신이 명령을 지어내면 순환검증).
- 새 하드 블로커 **`BLOCKED_NO_INPUT_PATH`** — 어느 표면에도 입력 경로가 없을 때.
  실제 LK 사례가 이걸 증명했다: 12명령 콘솔이 바이너리에 실재하지만 UART 는 출력
  전용이고 어떤 USB 리더도 그 테이블을 참조하지 않아 인터랙티브 도달이 구조적으로
  불가능했다(트램폴린으로 출력을 강제하는 건 FORCED).

### MediaTek 을 막고 있던 결함 (실제 lk.bin 으로 확인)
- **`carve_check` 가 S-Boot 잣대(4 MB + Exynos 문자열)를 모든 이미지에 적용**해,
  1.5 MB LK 를 carve 로 오판하고 `BLOCKED_CARVE` 로 **첫 단계에서 거부**했다.
  아키텍처별 기준(arm32: 512 KB + LK 문자열)으로 교정.
- **`find_xref_to` 가 8 바이트 포인터만 스캔** — AArch32 는 4 바이트라 명령 테이블을
  못 찾고 "없음" 으로 오판했다.
- `carve_disasm.py --arch arm64|arm32` 신설 (Thumb 디스어셈블, AArch32 진입 패턴 점수).
- `soc_family` · `arch` · `bootloader_path`(구 `bl3_path` 도 인식) 슬롯 도입.
- setup 이 파일·매직·문자열로 **SoC 계열과 부트로더를 사실로 판별**한다.

### MediaTek 트랙 2 지식 (코드 변경 없이 이득)
- **`cpu_cluster_mpidr`** — DTB `cpu reg` 와 QEMU cores-per-cluster 불일치로
  `psci cpu_on -22` → `cpuhp` 가 `cpu_hotplug_lock` 점유 → init 영구 블록.
  **에러 메시지 없이 부팅이 멈추는** 유형. MTK K1 의 실제 근본원인이었다.
- **`irq_edge_level`** — HCI 인터럽트는 level-triggered 여야 한다 (edge 면 UIC -110).
- **`is_bit_layout`** — IS 비트 위치 (UPMS 는 bit 4, bit 8 로 오해하기 쉬움).
- **`query_upiu_overwrite`** — 응답 UPIU 는 헤더+페이로드를 **1회** 로 써야 한다.
- **`sparse_super_gpt`** — Android sparse super 는 GPT 디스크가 아니다. LUN 합성 필요.
- 프로필 `mediatek.yaml` 확장 (LK 구조·엔트리 16 B·포인터 4 B·`-icount`·`initcall_debug`).

### 남은 격차 (정직 기록)
- **AArch32 머신 템플릿이 없다.** 트랙 1 MediaTek 은 Build 단계에서 AArch64 템플릿을
  쓰지 않고 **정직하게 실패를 보고**하도록 했다 — 잘못된 머신을 조용히 만드는 것보다
  낫기 때문이다. USB 컨트롤러 모델도 아직 없다.
- 트랙 2 MediaTek 은 지식·프로필이 준비됐으나, sparse super → GPT LUN 합성 도구는
  아직 없다.

### 회귀
하니스 45 → **50 케이스** (MediaTek 5 케이스 추가: carve 아키텍처 기준, fastboot 표면
마일스톤, 외부 입력 검증).

## 0.9.2 — 2026-07-22

실제 리호스팅 산출물(SM-G977N / Exynos 9820)과 대조해 **한 펌웨어 형상에 과적합된
전제**를 걷어내고, 트랙 2 의 목표를 문서·코드에 제대로 반영했다.

### 트랙 2 의 목표를 명시 — K3 = 진짜 UFS 컨트롤러 구현
- `docs/components.md` 에 **"트랙 2 의 목표 — 진짜 UFS 컨트롤러 구현"** 절 신설.
  목표는 rootfs 마운트가 아니라 컨트롤러를 구동시키는 것이고 마일스톤은 그 완성도의
  눈금이라는 점, "드라이버를 계측기로 쓴다" 는 핵심 발상, 어느 컴포넌트가 무엇을
  맡는지를 정리. 기존에는 `fixer-storage` 항목 하나로 격하돼 있었다.
- K3a(`partitions_up`, 최소 완료) / K3b(`super_mounted`, 캡스톤) 단계를
  `verify.py` · `knowledge` · `fixer-storage` · `CLAUDE.md` · 스킬에 일관 반영.

### 잘못된 REAL 을 막는 수정
- **`verify.py` K3 항목 2 가 3개 패턴의 OR 판정이라, `power_mode` 같은 중간
  마일스톤 하나만 있어도 통과했다.** 방법론이 "컨트롤러 미완성" 이라 규정한 상태에
  REAL 을 주던 홀 — `partitions_up` 필수로 교정하고 도달 단계를 `ufs_controller`
  필드로 보고.

### 오탐으로 REAL 을 깎던 수정
- **항목 3(소스 negative)** 이 주석과 `#include` 까지 검사해 정상 산출물을 누출로
  판정했다. 주석·include 를 제거하고 **문자열 리터럴만** 검사하도록 수정.
- **우회 4항목 검출**이 리터럴 `대상:` 만 찾아, `**대상**:` · `알려진 부작용` 같은
  실제 표기를 0건으로 읽었다. 마크다운 강조·표기 변형을 허용 (`verify.py`,
  `check_change.sh`).
- 두 오탐 탓에 실제 5/5 REAL 인 산출물이 3/5 FORCED 로 측정됐다.

### 형상 다양성 — 한 기기 형태를 보편으로 박지 않는다
- **`BLOCKED_KO` 정교화**: `.ko` 부재만으로 블로커를 내면 **도달 가능한 실행을
  거부**한다. 커널이 UFS 를 빌트인(`=y`)으로 컴파일하면 `.ko` 는 설계상 없고 진짜
  벤더 드라이버는 커널 안에 있다(**K3\***). 이제 `.ko` 부재 **그리고** 커널 이미지에도
  드라이버가 없을 때만 블로커이며, static-analyzer 가 사실로 도출한다.
- **rootfs 마일스톤**이 EROFS 전제였다. ext4(`EXT4-fs … mounted` /
  `VFS: Mounted root (ext4 …)`)와 `UFS link established` 변형을 수용.
- **캡스톤은 토폴로지가 정한다**: `super.img` 가 없는 분리형 system/vendor 펌웨어는
  `super_mounted` 를 구조적으로 찍을 수 없다. `has_super` 인자로 사다리에서 제외해
  존재할 수 없는 목표를 요구하지 않는다.
- `run_kernel.sh` 가 **0 바이트 initramfs**(system-as-root)를 `-f` 로 통과시켜 QEMU 에
  넘기던 문제 → `-s`.

### 지식 보강
- 새 정지점 **`prdt_stride`** 추가 — 벤더 확장 sg 엔트리(Samsung Exynos FMP 인라인
  암호: 16 B + 112 B = **128 B stride**)를 16 B 로 오독하면 read 는 `got == bytes` 로
  "성공" 하는데 멀티페이지 배치가 어긋나 유저스페이스가 엉뚱한 바이트를 실행한다.
- **"완전성은 정확성이 아니다"** 교훈 추가 — `got == bytes` 계측은 scatter 배치
  오류를 놓친다.
- 회귀 하니스에 형상 다양성 7 케이스 추가 (총 45).

## 0.9.1 — 2026-07-21

문서 보강. 기능 변경 없음.

- `docs/components.md` 신설 — 아키텍처의 각 컴포넌트를 실행 순서대로
  (Analysis → Build → Run → Manage → Diagnosis → Fix → Verify → Package) 정리.
  컴포넌트마다 역할 · 정체 · 입력/출력 · 동작 과정 · 규칙을 항목화.
- `README.md` 을 진입점으로 재작성하고 **업데이트 절** 신설 —
  CLI · VS Code 확장 각각의 절차, 자동 업데이트가 서드파티 마켓플레이스에서
  기본 비활성이라는 점, 업데이트가 안 될 때의 조치.

## 0.9.0 — 2026-07-21

**아키텍처 전면 재설계.** 측정은 스크립트, 해석·제어는 LLM, 정지의 입력값은 사실.

### 에이전트 재편 (8 → LLM 5 역할)
- `static-analyzer` — `bl3-analyzer` + `stub-locator` + `kernel-boot-analyzer` +
  `storage-modeler`(`.ko` 역어셈블) 병합. 사전 도출 + 에스컬레이션 2 모드
- `supervisor` 신설 — 회차 라우팅·정지
- `fault-classifier` 신설 — 분류를 수리에서 분리. `unknown` 이 정상 답
- `fixer-memory` / `el3` / `bootflow` / `kernel` / `storage` — 담당 오류 + 도구로 분화.
  LLM 중 유일하게 쓰기 권한
- `verifier` — 검증 5/5 의 2 차 재검증
- `critic` 삭제 — 정지 조건으로 흡수

### 결정론 계층 신설
- `run_round.sh` — 한 회차를 통째로 수행하고 관측 문서 하나(`observation.json`)를 냄
- `check_change.sh` — diff 로 "회차 = 한 변경" 강제, 우회 4항목 검문
- `stop_conditions.py` — 정지 조건 계산 (구조상 도달 불가만)
- `verify.py` — 검증 5/5 측정
- `record.py` — 시간·토큰 등 측정치를 `metrics.jsonl` · `rounds.jsonl` ·
  `blockers.jsonl` 로 실시간 기록
- `run_qemu.sh` / `run_kernel.sh` — 지문 추출 + **출처 게이트를 매 회차 집행**

### 파이프라인 통합
- `pipeline.js` + `pipeline_kernel.js` + `iter-loop.js` → **`pipeline.js` 하나**
  (`track` 인자 + 목표 사다리)
- 목표 전진을 **관측으로만** 판정 (supervisor 의 주장으로는 사다리가 움직이지 않음)

### 정지 정책 변경
- **회차 수·소요 시간은 더 이상 정지 사유가 아니다.** `max_iterations` 상한 제거
- 정지는 구조상 도달 불가만 — `BLOCKED_*` 5종 + `EXHAUSTED`(무브 소진)
- 사실로 측정된 정지를 LLM 이 우회하려 하면 파이프라인이 **강제 정지**

### 검증 2단화
- 스크립트가 5/5 를 측정하고, LLM 이 재검증
- **방향 비대칭** — 낮추기(REAL→FORCED)는 자유, 올리기는 byte-level 증거 필요

### 지식 / 프로세스 분리
- `fixers/registry.yaml` — 오류 이름 → 담당 fixer
- `knowledge/faults_bootloader.md` · `faults_kernel.md` · `faults_storage.md` ·
  `kernel_gates.md` — 정지점 테이블
- `profiles/generic.yaml` · `exynos.yaml` · `mediatek.yaml` — SoC 탐색 힌트(값 아님)
- 새 정지점 = 테이블 한 줄, 새 fixer = 파일 하나 + 등록부 몇 줄

### 수정한 결함 (전부 재현으로 확정)
- `grep -c` 가 0 매치일 때 `fingerprint.json` 이 깨지던 문제
- `verify.py` 항목 1 이 영구 FAIL 이라 REAL 도달이 불가능하던 문제
  (PC 를 `STATIC.md` 에서 자동 도출하도록 수정)
- 목표 초과 도달 시 사다리가 전진하지 않던 문제
- 사다리가 건너뛴 단 때문에 하위 도달이 가려지던 문제
- 에이전트 자유 텍스트를 통한 **쉘 인젝션** (단일따옴표 이스케이프로 차단)
- 에스컬레이션 임계값이 소진 임계값과 같아 도출이 한 번도 불리지 못하던 문제
- 회차 이중 기록으로 정체를 오탐하던 문제
- 콘솔이 오염돼도 다른 토큰으로 도달을 인정하던 출처 게이트 허점
- `record.py` 가 16진 주소를 정수로 바꿔 지문 비교가 깨지던 문제

### 기타
- `tests/smoke.sh` 신설 — 가짜 QEMU 로 결정론 계층을 검증하는 회귀 하니스 (38 케이스)
- 에이전트 프롬프트를 영어로, 사용자가 읽는 산출물은 한국어로 분리
- 우회 기록 파일명을 `bypasses.md` 로 (기존 워크스페이스의 옛 이름도 계속 인식)

---

## 이전 버전

| 버전 | 내용 |
|---|---|
| 0.8.1 | 슬래시 명령 네임스페이스화 (`/sboot-rehost:rehost-*`) + `disable-model-invocation` |
| 0.8.0 | `/rehost-init` 재도입 (폴더 스캐폴딩), 작업·예제 폴더 전부 gitignore |
| 0.7.0 | `/rehost-export` — 펌웨어·트랙별 "빌드 없이 실행" 키트 |
| 0.6.1 | `/rehost-setup` 이 이름만 받고, 트랙은 마지막에 프롬프트 |
| 0.6.0 | init→setup 통합, 펌웨어별 격리 워크스페이스, `_inbox` 자동 생성 |
| 0.5.0 | init/setup 분리, Windows cwd 문서 + WSL 대용량 쓰기, 자율 실행 |
| 0.4.0 | 두 트랙 분리, 실행 명령 분리, JOURNAL 기록, 자율 실행 |
| 0.2.0 | `/rehost-init` + `/rehost` 분리, 병렬 멀티에이전트용 `pipeline.js` |
