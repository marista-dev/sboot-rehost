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
| `cpu_cluster_mpidr` | `psci … cpu_on` returns **-22**, only some CPUs online, then boot hangs in `cpuhp`/`__alloc_workqueue_key` | `fixer-memory` | make the machine's cores-per-cluster match the DTB `cpu reg` encoding so MPIDR values line up |
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

## `cpu_cluster_mpidr` - the quiet boot killer

The DTB encodes each CPU's MPIDR in its `reg` property. Some SoCs use
`0x0, 0x100, 0x200 …` (Aff1 = core index, i.e. **one core per cluster**), while
QEMU's default topology packs 4 cores per cluster and produces `0x0..0x3,
0x100..0x103`. The two disagree, so `psci cpu_on` fails with **-22** for every CPU
whose MPIDR does not exist.

What makes it hard to spot is the *second-order* effect: the kernel's hotplug
worker keeps retrying the failed CPUs while **holding `cpu_hotplug_lock`**, so
`init`'s `__alloc_workqueue_key` blocks on `cpus_read_lock` forever. The console
shows no error - the boot simply stops after the last initcall.

Derive the DTB encoding and set cores-per-cluster to match:
```bash
fdtdump <dtb> | grep -A3 'cpu@'      # read the reg values
```
`initcall_debug` on the cmdline pinpoints the stall ("calling X" with no
"returned X"), and a `-d exec` PC histogram confirms the spin.

## Traps

- **Never patch the kernel without the pre-image check** - it is the signal that
  the address is wrong or the build differs.
- **A boot that stops with no error message is usually a lock, not a crash.**
  Check CPU onlining and `initcall_debug` before assuming a missing peripheral.
- **Timer interrupt overload** can starve forward progress; `-icount` makes guest
  time deterministic and is often what turns a "hang" into a boot.
- **`psci_conduit=DISABLED` is forbidden**; every PSCI call would fall through as
  an undefined exception.
- **With `kvm-arm.mode=protected`, the shim must not intercept HVC** - that is the
  kernel's own pKVM.
- **Routing K3 around rootfs with generic storage bypasses the goal.** That is K2.
  Either lower the grade honestly or hand it to `fixer-storage`.
