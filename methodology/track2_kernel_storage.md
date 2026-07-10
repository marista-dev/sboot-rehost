# 트랙 2 방법론 — 커널 직부팅 + 진짜 벤더 스토리지 컨트롤러

> 이 문서는 "답"을 주지 않는다. 새 펌웨어를 받아 **진짜 커널·진짜 벤더 드라이버**를
> QEMU 에서 실행시키는 **방법론**만 적는다. 주소·오프셋·패치 목록은 도출한다 —
> 못 하면 도달도 못 한다. S921N/Exynos2400 값은 전부 "예시" 로만 표기한다.
>
> 트랙 1 (S-Boot 셸) 은 [instruction.md](instruction.md). 정직성 규칙은 두 트랙 공통.

---

## 0. 트랙 2 가 하는 일

부팅 체인의 **커널 진입점부터** 진짜 바이너리를 실행한다. 이전 스테이지
(BootROM/BL1/BL2/부트로더/EL3 모니터) 는 실행하지 않고 QEMU 가 커널을 직접 적재
(Path A). 커널·벤더 드라이버는 가짜화하지 않는다 — 막히는 정지점만 정직히 모델하거나
우회한다. Jetset 식 타깃 리호스팅.

```
BootROM ─ BL1/2 ─ 부트로더 ─ EL3mon ─ EL2 hyp ─ [커널 EL1] ─ init ─ 2단계 ─ …
 (스킵)   (스킵)   (스킵)     (모델)   (커널내장)   ★여기부터 진짜 실행★
```

목표 등급 (K):

| 등급 | 도달 지점 | 스토리지 |
|---|---|---|
| **K1** | 커널 → 유저스페이스 (`Run /init`) | 제네릭 (QEMU 내장) |
| **K2** | 진짜 rootfs 마운트 (system/vendor) | 제네릭 + DT fstab **또는** dm-linear |
| **K3** | 진짜 벤더 스토리지 HCI 모델 → **진짜 벤더 드라이버**가 블록디바이스+파티션 구동 | 실모델 (관찰 루프) |

K3 = 트랙 2 의 본령 ("컨트롤러 구현하면서 리호스팅"). K1→K2→K3 순으로 확장.

---

## 1. 정직성 (두 트랙 공통 + 트랙 2 추가)

[CLAUDE.md](../CLAUDE.md) 의 정직성 7 규칙 그대로. 트랙 2 추가:

- **커널·벤더 드라이버는 진짜 실행.** 가짜 rootfs·가짜 드라이버로 "부팅한 것처럼" 금지.
- **모델은 환경 (페리페럴/SMC/HVC/스토리지 HCI) 만.** 진짜 타깃 코드 대체 금지.
- **성공은 커널 자신의 메시지로 판정.** `erofs: (device dm-0): mounted`, `sda: sda1 …`,
  `Power mode change` 같은 **커널이 찍은 줄**이 객관 증거. 머신이 찍은 문자열은 불인정.
- **`.ko` 우회도 우회.** 벤더 드라이버 패치는 `[대상/이유/방법/부작용]` 문서화.
- **관찰 루프에서 적응형 토글 금지.** "N 번 read 후 값 바꾸기" 절대 금지 (§1.1 그대로).

---

## 2. 부팅 자산 추출 (펌웨어 → 커널/DTB/initrd/rootfs)

트랙 2 는 BL3 하나가 아니라 **여러 자산**이 필요. 전부 펌웨어에서 추출 (도출 아님, 표준 언팩).

| 자산 | 어디서 | 추출 |
|---|---|---|
| 커널 `Image` | `boot.img` (Android boot image) | `unpack_bootimg` 또는 헤더 파싱 → kernel 영역, 필요 시 gunzip |
| DTB | `boot.img` 의 dtb 영역 또는 `dtbo.img`/별도 파티션 | 매직 `0xd00dfeed` 검색 |
| 1 단계 램디스크 | `boot.img` 의 ramdisk 영역 | gzip cpio |
| rootfs (`super.img`) | `AP_*.tar` 의 `super.img.lz4` | lz4 → sparse 면 `simg2img` → liblp 로 논리파티션 (system/vendor…) 카브 (EROFS) |
| userdata/metadata | (없으면 생성) | ext4 빈 이미지 (평문) — /data 암호화는 프론티어 |

