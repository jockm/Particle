# Particle Processor Architecture & System Engineering Specification

## 1. Overview
Particle is a high-efficiency 32-bit load/store RISC processor architecture utilizing compact, fixed-width 16-bit instructions, inspired by the Hitachi SH-2, ARM Thumb, and MiniRISC4 architectures. It is implemented in pure Intel ROHD (Rapid Open Hardware Development in Dart) without legacy Verilog codebases, synthesizing directly to SystemVerilog for modern FPGA platforms (such as Lattice ECP5 on the ULX3S).

---

## 2. Register & Execution Architecture
* **Registers**: 16 native 32-bit general-purpose registers:
  * `R0`: Hardwired Constant Zero. Reads return `0x00000000`; writes are safely discarded.
  * `R1`–`R4`: Function argument passing and return value registers (Caller-saved).
  * `R5`–`R10`: Preserved general-purpose registers (Callee-saved).
  * `R11`–`R13`: Scratchpad / temporary registers (Caller-saved).
  * `R14`: Subroutine link register (`RCALL`/`RRET`), immediate accumulator, and trap link register.
  * `R15` (`SP`): Architectural stack pointer (full-descending, 4-byte aligned).
* **Hardware Shadow Register Bank**:
  * 16 duplicate 32-bit shadow registers (`S0`–`S15`).
  * Single-cycle exchange operations:
    * `XCHG Rr`: Swaps active `Rr` with `Sr`.
    * `XCHGALL`: Swaps `R1`–`R15` with `S1`–`S15`.
    * `XCHGMOST`: Swaps `R1`–`R14` with `S1`–`S14` while preserving `SP` (`R15`) for instantaneous zero-memory-spill interrupt/trap entry.
* **Flagless Design**: No traditional ALU condition code flags. Branching evaluates registers directly (`FBRA.Z`, `FBRA.P`, `BBRA.Z`, etc.), while relational evaluations yield integer boolean results (`0` or `1`) directly in destination registers.

---

## 3. Direct Stride Vector Table
Vectors are computed without indirect pointer memory fetches using a direct 64-byte (32-instruction) stride:
$$\text{Target} = \text{TRAP\_TABLE\_BASE} + (\text{Vector} \times 64)$$

* Base Address: `0x00000100`
* Stride: 64 bytes (`0x40`)
  * Vector 0 (`0x00000100`): Cold Power-On Reset
  * Vector 1 (`0x00000140`): Inbound MBOX / FIFO Strobe Notification
  * Vectors 2–13 (`0x00000180`–`0x0000047F`): Software & User-defined Traps
  * Vector 14 (`0x00000480`): Memory Bus Misalignment Fault
  * Vector 15 (`0x000004C0`): Undefined / Illegal Opcode Decoded

---

## 4. Complete Instruction Set Architecture (ISA) Map
Instructions are 16 bits wide: `[15:8] Opcode`, `[7:4] Rr`, `[3:0] Rl / Imm4`.

### 4.1 Loads & Immediates (0x00 - 0x06)
* `0x00`: `LD Rr, Rl` — $Rr \leftarrow Rl$
* `0x01`: `LD Rr, Imm4` — $Rr \leftarrow \text{zero\_ext}(Imm4)$
* `0x02`: `LD R14, Imm8` — $R14 \leftarrow \text{zero\_ext}(Imm8)$
* `0x03`: `LD Rr, -Imm4` — $Rr \leftarrow -Imm4$
* `0x04`: `LD R14, -Imm8` — $R14 \leftarrow -Imm8$
* `0x05`: `PUSH4 Rr, Imm4` — $Rr \leftarrow (Rr \ll 4) \mid Imm4$
* `0x06`: `PUSH8 R14, Imm8` — $R14 \leftarrow (R14 \ll 8) \mid Imm8$

### 4.2 Memory Loads & Stores (0x10 - 0x39)
* `0x10`–`0x19`: `LD8` (Standard, indirect, pre/post inc/dec)
* `0x20`–`0x29`: `LD16` (Standard, indirect, pre/post inc/dec)
* `0x30`–`0x39`: `LD32` (Standard, indirect, pre/post inc/dec)

