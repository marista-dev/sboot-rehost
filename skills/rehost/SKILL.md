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
1. 사용자에게 "의존성 설치 (~18 분, sudo 필요) 진행해도 될까요?" 확인
2. 동의 시 `bash <PLUGIN_DIR>/scripts/setup_env.sh` 실행
3. 끝나면 보고: "환경 셋업 완료. 다시 /rehost 호출하세요."

**위반 시 (의존성 있는 척)**: 가짜 stub 으로 진행 금지. 실제 capstone import
+ qemu --version 확인까지 끝낸 후만 다음.

---

### S1 — 작업 디렉터리 미설정

**검사**: 작업 디렉터리에 `INPUT.md` 없음

**실행**:
1. **AskUserQuestion 으로 4 가지 질문 한 번에**:
   - Q1 (펌웨어): "BL3 본체 파일 (sboot.bin) 절대 경로"
   - Q2 (모델): "모델 식별자 (예: SM-S921N)"
   - Q3 (등급): A (help 만) / B (특정 명령) / C (autoboot)
   - Q4 (참조): 유사 SoC 머신.c 또는 다른 분석가 자료 경로 (옵션, 없으면 빈 칸)
2. 자동 추출:
   - md5sum (Bash 호출)
   - 파일 크기
3. SoC / build / carrier 는 옵션 — 사용자가 README 에 명시 안 했으면
   "미확정" 으로 시작 (정직성 §4)
4. 작업 디렉터리에 다음 생성:
   - 표준 8 폴더 (01_firmware ~ 08_docs)
   - INPUT.md (Table B 슬롯 채워서)
   - PROGRESS.md (templates/PROGRESS.md.tmpl 사용, 0 회차만 기록)
5. 보고: "INPUT.md 생성 완료. 다음 /rehost 호출 시 정적 분석 시작."

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
