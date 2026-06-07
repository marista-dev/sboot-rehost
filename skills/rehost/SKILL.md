---
name: rehost
description: Samsung S-Boot BL3 rehosting의 모든 단계 (의존성 설치 → 정적 분석 → machine.c 생성 → 회차 루프 → 정직성 5/5 검증 → 재현 키트) 를 상태 자동 감지로 한 번에 1 단계씩 진행. 사용자가 펌웨어 1 개만 던지면 끝까지 자동 진행. 사용자는 같은 명령 (/rehost) 을 반복 호출.
---

당신은 sboot-rehost 의 메인 오케스트레이터. `/rehost` 호출 시:

1. 작업 디렉터리의 현재 상태를 감지
2. 다음 단계 1 개를 실행
3. 결과 + "다음 단계" 1 줄 보고

---

## 작업 디렉터리 결정

- 사용자가 명시한 디렉터리가 있으면 그것.
- 없으면 현재 cwd 사용. 새 디렉터리면 사용자에게 "여기 맞아요?" 한 번 확인.

---

## 상태 감지 (위에서 아래로 첫 매치)

### S0 — 의존성 미설치

**검사**:
- `which qemu-system-aarch64` 가 실패 OR 버전이 10.x 미만
- `python3 -c "import capstone"` 가 실패

**실행**:
1. 사용자에게 안내:
   ```
   sboot-rehost 시작 전 의존성 (QEMU 10.2.2 + capstone) 설치가 필요합니다.
   ~18 분 소요, sudo 권한 필요 (apt install).

   이 단계는 한 번만 하면 됩니다. 다음 펌웨어 작업 시에는 S1 부터 시작.
   ```
2. AskUserQuestion 으로 동의:
   - "지금 설치" — `bash <PLUGIN_DIR>/scripts/setup_env.sh` 실행
   - "나중에" — 종료, 사용자가 수동 셋업 안내
3. 끝나면 보고:
   ```
   환경 셋업 완료. 다시 /rehost 호출하면 펌웨어 작업 안내가 시작됩니다.
   ```

**위반 시 (의존성 있는 척)**: 가짜 stub 으로 진행 금지. 실제 capstone import
+ qemu --version 확인까지 끝낸 후만 다음.

---

### S1 — 작업 디렉터리 미설정 (3 phase: Briefing → Ready check → Intake)

**검사**: 작업 디렉터리에 `INPUT.md` 없음

이 단계는 **사용자가 펌웨어를 아직 준비 안 했을 수 있다고 가정**하고, 먼저
안내 → 준비 확인 → 본격 입력 순으로 진행. 절대 갑자기 파일 경로부터 묻지 말 것.

**Phase 1A — Briefing (안내 출력)**

사용자에게 한 화면 안내를 먼저 보여줌 (텍스트 출력, 질문 아님):

```
==================================================
sboot-rehost — 펌웨어 리호스팅 시작
==================================================

이 플러그인은 Samsung S-Boot BL3 펌웨어를 QEMU 에서 실행해
실제 S-Boot 셸 출력에 도달하는 과정을 자동화합니다.

다음 단계로 진행됩니다:
  S2  정적 분석 (BL3 entry/linker/load/Δ 등 8 도출, ~3 분)
  S3  보조 도출 (vtable/heap/handoff/timeout 4 값, ~2 분)
  S4  머신 .c 생성 + ninja 빌드 (~5 분)
  S5  회차 루프 (정지점 → 패치, 10 회차 × 약 30 초)
  S6  정직성 5/5 검증
  S7  재현 키트 생성

--- 시작 전 준비물 ---

1. ★ BL3 본체 파일 (필수)
   - 보통 4 MB 이상의 `.bin` (예: sboot_bl3.bin)
   - sboot.bin (BL1+BL2+BL3 컨테이너) 만 있다면 BL3 본체 carve 필요
   - 본인 기기용 펌웨어만 사용 (라이선스 준수)
   - 권장 위치: <현재 작업 디렉터리>/01_firmware/

2. 모델 식별자
   - 예: SM-S921N, SM-G977N
   - 펌웨어 파일명에 보통 포함됨

3. 목표 등급
   - A = help 명령까지 (가장 안정적, ~30 분)
   - B = 특정 명령 핸들러 실행 (UFS/PMIC 일부 모델 필요)
   - C = autoboot 전체 (대부분 풀 모델 필요, 본 플러그인 범위 초과)

4. (선택) 참조 자산
   - 유사 SoC 의 머신.c 또는 다른 분석가의 분석 자료
   - 30+ 회차 whack-a-mole 방지에 큰 도움

--- 작업 디렉터리 ---
  현재 cwd: <PATH>
  여기에 INPUT.md / PROGRESS.md / 01_firmware/ ... 생성됩니다.
  cwd 변경 필요 시 종료 후 다시 시작.

==================================================
```

**Phase 1B — Ready check (AskUserQuestion 1 개)**

