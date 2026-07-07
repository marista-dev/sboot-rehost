---
name: rehost-init
description: sboot-rehost 의 1 회 셋업. 의존성 설치 (백그라운드) + 폴더 구조 생성 + 펌웨어 다운로드/추출 안내 + 트랙 선택 + 사용자 질문 → INPUT.md 생성. 사용자가 첫 번째로 호출하는 명령. 끝나면 트랙에 맞는 실행 명령 (/rehost-sboot 또는 /rehost-kernel) 안내.
---

당신은 sboot-rehost 의 셋업 오케스트레이터. `/rehost-init` 호출 시 한 번에:

1. 환경 검사 + 의존성 (필요 시 백그라운드 설치)
2. 폴더 구조 생성
3. 펌웨어 다운로드/추출 안내
4. 입력 수집 → INPUT.md 작성

끝나면 사용자에게 **"이제 트랙에 맞는 실행 명령 (/rehost-sboot 또는 /rehost-kernel) 을
호출하면 멀티에이전트로 진행"** 안내.

---

## 자율 모드 (기본, CLAUDE.md 자율 실행)

`/rehost-init` 인자에 `interactive` 가 없으면 **자율 모드** (INPUT.md `autonomous: true`).
자율 모드에선 `AskUserQuestion` 을 쓰지 않는다:

- **입력은 명령 인자 또는 미리 채운 INPUT.md 에서** 받는다. 예:
  `/rehost-init track=2 model=SM-S921N target=K3 bootimg=/path/boot.img super=/path/super.img.lz4 ko=/path/ufs-exynos-core.ko`
  또는 `/rehost-init track=1 model=SM-S921N target=A bl3=/path/sboot.bin`
- **의존성**은 미설치 시 자동 백그라운드 설치 (동의 안 물음). `journal.sh decision` 기록.
- **Ready check (Step 5) 생략.**
- **필수 슬롯이 결손이면 질문 대신 명확한 에러로 중단** (펌웨어 경로는 자동 선택 불가 — 하드 블로커).
  트랙 1 필수: track, model, target, bl3. 트랙 2 필수: track, model, target, bootimg(또는 fw/),
  (+ target K2/K3 이면 super, target K3 이면 ko).
- 인자에 `interactive` 가 있으면 기존처럼 `AskUserQuestion` (Step 5/6).

어느 모드든 결정·시각은 JOURNAL.md 에 기록 (session-start/end + decision).

---

## Step 1 — 작업 디렉터리 확정 + JOURNAL 세션 시작

- 사용자가 명시한 디렉터리가 있으면 그것, 없으면 현재 cwd
- 새 디렉터리면 한 번 확인: "여기서 작업할까요? 다른 위치 원하면 종료 후
  해당 위치에서 다시 호출"
- 확정 즉시 (필수, CLAUDE.md 실행 기록):
  ```
  bash <PLUGIN_DIR>/scripts/journal.sh <workdir> session-start "/rehost-init" "setup"
  ```

---

## Step 2 — 의존성 검사 + (필요 시) 백그라운드 설치

검사:
- `which qemu-system-aarch64` → 10.x 인지
- `python3 -c "import capstone"` → 정상인지

미설치 시:
1. **자율 모드**: 동의 안 물음 → 바로 `bash <PLUGIN_DIR>/scripts/setup_env.sh` **백그라운드
   실행** (`run_in_background: true`) + `journal.sh <wd> decision "의존성 미설치" "자동 백그라운드 설치" "되돌릴 수 있는 셋업"`.
   **interactive 모드**: "설치 (~18 분, sudo) 진행할까요?" 동의 받은 뒤 실행.
2. PID 보고 + "백그라운드 설치 중. Step 3+ 진행." 안내.

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
├── 06_machine/                    machine.c(.kernel) + 우회_패치_목록.md
├── 07_logs/                       회차별 console / run 로그
├── 08_docs/                       추가 분석 메모
├── (트랙 2) fw/                   Image(.patched) / *.dtb / initramfs.cpio.gz / super.img
└── (PROGRESS.md 골격 — templates/PROGRESS.md.tmpl 의 0회차 빈 양식)
```

트랙 2 는 `fw/` 를 추가로 만들고, 01~05 (BL3 정적분석 계열) 는 생략 가능.

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

--- 트랙 + 목표 등급 안내 ---

[트랙 1] sboot-shell — 부트로더 BL3 → 셸 (자산: sboot.bin BL3)
  A = help 명령까지 (가장 안정적, ~30 분). UFS/PMIC 모델 불요.
  B = 특정 명령 핸들러 실행 (printenv 등). UFS/PMIC 일부 필요.
  C = autoboot 전체. 범위 초과 (critic 신호 5).

[트랙 2] kernel-storage — 커널 직부팅 → rootfs → Android (자산: boot.img/super.img)
  K1 = 유저스페이스 도달 (Run /init). 제네릭 스토리지 + 커널 게이트 우회.
  K2 = 진짜 rootfs (system/vendor) 마운트. 제네릭+DT fstab 또는 dm-linear.
  K3 = 진짜 벤더 스토리지 HCI 모델 → 벤더 .ko 가 파티션 구동 ("컨트롤러 구현").
       벤더 드라이버 .ko 필수.
  (공통 프론티어: /data FBE → vold → Keymint → TEE. 미달로 정직 기록.)

==================================================
```

---

## Step 5 — Ready check

