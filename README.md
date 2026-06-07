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

### 2) 첫 사용 — `/rehost` 가 모든 안내 제공

```bash
> /rehost
```

`/rehost` 가 **상태별로 자동 안내**:

| 호출 차수 | 상태 | `/rehost` 가 하는 일 |
|---|---|---|
| 1번째 | 의존성 없음 | apt + QEMU 10.2.2 설치 안내 → 동의 시 자동 (~18 분, sudo 한 번) |
| 2번째 | 환경 OK, 펌웨어 미지정 | **펌웨어 준비 안내** (필요 파일 / 추출 방법 / 등급 설명) → 준비됐는지 확인 → 4 질문 (펌웨어 경로, 모델, 등급, 참조자산) |
| 3번째~ | 입력 OK | 정적 분석 → 머신 빌드 → 회차 루프 → 5/5 검증 → 재현 키트 |

사용자는 **펌웨어 준비도, 설치도, 입력도 `/rehost` 호출 안에서 모두 안내받음**. 갑자기 파일 경로 묻지 않음.

### 3) 펌웨어 준비 (안내는 `/rehost` 가 알려주지만, 미리 알고 싶다면)

- BL3 본체 `.bin` 파일 (보통 4 MB 이상)
- 출처: samfw.com / sammobile.com 의 본인 기기용 `BL_*.tar.md5`
- 추출: `tar xf BL_*.tar.md5` → `lz4 -d sboot.bin.lz4 sboot.bin`
- 본인 기기용만 사용 (라이선스)

### 업데이트

```bash
> /plugin marketplace update sboot-rehost-marketplace
```

`/rehost` 가 매번 호출될 때마다 현재 상태를 감지해 다음 단계 1 개를 자동
수행. 사용자는 첫 호출에서 펌웨어 경로 / 모델 / 목표 등급 4 가지만 답하면
됨.

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

## 작동 방식 — 상태 머신

| 상태 | 트리거 | `/rehost` 가 하는 일 |
|---|---|---|
| **S0** | 의존성 (QEMU, capstone) 없음 | `scripts/setup_env.sh` 자동 실행 (~18 분) |
| **S1** | `INPUT.md` 없음 | **Briefing** (펌웨어 준비물 안내) → **Ready check** (지금/도움/나중에) → **Intake** (4 질문) |
| **S2** | `STATIC.md` 없음 | `bl3-analyzer` agent: 8 도출 (entry, linker, load, Δ, cmd 테이블, list head, shell 함수, carve 판정) |
| **S3** | `STUBS.md` 없음 | `stub-locator` agent: 4 보조 도출 (vtable, heap, handoff, timeout) |
| **S4** | `machine.c` 없음 | 템플릿 13 슬롯 채워서 작성 + ninja 빌드 |
| **S5** | `PROGRESS.md` 회차 0 | `iter-loop.js` workflow: 10 회차 자동 (fault → fix → critic 점검) |
| **S6** | UART 에 BL3 ASCII ≥ 3 토큰 | `reality-verifier` agent: 정직성 5/5 검증 |
| **S7** | 5/5 통과 | `10_reproduce/` 재현 키트 생성 |

매 단계마다 정직성 규칙 7 항 + 검증 5/5 자동 적용. 30 회차 누적 시 `critic`
agent 가 자동 발화: "방향 맞아? entry redirect 더 앞으로 옮길지 검토."

---

## 필요 환경

- **OS**: Ubuntu 22.04+ 또는 WSL2 (Ubuntu 22.04+)
- **디스크**: 약 3 GB 여유 (QEMU 빌드 산출물 포함)
- **Claude Code**: 최신 버전 (slash 명령, AskUserQuestion, Workflow 지원)
- **인터넷**: QEMU 10.2.2 다운로드용 (한 번)

자동 설치되는 것:
- apt: `build-essential ninja-build pkg-config libglib2.0-dev libpixman-1-dev libslirp-dev python3 python3-pip socat lz4 file`
- pip: `meson capstone lz4 keystone-engine`
- QEMU 10.2.2 (aarch64-softmmu 만)

---

## 플러그인 구조

```
sboot-rehost/
├── .claude-plugin/plugin.json     플러그인 매니페스트
├── CLAUDE.md                      ★ 항상 로드: 정직성 7 + 5/5 + 위기 5 신호
├── methodology/                   읽기 전용 참조 문서
│   ├── instruction.md             원본 방법론
│   ├── general_tables.md          Table A~I 일반화
│   └── worked_example.md          S921N 풀이 회고
├── skills/
│   ├── rehost/SKILL.md            /rehost — 상태 머신 (S0~S7)
│   └── rehost-status/SKILL.md     /rehost-status — 진행 요약
├── agents/
│   ├── bl3-analyzer.md            8 도출
│   ├── stub-locator.md            4 보조 도출
│   ├── fault-fixer.md             fault → 패치 (Table F)
│   ├── reality-verifier.md        5/5 검증 (Table G)
│   └── critic.md                  위기 5 신호 (Table H)
├── workflows/
│   └── iter-loop.js               회차 루프 (qemu → fix → critic)
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
    ├── EXPECTED_OUTPUT.txt
    └── machine.c
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

---

