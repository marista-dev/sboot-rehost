# Knowledge table - track 1 (bootloader shell) stop points

Read by `fault-classifier` when picking a name and by the fixers when picking a
treatment. **A new stop point class is one new row here** - the agent prompts stay
untouched.

Log sources: the `qemu -d int,in_asm,nochain` trace and the UART console.

| name | log signature | owning fixer | treatment |
|---|---|---|---|
| `data_abort_unmapped` | `Taking exception 4 [Data Abort]` with `FAR 0x…` in an unmodelled region | `fixer-memory` | add a MemoryRegion covering that FAR (read 0 / write absorb) |
| `infinite_poll` | the same FAR repeating hundreds of times, only runtime grows | `fixer-memory` | return a constant with **only the awaited bit** set for that offset |
| `smc_undef` | `Taking exception 2 [Undefined]` and ELR disassembles to `smc` | `fixer-el3` | handle that function id in `smc_handler` |
| `fpu_trap` | `Taking exception 2` and ELR is FP/SVE (`ldr q`, `str q`, `ld1`) | `fixer-el3` | `cpacr_el1 = 0x300000` in the reset hook (widen to 0x333000) |
| `null_ret` | `Taking exception 3 [Prefetch Abort]` with FAR=0 and ELR=0 | `fixer-bootflow` | trace back to the **last caller**, then use the entry redirect trampoline |
| `console_silent` | 0 bytes of console and 0 exceptions | `fixer-bootflow` | route the BL3 printf callback to a direct UART write |
| `shell_exit_early` | the shell exits without input, no `autoboot aborted..` | `fixer-bootflow` | make `getline_timeout_branch` unconditional |
| `harness_input_starved` | `fingerprint.json` `input.starved: true` - the firmware polled the console (`rx_polls > 0`) and read **none** of our bytes (`rx_served == 0`), then booted on | **harness - no fixer** | not a firmware stop point. Re-run; if it repeats, check `input_plan.json`'s `contiguous` / `empty_poll_budget` against the gate's disassembly and whether the gate opens before the harness's first write lands |
| `partition_table_unavailable` | the firmware reports its partition table absent or failing its integrity check, then every partition lookup fails and the environment, panel, modem and next-stage loads fail with it (`fingerprint.json` `storage.partition_table: "missing"`) | **track boundary - no fixer on track 1** | the table is **data read from the boot medium**, and track 1 models the medium as a stub, so there is nothing to parse - the parser is behaving correctly. Do not add memory windows for it and do not treat the downstream failures as separate stop points. The interactive surface is unaffected and is what track 1 targets. To reach the rungs that need the medium, run track 2 (`/sboot-rehost:rehost-kernel`), which implements the controller |
| `shell_mode_gate` | the shell function is entered and returns immediately, before the input gate is ever polled: console shows the "check … mode" line but no `autoboot aborted..`, and the trace goes shell-func → predicate → `cbz` → epilogue | `fixer-bootflow` | the predicate reads a mode/token word the rehost has no supplier for (typically memcpy'd from a handover blob into BSS, so crt0 zeroes it and no data patch can set it). Derive the predicate and the single branch it feeds, then neutralise **that one branch**. Record it as a guest-image patch in `bypasses.md`: it disables the vendor's "no token, no shell" gate, so grade C's autoboot fork can no longer be observed in this environment |
| `entry_el_mismatch` | `FAR == ELR` at a low unmapped address (e.g. `0x620`), exception count in the millions, 0 bytes of console | **build layer - no fixer** | the machine resets into the wrong exception level, so the image runs an entry path never meant for it. A BL33 (non-secure world bootloader) entered at EL3 falls through an EL3 path and sets a near-null VBAR, and the first exception fetches from unmapped low memory forever. `supervisor` routes `rebuild`: `has_el3=false`, or enter at non-secure EL2/EL1. **NOPing the instruction that corrupts the vector base treats the symptom** and leaves the next one waiting |
| `unknown` | nothing above matches | - | **static-analyzer re-derivation**, never a guess |

## Build-layer stop points

Some stop points cannot be fixed inside the loop at all. A fixer changes one place
in the machine sources that exist; it cannot change a premise the machine was
**built on** - `has_el3`, the entry exception level, entry PC, load/link address,
the memory skeleton, the CPU type.

For these the owning column reads **build layer**, and the treatment is for
`supervisor` to route `rebuild` with a concrete premise correction. Handing one to
a fixer produces a band-aid that changes nothing, which is what a run of identical
fingerprints looks like.

## Reaching the goal (not a stop point)

| milestone | evidence the BL3 prints |
|---|---|
| `shell` | the `S-BOOT #` prompt and `help` output (`Following commands…`) |

If that same string also exists in the machine `.c`, **nothing was reached** - we
printed it (honesty rule 7, self-injection). The provenance gate in the run script
filters this automatically every round.

## Common 4-byte AArch64 encodings

| instruction | encoding |
|---|---|
| `MOV W0, #0` | `0x52800000` |
| `MOV W0, #1` | `0x52800020` |
| `RET` | `0xD65F03C0` |
| `NOP` | `0xD503201F` |
| `B .` (spin in place) | `0x14000000` |
| `B target` | `0x14000000 \| ((target - PC) / 4) & 0x03FFFFFF` |

Apply a byte patch **only when the original 4 bytes match the expected pre-image**.

## Traps

- **Do not cover `null_ret` with a NOP.** It only moves the symptom; the cause is
  a function returning null further back.
- **Do not answer `infinite_poll` with 0xFFFFFFFF.** Extra bits get set and the
  firmware takes a wrong branch. Derive the awaited bit instead.
- **Do not solve `console_silent` by printing from the machine.** That is
  self-injection: the provenance gate catches it and voids the milestone.