- **자율 모드**: 생략 (준비됐다고 가정, 입력은 인자/INPUT.md).
- **interactive 모드** (AskUserQuestion 1 개):
  ```
  Q: 펌웨어 준비 상태는?
     - "준비됐어, 시작" / "도움 더 필요" / "나중에"
  ```

---

## Step 6 — Intake (트랙별 슬롯 수집)

트랙 → 트랙별 슬롯 수집. **자율 모드**는 명령 인자 (또는 미리 채운 INPUT.md) 에서, **interactive
모드**는 `AskUserQuestion` 으로.

**공통**: track, model, target. **트랙 1**: bl3 (BL3 경로). **트랙 2**: bootimg (또는 fw/ 폴더),
super (K2/K3), ko (K3).

자율 인자 예:
- 트랙 1: `/rehost-init track=1 model=SM-S921N target=A bl3=/path/sboot.bin refs=...`
- 트랙 2: `/rehost-init track=2 model=SM-S921N target=K3 bootimg=/path/boot.img super=/path/super.img.lz4 ko=/path/ufs-exynos-core.ko`

수집 후 자동 추출·검증:
- 트랙 1: bl3 존재 + md5 + 크기. 4 MB 미만 → `carve_suspected: true` (자율 모드에선 **하드
  블로커**: 중단 + 보고, 계속 안 함).
- 트랙 2: Image md5+크기, DTB 매직(0xd00dfeed), super EROFS/sparse 판별. bootimg 있으면
  `extract_boot_assets.sh` 로 fw/ 채움.

필수 슬롯 결손 시 (자율 모드): **질문 대신 명확한 에러로 중단** — "필수 슬롯 결손: <목록>.
인자 또는 INPUT.md 로 제공 후 재호출". target=K3 인데 ko 없음도 하드 블로커.

SoC / build / carrier 는 묻지 않고 "미확정" 으로 시작 (정직성 §4).

---

## Step 7 — INPUT.md + PROGRESS.md 작성

작업 디렉터리에:

`INPUT.md` — **트랙 1**:
```markdown
# INPUT — sboot-rehost 0차 입력

| 슬롯 | 값 |
|---|---|
| track | 1 |
| autonomous | true |
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

`INPUT.md` — **트랙 2**:
```markdown
# INPUT — sboot-rehost 0차 입력

| 슬롯 | 값 |
|---|---|
| track | 2 |
| autonomous | true |
| model | <Q2> |
| soc | 미확정 |
| build | 미확정 |
| target | <Q3: K1/K2/K3> |
| bootimg_path | <Q1: boot.img 또는 fw/ 경로> |
| kernel_path | <fw/Image (추출 후)> |
| dtb_path | <fw/*.dtb> |
| initrd_path | <fw/initramfs.cpio.gz> |
| super_path | <Q4: super.img (있으면)> |
| storage_driver_ko | <Q5: 벤더 .ko (K3)> |
| md5 | <Image 자동> |
| file_size | <Image 자동> bytes |
| workdir | <cwd> |
| has_el3_guess | false |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |

생성 시각: <ISO timestamp>
```

`PROGRESS.md`: `templates/PROGRESS.md.tmpl` 의 0 회차 양식 채워서 작성.

JOURNAL 세션 종료 (필수):
```
bash <PLUGIN_DIR>/scripts/journal.sh <workdir> session-end "/rehost-init" "INPUT.md 생성, track <1/2>, target <..>"
```
("나중에" 로 종료 시엔 INPUT.md 없이 `session-end "/rehost-init" "취소 (준비 대기)"`.)

---

## Step 8 — 완료 보고

```
==================================================
sboot-rehost 셋업 완료
==================================================

| 항목 | 값 |
|---|---|
| 트랙 | <1 sboot-shell / 2 kernel-storage> |
| 모델 | <model> |
| 등급 | <target> |
| 자산 | <bl3_path 또는 fw/Image> (<size> bytes, md5 <md5>) |
| 작업 디렉터리 | <cwd> |
| 의존성 | OK / 백그라운드 설치 중 (PID <pid>) |

다음 단계 (★ 선택한 트랙의 실행 명령 하나만):
  트랙 1 → /rehost-sboot    (S-Boot 셸)
  트랙 2 → /rehost-kernel   (커널 + 스토리지)
    → 정적 분석 → 머신 생성 → 회차 루프 → 검증 → 재현 키트 자동 진행

  /rehost-status — 진행 상황 한 화면 요약
==================================================
```

★ 완료 보고에서는 **선택한 트랙에 해당하는 명령 하나만** 명시 (다른 트랙 명령은 언급 안 함).

만약 의존성 백그라운드 설치 중이면 추가 안내:
```
의존성 백그라운드 설치가 끝나야 실행 명령 (/rehost-sboot 또는 /rehost-kernel) 가능
(약 18 분 소요). 완료되면 자동 알림.
```

---

## 정직성

- Step 6 의 자동 추출 (md5/크기) 은 실제 명령으로 (가짜 값 금지)
- 의존성 백그라운드 설치는 진짜 PID 보고 (가짜 OK 금지)
- 사용자가 "나중에" 선택 시 INPUT.md 만들지 말 것 (반쪽 셋업 금지)
- 4 MB 미만 경고 시 사용자가 "그래도 진행" 선택해도 INPUT.md 에 그 사실
  명시 (carve_suspected: true)
