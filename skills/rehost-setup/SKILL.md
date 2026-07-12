---
name: rehost-setup
description: 새 펌웨어 리호스팅 세팅. 사용자는 rehost-setup 뒤에 워크스페이스 이름만 적으면 된다(예 /rehost-setup a166b). 플러그인이 rehost_workspaces/_inbox/ 의 펌웨어를 자동 인식·언팩하고 독립 워크스페이스를 만든 뒤, 마지막에 어떤 트랙(1 sboot / 2 kernel)·등급을 실행할지 사용자에게 프롬프트로 물어 INPUT.md 를 작성한다. 의존성은 1회성.
---

당신은 **새 펌웨어 세팅** 오케스트레이터. 사용자는 **`/rehost-setup <이름>`** 만 치면 된다.
플러그인이 알아서: `_inbox/` 펌웨어 인식 → 격리 워크스페이스 생성 → **마지막에 트랙을 프롬프트로
물어봄** → INPUT.md. (예전처럼 인자를 다 요구하지 않는다.)

- **인자**: `<이름>` (워크스페이스 이름, 자유 라벨). 생략 시 펌웨어에서 `<model>_<build>` 도출.
  펌웨어를 직접 지정하려면 `fw=<경로>` 도 가능(선택).
- **트랙/등급은 세팅 끝에 프롬프트로** 고른다 (인자로 `track=`/`target=` 주면 프롬프트 생략).

---

## 폴더 규약

```
<cwd>/rehost_workspaces/     ← 작업 루트 (설치 시 훅이 _inbox/ 자동 생성)
├── _inbox/                  ← 펌웨어 zip/tar 드롭
├── .active                  ← 실행 명령의 기본 대상
└── <이름>/                  ← 이 세팅이 만드는 격리 워크스페이스
```

## Step 0 — 작업 루트 + 의존성(1회) + 펌웨어 인식

1. `WORKROOT = <cwd>/rehost_workspaces` (없으면 생성; `_inbox/` 포함). WSL 접근용 `/mnt/c/...` 확보.
2. **의존성(공유·1회)**: `qemu-system-aarch64`/`capstone`/`dtc` 검사. 없으면 `setup_env.sh`
   백그라운드(첫 펌웨어 1번, ~18분). 있으면 스킵.
3. **펌웨어 자동 인식**: `fw=` 인자 우선, 없으면 `WORKROOT/_inbox/` 스캔.
   - zip/tar.md5/이미지가 없으면: "`_inbox/` 에 펌웨어를 넣고 다시 호출" 안내 후 종료(하드 블로커).
   - 여러 개면 가장 최근(mtime) 것 사용 + 어느 것을 썼는지 보고.

## Step 1 — 워크스페이스 이름

- `id` = 인자 `<이름>`(공백/특수문자 정리). 생략 시 펌웨어 파일명·메타에서 `<model>_<build>` 도출.
- `WS = WORKROOT/<id>`. **이미 있으면 덮어쓰지 말 것** — "이미 존재. 다른 이름을 주거나 폴더 삭제
  후 재시도" 안내 후 종료(하드 블로커). 새 id 면 표준 폴더 생성:
  `01_firmware 02_unpacked 03_bl3 04_static-analysis 06_machine 07_logs 08_docs fw`.
- 기록: `bash <PLUGIN>/scripts/journal.sh <WS> session-start "/rehost-setup" "새 워크스페이스 <id>"`.

## Step 2 — 트랙·등급 선택 (★ 프롬프트)

`track=`/`target=` 인자가 **없으면** `AskUserQuestion` 으로 사용자에게 묻는다:

- **Q1 트랙**: 펌웨어에서 추정한 것을 첫 옵션으로(BL_*.tar → 트랙 1 추정, AP_*.tar/boot.img →
  트랙 2 추정):
  - "트랙 1 — S-Boot 셸 (`/rehost-sboot`)"
  - "트랙 2 — 커널 + 진짜 UFS 컨트롤러 (`/rehost-kernel`)"
