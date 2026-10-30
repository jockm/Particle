# Particle Memory Map, Vector Layout & ABI Conventions

---

## System Memory Map

The Particle processor architecture operates within a unified 32-bit address space mapped onto on-chip True Dual-Port Block RAM and memory-mapped I/O peripherals.

| Address Range | Size | Description |
|---|---|---|
| `0x00000000 - 0x000000FF` | 256 B | Boot scratchpad & low vectors |
| `0x00000100 - 0x000004FF` | 1024 B| Direct Stride Exception Vector Table (16 vectors $	imes$ 64 bytes) |
| `0x00000500 - 0x00007FFF` | ~31 KB| Program code & static constants |
| `0x00008000 - 0x0000FFFC` | 32 KB | Heap / Application Data Space |
| `0x00010000` | -- | Default Stack Pointer initialization (Full-descending) |
| `0xF0000000 - 0xFFFFFFFF` | -- | Memory-Mapped I/O (MMIO) Registers & Peripherals |

---

## Direct Stride Vector Table Layout

Unlike traditional processors requiring indirect pointer lookups from a vector table, Particle vectors calculate jump targets directly using a 64-byte (32-instruction) stride:

$$	ext{Vector Target} = 	ext{TRAP\_TABLE\_BASE} + (	ext{Vector Number} 	imes 64)$$

| Vector | Address | Identifier | Description |
|---|---|---|---|
| 0 | `0x00000100` | `TRAP_RESET` | Hardware Power-On Reset Vector |
| 1 | `0x00000140` | `TRAP_MBOX` | Inbound Inter-Core Strobe / FIFO Message Notification |
| 2–13 | `0x00000180`–`0x0000047F` | `TRAP_USER2..13` | Software & User-defined Traps |
| 14 | `0x00000480` | `TRAP_ALIGN` | Bus Misalignment Fault (Unaligned Halfword/Word) |
| 15 | `0x000004C0` | `TRAP_ILLEGAL` | Undefined/Illegal Opcode Decoded |

---

## Register Roles & Calling Convention (ABI)

| Register | Name | Role | Preserved across Calls |
|---|---|---|---|
| `R0` | Zero | Hardwired Zero (reads return 0, writes discarded) | Fixed |
| `R1` | Arg0 / Ret | Function argument 0 / primary return value | Caller-saved |
| `R2` | Arg1 | Function argument 1 | Caller-saved |
| `R3` | Arg2 | Function argument 2 | Caller-saved |
| `R4` | Arg3 | Function argument 3 | Caller-saved |
| `R5`–`R10` | Saved | General variables and callee-saved registers | Callee-saved |
| `R11`–`R13`| Scratch | Temporary values and scratchpad storage | Caller-saved |
| `R14` | Link/Acc | Return address link register & immediate accumulator | Caller-saved |
| `R15` | SP | Stack Pointer (Full-descending, 4-byte aligned) | Callee-saved |

### Trap Context Switching Protocol
To service a trap with zero memory overhead, invoke:
```assembly
_my_trap_handler:
    FAST_ENTER_TRAP        ; Executes XCHGMOST (R1-R14 swapped into shadow bank; SP preserved)
    ; Handler execution ...
    FAST_EXIT_TRAP         ; Restores R1-R14 and executes JMP R14, R0 back to application
```
