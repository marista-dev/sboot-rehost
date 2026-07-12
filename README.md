# sboot-rehost

> Samsung 펌웨어를 QEMU 에서 **진짜로** 실행시키는 Claude Code 플러그인.
> 펌웨어를 넣으면 두 트랙 중 하나로 자동 리호스팅한다.
>
> - **트랙 1 (sboot-shell)** — 부트로더 BL3 → 진짜 `S-BOOT #` 셸 + `help`
> - **트랙 2 (kernel-storage)** — 커널 직부팅 → rootfs 마운트 → 진짜 벤더 UFS 컨트롤러 모델 → Android

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 1. 설치 — .zip 다운로드 후 실행

무거운 실행(빌드·QEMU)은 **WSL2(Ubuntu)** 에서 돈다. Windows 라면 WSL2 안에서 진행 권장.

```bash
# ① GitHub → Code ▸ Download ZIP 로 받은 파일을 WSL 로 옮긴 뒤 압축 해제
unzip sboot-rehost-main.zip
```
```bash
# ② Claude Code 실행
claude
```
```text
# ③ 압축 푼 폴더를 로컬 마켓플레이스로 등록 (marketplace.json 이 있는 폴더)
/plugin marketplace add ./sboot-rehost-main
```
```text
# ④ 플러그인 설치
/plugin install sboot-rehost@sboot-rehost-marketplace
```
```text
# ⑤ 설치 확인 — /rehost-setup · /rehost-sboot · /rehost-kernel · /rehost-status · /rehost-export 가 보이면 완료
/plugin
```

설치 후 세션이 시작되면 작업 폴더에 **`rehost_workspaces/_inbox/`** 가 자동 생성됩니다(SessionStart 훅).
여기에 펌웨어를 넣고 `/rehost-setup` 을 실행하면 됩니다.

> **대안 설치**
> - git clone: `git clone https://github.com/marista-dev/sboot-rehost.git` 후 ③④ 그대로
> - 마켓플레이스(원격): `/plugin marketplace add marista-dev/sboot-rehost` 후 ④

---

## 2. 명령어 (역할 항목화)

| 명령 | 역할 | 산출물 |
|---|---|---|
| **`/rehost-setup <이름>`** | **새 펌웨어 세팅** — `_inbox/` 펌웨어 **자동 인식** + 격리 워크스페이스 `rehost_workspaces/<이름>/` 생성(덮어쓰기 금지) + 언팩·WSL 이동 → **끝에 "트랙?(1 sboot / 2 kernel)·등급" 프롬프트** → `INPUT.md` + `.active` | 워크스페이스, INPUT.md |
| **`/rehost-sboot`** | **트랙 1 실행** — S-Boot BL3 → 진짜 셸 + `help` | machine.c, 셸 증거 |
| **`/rehost-kernel`** | **트랙 2 실행** — 커널 + 진짜 벤더 UFS 컨트롤러 → rootfs·Android | machine_kernel.c, 커널 증거 |
| `/rehost-status` | **워크스페이스 목록** + 각 진행/검증 요약 | — |
| **`/rehost-export`** | **완료 후 "빌드 없이 실행" 키트** 조립(프리빌트 QEMU+펌웨어+machine+docs+evidence+run.sh) → `rehost_exports/<firmware>/track<N>/` (항상 gitignore) | 공유 키트 |

- **사용자는 `/rehost-setup <이름>` 만.** 펌웨어는 `_inbox/` 에서 자동 인식, **트랙(sboot/kernel)·등급은 세팅 끝에 프롬프트로 선택**(`track=`/`target=` 인자로 미리 주면 프롬프트 생략).
- **펌웨어당 워크스페이스 1개(격리).** 여러 펌웨어를 넣어도 서로 안 덮어씀. 실행 대상 = `.active`(가장 최근 setup) 또는 `workdir=<이름>`.
- **드롭 폴더 `rehost_workspaces/_inbox/` 는 설치 후 세션 시작 시 자동 생성**(SessionStart 훅).
- 실행 명령은 자율 — 하드 블로커 전까지 안 멈춤. 등급: 트랙 1 = A/B/C, 트랙 2 = K1/K2/K3(파티션+super 마운트까지).

---

## 3. 실행 순서

