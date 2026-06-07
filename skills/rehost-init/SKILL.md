---
name: rehost-init
description: sboot-rehost 의 1 회 셋업. 의존성 설치 (백그라운드) + 폴더 구조 생성 + 펌웨어 다운로드/추출 안내 + 사용자 4 질문 → INPUT.md 생성. 사용자가 첫 번째로 호출하는 명령. 끝나면 /rehost 로 본격 멀티에이전트 실행.
---

당신은 sboot-rehost 의 셋업 오케스트레이터. `/rehost-init` 호출 시 한 번에:

1. 환경 검사 + 의존성 (필요 시 백그라운드 설치)
2. 폴더 구조 생성
3. 펌웨어 다운로드/추출 안내
4. 사용자 4 질문 → INPUT.md 작성

끝나면 사용자에게 **"이제 /rehost 를 호출하면 병렬 멀티에이전트로 진행"** 안내.

---

## Step 1 — 작업 디렉터리 확정

- 사용자가 명시한 디렉터리가 있으면 그것, 없으면 현재 cwd
- 새 디렉터리면 한 번 확인: "여기서 작업할까요? 다른 위치 원하면 종료 후
  해당 위치에서 다시 호출"

---

## Step 2 — 의존성 검사 + (필요 시) 백그라운드 설치

검사:
- `which qemu-system-aarch64` → 10.x 인지
- `python3 -c "import capstone"` → 정상인지

미설치 시:
1. 사용자에게 "의존성 설치 (apt + QEMU 10.2.2 빌드, ~18 분, sudo 필요)
   백그라운드로 진행할까요?" 동의 받기
2. 동의 시: `bash <PLUGIN_DIR>/scripts/setup_env.sh` 를 **백그라운드로
   실행** (Bash tool 의 `run_in_background: true`)
3. PID 보고 + "백그라운드 설치 중. Step 3, 4 진행." 안내

이미 설치돼있으면 "환경 OK" 한 줄 + Step 3 진행.

**병렬 효과**: 의존성 설치 ~18 분이 사용자 인터랙션 (Step 4~6) 과 겹쳐
실제 대기 시간 ↓.

---

## Step 3 — 폴더 구조 생성

작업 디렉터리에 표준 8 폴더 + 빈 PROGRESS.md 골격:

```
<workdir>/
├── 01_firmware/                   사용자가 펌웨어 .tar.md5 / .zip 넣을 곳
├── 02_unpacked/                   lz4 해제 후 sboot.bin / .pit
├── 03_bl3/                        BL3 본체 (carve 또는 full)
├── 04_static-analysis/            STATIC.md / STUBS.md / 도출 스크립트 출력
├── 05_qemu/                       QEMU 빌드 디렉터리 심볼릭링크 (옵션)
├── 06_machine/                    machine.c + 우회_패치_목록.md
├── 07_logs/                       회차별 console / run 로그
├── 08_docs/                       추가 분석 메모
└── (PROGRESS.md 골격 — templates/PROGRESS.md.tmpl 의 0회차 빈 양식)
```

---

## Step 4 — 펌웨어 가이드 출력 (Briefing)

작업 디렉터리 셋업 후 한 화면 텍스트:

```
==================================================
sboot-rehost — 펌웨어 가이드
==================================================

Samsung Galaxy 펌웨어 (S-Boot BL3) 확보 절차:

[1] 다운로드
    - samfw.com 또는 sammobile.com 접속
    - 본인 기기 모델 (예: SM-S921N) 검색
    - 캐리어 (OKR/KOO/KOR/etc) 선택
    - "Download" 클릭하여 zip 파일 받기 (약 ~5 GB)

    ★ 본인 소유 기기의 펌웨어만 사용 (라이선스 준수)

[2] 압축 해제 → BL_ 파일 추출
    - 받은 zip 해제 시 다음 5 개 .tar.md5 파일 등장:
      * AP_*.tar.md5     — 안드로이드 시스템 (15 GB, 본 작업 불요)
      * BL_*.tar.md5     — 부트로더 (★ 필요, 약 ~11 MB)
      * CSC_*.tar.md5    — 캐리어 (PIT 파일용, 약 ~120 MB)
      * HOME_CSC...
      * USERDATA...

    → 01_firmware/ 에 BL_*.tar.md5 와 CSC_*.tar.md5 만 복사

[3] BL3 본체 추출
    cd <workdir>/01_firmware
    tar xf BL_*.tar.md5                              # sboot.bin.lz4 등 추출
    lz4 -d sboot.bin.lz4 sboot.bin                   # lz4 해제 (lz4 패키지 필요)
    mv sboot.bin ../02_unpacked/

    BL3 본체 크기 확인:
      ls -la ../02_unpacked/sboot.bin                # 보통 4 MB 이상이면 full

    ★ sboot.bin 이 4 MB 미만이면 carve 가능성 → 회차 진입 전 critic 신호 4 발화

[4] 최종 위치
    <workdir>/02_unpacked/sboot.bin   ← Step 5 의 Q1 에서 이 절대경로 입력

--- 목표 등급 안내 ---

A = help 명령까지 (가장 안정적, ~30 분)
    셸 도달 + 명령 목록 출력. UFS/PMIC 모델 불요.

B = 특정 명령 핸들러 실행 (printenv 등, ~2 시간)
    UFS / PMIC 일부 모델링 필요. 부분적.

C = autoboot 전체 (대부분 풀 모델 필요, ~수일)
    본 플러그인 범위 초과. 시도 시 critic 신호 5.

==================================================
```

