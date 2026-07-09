# sboot-rehost — 항상 로드되는 컨텍스트

이 파일은 sboot-rehost 플러그인 작업 중 Claude Code 가 항상 컨텍스트에
로드한다. 모든 회차·도출·검증이 이 규칙에 따른다.

---

## 트랙 (목표 타깃 2종)

부팅 체인의 **어느 진입점부터 진짜 바이너리를 실행하느냐**로 트랙이 갈린다.
INPUT.md 의 `track` 슬롯 (1|2) 이 결정. 두 트랙은 별도 진입점 (한 체인으로 잇지 않음).

| 트랙 | 진입점 (체인) | 도달 지점 | 등급 | 방법론 |
|---|---|---|---|---|
| **1 sboot-shell** | 부트로더 BL3 (③) | 진짜 S-Boot 셸 + `help` | A/B/C | [instruction.md](methodology/instruction.md) |
| **2 kernel-storage** | 커널 EL1 (⑥⑦) | 커널 → rootfs 마운트 → 진짜 벤더 스토리지 드라이버 → Android 2단계 | K1/K2/K3 | [track2_kernel_storage.md](methodology/track2_kernel_storage.md) |

- 트랙 1 등급 A=help / B=명령 핸들러 / C=autoboot.
- 트랙 2 등급 K1=유저스페이스(`Run /init`) / K2=진짜 rootfs 마운트 / K3=진짜 벤더
  스토리지 HCI 모델로 벤더 드라이버가 블록디바이스+파티션 구동.
- **정직성 7 규칙·"회차=한 변경"·"우회는 우회로"·"실증거로만 판정" 은 두 트랙 공통.**

---

## 실행 기록 (JOURNAL.md) — 필수

**모든 `/rehost*` 명령은 `<workdir>/JOURNAL.md` 에 기록해야 한다.** 기록 없이 완료 보고 금지.
기록은 `scripts/journal.sh` 로만 (시각은 실제 `date` — 조작·추정 금지, 정직성 §6 확장).

| 시점 | 명령 | 기록 내용 |
|---|---|---|
| 명령 시작 | `journal.sh <wd> session-start "<cmd>" "<track/target>"` | **시작 시각** |
| 명령 완료 | `journal.sh <wd> session-end "<cmd>" "<결과>"` | **완료 시각 + 소요 + 결과** |
| 시행착오 시작 | `journal.sh <wd> try-start "<id>" "<정지점/벽>"` | **각 시행착오 시작 시각** |
| 시행착오 완료 | `journal.sh <wd> try-end "<id>" "<원인>" "<분석>" "<해결>" "<증거>"` | **완료 시각 + 소요 + 원인/분석/해결 + 증거** |
| 단계 경계 | `journal.sh <wd> phase "<phase>"` | 단계 전환 시각 |

규칙:
- **세션**: `/rehost-init` / `/rehost-sboot` / `/rehost-kernel` / `/rehost-status` 는 시작 즉시
  `session-start`, 끝에 `session-end`.
- **시행착오**: 매 회차(트랙 1)·매 정지점/벽(트랙 2 K1~K3)은 `try-start`(시작 시각) + `try-end`
  (완료 시각 + **원인·분석·해결** + 증거 로그 경로). 회차 번호 = try id.
- 시각은 반드시 실제 `date` 출력. 지어내거나 사후 추정 금지.
- JOURNAL.md 는 append-only. 과거 항목 수정·삭제 금지.

---

## 자율 실행 (autonomous) — 기본 켜짐

**모든 `/rehost*` 명령은 기본 자율 실행이다.** 실행 중 `AskUserQuestion` 으로 사용자에게
선택을 묻지 않고, 아래 정책으로 **자동 결정**하고 그 결정을 JOURNAL.md 에 기록한다
(`journal.sh <wd> decision "<지점>" "<선택>" "<근거>"`). `AskUserQuestion` 은 하니스가
자동응답을 지원하지 않으므로 자율 모드에선 호출 금지.

