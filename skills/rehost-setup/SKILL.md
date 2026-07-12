---
name: rehost-setup
description: 새 펌웨어 리호스팅 세팅 (init+setup 병합, 펌웨어당 1회). 의존성 확인(1회성) + 펌웨어당 독립 워크스페이스 <cwd>/rehost_workspaces/<id>/ 생성(덮어쓰기 금지) + 언팩 + 실행 사본 WSL 이동 + INPUT.md 작성 + .active 갱신. 펌웨어 zip 을 rehost_workspaces/_inbox/ 에 넣거나 fw= 로 지정. 여러 펌웨어를 격리 관리.
---

당신은 **새 펌웨어 리호스팅 세팅** 오케스트레이터. **펌웨어당 이 명령 한 번**으로 그 펌웨어
전용 독립 워크스페이스를 만든다 (예전 init+setup 을 병합). **여러 펌웨어를 서로 안 덮어쓴다.**

**자율(기본)**: track/model/target 는 인자, 펌웨어는 `_inbox/` 자동 감지 또는 `fw=` 로. 필수
결손·carve 의심은 하드 블로커(중단+보고). `interactive` 인자면 `AskUserQuestion`.

---

## 폴더 규약 (작업 루트 = Windows cwd 밑)

```
<cwd>/rehost_workspaces/            ← 작업 루트 (플러그인 폴더 아님)
├── _inbox/                         ← 펌웨어 zip 드롭 (설치 시 훅이 자동 생성)
├── .active                         ← 현재 워크스페이스 id 포인터
├── <model>_<build>/                ← 펌웨어 A 워크스페이스 (독립)
│   ├── INPUT.md JOURNAL.md PROGRESS.md
│   ├── 01_firmware/ 02_unpacked/ fw/ 06_machine/ 07_logs/ 08_docs/
└── <다른 model>_<build>/           ← 펌웨어 B (독립)
```

---

## Step 0 — 작업 루트 + 의존성 (1회성)

1. `WORKROOT = <cwd>/rehost_workspaces` (없으면 생성; `_inbox/` 도). WSL 접근용 `/mnt/c/...` 형태도 확보.
2. **의존성 (모든 펌웨어 공유, 1회만)**: `qemu-system-aarch64`/`capstone`/`dtc` 검사. 없으면
   `bash <PLUGIN>/scripts/setup_env.sh` **백그라운드** 실행(~18분, 첫 펌웨어에서 1번). 있으면 스킵.

## Step 1 — 펌웨어 입력 + 슬롯

- 펌웨어: `fw=<경로>` 인자 우선, 없으면 `WORKROOT/_inbox/` 에서 zip/tar.md5/이미지 자동 감지
  (여러 개면 가장 최근 것, 또는 사용자에게 어느 것인지 안내).
- 슬롯: `track` / `model` / `target`. model/build 는 펌웨어 파일명·메타에서 도출 시도(예:
  `SM-A166B_A166B...zip`), 인자로 덮어쓰기 가능. 필수(track/model/target) 결손이면 하드 블로커.

## Step 2 — 워크스페이스 id + 격리 폴더 생성 (★ 덮어쓰기 금지)

- `id = <model>_<build>` (build 미상이면 `<model>_<soc>` 또는 짧은 해시). 예: `SM-A166B_A166BXXU2AXXX`.
- `WS = WORKROOT/<id>`. **이미 있으면 덮어쓰지 말 것** — 사용자에게 "이미 존재. 재세팅은 폴더
  삭제 후, 또는 `id=<새이름>`" 안내 후 종료(하드 블로커). 새 id 면 표준 폴더 생성:
  `01_firmware 02_unpacked 03_bl3 04_static-analysis 06_machine 07_logs 08_docs` (+ 트랙 2 `fw/`).
- 기록 시작: `bash <PLUGIN>/scripts/journal.sh <WS> session-start "/rehost-setup" "새 워크스페이스 <id>"`.

