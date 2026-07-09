---
name: rehost-setup
description: sboot-rehost 2단계 셋업 (펌웨어 반입). /rehost-init 후 사용자가 <workdir>/01_firmware/ 에 펌웨어를 넣으면 호출. 펌웨어 언팩(tar/lz4 → sboot.bin 또는 boot.img/super) + 실행 사본을 WSL ext4 작업공간으로 이동 + 의존성 완료 확인 + md5/크기 검증 → INPUT.md 생성. 끝나면 트랙 실행 명령(/rehost-sboot 또는 /rehost-kernel).
---

당신은 sboot-rehost 의 **2단계 셋업(펌웨어 반입)** 오케스트레이터. `/rehost-init` 로 폴더·
의존성이 준비되고 사용자가 **`<workdir>/01_firmware/` 에 펌웨어를 넣은 뒤** 호출된다.
하는 일: 펌웨어 언팩 → **WSL ext4 로 실행 사본 이동** → 의존성 확인 → INPUT.md 작성.

**자율(기본)**: track/model/target 는 인자로. 펌웨어 파일은 `01_firmware/` 에서 자동 감지.
`AskUserQuestion` 안 씀. 필수 결손·carve 의심은 하드 블로커(중단+보고).

---

## Step 0 — 선행 조건 + 세션 시작

1. **workdir 확정**: 현재 Windows cwd (또는 인자 `workdir=`). init 이 만든 표준 폴더가 있어야 함.
   - 폴더 없으면: "/rehost-init 을 먼저 호출하세요" 안내 후 종료.
2. **펌웨어 존재**: `<workdir>/01_firmware/` 에 파일이 있어야 함 (`.zip` / `BL_*.tar.md5` /
   `AP_*.tar.md5` / 이미 푼 `sboot.bin`·`boot.img`·`super.img` 등). 비었으면:
   "01_firmware/ 에 펌웨어를 넣고 다시 호출" 안내 후 종료 (하드 블로커).
3. 기록: `bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/rehost-setup" "펌웨어 반입 track <1|2>"`.

---

## Step 1 — 트랙 슬롯 수집

- **자율**: 인자에서 `track` / `model` / `target` (+ 트랙2: `super`·`ko` 없으면 01_firmware 에서 탐색).
- **interactive**: `AskUserQuestion` 으로 track/model/target.
- 필수: track, model, target. 결손이면 하드 블로커(중단+보고).

---

## Step 2 — 펌웨어 언팩 (WSL 에서)

`01_firmware/` 의 파일을 트랙별로 언팩 (`wsl -- bash ...`, 모두 실제 명령):

**트랙 1**:
```
tar xf 01_firmware/BL_*.tar.md5 -C 01_firmware sboot.bin.lz4   # (있으면)
lz4 -d 01_firmware/sboot.bin.lz4 02_unpacked/sboot.bin          # 또는 이미 sboot.bin 이면 복사
```
**트랙 2**:
```
bash <PLUGIN>/scripts/extract_boot_assets.sh <workdir> <01_firmware/boot.img> [super.img.lz4] [dtb]
# → <workdir>/fw/ 에 Image / *.dtb / initramfs / super.img
```
이미 풀린 파일(sboot.bin/boot.img)이 그대로 있으면 언팩 생략하고 사용.

---

## Step 3 — WSL ext4 작업공간으로 실행 사본 이동

QEMU 실행 입력(펌웨어)은 `/mnt/c`(느림) 대신 **WSL ext4** 에 두어야 빠르다 (방법론 §10.1).

```
WS="$HOME/rehost/<model>"; mkdir -p "$WS"
# 트랙 1: cp 02_unpacked/sboot.bin  "$WS/sboot.bin"
# 트랙 2: cp fw/Image fw/*.dtb fw/initramfs.cpio.gz "$WS/";  (super/디스크 이미지도 대용량이면 여기로)
```
- 이동한 경로를 INPUT.md 의 자산 슬롯(bl3_path / kernel_path 등)에 **WSL 경로로** 기록.
- 문서·기록·해결과정(JOURNAL/PROGRESS/VERIFICATION/INPUT/STATIC/07_logs 콘솔·요약)은
  **Windows cwd(workdir) 그대로** — 사용자가 로컬에서 봄.
