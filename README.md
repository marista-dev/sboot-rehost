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
# ⑤ 설치 확인 — 아래 5개 명령이 보이면 완료
/plugin
```

> **대안 설치**
> - git clone: `git clone https://github.com/marista-dev/sboot-rehost.git` 후 ③④ 그대로
> - 마켓플레이스(원격): `/plugin marketplace add marista-dev/sboot-rehost` 후 ④

---

## 2. 명령어 (역할 항목화)

| 명령 | 단계 | 역할 | 산출물 |
|---|---|---|---|
| **`/rehost-init`** | 준비 1 | 표준 폴더를 **Windows 현재 폴더(cwd)** 에 생성 + 의존성 백그라운드 설치 + 펌웨어 확보 안내 | 폴더 트리, 의존성 |
| **`/rehost-setup`** | 준비 2 | `01_firmware/` 의 펌웨어 언팩 + **실행 사본을 WSL 로 이동** + 의존성 확인 → `INPUT.md` 작성 | INPUT.md, 자산 |
| **`/rehost-sboot`** | 실행 (트랙 1) | S-Boot BL3 를 QEMU 로 실행해 진짜 셸 + `help` 도달 | machine.c, 셸 증거 |
| **`/rehost-kernel`** | 실행 (트랙 2) | 커널 직부팅 + 진짜 벤더 UFS 컨트롤러로 rootfs·Android 도달 | machine_kernel.c, 커널 증거 |
| `/rehost-status` | 조회 (옵션) | 진행 상태(회차·검증·트랙) 한 화면 요약 | — |

- **한 명령 = 한 트랙.** INPUT.md 의 `track` 슬롯에 맞는 실행 명령 하나만 쓴다(어긋나면 올바른 명령 안내).
- **자율 실행이 기본**(`autonomous: true`): 실행 명령은 하드 블로커 전까지 **멈추지 않는다**. 단계마다 확인받으려면 `interactive` 인자.
- **등급**: 트랙 1 = A(help)/B(명령핸들러)/C(autoboot). 트랙 2 = K1(유저스페이스)/K2(rootfs)/K3(진짜 UFS 컨트롤러).

---

## 3. 실행 순서

```text
① /rehost-init                          # 폴더 생성(Windows cwd) + 의존성 설치
② (펌웨어를 <cwd>/01_firmware/ 에 드롭)   # 탐색기로 넣기
③ /rehost-setup track=1 model=SM-XXXX target=A     # 언팩 + WSL 이동 + INPUT.md
④ /rehost-sboot                         # 트랙 1 실행  (트랙 2 는 /rehost-kernel)
⑤ /rehost-status                        # (옵션) 진행 확인
```
트랙 2 예: `③ /rehost-setup track=2 model=SM-XXXX target=K3` → `④ /rehost-kernel`.

---

## 4. 각 명령이 거치는 과정

### `/rehost-init` — 준비 1 (펌웨어 불요)
1. 작업 디렉터리 = **Windows cwd** 확정 (플러그인 설치 폴더 안 아님, WSL 아님).
2. JOURNAL 세션 시작 기록.
3. 의존성 검사(`qemu-system-aarch64`/`capstone`/`dtc`). 없으면 `setup_env.sh` **백그라운드** 실행(apt+pip+QEMU 10.2.2 빌드, ~18분).
4. 표준 폴더 생성: `01_firmware 02_unpacked 03_bl3 04_static-analysis 06_machine 07_logs 08_docs` (+ 트랙 2 `fw/`).
5. 펌웨어 확보 안내 출력(어디서 받아 `01_firmware/` 에 넣을지).
6. 완료 보고 → 다음: 펌웨어 드롭 후 `/rehost-setup`. **INPUT.md 는 만들지 않는다.**

