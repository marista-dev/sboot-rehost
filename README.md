# sboot-rehost

> Samsung 펌웨어 rehosting helper for Claude Code.
> 펌웨어 1 개 던지면 QEMU 안에서 **두 타깃** 중 하나로 자동 리호스팅.
>
> - **트랙 1 (sboot-shell)** — 부트로더 BL3 → 진짜 S-Boot 셸 + `help`
> - **트랙 2 (kernel-storage)** — 커널 직부팅 → 진짜 rootfs 마운트 → 진짜 벤더
>   스토리지 컨트롤러 (UFS 등) 모델 → Android 2 단계 init

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Quick Start

### 1) 설치 (한 번) — 세 방법 중 하나

이 리포는 자체 마켓플레이스(`.claude-plugin/marketplace.json`)를 포함하므로, 원격·로컬·zip
어느 쪽이든 `/plugin marketplace add <소스>` 로 등록한 뒤 설치한다.

**A. 마켓플레이스 (원격, 권장)**
```bash
claude
> /plugin marketplace add marista-dev/sboot-rehost
> /plugin install sboot-rehost@sboot-rehost-marketplace
```

**B. git clone (로컬)**
```bash
git clone https://github.com/marista-dev/sboot-rehost.git
claude
> /plugin marketplace add ./sboot-rehost          # marketplace.json 있는 로컬 폴더
> /plugin install sboot-rehost@sboot-rehost-marketplace
```

**C. zip 다운로드**
GitHub → **Code ▸ Download ZIP** → 압축 해제 후:
```bash
claude
> /plugin marketplace add /abs/path/to/sboot-rehost   # 압축 푼 폴더 (marketplace.json 있는 곳)
> /plugin install sboot-rehost@sboot-rehost-marketplace
```

설치 확인: `/plugin` 목록에 **sboot-rehost** 가 있고 `/rehost-init`·`/rehost-sboot`·
`/rehost-kernel`·`/rehost-status` 가 보이면 완료.

> 무거운 실행(빌드·QEMU·트레이스)은 **WSL2(Ubuntu)** 에서 돈다. Windows 라면 WSL2 안에
> clone/압축해제하고, Claude Code 도 그 경로에서 여는 것을 권장. (Claude Code 없이 스크립트만
> 쓰려면 `scripts/setup_env.sh` 등을 WSL 에서 직접 실행해도 된다.)

### 2) 셋업 → 트랙 실행

자율 실행이 기본이라 `/rehost-init` 에 입력을 **인자로** 주면 이후 멈춤 없이 끝까지 진행:

```bash
# 트랙 1 (S-Boot 셸)
> /rehost-init track=1 model=SM-S921N target=A bl3=/mnt/c/.../sboot.bin
> /rehost-sboot

# 트랙 2 (커널 + 스토리지)
> /rehost-init track=2 model=SM-S921N target=K3 bootimg=/path/boot.img super=/path/super.img.lz4 ko=/path/ufs-exynos-core.ko
> /rehost-kernel
```

대화형으로 단계마다 확인받으려면 `/rehost-init interactive` (INPUT.md `autonomous: false`).

흐름:

| 명령 | 역할 |
|---|---|
| **`/rehost-init`** | **셋업** — 의존성 설치 + 폴더 구조 + 펌웨어 추출 안내 + 사용자 질문 (**트랙 (1/2)** / 자산 경로 / 모델 / 등급 / 참조) → INPUT.md 생성 |
| **`/rehost-sboot`** | **트랙 1 실행** — `pipeline.js`. 정적 분석 → 머신 .c + ninja → 회차 루프 → 5/5 검증 → 재현 키트 |
| **`/rehost-kernel`** | **트랙 2 실행** — `pipeline_kernel.js`. 자산+DTB 골격 → 머신+코어/커널 패치 → K1 → K2 → K3 → 5/5 검증 → 재현 키트 |
| `/rehost-status` (옵션) | 진행 상황 한 화면 요약 (트랙 인식) |

**두 트랙은 별도 명령·별도 실행** (한 명령이 둘 다 돌리지 않음). `/rehost-init` 이 기록한
`track` 슬롯에 맞는 실행 명령 하나를 호출. 실행 명령은 트랙이 어긋나면 올바른 명령을 안내.