---

## Step 5 — Ready check (AskUserQuestion 1 개)

```
Q: 펌웨어 준비 상태는?
   - "준비됐어, 시작" — Step 6 의 4 질문 진행
   - "도움 더 필요" — Step 4 의 가이드를 다시 출력하거나, 사용자 특정
     질문에 답변 후 다시 묻기
   - "나중에" — 종료. 준비되면 다시 /rehost-init 호출
```

---

## Step 6 — Intake (AskUserQuestion 4 질문)

"시작" 선택 시:

- **Q1 (펌웨어 경로)**: "BL3 본체 파일 절대 경로 (예: /mnt/c/.../02_unpacked/sboot.bin)"
- **Q2 (모델)**: "모델 식별자 (예: SM-S921N)"
- **Q3 (등급)**: A / B / C
- **Q4 (참조 자산)**: 콤마 구분 경로 (없으면 빈 칸)

자동 추출 (입력 후):
- 파일 존재 확인 (없으면 다시 묻기)
- md5sum 자동 계산
- 파일 크기 자동
- 4 MB 미만이면 경고:
  ```
  ★ 경고: BL3 가 4 MB 미만 (~XKB). carve 가능성 높음.
  full BL3 본체로 작업해야 셸 도달 가능. 계속 진행할까요?
  ```

SoC / build / carrier 는 추가로 묻지 않고 "미확정" 으로 시작 (정직성 §4).

---

## Step 7 — INPUT.md + PROGRESS.md 작성

작업 디렉터리에:

`INPUT.md`:
```markdown
# INPUT — sboot-rehost 0차 입력

| 슬롯 | 값 |
|---|---|
| model | <Q2> |
| soc | 미확정 |
| build | 미확정 |
| md5 | <자동> |
| file_size | <자동> bytes |
| carrier | 미확정 |
| target | <Q3: A/B/C> |
| bl3_path | <Q1> |
| workdir | <cwd> |
| refs | <Q4> |
| has_el3_guess | false |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |

생성 시각: <ISO timestamp>
```

`PROGRESS.md`: `templates/PROGRESS.md.tmpl` 의 0 회차 양식 채워서 작성.

---

## Step 8 — 완료 보고

```
==================================================
sboot-rehost 셋업 완료
==================================================

| 항목 | 값 |
|---|---|
| 모델 | <model> |
| 등급 | <target> |
| BL3 | <bl3_path> (<size> bytes, md5 <md5>) |
| 작업 디렉터리 | <cwd> |
| 의존성 | OK / 백그라운드 설치 중 (PID <pid>) |

다음 단계:
  /rehost   — 병렬 멀티에이전트로 정적 분석 → 머신 생성 → 회차 루프 →
              검증 → 재현 키트 자동 진행 (인간 개입 최소)

  /rehost-status — 진행 상황 한 화면 요약 (회차 수, 미확정 항목, 5/5 검증)
==================================================
```

만약 의존성 백그라운드 설치 중이면 추가 안내:
```
의존성 백그라운드 설치가 끝나야 /rehost 실행 가능 (약 18 분 소요).
완료되면 자동으로 알림 (백그라운드 task 완료 시).
```

---

## 정직성

- Step 6 의 자동 추출 (md5/크기) 은 실제 명령으로 (가짜 값 금지)
- 의존성 백그라운드 설치는 진짜 PID 보고 (가짜 OK 금지)
- 사용자가 "나중에" 선택 시 INPUT.md 만들지 말 것 (반쪽 셋업 금지)
- 4 MB 미만 경고 시 사용자가 "그래도 진행" 선택해도 INPUT.md 에 그 사실
  명시 (carve_suspected: true)