### `/rehost-setup track= model= target=` — 준비 2 (펌웨어 반입)
1. 선행 검사: init 폴더 존재 + `01_firmware/` 에 펌웨어 존재. 세션 시작 기록.
2. 펌웨어 언팩(WSL): 트랙 1 = `tar → lz4 → sboot.bin`(→ `02_unpacked/`), 트랙 2 = `extract_boot_assets.sh` → `fw/`(Image/dtb/initrd/super).
3. **실행 사본을 WSL ext4(`~/rehost/<model>/`)로 이동** — `/mnt/c` QEMU I/O 느림 회피.
4. 의존성 완료 확인(init 백그라운드 빌드가 끝났는지, 진행 중이면 자동 대기).
5. 자산 검증(실제 md5·크기): 트랙 1 4MB 미만 = carve 의심 **하드 블로커**, 트랙 2 DTB 매직·super EROFS, K3 는 벤더 `.ko` 필수.
6. `INPUT.md`(자산=WSL 경로, workdir=Windows) + `PROGRESS.md` 작성. 세션 종료 기록.

### `/rehost-sboot` — 트랙 1 실행 (`pipeline.js`)
1. 선행 검사: `INPUT.md(track:1)`. 세션 시작 기록.
2. 워크플로우 자동 진행(자율, 안 멈춤):
   - **Static** — `bl3-analyzer` 가 8값 도출(carve/entry/linker/load/Δ/cmd테이블/list head/shell 함수) + `stub-locator` 4개 병렬 도출 → `STATIC.md`·`STUBS.md`.
   - **Machine** — `machine.c.tmpl` 슬롯 채워 `06_machine/machine.c` 작성 → QEMU 트리 통합 + `ninja`.
   - **Iterate** — 회차 루프(한 회차 한 변경): `run_qemu.sh` 실행 → `fault-fixer` 정지점 분류 → 패치 → 재빌드 → JOURNAL 시행착오 기록 → `critic`. 셸 도달까지.
   - **Verify** — `reality-verifier` 5/5(아래) 검증 → `VERIFICATION.md`.
   - **Package** — `10_reproduce/` 재현 키트.
3. 세션 종료 기록. 도달: 진짜 `S-BOOT #` 셸 + `help`.

### `/rehost-kernel` — 트랙 2 실행 (`pipeline_kernel.js`)
1. 선행 검사: `INPUT.md(track:2)`. 세션 시작 기록.
2. 워크플로우 자동 진행:
   - **Static** — `kernel-boot-analyzer` 가 DTB 로 머신 골격 + 커널 보안게이트 사이트 도출 → `KERNEL_STATIC.md`.
   - **Machine** — `machine_kernel.c` + `patch_qemu_core.py`(SMC 코어 3패치) + `patch_kernel.py`(게이트) + `ninja`.
   - **K1** — `boot-fault-fixer` 회차 → 유저스페이스(`Run /init`).
   - **K2** — rootfs 마운트(제네릭+DT fstab 또는 dm-linear) → `erofs: (device dm-N): mounted`.
   - **K3** — `storage-modeler` 관찰 루프 → 진짜 벤더 `.ko` 가 `sda1..` 파티션 구동.
   - **Verify/Package** — `reality-verifier` 5/5(커널 메시지 증거) → `10_reproduce/`.
3. 도달: 목표 등급(K1/K2/K3)까지.

### `/rehost-status` — 조회
`INPUT/STATIC/KERNEL_STATIC/PROGRESS/VERIFICATION/JOURNAL` 을 읽어 트랙·회차·미확정·5/5 통과 항목을 한 화면 표로 요약.

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
- 자동 설치(`/rehost-init` → `setup_env.sh`): apt 빌드 툴 + `flex bison device-tree-compiler`, pip `meson capstone lz4 keystone-engine`, **QEMU 10.2.2(aarch64)**. 트랙 2 K3 는 aarch64 크로스툴체인 추가.

---

## 8. 알려진 한계

- **트랙 1**: 등급 A 안정. BL3 는 full 본체(4 MB 이상). B/C 는 UFS/PMIC~풀 모델 필요.
- **트랙 2**: K1/K2 안정, K3 은 벤더 `.ko` 필요. 공통 프론티어 = `/data` 암호화 → vold → Keymint → **TEE(TEEGRIS)**(범위 밖, 미달로 정직 기록).
- **Samsung Exynos** 가정. 다른 SoC 는 DTB 도출로 대응하되 UART·HCI 레지스터는 대상 표준으로 확인.