### 4.3 Unsigned & Signed Arithmetic (0x40 - 0x57)
* `0x40`: `ADD Rr, Rl`
* `0x41`: `SUB Rr, Rl`
* `0x42`: `DIV Rr, Rl`
* `0x43`: `MOD Rr, Rl`
* `0x44`: `ADD Rr, Imm4`
* `0x45`: `SUB Rr, Imm4`
* `0x46`: `DIV Rr, Imm4`
* `0x47`: `MOD Rr, Imm4`
* `0x50`–`0x57`: `SADD`, `SSUB`, `SDIV`, `SMOD` (Register and Imm4 forms)

### 4.4 Logic, Shifts, Sign-Extension & Inversions (0x60 - 0x77)
* `0x60`: `SHIFTL Rr, Rl`
* `0x61`: `SEXT8 Rr` — Sign extend lower 8 bits of $Rr$
* `0x62`: `SHIFTR Rr, Rl` (Logical)
* `0x63`: `ASHIFTR Rr, Rl` (Arithmetic)
* `0x64`: `ROTL Rr, Rl`
* `0x65`: `ROTR Rr, Rl`
* `0x66`: `AND Rr, Rl`
* `0x67`: `OR Rr, Rl`
* `0x68`: `XOR Rr, Rl`
* `0x69`: `SHIFTL Rr, Imm4`
* `0x6A`: `SEXT16 Rr` — Sign extend lower 16 bits of $Rr$
* `0x6B`: `SHIFTR Rr, Imm4`
* `0x6C`: `ASHIFTR Rr, Imm4`
* `0x6D`: `ROTL Rr, Imm4`
* `0x6E`: `ROTR Rr, Imm4`
* `0x6F`: `AND Rr, Imm4`
* `0x70`: `OR Rr, Imm4`
* `0x71`: `XOR Rr, Imm4`
* `0x72`: **`NOT Rr`** — Bitwise NOT / Inversion: $Rr \leftarrow \sim Rr$
* `0x73`: **`NEZ Rr`** — Set on Not Equal Zero: $Rr \leftarrow (Rr \ne 0) \ ? \ 1 : 0$

### 4.5 Multipliers (0x78 - 0x7F)
* `0x78`: `MULL Rr, Rl`
* `0x79`: `MULH Rr, Rl`
* `0x7A`: `SMULH Rr, Rl`
* `0x7B`: `MULHSU Rr, Rl`
* `0x7C`–`0x7F`: Multipliers with `Imm4`

### 4.6 Bit Manipulation & System Operations (0x80 - 0x8B)
* `0x80`: `BEXTR Rr, Rl`
* `0x81`: `JTBL Rr, Rl`
* `0x82`: `CLZ Rr, Rl`
* `0x83`–`0x84`: `BSET` (R-R, Imm4)
* `0x85`–`0x86`: `BCLR` (R-R, Imm4)
* `0x87`–`0x88`: `BINV` (R-R, Imm4)
* `0x89`–`0x8A`: `BGET` (R-R, Imm4)
* `0x8B`: `TAS (Rr), Rl` — Atomic Test-and-Set / Swap

### 4.7 Relational Comparisons (0x90 - 0x99)
* `0x90`–`0x94`: `SLT` (Set on Less Than, Unsigned)
* `0x95`–`0x99`: `SSLT` (Set on Less Than, Signed)

### 4.8 Control Flow & Hardware Synchronization (0xA0 - 0xA4)
* `0xA0`: `JMP Rr, Rl` — Jump Register and Link ($Rl \leftarrow PC + 2; PC \leftarrow Rr$)
* `0xA1`: `RJUMP Rr, Rl` — Relative Jump and Link ($Rl \leftarrow PC + 2; PC \leftarrow PC + (Rr \times 2)$)
* `0xA2`: `TRAP Rr`
* `0xA3`: `TRAP Imm4`
* `0xA4`: **`WAIT`** — Halts execution pipeline until inbound MBOX strobe asserts (`mboxStrobeIn == 1`).

### 4.9 Branches & Context Exchange (0xB0 - 0xE9)
* `0xB0`–`0xB9`: `FBRA` (Unconditional, `.Z`, `.N`, `.P`)
* `0xC0`–`0xC9`: `BBRA` (Unconditional, `.Z`, `.N`, `.P`)
* `0xD0`: `XCHG Rr`
* `0xD1`: `XCHGALL`
* `0xD2`: `XCHGMOST`
* `0xE0`–`0xE9`: Hardware Streaming FIFOs (`FIFO.R`, `FIFO.W`, `FIFO.STAT`, `FIFO.TRYR`, `FIFO.TRYW`, `MBOX`)