**★ 실행 명령(`/rehost-sboot`·`/rehost-kernel`)은 시작하면 하드 블로커(아래) 전까지 한 번도
멈추지 않는다.** 파이프라인이 FORCED/critic/미달을 반환해도 사용자에게 되묻지 말고 자율 정책으로
처리 후 계속·마무리한다. "계속할까요/확인해주세요" 류 질문 자체가 규칙 위반. (`/rehost-init` 만은
펌웨어 경로 등 데이터가 없으면 종료-보고 — 이건 데이터 결손이지 선택 질문이 아니다.)

INPUT.md 의 `autonomous` 슬롯으로 제어: `true`(기본) = 자동 결정, `false` = 기존처럼
분기마다 `AskUserQuestion` (사람이 지켜볼 때만).

### 자동 결정 정책

| 분기 | 자율 기본 선택 | 근거 |
|---|---|---|
| 의존성 미설치 | `setup_env.sh` **자동 백그라운드 설치** | 되돌릴 수 있는 셋업. 동의 불요 |
| critic 위기 신호 | **계속** + 신호의 `recommended_action` 자동 적용 | 방향 조정은 다음 정지점으로 검증됨. 단 하드 블로커면 중단 |
| verification FORCED (4/5 이하) | 회차 루프 max 까지 이미 돌았으면 **FORCED 로 마무리** (재현 키트만 생성, **REAL 표기 금지**) | 무한 루프 방지 + 정직성. 더 원하면 max_iterations 올려 재실행 |
| 트랙 2 TEE 프론티어 (vold/Keymint/TEEGRIS) | **미달로 정직 기록** 후 도달 등급까지 마무리 | 시큐어월드 에뮬은 범위 밖 (§9) |
| Intake 데이터 (트랙/경로/모델/등급) | 질문 아님·데이터 → **args 또는 미리 채운 INPUT.md 로 선공급** | 펌웨어 경로는 자동 선택 불가 |

### 하드 블로커 (자동 중단 + 보고, 계속 금지)

이 경우엔 자동으로 계속하지 않고 중단 + JOURNAL 기록 + 사용자에게 보고:
- BL3 carve 의심 (트랙 1) / 부팅 자산 없음 (트랙 2)
- 필수 입력 결손 (자율 모드에서 args·INPUT.md 에 필수 슬롯 없음)
- target=K3 인데 벤더 `.ko` 부재
- 빌드 에러 (추측 수정 금지, 그대로 보고)

### 정직성 가드레일 (자율의 절대 조건)

- 자동 결정이 **성공을 지어내는 방향이면 금지.** FORCED 는 FORCED 그대로, 블로커는 중단.
- 5/5 미달을 자동으로 "REAL"·"성공" 으로 만들지 말 것.
- 모든 자동 결정은 JOURNAL.md 에 `decision` 으로 남겨 추적 가능해야 함.

---

## 정직성 규칙 7 항 (어기는 변경은 무효)