DTB 는 **머신 골격 도출의 1 차 자료**다 (§4). `fdtdump`/libfdt 로 다음을 읽는다:
- `chosen/bootargs` (cmdline: earlycon, `kvm-arm.mode=`, root 등)
- UART 노드 (`reg` = UART 베이스)
- interrupt-controller (GIC 노드: GICD/GICR 베이스, `#interrupt-cells`)
- 스토리지 노드 (`ufs`/`mmc` 등: `reg` = HCI 베이스, `interrupts` = SPI 번호) ← K3 의 시작

**금지**: 커널·DTB 를 다른 기기 것으로 섞기. 같은 빌드의 자산만.

---

## 3. Path A — 커널 직부팅

QEMU 의 `arm_load_kernel` (또는 `-kernel`) 로 `Image + dtb + initrd` 를 적재. 부트로더가
하던 일 (커널 압축해제·DTB 전달·EL 셋업) 을 QEMU/커널 자신이 한다.

첫 실행 = 거의 확실히 정지점. 그게 분석의 출발 (트랙 1 §5.3 과 동일 철학).

```bash
timeout 60 qemu-system-aarch64 -M <machine> -cpu <core> -smp <n> -m <size> \
  -kernel fw/Image.patched -dtb fw/<soc>.dtb -initrd fw/initramfs.cpio.gz \
  -append "<cmdline>" -serial mon:stdio -d unimp,guest_errors -D /tmp/run.log
```

---

## 4. 머신 골격 (K1 최소)

DTB 에서 도출한 값으로 최소 머신. `templates/machine_kernel.c.tmpl` 참조.

| 요소 | 도출 | 함정 |
|---|---|---|
| **CPU** | SoC 코어 (cortex-aXX), 코어 수 = DTB `cpus`. `has_el2=true` (커널 pKVM), `has_el3=false` 시작 | mp-affinity cluster.core 를 QOM 으로 설정 |
| **DRAM** | DTB `memory` 노드의 base/size | — |
| **GICv3** | DTB gic 노드의 GICD/GICR 베이스 | ★ **arch-timer PPI 는 풀 INTID (예: 30/27/26/29) 로 배선.** PPI 상대번호 쓰면 `gicv3_set_irq` assert |
| **UART** | DTB uart `reg`. TX→chardev, RX FIFO + **`qemu_chr_fe_accept_input`** | earlycon 이름 (예: exynos4210/pl011) 확인. accept_input 누락 = RX 한 번 차고 끊김 (instruction.md §8.2) |
| **catch-all MMIO** | `0 … DRAM_BASE` overlap(prio 낮게) fail-loud | 미모델 페리페럴 1 회 보고 → 다음 정지점 발견 |

첫 목표: `Run /init` (커널이 유저스페이스로). 그 전 정지점은 §5 로 처리.

---

## 5. K1 — 유저스페이스 도달 (커널 보안게이트 + EL3/SMC)

Path A 는 verified-boot/시큐어모니터가 부재 → 커널의 무결성·보안 검사가 실패한다.
정지점마다 분류·우회 (`[대상/이유/방법/부작용]`).

### 5.1 커널 보안게이트 우회 (`.text` 바이너리 패치)

`scripts/patch_kernel.py` = **사이트 테이블 구동 + pre-image 검증** 패처 (틀린 오프셋은
fail-loud). 각 사이트는 커널 심볼/문자열 xref 로 **도출**한다 (예시 오프셋 박제 금지).

| 게이트 | 증상 | 도출 | 우회 |
|---|---|---|---|
| FIPS-140 POST | 부팅 초기 panic (self-integrity) | `fips140`/`crypto` self-test 함수의 실패 분기 | 실패 `cbnz`→NOP |
| DEFEX/KNOX | rules 서명 mismatch panic | `defex_load_rules` 류 | mismatch 분기 → `b ret` |
| SELinux enforce | vold/init 조기 SIGABRT/denial | `sel_write_enforce` 의 `cset` | `mov w8,#0` (permissive) |
| verified-boot/AVB | vbmeta 검사 실패 | AVB verify 반환 검사 | 성공 반환 강제 |
| debug-kinfo early_module | 2 번째 벤더 모듈 로드 시 BUG (K3 전제) | `complete_formation` 의 single-slot BUG | 그 `cbnz`→NOP |

