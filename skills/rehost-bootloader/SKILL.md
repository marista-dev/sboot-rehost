---
name: rehost-bootloader
description: 트랙 1 (부트로더 단계) 실행. 부팅 체인에서 커널 직전의 부트로더를 QEMU 위에서 진짜로 실행해 그 부트로더의 인터랙티브 표면(UART 셸 또는 fastboot/USB)에 도달한다. Samsung S-Boot(AArch64) · MediaTek LK(AArch32) · Qualcomm aboot 등 벤더 구현체가 달라도 같은 단계이므로 같은 명령이다. INPUT.md(track 1)로 workflows/pipeline.js 를 track=1 로 호출.
disable-model-invocation: true
---

당신은 **트랙 1 (부트로더 단계)** 실행 오케스트레이터.
`/sboot-rehost:rehost-bootloader` 호출 시 **`workflows/pipeline.js` 를 `track: 1` 로 호출**한다.
(커널 단계는 `/sboot-rehost:rehost-kernel`.)

## 이 명령이 다루는 자리

```
BROM → Preloader / BL1·BL2 → ★ 부트로더 ★ → 커널
                              │
        Samsung Exynos ───────┤ S-Boot   (AArch64)
        MediaTek       ───────┤ LK       (AArch32 Thumb)
        Qualcomm       ───────┤ aboot
        일반 임베디드     ───────┘ U-Boot
```

ARM TF-A 용어의 **BL33(non-secure world bootloader)** 자리다. **벤더 구현체가 달라도 같은
단계이므로 같은 명령**이며, 구현체 차이는 `profiles/` 와 목표 표면이 흡수한다.

### ★ 실행 범위 — 위 그림은 "어느 자리인가" 지도이지 리호스팅 범위가 아니다

**실행하는 것은 BL33 하나뿐이다.**

| 단계 | 우리가 하는 것 |
|---|---|
| BROM · BL1(EPBL) · BL2 | **실행 안 함.** 이들이 남겼을 상태(부트정보 SFR 등)는 모델로 성립 |
| EL3 monitor (TF-A/TEEGRIS) | **실행 안 함.** 최소 EL3 shim이 `smc` 를 SMCCC_SUCCESS 로 받고 EL1 로 내려줌 |
| **BL33** | **진짜로 실행.** 리셋 스텁 → main → 디바이스 init → 셸 루프 전부 원본 바이너리 |
| 커널 | 범위 밖 (`/sboot-rehost:rehost-kernel`) |

멀티스테이지 컨테이너(`sboot.bin` 등)는 **통째로 로드하되 BL33 세그먼트만 실행**한다.
진입 PC 는 파일 오프셋 0(TOC 헤더)이 아니라 **도출된 BL33 리셋 진입점**이다 — 헤더로
진입하면 헤더를 코드로 실행해 첫 워드에서 트랩한다.

우리가 만드는 것은 **그 코드가 접근하는 환경**뿐이며 두 종류를 구분한다:

- **모델링**(정상 모델): UART, GIC, DRAM 골격, 부트정보 SFR, PMIC/I2C 폴 레지스터 등
- **shim·우회**(FORCED 요소): EL3 monitor shim, 셸과 무관한 서브시스템 중화, 게이트 플래그 우회
  → 전부 `bypasses.md` 4항목 기재

**★ 실행은 자율이다.** `AskUserQuestion` 호출 금지.
**★ 회차 수·소요 시간은 멈출 이유가 아니다.** 멈추는 경우는 구조상 도달 불가일 때뿐이며,
그 판정은 `scripts/stop_conditions.py` 가 소유한다.

---

## ★ 목표는 "인터랙티브 표면" 이다 — 셸이 전부가 아니다

부트로더마다 **사용자 명령을 받는 경로가 다르다.** 목표는 "셸" 이 아니라
**그 부트로더에서 실제로 도달 가능한 인터랙티브 표면**이다.

| 표면 | 무엇 | 도달 증거 | 대표 |
|---|---|---|---|
| `shell` | UART 콘솔 명령 루프 | 프롬프트 + `help` 출력 | Samsung S-Boot |
| `fastboot` | USB 명령 dispatch | `getvar:` 수신·에코·dispatch | MediaTek LK |

`INPUT.md` 의 `bl_surface` 슬롯이 결정하며, **static-analyzer 가 사실로 확정**한다.

### 등급 A/B/C — 표면 위에서 얼마나 깊이 동작하나

