# Knowledge table - track 2 K3 (vendor storage HCI) walls

The trap table for `fixer-storage`. **A new wall is one new row here.**
Methodology: `methodology/track2_kernel_storage.md` section 7.

Core idea: **use the driver as the instrument.** With no datasheet, observe which
registers the real vendor driver polls and what value it waits for, then fill the
model from that observation.

Log sources: the kernel console plus the storage model's own `qemu_log` (vendor
window reads and writes, UTRD/UPIU transactions).

| name | log signature | treatment |
|---|---|---|
| `poll_stall` | hundreds of repeating `RD <win>+0x… -> 0x0` lines | if that offset is a done/ready bit, set **only that bit**. If the awaited bit is unknown, derive it |
| `desc_addr_corrupt` | `NOP OUT failed -22`, response ttype mismatch | dump the raw 32-byte UTRD. Bit 31 set in the lo dword means a **sign-extension bug**: cast to `(uint32_t)` before widening |
| `pwrmode_timeout` | `change_power_mode … -110`, `uic … timeout` | re-check the DME opcode. For `attr==PWRMode`, set `HCS.UPMCRS=1` and raise the `IS.UPMS` completion IRQ |
| `gear_source` | `max_gear(0)`, `Failed getting max … power mode` | when the log has no gear read, confirm the window and offset by `.ko` disassembly and return the gear value there |
| `upiu_field_off` | `[sda] Attached` but no `sda1`, `lun=68 edtl=0` | correct `handle_scsi` to `lun = cmd[2]`, `edtl = cmd[12..15]` |
| `block_size` | only LBA0 is read, `EFI PART` not found | locate the `EFI PART` signature in the backing image, then set `EUFS_LBS` to 512 or 4096 |
| `vendor_telemetry_null` | null-pointer Oops after the power mode passes | return early from the telemetry function (`*_sec_set_features` family) with `mov w0,#0; ret`. Bypass documentation mandatory |
| `unknown` | nothing above matches | **static-analyzer re-derivation** |

## UniPro DME opcodes

| command | opcode |
|---|---|
| `DME_GET` | 0x01 |
| `DME_SET` | 0x02 |
| `DME_PEER_GET` | 0x03 |
| `DME_PEER_SET` | 0x04 |

## Milestone ladder - the K3 completion bar

| milestone | line the kernel prints | walls to clear |
|---|---|---|
| `link_up` | `scsi host0: ufshcd` | PHY calibration (`poll_stall`) |
| `power_mode` | `Power mode change(0): M(1)G(3)L(2)HS-series(2)` | `desc_addr_corrupt`, `pwrmode_timeout`, `gear_source` |
| `scsi_attach` | `[sda] Attached SCSI disk` | Query device, `vendor_telemetry_null` |
| `partitions_up` | `sda: sda1 sda2 sda3 sda4` | `upiu_field_off`, `block_size` |
| `super_mounted` | `erofs: (device dm-0/dm-4): mounted` plus `supermount: SUCCESS` | async probe timing |

**`partitions_up` is the K3 minimum, `super_mounted` is full completion.**
Stopping midway is not completion - report the highest milestone honestly.

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
  `desc_addr_corrupt`.
- **Doubt constants, field positions and block sizes**; re-check them against the
  spec or the on-disk signature rather than intuition.
- **Document every `.ko` bypass.** Replacing real driver code defeats the point of K3.
