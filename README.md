# sboot-rehost

> Samsung S-Boot BL3 rehosting helper for Claude Code.
> 펌웨어 1 개 던지면 QEMU 안에서 진짜 S-Boot 셸까지 자동으로 도달.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Quick Start

### 1) 설치 (한 번)

```bash
claude
> /plugin marketplace add marista-dev/sboot-rehost
> /plugin install sboot-rehost@sboot-rehost-marketplace
```

### 2) 두 명령으로 끝

```bash
# 첫 호출 — 셋업 + 펌웨어 가이드 + 4 질문
> /rehost-init

# 두 번째 호출 — 병렬 멀티에이전트로 본격 실행
> /rehost
```

흐름:

| 명령 | 역할 |
|---|---|
| **`/rehost-init`** | **셋업** — 의존성 백그라운드 설치 + 폴더 구조 (8 폴더) 생성 + 펌웨어 다운로드/추출 안내 (samfw.com 어디서 받아서 어디에 넣을지) + 사용자 4 질문 (펌웨어 경로 / 모델 / 등급 / 참조) → INPUT.md 생성 |
| **`/rehost`** | **본 실행** — `workflows/pipeline.js` 호출. 5 phase 자동: ① 정적 분석 (병렬 멀티에이전트) → ② 머신 .c + ninja → ③ 회차 루프 (직렬, max 30 회) → ④ 5/5 정직성 검증 → ⑤ 재현 키트 |
| `/rehost-status` (옵션) | 진행 상황 한 화면 요약 |

`/rehost-init` 끝나면 사용자 추가 입력 없이 `/rehost` 한 번으로 끝까지.
중간에 critic 가 위기 5 신호 (방향 오류 / carve 의심 / 등급 미스매치 등)
감지하면 사용자에게 분기 요청.

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

## 작동 방식 — 2 단계 + 5 phase

```
사용자가 호출하는 명령은 2 개

┌─────────────────────────────────────────────────────┐
│  /rehost-init         (1 회, ~20 분 — 대부분 의존성 빌드)
└─────────────────────────────────────────────────────┘
  Step 1: 의존성 검사
  Step 2: (미설치 시) setup_env.sh 백그라운드 실행 (~18 분)
  Step 3: 표준 8 폴더 생성 (01_firmware/ ~ 08_docs/)
  Step 4: BRIEFING 출력 — samfw.com 어디서, BL_*.tar.md5 어떻게 풀어,
                         어떤 파일이 sboot.bin 인지, 어디에 두는지
  Step 5: Ready check  — "지금 시작 / 도움 더 필요 / 나중에"
  Step 6: Intake       — AskUserQuestion 4 (경로/모델/등급/참조)
  Step 7: INPUT.md + PROGRESS.md 작성
  Step 8: 완료 보고

┌─────────────────────────────────────────────────────┐
│  /rehost              (1 회, ~30 분 ~ 수 시간)
└─────────────────────────────────────────────────────┘
  Phase 1: Static Analysis  ★ 병렬 멀티에이전트
    - bl3-analyzer: 8 도출 (carve/entry/linker/load/Δ/cmd_table/head/shell)
    - stub-locator: 4 sub-task 병렬 (vtable/heap/handoff/timeout)
    → STATIC.md + STUBS.md

  Phase 2: Machine Build    (직렬)
    - machine.c.tmpl 의 13 슬롯 채움 → 06_machine/machine.c
    - QEMU 트리 통합 + ninja

  Phase 3: Iteration Loop   (직렬, 한 회차 한 변경)
    - iter-loop.js 가 max 30 회차 자동
    - 매 회차: qemu → fault-fixer → 패치 → critic 점검

  Phase 4: 5/5 Verification (직렬)
    - reality-verifier — Table G 5 항목

  Phase 5: Reproduce Kit    (직렬)
    - 10_reproduce/ 생성
```

---

## 정직성 보장 (`reality-verifier` 의 5/5)

`/rehost` 가 셸 도달했다고 보고하기 전 반드시 자동 통과해야 하는 항목:

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

자동 설치되는 것 (`/rehost-init` 의 Step 2):
- apt: `build-essential ninja-build pkg-config libglib2.0-dev libpixman-1-dev libslirp-dev python3 python3-pip socat lz4 file`
- pip: `meson capstone lz4 keystone-engine`
- QEMU 10.2.2 (aarch64-softmmu 만)

---

## 플러그인 구조

```
sboot-rehost/
├── .claude-plugin/
│   ├── plugin.json                플러그인 매니페스트
│   └── marketplace.json           자체 마켓플레이스 (1 인 리포)
├── CLAUDE.md                      ★ 항상 로드: 정직성 7 + 5/5 + 위기 5 신호
├── methodology/                   읽기 전용 참조 문서
│   ├── instruction.md             원본 방법론
│   ├── general_tables.md          Table A~I 일반화
│   └── worked_example.md          S921N 풀이 회고
├── skills/
│   ├── rehost-init/SKILL.md       /rehost-init — 셋업 + 가이드 + 4 질문
│   ├── rehost/SKILL.md            /rehost — 본 실행 (pipeline.js 호출)
│   └── rehost-status/SKILL.md     /rehost-status — 진행 요약
├── agents/
│   ├── bl3-analyzer.md            8 도출
│   ├── stub-locator.md            4 보조 도출
│   ├── fault-fixer.md             fault → 패치 (Table F)
│   ├── reality-verifier.md        5/5 검증 (Table G)
│   └── critic.md                  위기 5 신호 (Table H)
├── workflows/
│   ├── pipeline.js                ★ /rehost 가 호출 — 5 phase 멀티에이전트
│   └── iter-loop.js               회차 루프 (pipeline 의 Phase 3 위임)
├── templates/
│   ├── machine.c.tmpl             13 슬롯 머신 골격
│   └── PROGRESS.md.tmpl
├── scripts/
│   ├── setup_env.sh               의존성 자동 설치
│   ├── carve_disasm.py            capstone 래퍼
│   ├── run_qemu.sh                표준 실행 인자
│   └── verify_byte_match.py       Table G #2-3
└── examples/s921n-exynos2400/     완성 worked example
    ├── INPUT.md
    ├── EXPECTED_OUTPUT.txt        308 bytes (S-BOOT # help ...)
    └── machine.c                  454 줄
```

---

## 멀티에이전트 병렬화 지점

`/rehost` → `pipeline.js` 안에서:

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

- **목표 등급 A (help)** 만 안정적. B (특정 명령 핸들러 실행) 는 UFS/PMIC
  모델 일부 필요, C (autoboot) 는 거의 풀 모델 필요.
- **Samsung Exynos** UART 패밀리 가정. Snapdragon / MediaTek 은 UART 모델
  교체 필요 (`templates/machine.c.tmpl` 의 peri_lo_ops 부분).
- BL3 가 **carve 가 아닌 full 본체** 여야 함. 보통 4 MB 이상.

---

## 기여

- Issue: 실패 케이스, 새 펌웨어 시도 보고
- PR: 새 SoC 의 UART/peri 모델, 추가 worked example

---

## 라이선스

MIT. 펌웨어 바이너리는 본 리포에 포함되지 않음 — 사용자 본인이 정식 채널로
확보 (예: samfw.com 의 본인 기기용 펌웨어).