| 등급 | 사다리 | `shell` 표면 | `fastboot` 표면 |
|---|---|---|---|
| **A** | `[표면]` | 프롬프트 + `help` 출력 | `getvar:` 수신·에코·dispatch |
| **B** | `[표면, commands]` | `reset`·`printenv` 등 핸들러 동작 | `flash`·`reboot` 등 핸들러 동작 |
| **C** | `[표면, commands, autoboot]` | autoboot 진행 | 부트모드 결정 → 커널 로드 |

각 단의 관측 문자열은 **static-analyzer 가 도출**해 `<workdir>/milestone_tokens.txt` 에
`<마일스톤>\t<토큰>` 형식으로 쓴다. 파일이 없으면 표면 기본 토큰만 쓰이므로 **등급 A 만
관측 가능**하다 — B/C 를 목표로 잡았다면 이 파일이 반드시 있어야 한다.

### 표면을 잘못 잡으면 도달 불가를 도달로 착각한다

실제 사례(MediaTek LK): 12명령 콘솔이 바이너리에 **실재하지만** UART 드라이버에 수신
경로가 없고(출력 전용), 어떤 USB 리더도 그 명령 테이블을 참조하지 않아 **인터랙티브
도달이 구조적으로 불가능**했다. 트램폴린으로 `help` 를 강제 호출해 출력시키는 건
**FORCED**(등급 A 아님)이고, 진짜 도달 가능한 표면은 **fastboot** 였다.

static-analyzer 가 이걸 도출하면:
- 표면을 `fastboot` 로 확정하고 계속 진행하거나,
- 어느 표면에도 입력 경로가 없으면 **`BLOCKED_NO_INPUT_PATH`** 로 정직하게 정지한다.

---

## Step 0 — 워크스페이스 확정 + 선행 조건

1. `WORKROOT = <cwd>/rehost_workspaces`. `workdir=<id>` 또는 `.active`.
   없으면 "먼저 `/sboot-rehost:rehost-setup <이름>`" 안내 후 종료.
2. **`INPUT.md` `track: 1`** 확인. `track: 2` 면 `/sboot-rehost:rehost-kernel` 안내 후 종료.
3. **부트로더 이미지**: `bootloader_path` (구 워크스페이스의 `bl3_path` 도 인식).
4. **SoC 계열·표면**: `soc_family`(exynos | mediatek | generic)와 `bl_surface`.
   미확정이면 그대로 두고 넘긴다 — static-analyzer 가 확정한다.

## Step 0.5 — JOURNAL 세션 시작 (필수)

```
bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/sboot-rehost:rehost-bootloader" "track 1, <soc_family>, surface <bl_surface>, target <A/B/C>"
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
    bootloader_path: '<INPUT.md bootloader_path 또는 bl3_path>',
    soc_family: '<exynos | mediatek | generic>',
    bl_surface: '<shell | fastboot | 미확정이면 생략>',
    arch: '<arm64 | arm32>',
    plugin_dir: '<PLUGIN_DIR>',
    run_timeout_s: <INPUT.md run_timeout_s, 없으면 생략 (기본 20)>,
  }
})
```

`run_timeout_s` 는 **한 회차의 벽시계 예산**이다. 부트로더가 표면까지 걸어가는 시간은
펌웨어마다 다르고 전량 트레이스가 그 시간을 늘린다 — S921N 은 프롬프트가 벽시계
5.2~8.0 초에 나왔다. 예산이 그 시간과 비슷하면 같은 펌웨어가 호스트 속도에 따라
"미도달" 이 된다. 콘솔이 늘고 있는데 회차가 끊긴다면 먼저 이 값을 올린다.

### 파이프라인 단계

| 단계 | 하는 일 |
|---|---|
| **Analyze** | `static-analyzer` — **표면 판정 먼저**, 그다음 carve/entry/linker/load/Δ/cmd 테이블/핸들러. `profiles/<soc_family>.yaml` 의 힌트 사용. AArch32 대상은 `carve_disasm.py --arch arm32` |
| **Build** | 표면·아키텍처에 맞는 템플릿으로 머신 소스 생성 → QEMU 통합 + ninja |
| **Loop** | `run_round.sh` → 지문 + **출처 게이트** → `supervisor` → `fault-classifier` → **1 순위 fixer 한 변경** → 검문 → ninja |
| **Verify** | `verify.py --track 1 --surface <표면>` 5/5 측정 → `verifier` 재검증 |
| **Package** | `10_reproduce/` |

## Step 2~5 — 보고 · 정지 · 검증 · 세션 종료

정지 사유별 보고:

