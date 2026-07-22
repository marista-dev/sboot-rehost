---
name: rehost-setup
description: 새 펌웨어 리호스팅 세팅. 사용자는 rehost-setup 뒤에 워크스페이스 이름만 적으면 된다(예 /sboot-rehost:rehost-setup a136u). 플러그인이 rehost_workspaces/_inbox/ 의 펌웨어를 자동 인식·언팩하고, SoC 계열(Exynos/MediaTek/기타)과 부트로더 종류를 사실로 판별한 뒤 독립 워크스페이스를 만들고, 마지막에 트랙(1 부트로더 / 2 커널)·등급을 프롬프트로 물어 INPUT.md 를 작성한다.
disable-model-invocation: true
---

당신은 **새 펌웨어 세팅** 오케스트레이터. 사용자는 **`/sboot-rehost:rehost-setup <이름>`** 만 치면 된다.
플러그인이 알아서: `_inbox/` 펌웨어 인식 → **SoC 계열·부트로더 판별** → 격리 워크스페이스 →
**트랙 프롬프트** → INPUT.md.

- **인자**: `<이름>` (워크스페이스 이름). 생략 시 펌웨어에서 `<model>_<build>` 도출.
  `fw=<경로>` 로 펌웨어 직접 지정 가능(선택).
- **트랙/등급은 세팅 끝에 프롬프트**로 고른다 (`track=`/`target=` 인자로 주면 생략).

---

## 폴더 규약

```
<cwd>/rehost_workspaces/     ← 작업 루트
├── _inbox/                  ← 펌웨어 zip/tar 드롭
├── .active                  ← 실행 명령의 기본 대상
└── <이름>/                  ← 이 세팅이 만드는 격리 워크스페이스
```

## Step 0 — 작업 루트 확인 + 펌웨어 인식

1. `WORKROOT = <cwd>/rehost_workspaces`. 없으면 `/sboot-rehost:rehost-init` 안내(자율 시 자동 생성).
2. **의존성**: init 에서 설치됨. 검사만 하고 진행 중이면 자동 대기.
3. **펌웨어 인식**: `fw=` 우선, 없으면 `_inbox/` 스캔. 없으면 하드 블로커로 종료.
   여러 개면 가장 최근(mtime) + 어느 것을 썼는지 보고.

## Step 1 — 워크스페이스 이름

- `id` = 인자 `<이름>`. 생략 시 펌웨어에서 도출.
- `WS = WORKROOT/<id>`. **이미 있으면 절대 덮어쓰지 말 것** — 안내 후 종료(하드 블로커).
- 새 id 면 폴더 생성: `01_firmware 02_unpacked 03_bootloader 04_static-analysis 06_machine 07_logs 08_docs fw`.
- `bash <PLUGIN>/scripts/journal.sh <WS> session-start "/sboot-rehost:rehost-setup" "새 워크스페이스 <id>"`.

## ★ Step 2 — SoC 계열·부트로더 판별 (사실로)

**추측하지 말고 파일과 매직으로 판별한다.** 결과는 탐색 힌트(`profiles/`)를 고르는 데 쓰이며,
값 자체는 이후 static-analyzer 가 대상에서 도출한다.

| 관찰 | 판정 |
|---|---|
| `sboot.bin`(또는 `BL_*.tar` 안) + `S-BOOT`/`Following commands` ASCII | `soc_family: exynos`, 부트로더 `S-Boot` |
| `lk.bin` · `lk-verified.img` · MTK 헤더 매직 `0x58881688` · `preloader_*` | `soc_family: mediatek`, 부트로더 `LK` |
| `aboot`/`emmc_appsboot.mbn` | `soc_family: qualcomm`, 부트로더 `aboot` |
| DTB `compatible` 문자열 | `samsung,exynos*` → exynos · `mediatek,mt*` → mediatek |
| 위 어디에도 안 맞음 | `soc_family: generic` (프로필 `generic.yaml`) |

실제 명령 예:
```bash
strings <bootloader.bin> | grep -m1 -E 'S-BOOT|Little Kernel|LK build'
xxd -l 8 <lk-verified.img>            # MTK 헤더 매직 확인
fdtdump <dtb> | grep -m1 compatible
```

### 부트로더 아키텍처(`arch`)
- AArch64 커널 헤더/`adrp` 패턴 → `arm64` (Exynos S-Boot)
- ARM/Thumb 벡터(`b reset`), 64-bit 포인터 스캔 0히트 → **`arm32`** (MediaTek LK)

### 인터랙티브 표면(`bl_surface`) — **힌트만**
setup 은 후보만 적고 **확정하지 않는다.** static-analyzer 가 UART 수신 경로 유무와
USB dispatcher 를 도출해 확정한다.

| 힌트 | 근거 |
|---|---|
| `shell` | UART 콘솔 프롬프트 문자열(`S-BOOT #` 등) 존재 |
| `fastboot` | `fastboot`/`getvar:` 문자열 존재, UART 프롬프트 없음 |
| `미확정` | 판단 불가 — static-analyzer 가 결정 |

`journal.sh <WS> decision "SoC 계열" "<판정>" "<근거: 파일·매직·문자열>"` 로 기록.