- 대용량 `-d` 전체 트레이스는 run 스크립트가 `TRACE_DIR`(기본 `~/rehost/_traces`, WSL ext4)에
  쓴다 — 사용자가 직접 볼 필요 없는 중간물. (로컬 07_logs 엔 콘솔 + `*.summary.txt` 만.)
- `journal.sh <wd> decision "펌웨어 위치" "WSL ext4 로 이동 ($WS)" "/mnt/c QEMU I/O 느림 회피"`.

---

## Step 4 — 의존성 완료 확인 + 자산 검증

- **의존성**: init 의 백그라운드 빌드가 끝났는지 확인. 진행 중이면 **자율은 완료까지 자동 대기(폴링)** — 안 물음.
  `qemu-system-aarch64 --version` + `import capstone` 통과해야 함.
- **자산 검증** (실제 명령, 가짜 값 금지):
  - 트랙 1: `md5sum`·크기. **4 MB 미만 → carve 의심 = 하드 블로커** (중단+보고, `carve_suspected: true`).
  - 트랙 2: Image md5·크기, DTB 매직 `0xd00dfeed`, super EROFS(`0xe0f5e1e2`)/sparse 판별.
    target=K3 인데 `ko` 없음 → 하드 블로커.

---

## Step 5 — INPUT.md + PROGRESS.md 작성

`<workdir>/INPUT.md` (자산 경로는 **WSL 사본**, workdir 는 `/mnt/c/...` 형태):

**트랙 1**:
```markdown
| 슬롯 | 값 |
|---|---|
| track | 1 |
| autonomous | true |
| model | <model> |
| soc | 미확정 |
| build | 미확정 |
| md5 | <자동> |
| file_size | <자동> bytes |
| carrier | 미확정 |
| target | <A/B/C> |
| bl3_path | <WSL: ~/rehost/<model>/sboot.bin> |
| workdir | </mnt/c/.../cwd> |
| wsl_workspace | ~/rehost/<model> |
| refs | <있으면> |
| has_el3_guess | false |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |
```

**트랙 2**: 위와 동일 골격 + `track:2`, `bootimg_path`/`kernel_path`/`dtb_path`/`initrd_path`/
`super_path`/`storage_driver_ko` (모두 WSL 사본 경로), `wsl_workspace`.

`PROGRESS.md`: `templates/PROGRESS.md.tmpl` 0회차 양식 (track/autonomous 포함).

기록: `bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/rehost-setup" "INPUT.md 생성, 자산 WSL 이동, md5 <..>"`.

---

## Step 6 — 완료 보고

```
==================================================
sboot-rehost 2단계(펌웨어 반입) 완료
==================================================
| 트랙 / 등급 | <1|2> / <target> |
| 모델        | <model> |
| 자산(WSL)   | <bl3_path 또는 fw 자산> (<size>, md5 <md5>) |
| 문서/로그   | <workdir> (Windows cwd) |
| 의존성      | OK |

다음:  트랙 1 → /rehost-sboot   /   트랙 2 → /rehost-kernel
       (하드 블로커 전까지 안 멈추는 자율 회차 루프)
==================================================
```

---

## 정직성

- 언팩·md5·크기는 **실제 명령**으로 (가짜 값 금지).
- carve 의심(4MB 미만) / 필수 결손 / K3 `.ko` 부재 는 **하드 블로커** — 중단+보고, 자동 진행 금지.
- 자산은 WSL, 문서·로그는 Windows cwd — 위치를 INPUT.md 에 정확히 기록.
- 펌웨어가 없으면 INPUT.md 만들지 말 것 (반쪽 셋업 금지).
