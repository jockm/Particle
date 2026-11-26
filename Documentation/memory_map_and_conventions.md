# Particle Memory Map, Vector Layout & ABI Conventions

---

## Memory Map

Particle has a single 32-bit, byte-addressed address space for code and data. On hardware, the bottom of it is on-chip block RAM (`tcmSizeBytes` in `CpuConfig`, 64 KiB by default); in psim each core has 128 KiB by default (`mem_size` in a cluster file), and addresses wrap within it.

| Address | Contents |
|---|---|
| `0x00000000`–`0x000000FF` | Zero page: 256 bytes reachable with an 8-bit address (the `LDZP32`/`STZP32` macros) |
| `0x000000F4`–`0x000000FF` | Trap words: `0xF4` return PC and `0xF8` vector number of the last unexpected trap (`lib/vectors.inc`); `0xFC` unused (it held the last `MBOX` value before the network interface's `NI_MBOX_VALUE`) |
| `0x00000100`–`0x000001FF` | Trap vector table: 16 vectors × 16 bytes (vector 0 is the reset entry point) |
| `0x00000200` up | The rest of the program image: code, then constants and global data |
| `__image_end` up | The heap: the allocator (`lib/alloc.asm`) starts it at the end of the image, which the assembler defines as `__image_end`, and it grows upward |
| below `0x00010000` | The stack: `R15` starts at `0x00010000` and the stack grows downward (full-descending, 4-byte aligned). The Action compiler's `--stack-top` and the `START_PROGRAM` macro set it. |
| `0x80000000` | In a psim cluster, the default shared memory window (`shared_memory_base`) |
| `0xF0000000` up | Memory-mapped I/O and the external memory window on hardware (`mmioBaseAddr`) |
| `0xFFFFFF00`–`0xFFFFFF0F` | The network interface's registers, answered by the core or its interface rather than memory: `NI_FLUSH`, `NI_MBOX_VALUE`, `NI_MBOX_SOURCE`, `NI_CONFIG` (`lib/common.inc`; see [MBOX design](mbox_design.md)) |

The image is loaded at `0x00000100`, the reset vector, so a program starts with its vector table. The heap and the stack share the memory between the end of the image and the stack top; nothing checks that they do not meet.

---

## Trap Vector Table

Each vector is a 16-byte (8-instruction) slot at a fixed address, and a trap jumps straight to it; there is no table of pointers:

$$\text{Vector address} = \text{trapTableBase} + \text{vector} \times 16$$

with `trapTableBase` = `0x00000100`.

| Vector | Address | Use |
|---|---|---|
| 0 | `0x00000100` | Reset: the program's entry point. `TRAP 0` ends a psim run. |
| 1 | `0x00000110` | Inter-core notification, by convention: `MBOX Rr, 1` from another core. (`MBOX` can raise any vector.) |
| 2–13 | `0x00000120`–`0x000001DF` | Software traps (`TRAP n`) and other `MBOX` vectors |
| 14 | `0x000001E0` | Misaligned memory access or odd PC |
| 15 | `0x000001F0` | Undefined opcode. `TRAP 15` ends a psim run as a failure. |

On a trap, `R14` gets the return address and the PC jumps to the vector (see §3 of `particle_spec.md`).

---

## Register Roles & Calling Convention (ABI)

This is the convention the Action compiler uses; hand-written assembly that calls or is called by Action code must follow it (see §2.6 of `action-language-guide.md`).

| Register | Role | Across a call |
|---|---|---|
| `R0` | Always zero (writes are discarded) | — |
| `R1` | Argument 1; the return value (and the first of a tuple's) | Clobbered |
| `R2`–`R4` | Arguments 2–4; further values of a tuple | Clobbered |
| `R5`–`R10` | General purpose | Preserved (compiled code never uses them) |
| `R11`–`R13` | Scratch (`R13` is the compiler's) | Clobbered |
| `R14` | Return address (link register), and the target of 8-bit immediate loads (`LD R14, imm8`) and of the `LOAD16`/`LOAD24`/`LOAD32` and `RCALL` macros | Clobbered |
| `R15` | Stack pointer (full-descending, 4-byte aligned) | Preserved |

Arguments after the fourth go on the stack. Calls use `RCALL _name` and returns use `RRET`; the callee saves `R14`.

### Trap handlers

A trap handler swaps out the interrupted code's registers instead of saving them to memory:

```assembly
_my_trap_handler:
    FAST_ENTER_TRAP        ; XCHGMOST: R1–R14 swap with the shadow bank (R15, the stack pointer, stays)
    ; ... the handler ...
    FAST_EXIT_TRAP         ; XCHGMOST again, then JMP R14, R0 back to the interrupted code
```
