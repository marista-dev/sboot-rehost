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
| `unknown` | nothing above matches | - | **static-analyzer re-derivation**, never a guess |

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
