# SM-S921N (Exynos 2400) — 트랙 2 Worked Example

트랙 2 (`kernel-storage`) 가 도달하는 최종 상태. 값은 이 펌웨어의 **예시** — 새 펌웨어는
DTB/커널/드라이버에서 다시 도출 (methodology/track2_kernel_storage.md).

## INPUT (Table J 슬롯, 채워진 예)

| 슬롯 | 값 |
|---|---|
| track | 2 |
| model | SM-S921N |
| soc | Exynos 2400 (ARMv9, 8×cortex-a76) |
| target | K3 |
| kernel_path | fw/Image (GKI, boot.img 추출) |
| dtb_path | fw/exynos.dtb |
| super_path | fw/super.img (EROFS: system/vendor) |
| storage_driver_ko | ufs-exynos-core.ko |

## 머신 골격 (DTB 도출, Table K)

| 요소 | 값 (예시) | 도출 |
|---|---|---|
| DRAM | 0x80000000 | /memory |
| GICD / GICR | 0x10200000 / 0x10240000 | gic 노드. arch-timer PPI = 30/27/26/29 (풀 INTID) |
| UART | 0x10840000 (STAT+0x10/TX+0x20/RX+0x24) | serial 노드. earlycon=exynos4210 |
| 스토리지 HCI | 0x17100000 | ufs 노드 reg. SPI = 0x295 |
| cmdline | `kvm-arm.mode=protected` | HVC 는 커널 내장 pKVM (셤이 안 건드림) |

## 커널 게이트 우회 (Table L, pre-image 검증)

FIPS-140 POST / DEFEX / SELinux enforce / ufshcd-pci id / debug-kinfo early_module —
각 사이트는 `Image` 심볼 xref 로 도출 (예시 오프셋 박제 금지).

## K3 스토리지 HCI 관찰 루프 결과 (Table M 함정 통과)

PHY cal → NOP 부호확장 → Query 디바이스 → 전원모드 (DME_SET opcode + UPMS) → gear (.ko
역어셈블) → UPIU LUN/EDTL → 블록크기 4096 → 벤더 텔레메트리 우회.

## 도달 상태 (커널 메시지 = 객관 증거)

```
sd 0:0:0:0: [sda] 4243717 4096-byte logical blocks: (17.4 GB/16.2 GiB)
 sda: sda1 sda2 sda3 sda4              ← 진짜 GPT (super/userdata/metadata/efs)
Power mode change(0): M(1)G(3)L(2)HS-series(2)
erofs: (device dm-0): mounted          ← system
erofs: (device dm-4): mounted          ← vendor
```

검증 (트랙 2 5/5): `Run /init` ✅ / 커널 메시지 (erofs dm-N · sda1 · Power mode) ✅ /
소스 negative ✅ / 드라이버 진짜 구동 (UTRD/Query/SCSI, `.ko` 6곳만 문서화 우회) ✅ /
우회 목록 4 항 ✅ → **REAL**.

## 프론티어 (정직히 미달)

`/data` FBE → vold → Keymint → TEEGRIS (시큐어월드 하드웨어 키). UFS·rootfs 와 별개 주제.

원본 작업: `2400/10_exynos2400_rehost/` (machine/exynos_ufs.c, storage/UFS_CONTROLLER_GUIDE.md).
