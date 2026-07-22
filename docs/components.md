# sboot-rehost 컴포넌트 정리

아키텍처의 각 컴포넌트를 **실행 순서대로** 정리한 문서.
각 컴포넌트마다 역할 · 정체 · 입력/출력 · 동작 과정 · 규칙을 항목화했다.

> **설계 원칙 — 측정은 스크립트, 해석·제어는 LLM, 정지의 입력값은 사실.**

---

## 목차

| # | 컴포넌트 | 정체 | 한 줄 |
|---|---|---|---|
| 1 | [Analysis](#1-analysis) | LLM | 바이너리·자산 → 근거 있는 사실 |
| 2 | [Build](#2-build) | 스크립트 + LLM | 사실 → 머신 소스 → ninja |
| 3 | [Run](#3-run) | 스크립트 | 실행 → 지문 + 출처 게이트 |
| 4 | [Manage](#4-manage) | LLM + 스크립트 | 라우팅 · 정지 |
| 5 | [Diagnosis](#5-diagnosis) | LLM | 정지점 이름 + 담당 fixer 순위 |
| 6 | [Fix](#6-fix) | LLM + 스크립트 | 한 변경 수정 + 검문 |
| 7 | [Verify](#7-verify) | 스크립트 + LLM | 5/5 측정 → 재검증 |
| 8 | [Package](#8-package) | 스크립트 + LLM | 재현 키트 · export |
| — | [트랙 2 의 목표](#트랙-2-의-목표--진짜-ufs-컨트롤러-구현) | — | K3 = 컨트롤러를 구현하면서 리호스팅 |
| — | [데이터](#데이터-지식--프로세스-분리) | YAML/MD | 등록부 · 지식 테이블 · 프로필 |
| — | [기록](#기록-사람용--기계용) | 스크립트 | JOURNAL · JSONL |
| — | [명령](#슬래시-명령) | 스킬 | 사용자 진입점 |

## 전체 플로우

```
[Analysis] → (Build) → ┌─ (Run) → [Manage] ─┬─ 도달 → 사다리 다음 / [Verify]
                       │                     ├─ 정지 → ★ 구조상 도달 불가
                       │                     ├─ 미지·정체 → [Analysis 재도출]
                       │                     └─ 실패 → [Diagnosis] → [Fix] ─┐
                       └──────────────────────────────────────────────────┘
                                                              → (Package)
```

**LLM 중 코드를 고치는 것은 Fix 의 fixer 뿐이다.** 나머지는 읽기 전용이다.

---

# 트랙 2 의 목표 — 진짜 UFS 컨트롤러 구현

트랙 2 를 "커널을 부팅시켜 rootfs 를 마운트하는 것" 으로 읽으면 목표를 놓친다.

> **K3 는 트랙 2 의 본령이다 — "컨트롤러를 구현하면서 리호스팅".**
> 목표는 **진짜 벤더 UFS 컨트롤러를 실제로 구동시키는 것**이고,
> 마일스톤은 별개의 목표가 아니라 **그 컨트롤러의 완성도를 재는 눈금**이다.

K1(유저스페이스)·K2(rootfs 마운트)는 그 도중에 지나가는 지점이다. 제네릭 스토리지로
rootfs 를 마운트하면 K2 는 되지만 **컨트롤러는 한 줄도 구현되지 않은 것**이므로 K3 가 아니다.

## 핵심 발상 — 드라이버를 계측기로 쓴다

데이터시트가 없다. 대신 **진짜 벤더 드라이버가 어느 레지스터를 폴링하고 무슨 값을
기다리는지 관찰해서** 모델을 채운다. 드라이버가 곧 컨트롤러 사양서다.
로그에 값의 출처가 안 보이면 `.ko`(또는 커널 이미지) 를 역어셈블해 확정한다 — 추측하지 않는다.

## 완성도 사다리

| 단계 | 마일스톤 | 커널이 찍는 줄 | 뜻 |
|---|---|---|---|
| | `link_up` | `scsi host0: ufshcd` · `… UFS link established` | 링크 |
| | `power_mode` | `Power mode change(0): M(1)G(3)…` | 전원모드 협상 |
| | `scsi_attach` | `[sda] Attached SCSI disk` | 디바이스 인식 |
| **K3a** | **`partitions_up`** | `sda: sda1 sda2 sda3 sda4` | **최소 완료 — 커널이 파티션 열거** |
| **K3b** | `super_mounted` | `erofs: (device dm-N): mounted` + `supermount: SUCCESS` | **캡스톤 = 완전한 UFS 컨트롤러** |

**`partitions_up` 미도달 = UFS 컨트롤러 미완성.** 최고 마일스톤을 "미완" 으로 정직 보고하고
success·REAL 을 쓰지 않는다. 중간에서 멈춘 것은 완료가 아니다.

## 두 가지가 목표를 정한다 — 노력이 아니라 사실

### ① 드라이버 형태 — `.ko` 부재는 불가가 아니다

커널이 UFS 를 빌트인(`CONFIG_SCSI_UFS_*=y`)으로 컴파일하면 **`.ko` 는 설계상 존재하지 않는다.**
그래도 진짜 벤더 드라이버는 커널 안에 있고, HCI 를 모델링하면 그 드라이버가 구동한다.

| 사실 (Analysis 가 도출) | 판정 |
|---|---|
| 벤더 `.ko` 있음 | **K3** — 진짜 모듈 로드 |
| `.ko` 없지만 `Image` 에 드라이버 심볼·문자열 | **K3\*** — 빌트인 벤더 드라이버가 모델을 구동 |
| `.ko` 없고 `Image` 에도 없음 | **`BLOCKED_KO`** — 진짜 도달 불가 |

`.ko` 부재만 보고 블로커를 내면 **도달 가능한 실행을 거부**하는 것이다.

### ② 이미지 토폴로지 — 캡스톤이 존재하는가

| 토폴로지 | 캡스톤 |
|---|---|
| `super.img` (dm-linear, 보통 EROFS) | `super_mounted` 적용 → K3b 까지 |
| `system`/`vendor` 분리 raw (보통 ext4) | **캡스톤 없음 — K3a 가 완료** |

분리형 펌웨어는 `supermount: SUCCESS` 를 **구조적으로 찍을 수 없다.** 사다리에 캡스톤을
남겨두면 존재할 수 없는 목표를 요구하게 되므로, `has_super` 로 사다리에서 뺀다.

## 어느 컴포넌트가 무엇을 맡나

| 컴포넌트 | UFS 컨트롤러에 대한 역할 |
|---|---|
| [Analysis](#1-analysis) | DTB 에서 HCI base·IRQ 도출, **드라이버 형태(모듈/빌트인)와 토폴로지 판정**, 값의 출처가 코드면 역어셈블 |
| [Build](#2-build) | `storage_hci.c.tmpl` 로 컨트롤러 모델 골격 생성 |
| [Run](#3-run) | 마일스톤 관측 + 출처 게이트 (커널이 찍은 줄만 인정) |
| [Manage](#4-manage) | 사다리 전진·정지 판정 |
| [Diagnosis](#5-diagnosis) | 벽에 이름 붙이기 (`knowledge/faults_storage.md`) |
| [Fix](#6-fix) | `fixer-storage` 가 레지스터 모델·UPIU 필드·`.ko` 우회를 한 변경씩 |
| [Verify](#7-verify) | **K3 는 `partitions_up` 필수** — 중간 마일스톤으로는 통과 못 함. K3a/K3b 를 구분해 보고 |

---

## 1. Analysis

### 역할
대상 펌웨어를 디스어셈블·파싱해 **근거가 붙은 사실**을 도출한다. 처방은 하지 않는다.

### 정체
LLM — `agents/static-analyzer.md`

### 입력 → 출력
```
INPUT.md, BL3 또는 fw/, profiles/*.yaml
  (에스컬레이션 시) 지문 · 요약 로그 · 전체 트레이스
    → STATIC.md / KERNEL_STATIC.md  +  facts JSON
```

### 동작 과정 — `mode=prior` (루프 전 1회)

| 트랙 1 (12 도출) | 트랙 2 |
|---|---|
| ① **carve 판정** (가장 먼저) | ① 부팅 자산 타입 확인 |
| ② entry 오프셋 (부팅 패턴 점수) | ② DTB → cpu/DRAM/GIC/UART/HCI base/cmdline |
| ③ linker base (basefind) | ③ 보안게이트 사이트 (fips·defex·selinux·avb) |
| ④ load base | |
| ⑤ Δ 산출 + **정합 검증** | |
| ⑥ cmd 테이블 + 엔트리 포맷 | |
| ⑦ cmd list head | |
| ⑧ shell 함수 | |
| ⑨ 콘솔 vtable 3 슬롯 | |
| ⑩ heap allocator | |
| ⑪ BL2 핸드오프 매직 | |
| ⑫ getline timeout 분기 | |

### 동작 과정 — `mode=escalation` (루프 중)
받은 질문 하나에 집중한다. 넓게 다시 훑지 않는다.
- "ELR 0x… 에서 뭐가 실행 중인가" → 그 주소 디스어셈블 + 호출자 xref
- "이 값은 어디서 오나" → 문자열 → `.rela.text` → `.text` → `readl(창+오프셋)` 확정
- "미확정 슬롯이 이번 fault 로 확정되나" → 관측된 FAR/ELR 로 확정

### 규칙
1. **도출만, 차용 금지** — 다른 기기 값을 가져오지 않는다
2. **모든 값에 근거** — capstone 라인+바이트 · fdt 노드 · `.rela` 엔트리
3. **미확정은 미확정으로** + 확정 계획(`confirm_plan`)
4. **pre-image 검증** 없는 패치 사이트는 확정 금지
5. **머신 소스 수정 금지**

### ★ 정지 조건과의 연결
에스컬레이션에서 새 사실이 없으면 **`new_facts_count=0` 으로 정직하게 보고**해야 한다.
이 값이 무브 소진 판정의 입력이므로 부풀리면 루프가 끝나지 않는다.

### 하드 블로커
`carve_is_full=false`(트랙 1) · `assets_ok=false`(트랙 2) → 즉시 정지.

### 쓰는 도구
`carve_disasm.py`(capstone 래퍼 — `carve_check`/`score_entry`/`disasm`/`find_xref_to`),
`fdtdump`, `readelf`, `objdump`, `strings`, `xxd`

---

## 2. Build

### 역할
도출된 사실로 머신 소스를 만들고 QEMU 에 통합해 빌드한다.

### 정체
LLM(템플릿 채움) + 스크립트(패치·빌드)

### 입력 → 출력
```
STATIC.md / KERNEL_STATIC.md + templates/*.tmpl
  → 06_machine/machine[_kernel].c (+ <hci>.c)
  → hw/arm/ 등록 → ninja → qemu-system-aarch64
```

### 동작 과정
1. 템플릿 슬롯을 **도출된 값으로만** 채운다
2. (트랙 2) `patch_qemu_core.py` — QEMU 코어 SMC 패치 (멱등)
3. (트랙 2) `patch_kernel.py` — 게이트 사이트 적용. **pre-image 불일치면 적용 거부**
4. `hw/arm/` 복사 + `meson.build` 등록
5. `ninja qemu-system-aarch64`
6. `-M help` 로 머신 등록 확인
7. `bypasses.md` 준비 (헤더만이라도)

### 규칙
- **도출되지 않은 값을 지어내지 않는다.** 미확정 슬롯은 주석으로 명시한다.
- **빌드 에러는 추측으로 고치지 않는다.** 원문 그대로 보고하고 `BLOCKED_BUILD` 로 정지.

### 템플릿
| 파일 | 쓰임 |
|---|---|
| `machine.c.tmpl` | 트랙 1 머신 |
| `machine_kernel.c.tmpl` | 트랙 2 머신 |
| `storage_hci.c.tmpl` | 트랙 2 K3 스토리지 컨트롤러 |

---

## 3. Run

### 역할
QEMU 를 실행하고 **원시 지문을 추출**하며 **출처 게이트를 집행**한다.
한 회차를 통째로 수행해 **관측 문서 하나**를 낸다.

### 정체
스크립트 — `run_round.sh` → `run_qemu.sh` | `run_kernel.sh`

### 입력 → 출력
```
머신 + 펌웨어 자산
  → 07_logs/console_N.txt      콘솔        (로컬)
  → 07_logs/run_N.summary.txt  핵심 정지점 (로컬)
  → ~/rehost/_traces/run_N.log 전체 트레이스 (WSL ext4)
  → fingerprint.json           원시 지문
  → observation.json           지문 + 정지조건 병합 문서
```

### 동작 과정
```
journal try-start
  → check_change snapshot        (fixer 수정 전 원본 확보)
  → run_qemu.sh | run_kernel.sh
       ① timeout 으로 QEMU 실행
       ② 요약 로그 생성
       ③ 지문 추출
       ④ 마일스톤 판정 + 출처 게이트
       ⑤ fingerprint.json + record.py metric
  → stop_conditions.py           (정지 조건)
  → python3 병합 → observation.json
```

### 지문
```
(예외 개수, FAR, ELR, 마일스톤, 콘솔 바이트 수)
```
**원시 관측값이며 분류 결과가 아니다.** 16진 주소는 문자열로 보존한다 — 정수로 바꾸면
로그 표기와 어긋나고 대소문자 차이가 뭉개져 지문 비교가 깨진다.

### ★ 출처 게이트 (자가주입 금지 집행)
도달 문구를 콘솔에서 찾으면 **그 문자열이 머신 소스(`06_machine/*.c`)에 있는지** 검사한다.
있으면 우리가 찍은 것이므로 도달로 인정하지 않는다.

- **매 회차** 집행한다. 이전에는 맨 끝 5/5 에서 한 번만 해서, 가짜 도달 뒤 회차가
  전부 헛수고가 됐다.
- **주입은 지배적이다** — 토큰 하나라도 주입이면 다른 토큰이 깨끗해도 마일스톤 전체를
  인정하지 않는다. 콘솔이 이미 오염됐는데 다른 토큰으로 도달을 주면 프롬프트를 위조한
  머신이 셸을 주장할 수 있다.
- 오탐(주석에 우연히 토큰)은 경고가 토큰을 지목하므로 이름만 바꾸면 된다.
  **거짓 미달(회차 몇 번)보다 거짓 도달(가짜 성공)의 비용이 훨씬 크다.**

### 마일스톤 보고
**도달한 단을 전부** 보고한다(`milestones_reached`). 최고 단 하나만 보고하면 사다리가
건너뛴 단(K3 에는 `rootfs` 가 없다) 때문에 이미 도달한 하위 단이 가려진다.

### ★ 왜 `run_round.sh` 가 병합까지 하는가
이전에는 실행 스크립트의 `key=value` 출력과 정지 조건 JSON 을 **에이전트가 합치게** 했다.
`stop` 을 잘못 옮기면 정지 백스톱이 약해진다. 병합을 스크립트로 내려, 에이전트는
**자기가 만들지 않은 문서 하나를 전달**할 뿐이다.

`run_ok=false` 는 fingerprint 미생성을 뜻하며, QEMU 실행 자체가 실패한 회차가 깨끗한
회차로 위장되지 않게 한다.

---

## 4. Manage

### 역할
회차 루프의 제어자. **계속할지 · 누구에게 맡길지 · 멈출지**만 정한다.

### 정체
LLM(`agents/supervisor.md`) + 스크립트(`stop_conditions.py`)
— **판단은 LLM, 정지의 입력값은 스크립트가 측정**

### 입력 → 출력
```
observation.json (지문 + 정지 조건)
  → route · progress · stop_reason · decision_note
```

### 동작 과정 — 라우팅 (위에서부터 먼저 걸리는 것)

| # | 조건 | route |
|---|---|---|
| 1 | `stop == true` | `stop` |
| 2 | 관측 마일스톤 == 목표 | `verify` |
| 3 | 관측 마일스톤 > 목표 | `next_goal` |
| 4 | `escalate_to_analyst == true` | `static-analyzer` |
| 5 | 그 외 | `fault-classifier` |

### 진전의 정의
```
진전 = 지문 변화 또는 마일스톤 상승      → 정체 카운터 0
정체 = 지문 동일 그리고 마일스톤 동일    → 카운터 +1
```
분류 이름이 아니라 **원시 숫자로** 잰다. 같은 문제를 회차마다 다르게 부르면 정체를
영영 감지하지 못한다.

### 정지 조건 (`stop_conditions.py` 가 계산)

**정지 사유는 "구조상 도달 불가" 뿐이다. 회차 수·소요 시간은 정지 사유가 아니다.**

| 코드 | 조건 | 감지 |
|---|---|---|
| `BLOCKED_CARVE` | BL3 가 carve | Analysis 도출 (사실) |
| `BLOCKED_ASSET` | 부팅 자산 없음 | 파일 체크 |
| `BLOCKED_KO` | K3 인데 벤더 `.ko` 부재 | 파일 체크 |
| `BLOCKED_BUILD` | ninja 실패 | 빌드 결과 |
| `BLOCKED_TEE` | 시큐어월드 (vold·Keymint·TEEGRIS) | 범위 밖 |
| `EXHAUSTED` | 무브 소진 | 계산 |

**무브 소진**은 회차 카운트가 아니라 가능한 수의 소진이며, 셋이 **동시** 성립할 때만이다:
```
(지문 정체 또는 A↔B 진동)
AND Analysis 에스컬레이션이 새 사실 0
AND 담당 fixer 전원이 "새로 시도할 변경 없음"
```
에스컬레이션은 소진보다 **한 단계 먼저** 발화한다(정체 2 vs 3) — 도출이 한 번도 불리지
못한 채 소진 판정이 나는 것을 막기 위해서다.

### ★ LLM 이 뒤집을 수 없는 것
- `stop=true` 인데 다른 route 를 내면 **파이프라인이 강제 정지**하고 모순을 JOURNAL 에
  기록한다. "한 번만 더"는 이 컴포넌트의 권한이 아니다.
- **목표 전진도 주장할 수 없다** — 관측되고 출처 게이트를 통과한 마일스톤만이 사다리를
  움직인다.
- 오류 비용이 비대칭이기 때문이다. **잘못 멈추면 재개하면 되지만(싸다), 안 멈추면
  예산이 그냥 탄다(되돌릴 수 없다).**

### 정지 산출물
최고 마일스톤 · 마지막 지문 · 시도한 변경 목록 · **재개 안내**.
`success=false`, **REAL 표기 금지.** 정지는 포기가 아니라 정직한 인계다.

`runtime_round_cap`(기본 120)은 **런타임 한계이지 목표 판정이 아니다.**

### 목표 사다리
| 트랙/등급 | 사다리 |
|---|---|
| 트랙 1 (A/B/C) | `shell` |
| K1 | `userspace` |
| K2 | `userspace` → `rootfs` |
| K3 | `userspace` → `link_up` → `power_mode` → `scsi_attach` → **`partitions_up`** → `super_mounted` |

---

## 5. Diagnosis

### 역할
로그를 읽고 **정지점에 이름을 붙이고**, 등록부에서 담당 fixer 순위를 매긴다.
고치는 방법은 말하지 않는다.

### 정체
LLM — `agents/fault-classifier.md`

### 입력 → 출력
```
observation.json · 콘솔 · 요약 로그 · (필요 시) 전체 트레이스
STATIC.md/KERNEL_STATIC.md · rounds.jsonl · knowledge/*.md · fixers/registry.yaml
  → category · evidence · novelty · fixer_ranking[] · escalation_request
```

### 동작 과정
1. **로그를 끝에서부터** 읽는다 (마지막 에러가 실제 실패 지점에 가장 가깝다)
2. 지식 테이블의 시그니처와 대조해 이름을 고른다
3. **근거가 된 로그 줄을 인용**한다
4. 등록부에서 담당 fixer 를 찾아 순위를 매긴다
5. 어디에도 안 맞으면 `unknown` + 에스컬레이션 요청

### 정지점 이름

| 트랙 1 | 트랙 2 커널 | 트랙 2 스토리지 |
|---|---|---|
| `data_abort_unmapped` | `kernel_oops` | `poll_stall` |
| `infinite_poll` | `security_gate` | `desc_addr_corrupt` |
| `smc_undef` | `smc_undef` | `pwrmode_timeout` |
| `null_ret` | `gic_ppi` | `gear_source` |
| `console_silent` | `unmapped_mmio` | `upiu_field_off` |
| `fpu_trap` | `rootfs_mount` | `block_size` |
| `shell_exit_early` | `psci_suspend` / `hvc_pkvm` | `vendor_telemetry_null` |

\+ **`unknown`**

### fixer 순위 기준
1. 로그 시그니처가 가장 정확히 일치하는 것
2. `rounds.jsonl` 기준 **아직 시도 안 한 변경**을 가진 쪽
3. 최근 연속 실패한 fixer 는 순위를 낮춤

**실제로 실행되는 것은 1 순위 하나뿐**이고 나머지는 다음 회차 후보로 남는다
(회차 = 한 변경).

### ★ "unknown" 이 정상 답인 이유
새 SoC 의 처음 보는 fault 를 기존 이름에 억지로 끼우면 신규성이 묻히고, 엉뚱한 fixer 가
추측으로 고쳐 **그럴듯하게 부팅되는 가짜**를 만든다. 확신이 없으면 `unknown` 을 내는 것이
손해가 없다 — **이것이 "분류에 쓰기 권한을 주지 않는" 이유**다. 고칠 게 있어야 하는
입장이 아니면 없는 병명을 지어낼 동기가 없다.

### 금지
처치 제안 · 소스 편집 · **지문 변경·재해석** · 억지 분류 · 등록부에 없는 오류의 임의 배정

---

## 6. Fix

### 역할
배정받은 정지점을 **소스에서 직접 고친다**. 그리고 그 변경이 규칙을 지켰는지 검문받는다.

### 정체
LLM 5종(`agents/fixer-*.md`) + 스크립트 검문(`check_change.sh`)
— **LLM 중 유일하게 쓰기 권한**

### 입력 → 출력
```
분류 결과 · 지문 · 도출된 사실 · 06_machine/ · rounds.jsonl · bypasses.md
  → 소스 편집 (한 군데) + bypasses.md 4항목 + change JSON
  → check_change verify → 통과하면 ninja, 위반이면 되돌림
```

### fixer 분화

분화 기준은 **담당 오류 + 쓰는 도구**다. 계층이나 트랙이 아니다.
`smc_undef` 는 트랙 1·2 양쪽에서 나오지만 고치는 방법이 같아 `fixer-el3` 하나가 맡는다.

| fixer | 담당 오류 | 고치는 것 | 도구 |
|---|---|---|---|
| **memory** | `data_abort_unmapped` `infinite_poll` `unmapped_mmio` | MemoryRegion · read 콜백 | fdtdump |
| **el3** | `smc_undef` `psci_suspend` `hvc_pkvm` `fpu_trap` | SMC 핸들러 · PSCI 컨듀잇 · CPU 초기 상태 | capstone |
| **bootflow** | `null_ret` `console_silent` `shell_exit_early` | entry redirect · 콘솔 라우팅 · getline timeout | capstone |
| **kernel** | `security_gate` `kernel_oops` `gic_ppi` `rootfs_mount` | 커널 `.text` 패치 · GIC 배선 · DT fstab | capstone · fdtdump · patch_kernel.py |
| **storage** | `poll_stall` `desc_addr_corrupt` `pwrmode_timeout` `gear_source` `upiu_field_off` `block_size` `vendor_telemetry_null` | UFS HCI 레지스터 모델 · UPIU 필드 · `.ko` 우회 | readelf · objdump |

### 공통 규칙 (어기면 검문에서 되돌려진다)

| # | 규칙 | 이유 |
|---|---|---|
| 1 | **한 회차 한 군데** | 무엇이 효과를 냈는지 알 수 있어야 한다 |
| 2 | **추측 stub·적응형 토글 금지** | "N 번째 읽기부터 값 변경"은 엉뚱한 분기로 보내 우연한 통과를 만든다 |
| 3 | **우회 4항목 기록** | `대상 / 이유 / 방법 / 부작용` |
| 4 | **같은 수정 두 번 금지** | `change_key` 조회 |
| 5 | **값 출처 모르면 에스컬레이션** | 추측 대신 도출 |
| 6 | **정체 시 이전 우회부터 의심** | `부작용` 칸이 지금 벽의 원인일 수 있다 |
| 7 | **담당 아니면 반려** | `not_mine: true` |
| 8 | **새 시도 없으면 정직 보고** | `no_new_change: true` — 정지 조건의 입력 |

### 검문 (`check_change.sh`)

| 검사 | 방법 | 위반이면 |
|---|---|---|
| 소스 파일 1개만 바뀌었나 | 스냅샷과 diff | 되돌림 |
| hunk 가 `MAX_HUNKS`(기본 3) 이하인가 | `diff -u \| grep -c '^@@'` | 되돌림 |
| 우회 4항목이 갖춰졌나 | `대상:` `이유:` `방법:` `부작용:` 개수 일치 | 되돌림 |

**프롬프트로 부탁하는 대신 diff 를 세서 막는다.** 되돌려진 회차는 `rounds.jsonl` 에
`effect=reverted` 로 남아 성공으로 위장되지 않는다.

### 각 fixer 의 주의점
- **memory** — `infinite_poll` 에 `0xFFFFFFFF` 금지. 다른 비트까지 켜져 엉뚱한 분기로 간다.
- **el3** — 패치 전 **ELR 을 디스어셈블해 정말 `smc`/FP 인지 확인**. 확인 없는 NOP 은 뒤를 오염시킨다.
- **bootflow** — `null_ret` 은 NOP 으로 안 풀린다(원인은 앞에서 널을 리턴한 함수).
  `console_silent` 을 머신 출력으로 해결하면 **자가주입**이다.
- **kernel** — 커널·`.ko` 패치는 **pre-image 불일치면 적용 거부**.
  `gic_ppi` 는 DTB 상대번호가 아니라 **풀 INTID**(30/27/26/29).
- **storage** — **적응형 토글이 이 도메인에서 가장 유혹적이고 가장 해롭다**
  (드라이버가 그럴듯하게 진행되기 때문). `desc_addr_corrupt` 는 UTRD 32 바이트 원시
  덤프로 가설을 배제한 뒤 결론 낸다.

---

## 7. Verify

### 역할
도달이 **진짜인지** 5 항목으로 판정한다. 2 단, 방향 비대칭.

### 정체
스크립트 측정(`verify.py`) + LLM 재검증(`agents/verifier.md`)

### 입력 → 출력
```
콘솔 · 전체 트레이스 · 머신 소스 · BL3/커널 · bypasses.md
  → verdict_script.json  (1 단계 측정)
  → VERIFICATION.md      (2 단계 최종 판정)
```

### 동작 과정
```
1 단계 (스크립트)  verify.py → 5 항목 코드 측정 → verdict_script.json
2 단계 (verifier)  원시 로그·바이트로 재검증 → VERIFICATION.md
```

2 단계에서 보는 것: 그 PC 가 정말 실행됐나(근처 주소는 아닌가) · 짧은 토큰이 우연히
일치한 건 아닌가 · 문자열 분할·매크로로 숨긴 건 아닌가 · 그 줄을 커널이 찍었나
(부트로더 잔상인가).

### ★ 방향 비대칭

| 방향 | 규칙 |
|---|---|
| **낮추기** REAL→FORCED | **verifier 무조건 우선.** 의심스러우면 낮춘다. 증거 불필요 |
| **올리기** FORCED→REAL | **byte-level 증거를 제시할 때만.** 못 대면 스크립트 판정 유지 |

성공을 만들어내는 방향에만 증거를 요구한다. `up` override 인데 증거가 비면 **무효**다.

### 측정 항목

| # | 트랙 1 | 트랙 2 |
|---|---|---|
| 1 | PC 트레이스 (shell 함수·`exec_command`) | 부팅 진행 `Run /init` |
| 2 | 출력 byte-match (콘솔 토큰 ⊂ BL3) | 커널 메시지 증거 (등급별) |
| 3 | 소스 negative (머신 C 에 출력 문자열 0개) | 소스 negative |
| 4 | UART 단일 경로 (`qemu_chr_fe_write` 1자리) | 드라이버 진짜 구동 (K3 만) |
| 5 | 우회 기록 4항목 | 우회 기록 4항목 |

트랙 2 등급별: K1 = #1,#3,#5 / K2 = +#2(erofs) / K3 = +#2(sda1) +#4.
항목 1 의 PC 는 `--pc` 를 주지 않으면 **`STATIC.md` 에서 자동 도출**한다.

### 판정
**5/5 = REAL, 4/5 이하 = FORCED.** 부분 점수 없음.
5/5 라도 "5/5 통과, REAL 판정"까지만 말하고 "성공했습니다"라고 단정하지 않는다.

### 검증 2층 구조

| | 출처 게이트 (Run) | 검증 5/5 (Verify) |
|---|---|---|
| 언제 | **매 회차** | 종료 시 1회 |
| 무엇을 | 이 줄, 대상이 찍었나 우리가 찍었나 | REAL / FORCED 최종 판정 |
| 쓰임 | 지문 신뢰성 → 루프 제어 | 보고 |
| 비용 | 싸다 (grep) | 비싸다 (byte-match + 트레이스) |

**"계속할지"를 정하는 건 출처 게이트이지 5/5 가 아니다.** 5/5 는 도달 전엔 통과할 수도 없다.

### K3 완료 기준
```
link_up → power_mode → scsi_attach → partitions_up(최소 완료) → super_mounted(완전)
```
**`partitions_up` 미도달이면 최고 마일스톤을 "미완"으로 정직 보고하고 success·REAL 금지.**

---

## 8. Package

### 역할
결과를 **다른 사람이 재현·실행**할 수 있는 형태로 조립한다.

### 정체
스크립트(`make_export.sh`) + LLM(서술 문서)

### 두 산출물

| | `10_reproduce/` | `rehost_exports/<fw>/track<N>/` |
|---|---|---|
| 만드는 것 | 파이프라인 (자동) | `/sboot-rehost:rehost-export` |
| 언제 | 파이프라인 종료 시 | **목표 완료 확인 후에만** |
| 무엇 | 워크스페이스 내 재현 자료 | **빌드 없이 실행** 키트 (프리빌트 QEMU 포함) |

### export 구조
```
rehost_exports/<fw>/track<N>/
├── run.sh              ← 받는 사람은 이것만 실행
├── setup.sh            공유 라이브러리 설치 (최초 1회)
├── bin/                프리빌트 QEMU
├── firmware/           BL3 또는 Image/dtb/initrd
├── machine/            머신 소스 + bypasses.md
├── scripts/            patch·build 스크립트
├── docs/               01_what-was-built ~ 06_verification
└── evidence/           VERIFICATION · JOURNAL · PROGRESS · 콘솔
                        + metrics.jsonl · rounds.jsonl · verdict_script.json
```

### 서술 문서 (docs/)
| 파일 | 근거 |
|---|---|
| `01_what-was-built.md` | 트랙·등급·도달 지점 |
| `02_boot-chain.md` | 부팅 체인 상 진입점 |
| `03_trial-and-error.md` | JOURNAL 시행착오 + `rounds.jsonl` 분류 분포 |
| `04_timeline.md` | JOURNAL 시각 + `metrics.jsonl` 소요·토큰 |
| `05_bypasses.md` | `bypasses.md` 4항목 |
| `06_verification.md` | **1·2 단계 판정 둘 다** + 갈렸으면 근거 |

### 규칙
- **미완이면 export 금지.** 완료로 위장하지 않는다.
- 서술은 실제 JOURNAL·VERIFICATION·콘솔 근거로만. 없는 결과를 지어내지 않는다.
- `rehost_exports/` 는 **항상 gitignore** (대용량·저작권). 폴더를 zip/복사로 전달한다.

---

## 데이터 (지식 / 프로세스 분리)

에이전트 프롬프트에는 "테이블을 어떻게 쓰는가"만 담고, "무슨 항목이 있나"는 데이터로 뺐다.

> **새 정지점 = 테이블 한 줄. 새 fixer = 파일 하나 + 등록부 몇 줄.**
> 어느 쪽도 프롬프트나 오케스트레이션 코드를 건드리지 않는다.

### fixers/registry.yaml
**오류 이름 → 담당 fixer** 매핑. Diagnosis 가 이름을 붙인 뒤 여기서 담당을 찾는다.
```yaml
fixers:
  fixer-storage:
    handles: [poll_stall, desc_addr_corrupt, pwrmode_timeout, ...]
    knowledge: [knowledge/faults_storage.md]
    tools: [readelf, objdump, capstone]
unmapped_policy: escalate_to_static_analyzer
```

**등록부에 없는 오류는 어느 fixer 에게도 가지 않는다** — Analysis 도출로 간다.
★ **만능 폴백 fixer 를 두지 않는다.** 이 도메인은 틀린 추측이 **그럴듯하게 부팅되는
가짜**를 만들기 때문이다.

**언제 더 쪼개나** — 미리 상상하지 않고 `rounds.jsonl` 데이터로 판단한다:
담당 오류 10종 초과 · 쓰는 도구가 갈림 · 특정 오류가 여러 펌웨어에서 반복 ·
특정 오류 성공률이 유독 낮음.

### knowledge/
| 파일 | 내용 | 참조 |
|---|---|---|
| `faults_bootloader.md` | 트랙 1 정지점 7종 + 4B 인코딩 | Diagnosis · fixer-memory/el3/bootflow |
| `faults_kernel.md` | 트랙 2 K1/K2 정지점 8종 + arch-timer INTID | Diagnosis · fixer-kernel/el3/memory |
| `faults_storage.md` | K3 벽 7종 + DME opcode + 마일스톤 사다리 | Diagnosis · fixer-storage |
| `kernel_gates.md` | 커널 보안게이트 **탐색 절차** | Analysis · fixer-kernel |

공통 형식: `| 이름 | 로그 시그니처 | 담당 fixer | 처치 방향 |` + **함정(Traps)** 절.

★ **값은 담지 않는다.** `kernel_gates.md` 가 대표적이다 — 오프셋은 커널마다 다르므로
찾는 절차만 적는다. 값을 적어 두면 다른 펌웨어에 그대로 가져다 쓰게 되고 그것이
차용 금지 위반이다.

### profiles/
SoC별 **"어디를 볼지" 힌트**. `generic.yaml` · `exynos.yaml` · `mediatek.yaml`.

| 담는다 | 안 담는다 |
|---|---|
| 찾아볼 ASCII 후보 · entry 스캔 범위 | 실제 주소·오프셋 |
| 읽을 DTB 노드 이름 | 그 노드의 실제 `reg` 값 |
| 게이트 탐색 키워드 | 게이트의 file offset |
| 스펙 상수 (DME opcode, arch-timer INTID) | — |

**새 SoC 대응** = `generic.yaml` 복사 후 힌트만 수정. 프롬프트는 건드리지 않는다.

---

## 기록 (사람용 / 기계용)

사람이 읽는 표는 세어볼 수 없고, 기계용 JSONL 은 읽기 불편하다. 그래서 둘을 분리한다.

### 사람용

| 파일 | 내용 | 쓰는 것 |
|---|---|---|
| `JOURNAL.md` | 세션·회차 서술 (**원인/분석/해결/증거**), 자동결정. 시각은 실제 `date` | `journal.sh` |
| `PROGRESS.md` | 회차 한 줄 이력 `\| run N \| 정지점 \| 한 변경 \|` | Fix |
| `VERIFICATION.md` | 검증 최종 판정 (1·2 단계 둘 다) | verifier |
| `STATIC.md` / `KERNEL_STATIC.md` | 도출된 사실 + 근거 | Analysis |
| `06_machine/bypasses.md` | 모든 우회의 `대상/이유/방법/부작용` | Fix |

**`부작용` 칸은 나중에 정체가 왔을 때 첫 번째 용의자로 읽힌다.** 성의 없이 쓰면
그때 쓸모가 없다.

### 기계용 (전부 JSONL, append-only, `record.py` 가 기록)

| 파일 | 내용 | 쓰임 |
|---|---|---|
| `metrics.jsonl` | **시간·토큰** 등 측정 이벤트 (단계마다 그때그때) | 소요·비용 집계, status, export 타임라인 |
| `rounds.jsonl` | 회차 1건 = 1줄 (지문·분류·fixer·`change_key`·효과) | ① 정지 조건 계산 ② 같은 변경 재시도 방지 ③ fixer 분화 근거 |
| `blockers.jsonl` | **사실로 감지된** 하드 블로커 | LLM 이 부정할 수 없는 정지 입력값 |

```json
{"ts":"2026-07-21T13:50:36+0900","epoch":1784609436,"elapsed_s":8,
 "round":12,"goal":"link_up","fp_far":"0x12860010","fp_milestone":"none",
 "category":"pwrmode_timeout","fixer":"fixer-storage",
 "change_key":"storage:uiccmd:dme_set_opcode","effect":"applied",
 "analyst_new_facts":0,"fixer_no_new_change":false,"tokens_total":124300}
```

`effect` = `progress` / `stall` / `applied` / `reverted`.
**16진 주소는 문자열로 보존한다** — 정수 변환은 지문 비교를 깨뜨린다.

### 회차 상태 파일
| 파일 | 내용 |
|---|---|
| `fingerprint.json` | 원시 지문 + `milestones_reached[]` + 출처 게이트 결과 |
| `observation.json` | 지문 + 정지 조건을 병합한 문서 (Manage 가 읽는 유일한 입력) |
| `verdict_script.json` | 검증 5/5 1차 측정 |

### 위치 원칙
사용자가 보는 기록은 **로컬 작업 폴더**, 대용량 쓰기(실행 사본·전체 트레이스)는
**WSL ext4**(`~/rehost/<id>/`, `~/rehost/_traces/`).

---

## 슬래시 명령

```
/sboot-rehost:rehost-init          작업 루트 + _inbox/ 생성, 의존성 설치   (1회)
      │  _inbox/ 에 펌웨어 드롭
/sboot-rehost:rehost-setup <이름>   워크스페이스 + 트랙·등급 → INPUT.md
/sboot-rehost:rehost-bootloader          트랙 1 실행  ┐ 자율, 끝까지
/sboot-rehost:rehost-kernel         트랙 2 실행  ┘
/sboot-rehost:rehost-status         진행·검증·정지·소요 요약   (아무 때나)
/sboot-rehost:rehost-export         완료 후 "빌드 없이 실행" 키트
```

| 명령 | 사전 조건 |
|---|---|
| `rehost-bootloader` | `INPUT.md` track=1, `bl3_path` |
| `rehost-kernel` | track=2, `fw/Image`(+dtb, initrd) · K2/K3 면 `super_path` · **K3 면 벤더 `.ko`** |

**`rehost-setup` 만 사용자에게 묻는다** (실행 루프 중의 멈춤이 아니라 세팅 시점의 결정).
실행 명령은 시작하면 **끝까지 자율**이며 `AskUserQuestion` 을 호출하지 않는다.

---

## 정직성 규칙 7항과 집행 주체

규칙이 프롬프트의 부탁이면 안 지키면 그만이다. **각 규칙에 집행 주체가 있다.**

| # | 규칙 | 집행 주체 | 방법 |
|---|---|---|---|
| 1 | 추측 stub 금지 | **Diagnosis → Analysis** | `unknown` 이 도출로 이어져 추측할 자리가 없다 |
| 2 | 우회는 우회로 명시 | **`check_change.sh`** | 4항목 없으면 되돌림 |
| 3 | 모든 값은 분석으로 도출 | **Analysis** | 모든 값에 이 펌웨어 근거 |
| 4 | 하드코딩 위장 금지 | **`patch_kernel.py`** | pre-image 불일치면 적용 거부 |
| 5 | 못 간 지점은 못 갔다고 | **Manage** | 정지 산출물에 최고 마일스톤·미완 명시 |
| 6 | 실증거로만 판정 | **`verify.py`** | 5/5 코드 측정, 올리는 방향만 증거 요구 |
| 7 | 자가주입 금지 | **Run 출처 게이트** | 매 회차 머신 소스 grep |
| — | 회차 = 한 변경 | **`check_change.sh`** | diff 를 세서 막음 |
| — | 무한 루프 금지 | **`stop_conditions.py`** | 결정론 정지 |
| — | 매몰비용 정지 거부 | **`pipeline.js`** | 사실 정지 우회 시 강제 정지 |

### 자주 저지르는 위반

| 하고 싶은 것 | 왜 안 되는가 | 대신 |
|---|---|---|
| 폴링에 `0xFFFFFFFF` 반환 | 다른 비트까지 켜져 엉뚱한 분기 | 기다리는 비트를 도출해 그것만 set |
| read 카운트로 값 바꾸기 | 우연한 통과를 만든다 | 상수 ready 만 |
| 콘솔이 비어서 머신이 문자열 출력 | 자가주입, 게이트가 잡는다 | BL3 출력이 UART 로 가는 경로를 고친다 |
| `null_ret` 을 NOP 으로 덮기 | 증상만 이동 | 호출자를 역추적해 entry redirect |
| pre-image 없이 커널 패치 | 주소가 틀렸다는 신호를 놓친다 | `expected_word` 확인 후에만 |
| K3 를 제네릭 스토리지로 통과 | 목표 자체를 우회 | 등급을 K2 로 낮추거나 HCI 를 모델링 |
| 회차가 많아서 그만두기 | 정지 사유가 아니다 | 무브가 남아 있으면 계속 |
| 4/5 를 "거의 완료"로 보고 | FORCED 는 FORCED | 실패 항목을 그대로 보고 |

---

## 회귀 검증

```bash
bash tests/smoke.sh
```

가짜 QEMU 로 **결정론 계층 전체**(Run · Fix 검문 · Manage 정지 · Verify · 기록)를
38 케이스로 돈다.

**덮지 않는 것**: LLM 에이전트의 실제 판단 · Build 의 템플릿 채우기 ·
진짜 QEMU 부팅. 이 셋은 실제 펌웨어 실행에서만 검증된다.

---

## 방법론 원본

이 문서는 컴포넌트 관점의 정리다. 도출 절차와 표의 원본은 [../methodology/](../methodology/):
`instruction.md`(트랙 1) · `track2_kernel_storage.md`(트랙 2) ·
`general_tables.md`(Table A~M) · `worked_example.md`(수행 사례).
