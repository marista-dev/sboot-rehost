---
name: rehost-setup
description: 새 펌웨어 리호스팅 세팅. 사용자는 rehost-setup 뒤에 워크스페이스 이름만 적으면 된다(예 /sboot-rehost:rehost-setup a136u). 플러그인이 rehost_workspaces/_inbox/ 의 펌웨어를 자동 인식·언팩하고, SoC 계열과 부트로더 종류를 사실로 판별한 뒤 독립 워크스페이스를 만들고, 마지막에 등급(F1/F2/F3)을 프롬프트로 물어 INPUT.md 를 작성한다. 실행은 /sboot-rehost:rehost-full 하나다.
disable-model-invocation: true
---

당신은 **새 펌웨어 세팅** 오케스트레이터. 사용자는 **`/sboot-rehost:rehost-setup <이름>`** 만 치면 된다.
플러그인이 알아서: `_inbox/` 펌웨어 인식 → **SoC 계열·부트로더 판별** → 격리 워크스페이스 →
**등급 프롬프트** → INPUT.md.

- **인자**: `<이름>` (워크스페이스 이름). 생략 시 펌웨어에서 `<model>_<build>` 도출.
  `fw=<경로>` 로 펌웨어 직접 지정 가능(선택).
- **등급은 세팅 끝에 프롬프트**로 고른다 (`target=` 인자로 주면 생략).
- 트랙 개념은 없다. 실행 명령은 **`/sboot-rehost:rehost-full` 하나**이며, 등급이 어디까지
  갈지를 정한다.

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

## Step 3 — 등급 선택 (프롬프트)

`target=` 인자가 없으면 `AskUserQuestion` 으로 **등급 하나만** 묻는다. 트랙은 묻지 않는다 —
하나의 연속 체인이고 명령도 하나다.

등급은 **체인의 어디까지 갈지**다. 판별한 표면·계열에 맞춰 설명을 바꿔서 제시한다.

| 등급 | 도달 지점 | 필요한 것 |
|---|---|---|
| **F1** | 도출된 스테이지 전부 실행 + 부트로더의 인터랙티브 표면 | 부트로더 컨테이너만 |
| **F2** (권장) | F1 + 매체 기동 → 파티션 열거 → 서명 검증 → 커널 진입 | + 커널 자산 |
| **F3** | F2 + 유저스페이스 → rootfs 마운트 | + 커널 자산 |

- **F1 은 커널 자산 없이 도달한다.** 부팅 매체 모델도 필요 없다 — 첫 스테이지는 이전 단계가
  남긴 함수 포인터로 블록을 읽는다.
- **커널 자산이 없으면 F2 이상을 고르지 않는다.** 고르면 파이프라인이 `BLOCKED_ASSET` 으로
  정지한다. 자산 유무는 Step 4 에서 사실로 확인한 뒤 선택지에 반영한다.
- 표면이 `fastboot` 인 펌웨어도 등급 정의는 같다. 첫 칸의 이름만 그 표면이 된다.

## Step 4 — 언팩 (WSL)

**부트로더 컨테이너는 항상 푼다.** 체인의 출발점이기 때문이다.

- Exynos: `tar xf BL_*.tar.md5 sboot.bin.lz4` → `lz4 -d` → `sboot.bin` → `WS/03_bootloader/`
- MediaTek: `lk-verified.img` 페이로드(파일 오프셋 0x200~) → `lk.bin`
- 같은 tar 안의 나머지 멤버(`keystorage`·`vbmeta`·`param` 등)도 `WS/02_unpacked/` 로 푼다.
  부트로더가 매체에서 이름으로 찾는 파티션의 원본이 된다.

**커널 자산은 있으면 푼다** (F2 이상에 필요):
`bash <PLUGIN>/scripts/extract_boot_assets.sh <WS> <boot.img> [super] [dtb]` → `WS/fw/`

없으면 그 사실을 기록하고 **F1 로 진행할 수 있음을 안내**한다. 없는 것을 있는 것처럼
적지 않는다.

## Step 5 — 실행 사본 + 자산 검증

- `WSDIR=$HOME/rehost/<id>` 로 실행 입력 복사 (문서·07_logs 는 Windows `WS`).
- 검증(실제 명령): md5·크기, 커널 자산이 있으면 DTB 매직 `0xd00dfeed`.
- **파티션 토폴로지**: `super.img` 존재 여부 → `has_super`.
  분리형 `system`/`vendor` raw 면 `has_super: false` (최종 칸 없음).
- **`.ko` 부재는 하드 블로커가 아니다.** 커널 빌트인(`=y`)이면 `.ko` 는 설계상 없다
  판정은 static-analyzer 가 커널 이미지 심볼로 한다 — 여기서는 경로만 적는다.

## Step 6 — INPUT.md + PROGRESS.md + .active

```markdown
| 슬롯 | 값 |
|---|---|
| workspace_id | <id> |
| autonomous | true |
| model | <도출/입력> |
| build | <도출 또는 미확정> |
| soc | <도출 또는 미확정> |
| soc_family | <exynos | mediatek | qualcomm | generic> |
| bootloader | <S-Boot | LK | aboot | 미확정> |
| arch | <arm64 | arm32> |
| bl_surface | <shell | fastboot | 미확정>  (힌트 — 분석이 확정) |
| bootloader_path | <WSL 사본, 컨테이너 통째로> |
| kernel_path / dtb_path / super_path | <WSL 사본, 있을 때만> |
| has_super | <true | false> |
| target | <F1 | F2 | F3> |
| md5 / file_size | <자동> |
| workdir | </mnt/c/.../rehost_workspaces/<id>> |
| wsl_workspace | ~/rehost/<id> |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |
```

`track` 슬롯은 없다. 있으면 파이프라인이 무시하므로 남겨 두면 혼란만 만든다.

`WS/PROGRESS.md`(0회차) + `WORKROOT/.active` 에 `<id>`.
`journal.sh <WS> session-end "/sboot-rehost:rehost-setup" "INPUT.md 생성, <target>, <soc_family>, active=<id>"`.

## Step 7 — 완료 안내

```
== 세팅 완료: 워크스페이스 <id> (active) ==
| 등급         | <F1 | F2 | F3> |
| SoC 계열     | <exynos | mediatek | ...>  (프로필 profiles/<계열>.yaml) |
| 부트로더     | <S-Boot | LK | ...> (<arm64|arm32>) |
| 표면(힌트)   | <shell | fastboot | 미확정 — 분석이 확정> |
| 모델         | <model> |
| 컨테이너     | <경로> (<size>, md5 <md5>) |
| 커널 자산    | <있음: 경로 | 없음 — F1 까지 진행 가능> |

▶ 다음:
   /sboot-rehost:rehost-full

  · 다른 펌웨어: _inbox/ 에 넣고 /sboot-rehost:rehost-setup <다른이름>
  · 상태 확인:   /sboot-rehost:rehost-status
```

**실행 명령은 하나다.** 등급에 따라 다른 명령을 안내하지 않는다.

## 정직성

- **덮어쓰기 금지** — 같은 이름 워크스페이스가 있으면 종료.
- SoC 계열·부트로더·아키텍처는 **파일·매직·문자열로 판별**한다. 모델명으로 넘겨짚지 않는다.
- **표면은 힌트일 뿐** — 확정은 static-analyzer 가 수신 경로 유무를 도출해서 한다.
- `.ko` 부재를 하드 블로커로 취급하지 않는다 (빌트인일 수 있음).
- 의존성은 1회성 — 두 번째 펌웨어부터 스킵.