**자율 실행이 기본** (INPUT.md `autonomous: true`): 실행 중 `AskUserQuestion` 으로 멈추지 않고
CLAUDE.md 자율 정책으로 자동 결정 (critic 신호 → 계속 + 권고 적용, FORCED → 정직하게 마무리,
하드 블로커 → 중단+보고). 모든 자동 결정은 JOURNAL.md 에 기록. 대화형이 필요하면 INPUT.md 에
`autonomous: false`. 무인 장기·반복 실행은 `/loop` 셀프페이스로 실행 명령을 감싸면 된다.
입력(펌웨어 경로·모델·등급)은 `/rehost-init` 인자나 미리 채운 INPUT.md 로 선공급.

트랙별 등급:
- **트랙 1**: A=help / B=명령 핸들러 / C=autoboot
- **트랙 2**: K1=유저스페이스(`Run /init`) / K2=진짜 rootfs 마운트 / K3=진짜 벤더 스토리지
  HCI 모델로 벤더 드라이버가 파티션 구동

---

## 무엇을 하는가

`SM-S921N` (Galaxy S24, Exynos 2400) 의 S-Boot BL3 를 QEMU 에서 진짜로
실행시켜 다음을 출력:

```
autoboot aborted..
S-BOOT # help
Following commands are supported:
* dramtest  * reset  * usb  * upload  * findenv  * saveenv
* setenv    * printenv  * load_cp_header  * display  * uarten
* uartdis   * dprm  * check_nad_dram  * drawimg  * debore
* sod       * ufs_sod  * help
To get commands help, Type "help <command>"
S-BOOT #
```

이 출력의 **모든 문자열이 BL3 ROM 안에 실제로 존재** (주입 아님, 검증됨).
같은 방법론을 **다른 Samsung 펌웨어** (S922N, S925N 등) 에도 자동 적용.

---

## 작동 방식 — 셋업 1 + 트랙 실행 1

```
┌─────────────────────────────────────────────────────┐
│  /rehost-init         (1 회 — 셋업, 트랙 선택)
└─────────────────────────────────────────────────────┘
  의존성 검사/설치 → 폴더 생성 → 펌웨어 추출 안내 →
  Intake: 트랙(1/2) + 자산 경로 + 모델 + 등급 (+ 참조) → INPUT.md(track 슬롯)

트랙에 맞는 실행 명령 하나 (한 명령 = 한 트랙):

┌─────────────────────────────────────────────────────┐
│  /rehost-sboot   [트랙 1]   pipeline.js
└─────────────────────────────────────────────────────┘
  Static  : bl3-analyzer(8 도출) + stub-locator(4 sub-task 병렬) → STATIC/STUBS.md
  Machine : machine.c.tmpl 13 슬롯 → 06_machine/machine.c + ninja
  Iterate : iter-loop.js (한 회차 한 변경) — qemu→fault-fixer→패치→critic
  Verify  : reality-verifier 5/5 (Table G)
  Package : 10_reproduce/

┌─────────────────────────────────────────────────────┐
│  /rehost-kernel  [트랙 2]   pipeline_kernel.js
└─────────────────────────────────────────────────────┘
  Static  : kernel-boot-analyzer — DTB 골격 + 커널 게이트 → KERNEL_STATIC.md
  Machine : machine_kernel.c + patch_qemu_core.py + patch_kernel.py + ninja
  K1      : boot-fault-fixer — 유저스페이스(Run /init)
  K2      : rootfs 마운트 (제네릭+fstab 또는 dm-linear)
  K3      : storage-modeler — 진짜 벤더 스토리지 HCI 관찰 루프
  Verify  : reality-verifier 5/5 (커널 메시지 증거)
  Package : 10_reproduce/
```

---

## 실행 기록 (JOURNAL.md)

모든 `/rehost*` 명령은 `<workdir>/JOURNAL.md` 에 기록한다 (`scripts/journal.sh`, 시각은 실제
`date`). 세션은 **시작·완료 시각 + 소요 + 결과**, 매 시행착오(회차/정지점/벽)는 **시작·완료
시각 + 원인·분석·해결 + 증거 로그**. append-only.