도출 절차: 콘솔 panic/oops 의 심볼 → `Image` 안 그 함수 → 실패 분기 명령 → 4B 패치.
반드시 pre-image (예상 워드) 를 검증하고 패치.

### 5.2 EL3/SMC — 시큐어 모니터 부재

커널은 PSCI (CPU on/off/suspend) 를 SMC 로 EL3 펌웨어에 요청한다. EL3 모니터 미실행 →
그 SMC 를 **보드에서 모델** (faithful) 하거나 QEMU PSCI 컨듀잇으로 처리.

- **faithful (권장)**: EL3 SMC 셤 = `smc_handler`. PSCI (`0x84xxxxxx`/`0xC4xxxxxx`)
  → `arm_handle_psci_call`, eFuse/칩ID read → 모델값, 그 외 SiP/벤더 → SMCCC SUCCESS.
- `psci_conduit=SMC` 로 셋업. **DISABLED 금지** (cpuidle 깨져 부팅 정체).
- **has_el3=false 인데 SMC 를 트랩하려면 QEMU 코어 3 패치 필요** (§5.3).

### 5.3 QEMU 코어 3 패치 (SMC-with-has_el3=false)

`scripts/patch_qemu_core.py`. `cpu->interrupt_handler != NULL` 로 게이트 → virt 등 타
머신 무영향 (멱등):
1. `cpu.h`: `void (*interrupt_handler)(CPUState*)` 필드 추가.
2. `tcg/op_helper.c`: pre_smc 의 has_el3=false UDEF 경로를 핸들러 설정 시 우회 (SMC→EXCP_SMC).
3. `helper.c`: EXCP_SMC 를 핸들러로 라우팅. **SMC 전용** — HVC 는 건드리지 않는다.

### 5.4 HVC 주의 (핵심 발견)

cmdline 에 **`kvm-arm.mode=protected`** 면 EL2 하이퍼바이저 (pKVM/RKP) 가 **커널 내장**.
호스트 HVC (hyp-stub, RKP) 는 **커널 자기 EL2 가 처리**해야 한다. 셤이 HVC 를 가로채면
멈춘다 (실측). ⇒ 별도 `uh.bin@EL2` 는 N/A, HVC 는 커널에 맡긴다.

K1 통과 = 콘솔에 `Run /init` (또는 첫 유저스페이스 프로세스).

---

## 6. K2 — 진짜 rootfs 마운트 (스토리지 2 경로)

커널이 `/init` 을 돌리면 곧 rootfs (system/vendor) 를 찾는다. 두 경로 중 택.

### 6.1 경로 A — 제네릭 스토리지 + DT fstab (빠름)

- QEMU 내장 스토리지 (`-device ufs`/virtio 등) 에 카브한 system/vendor (EROFS,ro) +
  userdata/metadata (ext4) 를 LU/디스크로 제시.
- Android fstab 을 DT 에 주입 (`get_dtb` 가 libfdt 로 `/firmware/android/fstab` 삽입):
  system→디스크N, vendor→디스크M (erofs), userdata/metadata (ext4, 평문).
- PCIe 스토리지면 `gpex-pcihost` + DT `/pcie` 노드 주입 (reg/ranges/interrupt-map 셀 수 주의).

### 6.2 경로 B — dm-linear 로 super 직접 마운트 (carve/verity/AVB 없이)

`super` 는 논리파티션 (system/vendor/product → super 내 익스텐트) 매핑. Android
first_stage_init 이 dm-linear 로 등록하는 것을 게스트 초소형 static init 이 대신 한다.

- `lp_tool.py dmtable` = liblp 파서로 논리파티션 익스텐트 추출.
- `supermount.c` = `/dev/mapper/control` 로 DM_DEV_CREATE + DM_TABLE_LOAD(linear) +
  DM_DEV_SUSPEND → `/dev/mapper/{system,vendor}` → EROFS ro 마운트. dm-verity 안 얹음 (AVB 무개입).
- 조사 전제: 커널에 `dm-mod.create=` 없고 GKI ramdisk 에 `dmsetup` 없음 → 직접 ioctl.
- `mkcpio.py` (순수 파이썬 newc cpio, 디바이스 노드 포함), `get_xtool.sh` (무루트 aarch64 툴체인).

K2 통과 = 커널 메시지 `erofs: (device dm-N): mounted` (system+vendor).