- **Q2 등급**: 트랙 1 → A(help,권장)/B/C, 트랙 2 → K1/K2/K3(진짜 UFS 컨트롤러).
- **model** 이 펌웨어에서 안 나오면 여기서 함께 묻기(예 SM-A166B).

인자로 이미 주어졌으면 프롬프트 생략(자율). `interactive` 무관하게 이 선택 프롬프트는 유효.

## Step 3 — 언팩 (선택 트랙 기준, WSL)

펌웨어를 `WS/01_firmware/` 로 옮긴 뒤:
- 트랙 1: `tar xf BL_*.tar.md5 sboot.bin.lz4 → lz4 -d → WS/02_unpacked/sboot.bin` (이미 sboot.bin 이면 복사).
- 트랙 2: `bash <PLUGIN>/scripts/extract_boot_assets.sh <WS> <boot.img> [super] [dtb]` → `WS/fw/`.

## Step 4 — 실행 사본 WSL + 자산 검증

- `WSDIR=$HOME/rehost/<id>` 로 실행 입력 복사. 문서·기록·07_logs 는 `WS`(Windows).
  `journal.sh <WS> decision "실행 사본" "WSL ($WSDIR)" "/mnt/c I/O 느림 회피"`.
- 검증(실제 명령): 트랙 1 md5·크기, **4 MB 미만 = carve 의심 하드 블로커**. 트랙 2 Image md5·크기,
  DTB 매직 `0xd00dfeed`, super EROFS, **K3 인데 `.ko` 없음 = 하드 블로커**.

## Step 5 — INPUT.md + PROGRESS.md + .active

`WS/INPUT.md` (자산=WSL 경로, workdir=WS 의 `/mnt/c/...`):

```markdown
| 슬롯 | 값 |
|---|---|
| workspace_id | <id> |
| track | <프롬프트/인자 결과 1|2> |
| autonomous | true |
| model | <도출/입력> |
| build | <도출 또는 미확정> |
| soc | 미확정 |
| target | <프롬프트 결과> |
| bl3_path 또는 kernel_path/dtb_path/initrd_path/super_path/storage_driver_ko | <WSL 사본> |
| md5 | <자동> |
| file_size | <자동> |
| workdir | </mnt/c/.../rehost_workspaces/<id>> |
| wsl_workspace | ~/rehost/<id> |
| has_el3_guess | false |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |
```

`WS/PROGRESS.md`(0회차) + `WORKROOT/.active` 에 `<id>` 기록.
`journal.sh <WS> session-end "/rehost-setup" "INPUT.md 생성, track <1|2>, active=<id>"`.

## Step 6 — 완료 안내 (★ 선택한 트랙의 실행 명령 하나만)

```
== 세팅 완료: 워크스페이스 <id> (active) ==
| 트랙 / 등급 | <1 sboot-shell | 2 kernel-storage> / <target> |
| 모델        | <model> |
| 자산(WSL)   | <경로> (<size>, md5 <md5>) |
| 의존성      | OK / 백그라운드 설치 중 |

▶ 다음 — 아래 하나를 실행하세요:
   <트랙 1 이면>  /rehost-sboot          (S-Boot 셸까지 자율 진행)
   <트랙 2 이면>  /rehost-kernel         (커널 → UFS 컨트롤러까지 자율 진행)

  · 다른 펌웨어: _inbox/ 에 넣고 /rehost-setup <다른이름>  (새 워크스페이스, 기존 안 덮어씀)
  · 워크스페이스 목록/상태: /rehost-status
```

★ 선택한 트랙에 **해당하는 명령 하나만** 굵게 안내(다른 트랙 명령은 흐리게/생략).

---

## 정직성

- **덮어쓰기 금지**: 같은 이름 워크스페이스 있으면 절대 덮어쓰지 말 것(기존 펌웨어 보호).
- 트랙 선택은 사용자 프롬프트(또는 인자). 언팩·md5·크기는 실제 명령. carve/필수 결손/K3 `.ko`
  부재 = 하드 블로커.
- 의존성은 1회성 — 두 번째 펌웨어부터 재설치 금지(스킵).