| stop_reason | 의미 |
|---|---|
| `BLOCKED_CARVE` | 부트로더 이미지가 carve (부분 추출) |
| **`BLOCKED_ENV`** | **실행 환경 미비** — WSL 부재 또는 QEMU·capstone 미설치. 목표 판정이 아니라 환경 문제이며, 갖추면 그대로 재개된다. (Windows 에서 띄운 세션은 `wsl_bridge.sh` 가 자동으로 WSL 로 건너간다) |
| **`BLOCKED_NO_INPUT_PATH`** | **어느 표면에도 인터랙티브 입력 경로가 없음** — 구조적 불가 |
| `BLOCKED_BUILD` | ninja 실패 (원문 그대로) |
| `EXHAUSTED` | 시도 소진 |

전부 `success=false`, **REAL 표기 금지**, 재실행하면 이어서 진행.

검증은 **5/5 = REAL, 4/5 이하 = FORCED**. 항목 4 는 표면별로 검사 대상이 다르다 —
`shell` 은 **UART 단일 출력 경로 + 입력이 외부에서 옴**, `fastboot` 은 **입력이 외부에서 옴**.
어느 쪽이든 머신이 자기 콘솔에 입력을 넣으면 불통과다.

마지막에 반드시:
```
bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/sboot-rehost:rehost-bootloader" "<결과>"
```

---

## 구성 요소

| 이름 | 역할 |
|---|---|
| `static-analyzer` | **표면 판정** + 도출 + 미지 정지점 에스컬레이션 |
| `supervisor` | 라우팅·정지 (정지 조건은 뒤집을 수 없음) |
| `fault-classifier` | 정지점 분류 + fixer 순위 |
| `fixer-memory` / `fixer-el3` / `fixer-bootflow` | 담당 오류 직접 수정 (회차당 하나) |
| `fixer-general` | 위 셋이 전부 반려했을 때만. 범위 무제한 (수정·빌드·실행) + 후보 기록 |
| `verifier` | 5/5 2 차 재검증 (비대칭 override) |

## ★ 이 명령은 스토리지 컨트롤러 구현으로 가지 않는다

트랙 1 의 목표는 **부트로더의 인터랙티브 표면**이다. 진짜 벤더 UFS 컨트롤러를 구동시키는
것은 **트랙 2 K3 의 목표**이며 이 명령의 범위가 아니다.

| | 트랙 1 등급 C | 트랙 2 K3 |
|---|---|---|
| 스토리지 | autoboot 이 막히지 않을 만큼 (스텁·우회 가능, 4항목 문서화) | **진짜 벤더 드라이버 구동** |
| 판정 | autoboot 진행 토큰 | `sda: sda1…` 파티션 열거 |

파이프라인이 이걸 구조로 집행한다 — 트랙 1 회차에는 `fixer-storage` · `fixer-kernel` 이
후보에 오르지 않고, 분류기에는 `knowledge/faults_bootloader.md` 만 넘어간다.
`verify.py` 의 UFS 항목도 K3 에서만 켜진다. **등급 A 목표라면 스토리지는 등장할 이유가 없다.**

## ★ 셸 도달은 autoboot 게이트를 넘는 문제다

부트로더는 부팅 중 콘솔을 잠깐 폴링해 **특정 바이트의 연속 입력**(대개 CR `0x0d` N회)이
있으면 셸로, 없으면 autoboot 으로 간다. 게이트는 보통 **one-shot** 이라, 그 창이 열려 있는
동안 그 패턴이 도착해야 한다. 못 넘기면 다른 모든 게 맞아도 표면은 도달 불가다.

- **연타 수 N 과 게이트 주소는 도출값**이다. static-analyzer 가 셸 함수의 첫 `bl`(게이트)을
  디스어셈블해 `<workdir>/input_plan.json` 에 쓴다.
- 입력은 `scripts/uart_harness.py` 가 **QEMU 밖에서** 넣는다. 게이트가 열릴 시점을 알 수
  없으므로 창 동안 반복 시도하고, 프롬프트가 관측되면 명령을 보낸다.
- 보낸 바이트는 전부 `07_logs/input_N.txt` 에 남는다 — 우리가 친 것과 펌웨어가 찍은 것을
  구분할 수 있어야 한다.
- 도출 실패 시 하니스는 **문서화된 기본값(CR×3)** 을 쓰고 "기본값이었다" 고 기록한다.

## 정직성

- 트램폴린으로 명령 출력을 강제하는 것은 **도달이 아니라 FORCED** 다.
  "사용자 입력 → dispatcher" 가 성립해야 도달이다.
- 입력은 **외부에서** 와야 한다. 머신이 명령을 지어내면 순환검증이다 (정직성 §7).
  머신이 RX 버퍼를 스스로 채우면 `verify.py` 항목 4 가 **두 표면 모두에서** 불통과시킨다.
- 5/5 미달 시 "REAL"·"성공" 금지.
