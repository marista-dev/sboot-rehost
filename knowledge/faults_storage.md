# Knowledge table - vendor storage controller walls

The trap table for `fixer-storage`. **A new wall is one new row here.**
Classification table: `knowledge/faults_unified.md`.

## What this is for

This is where rehosting happens *by implementing the controller*. The
goal is not "mount a rootfs" - it is **driving the real vendor UFS controller**
far enough that the kernel enumerates partitions. Every milestone below is a
graduation mark on that controller's completeness, not a separate objective.

Core idea: **use the driver as the instrument.** With no datasheet, observe which
registers the real vendor driver polls and what value it waits for, then fill the
model from that observation.

**The vendor driver need not be a `.ko`.** Kernels that compile UFS in
(`CONFIG_SCSI_UFS_*=y`) have no module by design, yet the real vendor driver is
present and will drive a modelled controller. Only
"no `.ko` **and** no driver in the kernel image" is a genuine blocker.

Log sources: the kernel console plus the storage model's own `qemu_log` (vendor
window reads and writes, UTRD/UPIU transactions).

| name | log signature | treatment |
|---|---|---|
| `poll_stall` | hundreds of repeating `RD <win>+0x… -> 0x0` lines | if that offset is a done/ready bit, set **only that bit**. If the awaited bit is unknown, derive it |
| `desc_addr_corrupt` | `NOP OUT failed -22`, response ttype mismatch | dump the raw 32-byte UTRD. Bit 31 set in the lo dword means a **sign-extension bug**: cast to `(uint32_t)` before widening |
| `prdt_stride` | reads "succeed" (`got == bytes`) but userspace executes wrong bytes: SIGILL, `init` dies early, loaded page contents mismatch the on-disk block | dump PRDT entries and measure the **actual stride between them**. Vendor extensions widen the sg entry (Samsung Exynos FMP inline crypto: 16 B descriptor + 112 B = **128 B stride**). Fix the scatter walk's stride; do not assume 16 B |
| `pwrmode_timeout` | `change_power_mode … -110`, `uic … timeout` | re-check the DME opcode. For `attr==PWRMode`, set `HCS.UPMCRS=1` and raise the `IS.UPMS` completion IRQ |
| `gear_source` | `max_gear(0)`, `Failed getting max … power mode` | when the log has no gear read, confirm the window and offset by `.ko` disassembly and return the gear value there |
| `upiu_field_off` | `[sda] Attached` but no `sda1`, `lun=68 edtl=0` | correct `handle_scsi` to `lun = cmd[2]`, `edtl = cmd[12..15]` |
| `block_size` | only LBA0 is read, `EFI PART` not found | locate the `EFI PART` signature in the backing image, then set `EUFS_LBS` to 512 or 4096 |
| `vendor_telemetry_null` | null-pointer Oops after the power mode passes | return early from the telemetry function (`*_sec_set_features` family) with `mov w0,#0; ret`. Bypass documentation mandatory |
| `irq_edge_level` | UIC command times out `-110` even though the model set the completion bit | the HCI interrupt must be **level-triggered** (`qemu_set_irq` held while IS & IE), not a pulse. An edge is missed and the driver waits forever |
| `is_bit_layout` | power-mode change times out `-110` while link-up worked | the IS register bit positions are wrong. Derive each from the driver's masks - **UPMS is bit 4**, ULSS bit 8, UCCS bit 10; guessing bit 8 for UPMS is the common miss |
| `query_upiu_overwrite` | `Response size is bigger than buffer`, or the descriptor arrives with a corrupt header | write the response UPIU **once**: place the descriptor at `resp+32` and write header+payload in a single transfer. Writing them separately lets the second write clobber the header. Cap the length by the request's own field |
| `sparse_super_gpt` | `[sda] Attached` but no partitions, and the backing image is `super.img` | an Android **sparse super is not a GPT disk**. Decode the sparse image and synthesise a LUN with a GPT (primary + backup) whose partition covers it, then back the model with that |
| `unknown` | nothing above matches | **static-analyzer re-derivation** |

## UniPro DME opcodes

| command | opcode |
|---|---|
| `DME_GET` | 0x01 |
| `DME_SET` | 0x02 |
| `DME_PEER_GET` | 0x03 |
| `DME_PEER_SET` | 0x04 |

## Milestone ladder - the completion bar

| stage | milestone | line the kernel prints | walls to clear |
|---|---|---|---|
| — | `link_up` | `scsi host0: ufshcd`, or `… UFS link established` | PHY calibration (`poll_stall`) |
| — | `power_mode` | `Power mode change(0): M(1)G(3)L(2)HS-series(2)` | `desc_addr_corrupt`, `pwrmode_timeout`, `gear_source` |
| — | `scsi_attach` | `[sda] Attached SCSI disk` | Query device, `vendor_telemetry_null` |
| **최소 완료** | **`partitions_up`** | `sda: sda1 sda2 sda3 sda4` | `upiu_field_off`, `block_size`, `prdt_stride` |
| **최종 칸** | `super_mounted` | `erofs: (device dm-0/dm-4): mounted` plus `supermount: SUCCESS` | async probe timing |

**`partitions_up` is minimum completion; `super_mounted` is the
final rung - the full UFS controller.** Below `partitions_up` the controller is unfinished:
report the highest milestone honestly and treat the next wall. Never dress
partial progress up as completion.

**The capstone depends on the image topology, not on effort.** Only firmware that
ships a `super.img` (dm-linear, usually EROFS) can print that line. Firmware with
separate `system`/`vendor` raw images - often ext4, mounting as
`EXT4-fs (sda): mounted filesystem` / `VFS: Mounted root (ext4 filesystem)` -
**completes at `partitions_up`** and never has a final rung. Keeping `super_mounted` as a
required rung there would demand a goal that cannot exist.

## When the value lives in code - `.ko` disassembly (ask static-analyzer)

```
find the .rodata file offset of the string, e.g. "max_gear(%d)"
 -> readelf -r <ko>, find the .rela.text entry referencing it -> .text offset
 -> objdump -d / capstone: ldr xbase / mov wimm / bl readl
 -> conclude readl(<window> + <imm>) and model that window and offset
```

## The most harmful cheat in this domain

**Adaptive toggles are absolutely forbidden.** "Change the value based on the read
count" (return 0 twelve times, then alternate 0xFFFFFFFF) is most tempting here,
because the driver visibly progresses. It sends the firmware down a wrong branch
and **fakes a pass** (honesty rule 1). **Model constant ready values only.**

- **Rule out hypotheses with a raw byte dump** before concluding, especially for
  `desc_addr_corrupt` and `prdt_stride`.
- **Completeness is not correctness.** Instrumenting a read to check
  `got == bytes` proves every byte arrived; it says nothing about *where* they
  were placed. A wrong PRDT stride passes that check and still corrupts
  multi-page transfers, so the mount (single-entry, one page) works while
  userspace executes garbage. When reads "succeed" but the loaded pages disagree
  with the on-disk blocks, measure the descriptor stride before blaming anything
  outside the storage model.
- **Doubt constants, field positions and block sizes**; re-check them against the
  spec or the on-disk signature rather than intuition.
- **Document every `.ko` bypass.** Replacing real driver code defeats the point.