## Step 3 — 트랙·등급 선택 (★ 프롬프트)

`track=`/`target=` 인자가 없으면 `AskUserQuestion`:

- **Q1 트랙** (펌웨어에서 추정한 것을 첫 옵션으로):
  - "**트랙 1 — 부트로더** (`/sboot-rehost:rehost-bootloader`) — `<판별한 부트로더>` 의 인터랙티브 표면 도달"
  - "**트랙 2 — 커널** (`/sboot-rehost:rehost-kernel`) — 커널 + 진짜 스토리지 컨트롤러"
- **Q2 등급**: 트랙 1 → A/B/C, 트랙 2 → K1/K2/K3.
- `model` 이 안 나오면 함께 묻기.

## Step 4 — 언팩 (선택 트랙 기준, WSL)

- **트랙 1**: 부트로더 이미지를 `WS/03_bootloader/` 로.
  - Exynos: `tar xf BL_*.tar.md5 sboot.bin.lz4` → `lz4 -d` → `sboot.bin`
  - MediaTek: `lk-verified.img` 페이로드(파일 오프셋 0x200~) → `lk.bin`
- **트랙 2**: `bash <PLUGIN>/scripts/extract_boot_assets.sh <WS> <boot.img> [super] [dtb]` → `WS/fw/`.

## Step 5 — 실행 사본 + 자산 검증

- `WSDIR=$HOME/rehost/<id>` 로 실행 입력 복사 (문서·07_logs 는 Windows `WS`).
- 검증(실제 명령): md5·크기, 트랙 2 는 DTB 매직 `0xd00dfeed`.
- **트랙 2 토폴로지**: `super.img` 존재 여부 → `has_super`.
  분리형 `system`/`vendor` raw 면 `has_super: false` (캡스톤 없음).
- **`.ko` 부재는 하드 블로커가 아니다.** 커널 빌트인(`=y`)이면 `.ko` 는 설계상 없다
  (K3\*). 판정은 static-analyzer 가 커널 이미지 심볼로 한다 — 여기서는 경로만 적는다.

## Step 6 — INPUT.md + PROGRESS.md + .active

```markdown
| 슬롯 | 값 |
|---|---|
| workspace_id | <id> |
| track | <1|2> |
| autonomous | true |
| model | <도출/입력> |
| build | <도출 또는 미확정> |
| soc | <도출 또는 미확정> |
| soc_family | <exynos | mediatek | qualcomm | generic> |
| bootloader | <S-Boot | LK | aboot | 미확정>          (트랙 1) |
| arch | <arm64 | arm32>                              (트랙 1) |
| bl_surface | <shell | fastboot | 미확정>             (트랙 1, 힌트) |
| bootloader_path | <WSL 사본>                         (트랙 1) |
| kernel_path / dtb_path / initrd_path / super_path / storage_driver_ko | <WSL 사본> (트랙 2) |
| has_super | <true | false>                          (트랙 2) |
| target | <A/B/C 또는 K1/K2/K3> |
| md5 / file_size | <자동> |
| workdir | </mnt/c/.../rehost_workspaces/<id>> |
| wsl_workspace | ~/rehost/<id> |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |
```

`WS/PROGRESS.md`(0회차) + `WORKROOT/.active` 에 `<id>`.
`journal.sh <WS> session-end "/sboot-rehost:rehost-setup" "INPUT.md 생성, track <1|2>, <soc_family>, active=<id>"`.

## Step 7 — 완료 안내

```
== 세팅 완료: 워크스페이스 <id> (active) ==
| 트랙 / 등급  | <1 부트로더 | 2 커널> / <target> |
| SoC 계열     | <exynos | mediatek | ...>  (프로필 profiles/<계열>.yaml) |
| 부트로더     | <S-Boot | LK | ...> (<arm64|arm32>)         ← 트랙 1 일 때만
| 표면(힌트)   | <shell | fastboot | 미확정 — 분석이 확정>     ← 트랙 1 일 때만
| 모델         | <model> |
| 자산(WSL)    | <경로> (<size>, md5 <md5>) |

▶ 다음 — 아래 하나를 실행하세요:
   <트랙 1 이면>  /sboot-rehost:rehost-bootloader     (부트로더 표면 도달까지 자율)
   <트랙 2 이면>  /sboot-rehost:rehost-kernel         (커널 → 스토리지 컨트롤러까지 자율)

  · 다른 펌웨어: _inbox/ 에 넣고 /sboot-rehost:rehost-setup <다른이름>
  · 상태 확인:   /sboot-rehost:rehost-status
```

선택한 트랙의 **명령 하나만** 굵게 안내.

---

## 정직성

- **덮어쓰기 금지** — 같은 이름 워크스페이스가 있으면 종료.
- SoC 계열·부트로더·아키텍처는 **파일·매직·문자열로 판별**한다. 모델명으로 넘겨짚지 않는다.
- **표면은 힌트일 뿐** — 확정은 static-analyzer 가 수신 경로 유무를 도출해서 한다.
- `.ko` 부재를 하드 블로커로 취급하지 않는다 (빌트인일 수 있음).
- 의존성은 1회성 — 두 번째 펌웨어부터 스킵.