```text
① (펌웨어를 rehost_workspaces/_inbox/ 에 드롭)   # 인박스는 설치 후 자동 생성
② /rehost-setup a166b                            # 이름만! 펌웨어 자동 인식 → 격리 워크스페이스
                                                 #   → 끝에 "트랙?(1 sboot / 2 kernel)·등급" 프롬프트
③ 프롬프트에서 선택한 트랙 실행:  /rehost-sboot  또는  /rehost-kernel
④ /rehost-status                                 # (옵션) 워크스페이스 목록/진행
⑤ /rehost-export                                 # (완료 후) 빌드 없이 실행 가능한 공유 키트 생성
```
- 다른 펌웨어: `_inbox/` 에 드롭 후 `/rehost-setup <다른이름>` → **새 워크스페이스**(기존 안 덮어씀).
- 특정 워크스페이스 실행: `/rehost-sboot workdir=<이름>`.
- **한 펌웨어의 track1·track2 를 각각 완료 후 export 하면** `rehost_exports/<firmware>/track1/`·`track2/` 가 생긴다(항상 gitignore).

---

## 4. 각 명령이 거치는 과정

### `/rehost-setup <이름>` — 새 펌웨어 세팅 (펌웨어당 1회)
1. **작업 루트** `<cwd>/rehost_workspaces/`(+`_inbox/`) 확인. **의존성 1회성**: 없으면 `setup_env.sh` 백그라운드(~18분), 있으면 스킵.
2. **펌웨어 자동 인식**: `_inbox/` 스캔(또는 `fw=<경로>`). 파일명·메타에서 model/build 도출.
3. **워크스페이스** `rehost_workspaces/<이름>/` 생성(이름 생략 시 `<model>_<build>`). **이미 있으면 덮어쓰지 않고 중단**(기존 펌웨어 보호).
4. **트랙·등급 프롬프트**: `AskUserQuestion` 으로 "트랙 1(sboot) / 트랙 2(kernel)" + 등급(A/B/C 또는 K1/K2/K3)을 물음(펌웨어에서 추정한 트랙이 기본값). `track=`/`target=` 인자 주면 생략.
5. 언팩(선택 트랙 기준) → **실행 사본 WSL ext4(`~/rehost/<이름>/`)로 이동** → 자산 검증(4MB미만·`.ko`부재 등 하드 블로커).
6. `INPUT.md`(자산=WSL, workdir=워크스페이스) + `PROGRESS.md` + `.active` 갱신 → 완료 안내에서 **선택한 트랙의 실행 명령 하나**만 굵게 안내.

### `/rehost-sboot` — 트랙 1 실행 (`pipeline.js`)
1. 대상 워크스페이스 = `.active`(또는 `workdir=<id>`)의 `INPUT.md(track:1)`. 세션 시작 기록.
2. 워크플로우 자동 진행(자율, 안 멈춤):
   - **Static** — `bl3-analyzer` 가 8값 도출(carve/entry/linker/load/Δ/cmd테이블/list head/shell 함수) + `stub-locator` 4개 병렬 도출 → `STATIC.md`·`STUBS.md`.
   - **Machine** — `machine.c.tmpl` 슬롯 채워 `06_machine/machine.c` 작성 → QEMU 트리 통합 + `ninja`.
   - **Iterate** — 회차 루프(한 회차 한 변경): `run_qemu.sh` 실행 → `fault-fixer` 정지점 분류 → 패치 → 재빌드 → JOURNAL 시행착오 기록 → `critic`. 셸 도달까지.
   - **Verify** — `reality-verifier` 5/5(아래) 검증 → `VERIFICATION.md`.
   - **Package** — `10_reproduce/` 재현 키트.
3. 세션 종료 기록. 도달: 진짜 `S-BOOT #` 셸 + `help`.

### `/rehost-kernel` — 트랙 2 실행 (`pipeline_kernel.js`)
1. 대상 워크스페이스 = `.active`(또는 `workdir=<id>`)의 `INPUT.md(track:2)`. 세션 시작 기록.
2. 워크플로우 자동 진행:
   - **Static** — `kernel-boot-analyzer` 가 DTB 로 머신 골격 + 커널 보안게이트 사이트 도출 → `KERNEL_STATIC.md`.
   - **Machine** — `machine_kernel.c` + `patch_qemu_core.py`(SMC 코어 3패치) + `patch_kernel.py`(게이트) + `ninja`.
   - **K1** — `boot-fault-fixer` 회차 → 유저스페이스(`Run /init`).
   - **K2** — rootfs 마운트(제네릭+DT fstab 또는 dm-linear) → `erofs: (device dm-N): mounted`.
   - **K3** — `storage-modeler` 관찰 루프 → 진짜 벤더 `.ko` 가 `sda1..` 파티션 구동.
   - **Verify/Package** — `reality-verifier` 5/5(커널 메시지 증거) → `10_reproduce/`.
