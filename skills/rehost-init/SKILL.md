---
name: rehost-init
description: sboot-rehost 1단계 셋업 (데이터 불요). 표준 폴더를 플러그인이 시작된 Windows 현재 폴더(cwd)에 생성 + 의존성 백그라운드 설치 + 펌웨어 확보 안내. 펌웨어는 아직 필요 없음. 끝나면 사용자가 펌웨어를 01_firmware/ 에 넣고 /rehost-setup 호출.
---

당신은 sboot-rehost 의 **1단계 셋업(환경 준비)** 오케스트레이터. `/rehost-init` 은
**펌웨어 없이** 되는 것만 한다:

1. 표준 폴더 생성 (★ **Windows 현재 폴더 = 플러그인이 시작된 cwd**. 플러그인 설치 폴더 안 아님, WSL 아님)
2. 의존성 백그라운드 설치
3. 펌웨어 확보 안내 (어디서 받아 어디에 넣을지)

펌웨어 반입·INPUT.md 작성은 다음 명령 **`/rehost-setup`** 이 한다 (펌웨어가 있어야 하므로 분리).

---

## Step 1 — 작업 디렉터리 = Windows cwd + JOURNAL 세션 시작

- **workdir = 플러그인이 시작된 Windows 현재 폴더(cwd)**. 별도 지정(`workdir=...`)이 있으면 그것.
  - ★ 플러그인 설치 폴더 안에 만들지 말 것 (업데이트 시 소실). ★ WSL 이 아니라 Windows 쪽.
  - WSL 스크립트가 접근하도록 workdir 의 `/mnt/c/...` 형태 경로도 같이 확보 (예:
    `C:\Users\you\exynos1300` → `/mnt/c/Users/you/exynos1300`).
- 즉시 기록: `bash <PLUGIN_DIR>/scripts/journal.sh <workdir> session-start "/rehost-init" "환경 준비"`.

---

## Step 2 — 의존성 검사 + 백그라운드 설치

검사: `which qemu-system-aarch64` (10.x), `python3 -c "import capstone"`, `dtc`(트랙 2).

미설치 시:
- **자율(기본)**: 동의 안 물음 → `bash <PLUGIN_DIR>/scripts/setup_env.sh` **백그라운드 실행**
  (`run_in_background: true`) + `journal.sh <wd> decision "의존성 미설치" "자동 백그라운드 설치" "되돌릴 수 있는 셋업"`. PID 보고.
- **interactive**: "설치 (~18분, sudo) 진행할까요?" 동의 후 실행.

이미 있으면 "환경 OK". 이 ~18분 빌드가 사용자가 펌웨어 받는 시간과 겹쳐 실제 대기 ↓.

---

## Step 3 — 표준 폴더 생성 (Windows cwd)

`<workdir>` (Windows cwd) 에 생성:

```
<workdir>/                          ← Windows cwd (플러그인 시작 위치)
├── 01_firmware/     ★ 여기에 펌웨어(.zip / BL_*.tar.md5 / AP_*.tar.md5)를 넣으세요
├── 02_unpacked/                    lz4 해제 후 sboot.bin / .pit
├── 03_bl3/                         BL3 본체
├── 04_static-analysis/             STATIC.md / STUBS.md 등
├── 06_machine/                     machine.c(.kernel) + 우회_패치_목록.md
├── 07_logs/                        회차별 console / run 로그
├── 08_docs/                        추가 분석 메모
├── (트랙 2) fw/                    Image / *.dtb / initramfs / super.img
└── PROGRESS.md (골격)              templates/PROGRESS.md.tmpl 0회차 양식
```

트랙 2 는 `fw/` 추가, 01~05 생략 가능. (펌웨어의 실제 실행 사본은 `/rehost-setup` 이 WSL 로 옮긴다.)

---

## Step 4 — 펌웨어 확보 안내 (Briefing)

```
==================================================
sboot-rehost — 펌웨어 확보 안내
==================================================
[1] 다운로드: samfw.com / sammobile.com 에서 본인 기기 모델 펌웨어 zip (본인 소유만).
[2] 압축 해제 → 트랙별 필요 파일:
    - 트랙 1: BL_*.tar.md5  (부트로더, ~11MB)  (+ CSC_*.tar.md5 = PIT, 선택)
    - 트랙 2: AP_*.tar.md5  (boot.img/super.img 포함)
[3] ★ 받은 파일(또는 압축 푼 것)을  <workdir>/01_firmware/  에 넣으세요.
    (여기서 굳이 풀 필요 없음 — /rehost-setup 이 언팩·WSL 이동까지 함)

--- 트랙/등급 ---
트랙 1 (sboot-shell):  A=help / B=명령핸들러 / C=autoboot
트랙 2 (kernel-storage): K1=유저스페이스 / K2=rootfs 마운트 / K3=진짜 UFS 컨트롤러
==================================================
```

---

## Step 5 — 완료 보고 + 다음 단계

JOURNAL 세션 종료: `bash <PLUGIN_DIR>/scripts/journal.sh <workdir> session-end "/rehost-init" "폴더 생성(Windows cwd) + 의존성 <OK/설치중 PID>"`.

```
==================================================
sboot-rehost 1단계(환경 준비) 완료
==================================================
| 작업 디렉터리 | <workdir> (Windows cwd) |
| 폴더          | 생성됨 |
| 의존성        | OK / 백그라운드 설치 중 (PID <pid>) |

다음:
  1) 펌웨어를  <workdir>/01_firmware/  에 넣으세요.
  2) /rehost-setup track=<1|2> model=SM-XXXX target=<A/B/C 또는 K1/K2/K3>
       → 펌웨어 언팩 + WSL 작업공간으로 이동 + 의존성 확인 + INPUT.md 생성
  3) /rehost-sboot  (또는 /rehost-kernel)  → 자율 회차 루프
==================================================
```

---

## 정직성

- 표준 폴더는 **Windows cwd** 에 생성 (플러그인 폴더 안·WSL 아님). 지어낸 경로 금지.
- 의존성 백그라운드 설치는 진짜 PID 보고.
- init 는 **INPUT.md 를 만들지 않는다** (펌웨어 없이 반쪽 INPUT 금지 — setup 이 작성).