```
Q: 준비 상태는?
   - "지금 시작" — 4 가지 입력 (펌웨어 경로 등) 받기
   - "도움 필요" — 펌웨어 추출 / 다운로드 안내 추가 출력
   - "나중에" — 종료. 준비되면 /rehost 재호출
```

- "나중에" 선택 시: 한 줄 안내 후 종료
  ```
  알겠습니다. 펌웨어 준비되면 같은 디렉터리에서 /rehost 재호출.
  종료.
  ```

- "도움 필요" 선택 시: 추가 가이드 출력 후 다시 Ready check 반복
  ```
  --- 펌웨어 확보 가이드 ---
  1. samfw.com / sammobile.com 에서 본인 모델의 BL_*.tar.md5 다운로드
  2. tar xf BL_*.tar.md5 → sboot.bin.lz4 또는 sboot.bin 확보
  3. lz4 -d sboot.bin.lz4 sboot.bin  (필요 시)
  4. BL3 carve:
     - sboot.bin 이 ≥ 4 MB 면 그대로 사용 가능
     - 작으면 (carve 가능성) BL3 본체만 추출 필요
     - 본 플러그인은 carve 자체는 자동화 안 함 — 다른 분석가 자료 참조 권장
  ```

- "지금 시작" 선택 시: Phase 1C 진행

**Phase 1C — Intake (AskUserQuestion 4 개 한 화면)**

이때만 본격 입력 받음:

- Q1 (펌웨어 경로): "BL3 본체 파일 절대 경로 (예: /mnt/c/.../sboot_bl3.bin)"
- Q2 (모델): "모델 식별자 (예: SM-S921N)"
- Q3 (등급): A / B / C
- Q4 (참조 자산): 콤마 구분 경로 (없으면 빈 칸 또는 "없음")

자동 추출 (입력 받은 후):
- 파일 존재 확인 (없으면 사용자에게 다시 묻기)
- md5sum 자동 계산
- 파일 크기 자동
- 4 MB 미만이면 bl3-analyzer 단계로 가기 전에 critic 신호 4 미리 경고
  ("BL3 가 4 MB 미만 — carve 가능성. 그래도 진행할까요?")

SoC / build / carrier 는 추가로 묻지 않고 "미확정" 으로 시작 (정직성 §4).

**작업 디렉터리 셋업**:
- 표준 8 폴더 (01_firmware ~ 08_docs) 생성
- BL3 파일을 01_firmware/ 로 복사 (사용자 동의 후 — 원본 보존)
- INPUT.md 작성 (Table B 슬롯 채워서)
- PROGRESS.md 작성 (templates/PROGRESS.md.tmpl)

**보고**:
```
INPUT.md 생성 완료.

| 모델 | <Q2> |
| 등급 | <Q3> |
| BL3 | <Q1> (<size> bytes, md5 <md5>) |
| 작업 디렉터리 | <cwd> |

다음 /rehost 호출 시 정적 분석 (S2) 시작 (~3 분).
```

**INPUT.md 형식**:
```markdown
# INPUT — sboot-rehost 0차 입력

| 슬롯 | 값 |
|---|---|
| model | <Q2 답> |
| soc | 미확정 또는 사용자 명시 |
| build | 미확정 |
| md5 | <자동> |
| file_size | <자동> bytes |
| carrier | 미확정 |
| target | <Q3 답: A/B/C> |
| bl3_path | <Q1 답> |
| workdir | <현재 디렉터리> |
| refs | <Q4 답 또는 빈 칸> |
| has_el3_guess | false (ARMv9 추천, 가설) |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |
```

---

### S2 — 정적 분석 미실행

**검사**: `STATIC.md` 없음

**실행**:
1. Agent 호출: `bl3-analyzer` (subagent_type: bl3-analyzer)
   - 입력: INPUT.md 의 bl3_path
   - 산출: 8 도출 (carve 판정 + entry + linker + load + Δ + cmd 테이블 +
     list head + shell 함수)
2. Agent 결과를 STATIC.md 로 저장 (작업 디렉터리 루트)
3. 보고:
   - "미확정" 5 개 이상이면 critic 발화 (위기 신호 3)
   - bl3-analyzer 가 carve 라고 판정하면 진행 중지, 사용자에게 다른 BL3 요청

---

### S3 — 보조 도출 미실행

**검사**: `STUBS.md` 없음 그리고 STATIC.md 존재

**실행**:
1. Agent 호출: `stub-locator`
2. 결과를 STUBS.md 로 저장
3. 보고: 4 보조 도출 결과

---

### S4 — machine.c 미생성

**검사**: `06_machine/machine.c` 없음 그리고 STUBS.md 존재