3. 도달: 목표 등급(K1/K2/K3)까지.

### `/rehost-status` — 조회
`rehost_workspaces/` 의 **모든 워크스페이스**를 나열(★=active) + 각 트랙/등급/진행(트랙 2 는 K3 최고 마일스톤)/5/5 요약. `workdir=<id>` 주면 그 워크스페이스만 상세.

### `/rehost-export` — 완료 후 공유 키트
1. **완료 확인**(미완이면 거부): 트랙 1 = `VERIFICATION.md` 5/5 REAL, 트랙 2 = 목표 등급 도달(K3=진짜 파티션 `sda1..`).
2. `make_export.sh` 로 **`rehost_exports/<model>_<build>/track<N>/`** 조립: `bin/qemu-system-aarch64`(프리빌트, 빌드 불필요) + `firmware/`(sboot.bin 또는 Image/dtb/initrd/디스크) + `machine/` + `scripts/`(patch·build) + turnkey `run.sh`·`setup.sh`.
3. `docs/`(무엇을 만들었나·부팅체인·시행착오·타임라인·우회·검증) + `evidence/`(console·VERIFICATION·JOURNAL) 를 실제 기록으로 생성.
4. **exports 전체 gitignore**(펌웨어 저작권·대용량) + 생성 위치를 사용자에게 안내.
   받는 사람: `cd <경로> && bash run.sh` (빌드 없이 실행).

---

## 5. 검증 5/5 (정직성)

실행 명령이 "도달"을 보고하기 전 자동 통과해야 하는 항목:

1. **PC 트레이스** — shell/exec_command(트랙 1) 또는 `Run /init`(트랙 2) PC 가 트레이스에 등장.
2. **증거 byte-match** — 콘솔의 모든 토큰이 진짜 바이너리 안에 존재(트랙 2 는 **커널이 찍은 줄**만 인정: `erofs dm-N`/`sda1`/`Power mode`).
3. **소스 negative** — 머신 C 소스에 그 출력 문자열 0 개.
4. **단일 경로 / 진짜 구동** — UART write 1 자리(트랙 1) / 벤더 드라이버 진짜 구동(트랙 2 K3).
5. **우회 목록** — 모든 우회를 `[대상/이유/방법/부작용]` 으로 기재.

**5/5 = REAL. 4/5 이하 = FORCED**(성공 표시 금지).

---

## 6. 기록 위치 (로컬 vs WSL)

- **로컬 Windows cwd** — 사용자가 보는 기록·해결과정: `JOURNAL.md`(세션·시행착오 원인/분석/해결 + 시각), `PROGRESS.md`, `VERIFICATION.md`, `INPUT.md`, `STATIC.md`, `07_logs/`(콘솔 + `*.summary.txt`).
- **WSL ext4** — 대용량 쓰기: 펌웨어 실행 사본(`~/rehost/<model>/`), `-d` 전체 트레이스(`~/rehost/_traces/`).

---

## 7. 필요 환경

- **OS**: WSL2(Ubuntu 22.04+) 또는 Ubuntu 22.04+ / **디스크** ~3 GB / **인터넷**(QEMU 최초 1회)
- 자동 설치(`/rehost-setup` 첫 실행 → `setup_env.sh`): apt 빌드 툴 + `flex bison device-tree-compiler`, pip `meson capstone lz4 keystone-engine`, **QEMU 10.2.2(aarch64)**. 트랙 2 K3 는 aarch64 크로스툴체인 추가.

---

## 8. 알려진 한계

- **트랙 1**: 등급 A 안정. BL3 는 full 본체(4 MB 이상). B/C 는 UFS/PMIC~풀 모델 필요.
- **트랙 2**: K1/K2 안정, K3 은 벤더 `.ko` 필요. 공통 프론티어 = `/data` 암호화 → vold → Keymint → **TEE(TEEGRIS)**(범위 밖, 미달로 정직 기록).
- **Samsung Exynos** 가정. 다른 SoC 는 DTB 도출로 대응하되 UART·HCI 레지스터는 대상 표준으로 확인.