```
## [SESSION] /rehost-kernel — track 2, target K2
- 시작: 2026-07-07T14:03:11+0900
- 시행착오:
  - ### try #k1-3 — K1 회차 3 부팅
    - 시작: 2026-07-07T14:18:02+0900
    - 완료: 2026-07-07T14:25:39+0900  (소요 0h07m37s)
    - 원인: smc_undef ELR=0x... (EL3 모니터 부재)
    - 분석: ELR 디스어셈블=smc, psci_conduit 미설정
    - 해결: smc_handler PSCI CPU_ON + psci_conduit=SMC
    - 증거: 07_logs/kboot_3.log
- 완료: 2026-07-07T15:20:44+0900  (소요 1h17m33s)
- 결과: K2 rootfs mounted (erofs dm-0/dm-4)
```

---

## 정직성 보장 (`reality-verifier` 의 5/5)

실행 명령이 셸 도달 (트랙 1) 을 보고하기 전 반드시 자동 통과해야 하는 항목:

1. **PC 트레이스** — BL3 의 shell 함수 + exec_command 진입 PC 가
   `-d in_asm` 로그에 등장
2. **출력 byte-match** — 콘솔 출력의 모든 토큰이 BL3 바이너리 안 file
   offset 으로 존재
3. **소스 negative** — 머신 C 소스에 동일 출력 문자열 0 개
4. **UART 단일 경로** — `qemu_chr_fe_write_all` 호출 단 1 자리, 조건이
   "BL3 가 UTXH 에 쓸 때만"
5. **우회 목록** — `[대상/이유/방법/부작용]` 4 항으로 N 개 우회 기재

5/5 = REAL. 4/5 이하 = FORCED 라고 보고 (성공 표시 금지).

---

## 필요 환경

- **OS**: Ubuntu 22.04+ 또는 WSL2 (Ubuntu 22.04+)
- **디스크**: 약 3 GB 여유 (QEMU 빌드 산출물 포함)
- **Claude Code**: 최신 버전 (slash 명령, AskUserQuestion, Workflow 지원)
- **인터넷**: QEMU 10.2.2 다운로드용 (한 번)

자동 설치되는 것 (`/rehost-init` 의 Step 2, `scripts/setup_env.sh`):
- apt: `build-essential ninja-build pkg-config libglib2.0-dev libpixman-1-dev libslirp-dev python3 python3-pip socat lz4 file` + `flex bison device-tree-compiler` (트랙 2 커널/DTB)
- pip: `meson capstone lz4 keystone-engine`
- QEMU 10.2.2 (aarch64-softmmu 만)
- (트랙 2 K3 캡스톤) aarch64 크로스툴체인 — worked example 의 `get_xtool.sh` 로 무루트 확보

---

## 플러그인 구조