## Step 3 — 언팩 (WSL)

펌웨어를 `WS/01_firmware/` 로 옮긴 뒤 트랙별 언팩:
- 트랙 1: `tar xf BL_*.tar.md5 sboot.bin.lz4 → lz4 -d → WS/02_unpacked/sboot.bin`.
- 트랙 2: `bash <PLUGIN>/scripts/extract_boot_assets.sh <WS> <boot.img> [super] [dtb]` → `WS/fw/`.
- 이미 풀린 sboot.bin/boot.img 면 언팩 생략.

## Step 4 — 실행 사본 WSL ext4 로 이동

- `WSDIR=$HOME/rehost/<id>`; 실행 입력(sboot.bin 또는 Image/dtb/initrd/super)을 거기로 복사.
- 문서·기록·07_logs 는 `WS`(Windows) 그대로. 대용량 `-d` 트레이스는 run 스크립트가 `~/rehost/_traces`.
- `journal.sh <WS> decision "실행 사본" "WSL ext4 ($WSDIR)" "/mnt/c I/O 느림 회피"`.

## Step 5 — 자산 검증 (실제 명령, 하드 블로커 판정)

- 트랙 1: md5·크기. **4 MB 미만 = carve 의심 → 하드 블로커**.
- 트랙 2: Image md5·크기, DTB 매직 `0xd00dfeed`, super EROFS `0xe0f5e1e2`. **target=K3 인데 `.ko` 없음 → 하드 블로커**.

## Step 6 — INPUT.md + PROGRESS.md + .active

`WS/INPUT.md` (자산=WSL 사본 경로, workdir=WS 의 `/mnt/c/...` 형태):

```markdown
| 슬롯 | 값 |
|---|---|
| workspace_id | <id> |
| track | <1|2> |
| autonomous | true |
| model | <model> |
| build | <build 또는 미확정> |
| soc | 미확정 |
| target | <A/B/C 또는 K1/K2/K3> |
| bl3_path 또는 kernel_path/dtb_path/initrd_path/super_path/storage_driver_ko | <WSL 사본> |
| md5 | <자동> |
| file_size | <자동> |
| workdir | </mnt/c/.../rehost_workspaces/<id>> |
| wsl_workspace | ~/rehost/<id> |
| has_el3_guess | false |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |
```

- `WS/PROGRESS.md`: `templates/PROGRESS.md.tmpl` 0회차.
- `WORKROOT/.active` 에 `<id>` 기록 (실행 명령의 기본 대상).
- 기록 종료: `journal.sh <WS> session-end "/rehost-setup" "INPUT.md 생성, active=<id>"`.

## Step 7 — 완료 보고

```
== 새 워크스페이스 세팅 완료 ==
| 워크스페이스 | rehost_workspaces/<id> (active) |
| 트랙 / 등급  | <1|2> / <target> |
| 자산(WSL)    | <경로> (<size>, md5 <md5>) |
| 의존성       | OK / 백그라운드 설치 중 |

다음:  트랙 1 → /rehost-sboot   /   트랙 2 → /rehost-kernel   (active 워크스페이스로 자율 실행)
       다른 펌웨어 → _inbox/ 에 넣고 /rehost-setup 다시 (새 폴더, 기존 안 덮어씀)
       전체 목록 → /rehost-status
```

---

## 정직성

- **덮어쓰기 금지**: 같은 id 워크스페이스가 있으면 절대 덮어쓰지 말 것 (기존 펌웨어 산출물 보호).
- 언팩·md5·크기는 실제 명령. carve 의심/필수 결손/K3 `.ko` 부재 = 하드 블로커(중단+보고).
- 의존성은 1회성 공유 — 두 번째 펌웨어부터 재설치 금지(스킵).
- 자산=WSL, 문서·기록=워크스페이스(Windows). 위치를 INPUT.md 에 정확히 기록.