---

## 7. K3 — 진짜 벤더 스토리지 HCI (관찰 루프)

경로 A/B 는 제네릭 컨트롤러라 **벤더 드라이버가 안 돈다**. K3 은 SoC 의 진짜 스토리지
HCI (예: Exynos UFS `0x17100000` — 대상 DTB 의 스토리지 노드 `reg` 로 도출) 를 직접
모델해서 **진짜 벤더 `.ko`** 를 링크업→전원모드→SCSI→파티션까지 구동한다.
`templates/storage_hci.c.tmpl` 참조.

### 7.1 방법론 — 드라이버를 계측기로

데이터시트 없이. **드라이버가 기다리는 값을 관찰→모델→재빌드→전진** 반복.

```
부팅 → 드라이버가 "어느 레지스터를 읽고 무슨 값을 기다리나" 로그 관찰
     → 기다리는 값 모델에 심음 → 재빌드 → 다음 벽까지 전진 → (반복)
```

로그로 값의 출처가 안 보이면 (코드가 결정) `.ko` 를 **역어셈블**: 문자열 →
`.rela.text` 재배치 → 해당 `.text` 오프셋 역추적 → "이 값을 이 주소에서 read" 확정.

### 7.2 3 계층 모델 (플랫폼/sysbus MMIO — PCI 아님)

| 계층 | 무엇 | 구현 |
|---|---|---|
| **레지스터** | HCI 표준 레지스터 (예 UFSHCI: HCE/HCS/IS/IE/도어벨/UICCMD) + 벤더 창 N 개 (phy/unipro/pcs…) | `mem_read/write` (표준) + `vendor_val` (관측값). 창들을 `memory_region_init_io` 로 매핑 |
| **트랜스포트** | RAM 디스크립터 링 + 도어벨 + DMA | 도어벨 write → 디스크립터 DMA read → 패킷 종류 분기 → 응답 DMA write → 완료 IRQ (GIC SPI) |
| **디바이스** | 표준 명령 (Query/디스크립터/SCSI) | 플래그(초기화완료)/속성/디스크립터 + INQUIRY/READ CAPACITY/READ/WRITE |
| **백킹** | 진짜 디스크 | scatter-gather (PRDT) 따라 `disk.img` ↔ 게스트 RAM (`pread`/`pwrite`). 경로/블록크기 = env |

DMA 는 `dma_memory_read/write(&address_space_memory, …)` 로 게스트 물리 RAM 직접.
IRQ 는 `qemu_irq` (DTB 스토리지 `interrupts` SPI 번호).

### 7.3 함정표 (실측 — 새 SoC 에도 유사 클래스로 재발)

| 벽 | 원인 | 처치 |
|---|---|---|
| PHY 캘리브레이션 무한폴링 | 벤더 창이 0 반환 → 완료비트 영영 0 | 완료비트 오프셋에서 all-1 반환. 레인 수는 경고 역산 |
| NOP/디스크립터 주소 오염 (상위 32b=0xffffffff) | QEMU `ldl_le_p` 가 **부호 있는 int** 반환 → 비트31 켜진 lo dword 부호확장 | 넓히기 전 `(uint32_t)` 캐스트 |
| 전원모드 변경 타임아웃 (-110) | **UIC opcode 오인** (DME_SET=0x02 인데 0x12 로 착각) → 완료 IRQ 미발행 | opcode 스펙 재확인. attr=PWRMode 면 완료 IRQ set |
| max_gear=0 (로그 안 보임) | 드라이버가 UIC 아닌 **벤더 mmio** 로 기어 read | `.ko` 역어셈블로 read 주소 확정 → 그 창에서 기어 반환 |
| 파티션 스캔 안 됨 | UPIU **LUN/EDTL 필드 오프셋 착각** (LUN=byte2, EDTL=byte12-15) | 필드 위치 정정 |
| 파티션 안 잡힘 | **논리 블록 크기 (512 vs 4096) 불일치** → GPT 헤더 위치 어긋남 | `EFI PART` 시그니처 위치로 블록크기 확정 (4096B 지점이면 4096) |
| 커널 패닉 (벤더 텔레메트리 null) | `*_sec_set_features` 류 플랫폼 텔레메트리 (health/sysfs) null 참조 | 그 함수만 조기 리턴 (`.ko` 우회, §1.2) |