1. **추측 stub 금지**. 특히 적응형 토글 (예: "12회 read=0, 그 뒤
   0xFFFFFFFF/0 교대"). 펌웨어를 잘못된 분기로 보내 "우연한 통과" 로 끝남.
2. **우회는 우회로 명시**. 펌웨어 패치를 정상 모델처럼 표현 금지. 매 우회는
   `[대상 / 이유 / 방법 / 알려진 부작용]` 4 항으로 문서화.
3. **모든 주소·구조·바이트열은 분석으로 도출**. 도구는 둘뿐:
   - 디스어셈블 (capstone)
   - 실행관찰 (`qemu -d exec,int,unimp,guest_errors`)
   - 도출하지 않은 값을 분석 결과처럼 쓰지 말 것.
4. **하드코딩을 분석처럼 위장 금지**. 미확정 값은 "미확정 — N단계에서 확정"
   으로 표기.
5. **못 간 지점은 못 갔다고 기록**. 가짜 통과 금지.
6. **성공은 실제 트레이스/콘솔/메모리 캡처로만 판정**. 문자열 regex 매칭
   단독 = 불인정.
7. **머신 안 입력 자가주입 금지** (예: TX 카운트 보고 RX 에 명령을 넣어주는
   식). 머신이 입력과 명령을 다 만들면 "동작 확인" 이 순환검증.

---

## 검증 5/5 — 트랙 1 (Table G — 셸 도달 보고 전 필수)

| # | 항목 | 통과 조건 |
|---|---|---|
| 1 | PC 트레이스 | shell 함수 + exec_command 진입 PC 가 `-d in_asm` 로그에 등장 |
| 2 | 출력 byte-match | 콘솔 출력 모든 토큰이 BL3 binary 에 file offset 으로 존재 |
| 3 | 소스 negative | 머신 C 소스에 동일 출력 문자열 0 개 |
| 4 | UART 단일 경로 | `qemu_chr_fe_write_all` 호출 단 1 자리, "BL3 가 UTXH 에 쓸 때만" |
| 5 | 우회 목록 | `[대상/이유/방법/부작용]` 4 항으로 N 개 우회 기재 |

5/5 = REAL. 4/5 이하 = FORCED (성공 표시 금지).

## 검증 5/5 — 트랙 2 (커널 도달 보고 전 필수)

| # | 항목 | 통과 조건 |
|---|---|---|
| 1 | 부팅 진행 | `Run /init` (K1) 이 콘솔·트레이스에 등장 |
| 2 | 커널 메시지 증거 | `erofs: (device dm-N): mounted` (K2) / `sda: sda1…`·`Power mode change` (K3) — **머신 아닌 커널이 찍은 줄** |
| 3 | 소스 negative | 머신 C 에 그 마운트/파티션 문자열 0 개 |
| 4 | 드라이버 진짜 구동 (K3) | 트랜잭션 로그에 UTRD/Query/SCSI, `.ko` 는 원본 + 문서화된 우회만 |
| 5 | 우회 목록 | 커널 패치 + `.ko` 패치 + SMC 셤 전부 `[대상/이유/방법/부작용]` |

5/5 = REAL. 4/5 이하 = FORCED (성공 표시 금지).

---

## 위기 5 신호 (critic agent 가 자동 발화)

**트랙 1** (sboot-shell):

| # | 트리거 | 발화 메시지 |
|---|---|---|
| 1 | 누적 회차 ≥ 30 + 마지막 5 fault 동일 카테고리 | "방향 맞아? entry redirect 위치를 더 앞으로 옮길지 검토." |
| 2 | UART 에 BL3 ASCII ≥ 3 토큰 + 5/5 검증 미실행 | "다음 실행 명령 호출에서 자동 5/5 검증 예정." |
| 3 | STATIC.md 또는 STUBS.md 의 "미확정" ≥ 5 개 | "참조 자산 (INPUT.md refs) 보강 검토." |
| 4 | bl3-analyzer 의 found_strings 비었거나 알려진 ASCII 없음 | "BL3 가 full 인지 carve 인지 재확인 필요." |
| 5 | target=A 인데 패치에 UFS/PMIC 키워드 출현 | "A 등급은 entry redirect 우회로 충분. UFS 모델 불필요." |

**트랙 2** (kernel-storage):

| # | 트리거 | 발화 메시지 |
|---|---|---|
| 1 | 누적 회차 ≥ 30 + 마지막 5 정지점 동일 카테고리 | "방향 재평가. 커널/DTB 자산·게이트 사이트 재도출 검토." |
| 2 | 스토리지 관찰 루프에서 같은 창 폴링 반복 + read 카운트 분기 흔적 | "적응형 토글 금지. .ko 역어셈블로 값 출처 확정." |
| 3 | KERNEL_STATIC.md "미확정" ≥ 5 개 (DTB 노드/게이트 사이트) | "DTB 파싱·심볼 xref 보강." |
| 4 | target=K3 인데 진짜 벤더 `.ko` 미확보 (INPUT.md storage_driver_ko 빈칸) | "K3 은 벤더 드라이버 필수. K2 (제네릭) 로 낮출지 검토." |
| 5 | `/data`/vold/Keymint/TEEGRIS 우회 시도 | "TEE 는 프론티어 (시큐어월드 대규모). 스토리지·rootfs 와 별개, 미달로 정직 기록." |

---

## 사용 가능한 슬래시 명령

- **`/rehost-init`** — 1단계(데이터 불요): 표준 폴더를 **Windows cwd** 에 생성 + 의존성 백그라운드 설치 + 펌웨어 확보 안내. INPUT.md 안 만듦.
- **`/rehost-setup`** — 2단계(펌웨어 반입): `01_firmware/` 의 펌웨어 언팩 + **실행 사본을 WSL ext4 로 이동** + 의존성 확인 + INPUT.md 생성.
- **`/rehost-sboot`** — 트랙 1 (sboot-shell) 실행 → pipeline.js
- **`/rehost-kernel`** — 트랙 2 (kernel-storage) 실행 → pipeline_kernel.js
- **`/rehost-status`** — 진행 상태 요약 (트랙 인식)

흐름: **init(폴더·의존성) → 펌웨어 드롭 → setup(반입·INPUT.md) → sboot/kernel(자율 실행)**.
트랙은 INPUT.md 의 `track` 슬롯. 실행 명령은 트랙별로 분리 (한 명령 = 한 트랙).
**폴더는 Windows cwd(플러그인 시작 위치, 설치 폴더 안 아님), 펌웨어 실행 사본은 WSL ext4.**

---

## 작업 디렉터리 표준 구조

`/rehost-init` 이 **Windows cwd** 에 만드는 표준 폴더 (공통 + 트랙별). 펌웨어 실행 사본은
`/rehost-setup` 이 WSL ext4(`~/rehost/<model>/`)로 이동; 문서·로그는 이 Windows cwd 에 유지:

```
<workdir>/  ← 로컬 Windows cwd (사용자가 보는 기록·해결과정)
├── INPUT.md                       0차 입력 (track 슬롯 포함)
├── PROGRESS.md                    회차별 한 줄 이력
├── JOURNAL.md                     ★ 실행 기록 (세션·시행착오 시각 + 원인/분석/해결 + 자동결정)
├── VERIFICATION.md                reality-verifier 출력 (5/5)
├── 06_machine/                    machine.c(.kernel) 및 우회 목록
├── 07_logs/                       회차별 콘솔(console_N/kboot_N) + 요약(*.summary.txt) — 로컬
├── 08_docs/                       추가 분석 메모
├── 10_reproduce/                  마지막 단계 재현 키트
│
├── (트랙 1)  STATIC.md STUBS.md   bl3-analyzer / stub-locator 출력
│            01_firmware/ 02_unpacked/ 03_bl3/ 04_static-analysis/
│
└── (트랙 2)  KERNEL_STATIC.md     kernel-boot-analyzer 출력 (DTB 골격 + 커널 게이트)
             fw/                   Image(.patched) / *.dtb / initramfs.cpio.gz / super.img

WSL ext4 (대용량 쓰기 — 사용자가 직접 볼 필요 없는 중간물):
  ~/rehost/<model>/          펌웨어 실행 사본 (QEMU 입력)
  ~/rehost/_traces/          회차별 대용량 -d 전체 트레이스 (run_N.log / kboot_N.log)
```

**기록 위치 원칙**: 사용자가 보는 **기록·해결과정(JOURNAL/PROGRESS/VERIFICATION/INPUT/STATIC/
콘솔·요약)은 로컬 Windows cwd**, 대용량 **쓰기(펌웨어 실행 사본·`-d` 전체 트레이스)는 WSL ext4**.
run 스크립트가 `console=`(로컬)·`summary=`(로컬)·`trace=`(WSL) 를 출력하고, 분석은 로컬 요약을
1차로 읽되 필요 시 WSL 전체 트레이스를 본다.

---

## 회차 기록 형식 (PROGRESS.md)

```
| run N | <정지점 신호> | <한 변경> |
```

예:
```
| run 12 | Data Abort FAR=0x12860010 | peri_lo 0x10000000 + 256MB 추가 |
| run 13 | Prefetch Abort FAR=0 ELR=0 | entry 0x90000050 → trampoline 0x90000148 |
```

한 회차 = 한 변경 = 한 줄. 여러 변경 묶기 금지 (instruction.md §7.3).

---

## 사용자 의도 파악

사용자가 다음을 말하면:

- "다시 검증해줘 / 진짜야?" → reality-verifier 즉시 호출
- "방향 맞아?" → critic 즉시 호출, 전략 재평가
- "9820 / 다른 분석가 자료 참고" → methodology/worked_example.md 재읽기

사용자가 명시적으로 다른 명령을 주지 않는 한 실행 명령 (트랙 1 `/rehost-sboot`,
트랙 2 `/rehost-kernel`) 의 파이프라인을 따른다.