```
sboot-rehost/
├── .claude-plugin/
│   ├── plugin.json                플러그인 매니페스트
│   └── marketplace.json           자체 마켓플레이스 (1 인 리포)
├── CLAUDE.md                      ★ 항상 로드: 트랙 + 정직성 7 + 5/5(양 트랙) + 위기 5 신호 + JOURNAL + 자율 실행
├── methodology/                   읽기 전용 참조 문서
│   ├── instruction.md             트랙 1 방법론 (S-Boot 셸)
│   ├── track2_kernel_storage.md   ★ 트랙 2 방법론 (커널 + 스토리지 HCI)
│   ├── general_tables.md          Table A~M 일반화 (양 트랙)
│   └── worked_example.md          S921N 트랙 1 풀이 회고
├── skills/
│   ├── rehost-init/SKILL.md       /rehost-init — 셋업 + 트랙 선택 + 인테이크
│   ├── rehost-sboot/SKILL.md      /rehost-sboot — 트랙 1 실행 (pipeline.js)
│   ├── rehost-kernel/SKILL.md     /rehost-kernel — 트랙 2 실행 (pipeline_kernel.js)
│   └── rehost-status/SKILL.md     /rehost-status — 진행 요약 (트랙 인식)
├── agents/
│   ├── bl3-analyzer.md  stub-locator.md  fault-fixer.md   (트랙 1)
│   ├── kernel-boot-analyzer.md    (트랙 2) DTB 골격 + 커널 게이트
│   ├── boot-fault-fixer.md        (트랙 2) 커널 정지점 → 패치
│   ├── storage-modeler.md         (트랙 2) 스토리지 HCI 관찰 루프
│   ├── reality-verifier.md        5/5 검증 (양 트랙)
│   └── critic.md                  위기 5 신호 (양 트랙)
├── workflows/
│   ├── pipeline.js                트랙 1 — 5 phase
│   ├── iter-loop.js               트랙 1 회차 루프
│   └── pipeline_kernel.js         ★ 트랙 2 — Static→K1→K2→K3→Verify
├── templates/
│   ├── machine.c.tmpl             트랙 1 머신 (13 슬롯)
│   ├── machine_kernel.c.tmpl      트랙 2 커널 머신 (CPU/GIC/UART/SMC/DT)
│   ├── storage_hci.c.tmpl         트랙 2 벤더 스토리지 HCI 골격
│   └── PROGRESS.md.tmpl
├── scripts/
│   ├── journal.sh                ★ 공통: 실행 기록 (세션·시행착오 시각 + 원인/분석/해결)
│   ├── setup_env.sh  carve_disasm.py  run_qemu.sh  verify_byte_match.py  (트랙 1)
│   ├── extract_boot_assets.sh     (트랙 2) boot.img/super → fw/
│   ├── patch_kernel.py  patch_qemu_core.py   (트랙 2) 커널/코어 패처
│   └── run_kernel.sh              (트랙 2) 커널 직부팅 실행 인자
└── examples/
    ├── s921n-exynos2400/          트랙 1 worked example (S-BOOT # help)
    └── s921n-exynos2400-kernel/   트랙 2 worked example (rootfs + UFS HCI)
```

---

## 멀티에이전트 병렬화 지점

`/rehost-sboot` → `pipeline.js` 안에서 (트랙 2 는 K3 관찰 루프가 직렬):

| Phase | 병렬 가능 | 어떻게 |
|---|---|---|
| 1 (Static) | ★ 부분 | bl3-analyzer 가 shell_func 도출 후 → stub-locator 의 4 sub-task (vtable/heap/handoff/timeout) 가 `parallel()` 으로 동시 실행 |
| 2 (Machine) | ✗ | machine.c 작성 → ninja 직렬 |
| 3 (Iterate) | ✗ | 한 회차 한 변경 (instruction.md §7.3 규칙). 회차 사이 직렬 |
| 4 (Verify) | ✗ | reality-verifier 1 회 호출 |
| 5 (Package) | ✗ | 파일 복사 |

병렬 이득이 큰 곳은 Phase 1 의 stub-locator 4 sub-task. 회차 루프는
의도적으로 직렬 (정직성 §7.3).

---

## 알려진 한계

- **트랙 1**: 등급 A (help) 만 안정적. B 는 UFS/PMIC 일부, C (autoboot) 는 풀 모델 필요.
  BL3 는 **full 본체** (carve 아님, 보통 4 MB 이상).
- **트랙 2**: K1/K2 안정, K3 은 벤더 스토리지 `.ko` 필요 + 관찰 루프 회차 소요.
  공통 프론티어 = **`/data` FBE → vold → Keymint → TEE (TEEGRIS)** — 시큐어월드 에뮬
  대규모, 미달로 정직 기록.
- **Samsung Exynos** UART/peri/UFS 패밀리 가정. 다른 SoC 는 DTB 도출로 대응하되 UART·HCI
  레지스터 셋은 대상 표준으로 확인 (`templates/*.tmpl` 은 골격).
- 트랙 2 캡스톤 (dm-linear/커널 모듈 로드) 빌드는 **WSL + aarch64 크로스툴체인** 필요
  (`scripts` 가 무루트 확보 안내).

---

## 기여

- Issue: 실패 케이스, 새 펌웨어 시도 보고
- PR: 새 SoC 의 UART/peri 모델, 추가 worked example

---

## 라이선스

MIT. 펌웨어 바이너리는 본 리포에 포함되지 않음 — 사용자 본인이 정식 채널로
확보 (예: samfw.com 의 본인 기기용 펌웨어).
