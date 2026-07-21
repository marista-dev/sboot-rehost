# Knowledge table - track 2 K1/K2 (kernel direct boot, rootfs) stop points

Read by `fault-classifier` and the fixers. **A new class is one new row here.**
Methodology: `methodology/track2_kernel_storage.md` sections 4, 5 and 6.

Log sources: the `qemu -d unimp,guest_errors,int` trace and the kernel console.

| name | log signature | owning fixer | treatment |
|---|---|---|---|
| `kernel_oops` | `Internal error: Oops` or `Unable to handle kernel … at <addr>` with a symbol | `fixer-kernel` | a security-gate symbol gets a `.text` patch. **Vendor telemetry belongs to `fixer-storage`** |
| `security_gate` | early panic with a `fips`/`crypto`/`defex`/`selinux`/`avb` symbol | `fixer-kernel` | add `(off, expected, new, why)` to the `patch_kernel.py` PATCHES table |
| `smc_undef` | `Taking exception 2 [Undefined]` with `smc` at ELR | `fixer-el3` | handle the function id in the SMC shim, keep `psci_conduit=SMC` |
| `psci_suspend` | stalls after WFI, cpuidle hangs | `fixer-el3` | let the shim handle `CPU_SUSPEND`. **`psci_conduit=DISABLED` is forbidden** |
| `hvc_pkvm` | hangs after HVC with `kvm-arm.mode=protected` in cmdline | `fixer-el3` | **remove the HVC interception**; the kernel's own pKVM handles it |
| `gic_ppi` | `gicv3_set_irq` assert, arch-timer not firing | `fixer-kernel` | wire the arch-timer PPIs as **full INTIDs** |
| `unmapped_mmio` | one-shot unmapped MMIO report (catch-all) | `fixer-memory` | check the DTB, then a peripheral window or RAM |
| `rootfs_mount` | `Kernel panic … VFS: Unable to mount root` | `fixer-kernel` | generic plus DT fstab (6.1) or dm-linear supermount (6.2) |
| `unknown` | nothing above matches | - | **static-analyzer re-derivation** |

## Reaching a goal (K1/K2 rungs)

| milestone | line the kernel prints |
|---|---|
| `userspace` (K1) | `Run /init` |
| `rootfs` (K2) | `erofs: (device dm-N): mounted` |

**Only lines the kernel printed count.** Machine `qemu_log` output is not evidence.

## arch-timer PPIs: full INTID, not the relative number

The DTB `interrupts` property usually carries **relative PPI numbers**, but QEMU
wiring needs **full INTIDs**. Passing the relative number straight through kills
the boot with a `gicv3_set_irq` assert.

| timer | full INTID |
|---|---|
| secure physical | 29 |
| non-secure physical | 30 |
| virtual | 27 |
| hypervisor | 26 |

## Traps

- **Never patch the kernel without the pre-image check** - it is the signal that
  the address is wrong or the build differs.
- **`psci_conduit=DISABLED` is forbidden**; every PSCI call would fall through as
  an undefined exception.
- **With `kvm-arm.mode=protected`, the shim must not intercept HVC** - that is the
  kernel's own pKVM.
- **Routing K3 around rootfs with generic storage bypasses the goal.** That is K2.
  Either lower the grade honestly or hand it to `fixer-storage`.