교훈: **상수·오프셋을 의심하라** (opcode, 필드 위치, 블록크기 — 전부 "한 끗"). **원시
바이트 덤프로 가설 배제** (레이아웃 정상 확인 후 부호확장으로 좁힘). **벤더 부가기능은
잘라낸다** (텔레메트리 우회 무방).

### 7.4 벤더 `.ko` 우회 + 의존성

- `.ko` 는 재배치 전 오브젝트 — 문자열→`.rela.text`→`.text` 로 패치 사이트 도출.
- 전형 우회 (예): 핀컨트롤/메모리로그/GPIO/SEC-텔레메트리 진입부 → `mov w0,#0;ret`.
- 벤더 심볼 미해결 시 no-op export 스텁 모듈 (`ufsdeps.ko` 류) 로 링크 충족.
- 게스트 init (`modload`) 이 `finit_module` 로 스텁+패치 `.ko` 로드. 비동기 프로브면
  `/dev/sdaN` 을 폴링 대기 + devtmpfs 없으면 `mknod`.

### 7.5 ★ 완료 기준 — 마일스톤 사다리 (중간에 멈추면 "완료" 아님)

"완벽한 UFS 컨트롤러" 는 관찰 루프가 아래를 **끝까지** 구동해야 한다. 한 마일스톤에서
멈추면 그건 **미완** — 정직히 최고 마일스톤을 기록하고 다음 벽을 처치한다 (§1.5).

| # | 마일스톤 | 커널 증거 (2400 검증) |
|---|---|---|
| 1 | link_up | `scsi host0: ufshcd` |
| 2 | power_mode | `Power mode change(0): M(1)G(3)L(2)HS-series(2)` |
| 3 | scsi_attach | `[sda] Attached SCSI disk` |
| 4 | **partitions_up** (K3 최소 완료) | `sda: sda1 sda2 sda3 sda4` |
| 5 | **super_mounted** (캡스톤 = 완전) | `erofs: (device dm-0/dm-4): mounted` + `supermount: SUCCESS` |

- **partitions_up 미도달** = UFS 컨트롤러 미완성. `partitions_up` 을 목표로 루프를 계속
  (max 소진 시 최고 마일스톤을 "미완" 으로 보고, "완료"·REAL 금지).
- **캡스톤(super_mounted)** = 진짜 컨트롤러가 실제 파일시스템까지 구동 (dm-linear super 마운트,
  `storage/run_path2_supermount.sh`·`supermount.c` 상당). 여기까지가 "완전한 UFS 컨트롤러".
- 파이프라인은 K3a(파티션) → K3b(캡스톤 마운트) 두 단계로 진행. K3a 미도달이면 K3b·완료로 넘어가지 말 것.

---

## 8. 검증 (트랙 2 — 실제 커널 메시지)

[CLAUDE.md](../CLAUDE.md) 트랙 2 검증표 (5/5) 참조. 핵심:
1. **PC/부팅 진행**: `Run /init` (K1) 트레이스·콘솔.
2. **커널 메시지 증거**: `erofs: (dm-N): mounted` (K2) / `sda: sda1…` (K3) — **머신이 아닌
   커널이 찍은 줄**.
3. **소스 negative**: 머신 C 에 그 마운트/파티션 문자열 0 개.
4. **드라이버 진짜 구동 (K3)**: 트랜잭션 로그에 UTRD/Query/SCSI, `.ko` 는 원본+문서화된 우회만.
5. **우회 목록**: 커널 패치 + `.ko` 패치 + SMC 셤 전부 `[대상/이유/방법/부작용]`.

---

## 9. 프론티어 (정직히 미달로 남김)

- **/data FBE → vold → Keymint → TEE (TEEGRIS/TrustZone)**: 하드웨어 키 → 시큐어월드 +
  Keymint TA 에뮬 필요 (대규모). 스토리지·rootfs 와 별개 주제. K3 이후의 벽.
- **부트로더→커널 연속 핸드오프 (트랙1 ③ → 트랙2 ⑥)**: 부트로더의 전체 스토리지 부팅
  경로 + board-init 완주 필요 — 공개 선례 미해결. 두 트랙은 **별도 진입점**으로 둔다.

이 둘은 도달 못 하면 "못 갔다" 고 근거와 함께 기록 (§1.5). 가짜 통과 금지.