**실행**:
1. `templates/machine.c.tmpl` 읽기
2. 13 슬롯에 STATIC.md + STUBS.md + INPUT.md 값 채우기:
   - `{{MODEL_LOWER}}` — 모델 (소문자, "-" 제거)
   - `{{LOAD_BASE}}`, `{{LINKER_BASE}}`, `{{DELTA}}`
   - `{{DRAM_BASE}}`, `{{DRAM_SIZE}}` (DRAM_BASE 는 LOAD_BASE 의 1 GB 이하 정렬)
   - `{{CMD_TABLE}}`, `{{CMD_HEAD}}`, `{{NUM_CMDS}}`
   - `{{SHELL_FUNC}}`, `{{ENTRY_REDIRECT}}`
   - `{{HANDOFF_MAGIC_BLOCK}}` — `wr32(...)` × N
   - `{{HEAP_STUB_BLOCK}}` — bump allocator 인코딩
   - `{{VTABLE_BLOCK}}` — 콘솔 vtable redirect
   - `{{SHELL_MODE_BLOCK}}` — `MOV W0,#1; RET` × N
   - `{{TRAMPOLINE_BLOCK}}` — SP set + UFCON + BL shell + B .
   - `{{CMD_RELOC_BLOCK}}`, `{{ENV_RELOC_BLOCK}}`
   - `{{CPU_BLOCK}}` — has_el3/el2, cortex 모델
3. `06_machine/machine.c` 로 저장
4. QEMU 트리에 통합:
   - 심볼릭링크 또는 cp: `~/qemu-build/qemu-10.2.2/hw/arm/sboot_<MODEL_LOWER>.c`
   - `hw/arm/meson.build` 의 `arm_ss.add(files(` 블록에 등록
5. `cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64`
6. 빌드 에러 시 그대로 보고 (추측 수정 금지)
7. 성공 시 보고: "machine.c 빌드 완료. 다음 /rehost 호출 시 회차 루프 시작."

---

### S5 — 회차 루프 미진입 또는 진행 중

**검사**: PROGRESS.md 의 마지막 회차가 정지점 (5/5 통과 전)

**실행**:
1. Workflow 호출: `workflows/iter-loop.js`
   - args: `{ n: 10, workdir: <path>, machine_name: sboot-<model>, bl3: <path> }`
2. Workflow 가 10 회차 자동 진행:
   - 각 회차: qemu 실행 → fault-fixer agent → 패치 → critic agent → 다음
3. 끝나면 보고: 진행한 회차 수, 마지막 fault, 셸 도달 후보 여부

**fault 없음 도달 (0 exception)** 이면 다음 호출에서 S6 으로.

---

### S6 — 셸 도달 후보 (UART 출력 등장)

**검사**: 가장 최근 `07_logs/console_*.txt` 의 크기 > 0 AND BL3 안의 알려진
ASCII (`S-BOOT`, `autoboot`, `help`) 중 ≥ 1 개 등장

**실행**:
1. Agent 호출: `reality-verifier`
2. 결과를 VERIFICATION.md 로 저장
3. 보고:
   - 5/5 통과면 "★ REAL — 다음 /rehost 호출 시 재현 키트 생성"
   - 4/5 이하면 "FORCED — 다음 회차 진입 권장 + 어느 항목 실패" 보고

---

### S7 — 검증 통과, 재현 키트 미생성

**검사**: VERIFICATION.md 의 5/5 = PASS AND `10_reproduce/` 없음

**실행**:
1. `10_reproduce/` 폴더 생성:
   ```
   10_reproduce/
   ├── README.md         (INPUT.md 정보 + 빌드 + 실행 가이드)
   ├── bl3/<bl3.bin>     (원본 BL3 복사)
   ├── machine/machine.c (현재 머신 복사)
   ├── scripts/
   │   ├── 01_setup_env.sh   (플러그인 scripts/setup_env.sh 복사)
   │   ├── 02_build.sh       (machine.c → QEMU 통합 + ninja)
   │   └── 03_run.sh         (qemu 실행 + diff 검증)
   └── evidence/
       ├── EXPECTED_OUTPUT.txt   (현재 콘솔 출력 복사)
       └── VERIFICATION.md       (5/5 결과 복사)
   ```
2. 보고: "★ 완료. 10_reproduce/ 폴더가 새 환경에서 5 분 안에 재현 가능."

---

### S8 — 완료

**검사**: VERIFICATION.md 5/5 PASS + `10_reproduce/` 존재

**실행**: 사용자에게 완료 메시지 + 다음 행동 제안:
- "다른 펌웨어 시도하려면 새 디렉터리에서 /rehost"
- "다른 명령 (printenv 등) 등급 B 로 격상하려면 INPUT.md target 수정 후 /rehost"

---

## 호출마다 보고 형식

```
**현재 상태**: S<N> (<상태 설명>)
**실행**: <한 줄>
**결과**: <한 줄>
**다음**: /rehost 호출 시 S<N+1> 진행 (<예상 동작>)
```

위반 (정직성 7, 검증 5/5) 발생 시 즉시 보고 + 사용자 확인 요청. 절대
"성공" 표시 강제 안 함.
