# Particle Processor Architecture & System Engineering Specification

## 1. Overview
Particle is a high-efficiency 32-bit load/store RISC processor architecture utilizing compact, fixed-width 16-bit instructions, inspired by the Hitachi SH-2, ARM Thumb, and MiniRISC4 architectures. It is implemented in pure Intel ROHD (Rapid Open Hardware Development in Dart) without legacy Verilog codebases, synthesizing directly to SystemVerilog for modern FPGA platforms (such as Lattice ECP5 on the ULX3S).

---

## 2. Register & Execution Architecture
- **Registers**: 16 native 32-bit general-purpose registers:
  - `R0`: Hardwired Constant Zero. Reads return `0x00000000`; writes are safely discarded.
  - `R1`–`R4`: Function argument passing and return value registers (Caller-saved).
  - `R5`–`R10`: Preserved general-purpose registers (Callee-saved).
  - `R11`–`R13`: Scratchpad / temporary registers (Caller-saved).
  - `R14`: Subroutine link register (`RCALL`/`RRET`), immediate accumulator, and trap link register.
  - `R15` (`SP`): Architectural stack pointer (full-descending, 4-byte aligned).
- **Hardware Shadow Register Bank**:
  - 16 duplicate 32-bit shadow registers (`S0`–`S15`).
  - Single-cycle exchange operations:
    - `XCHG Rr`: Swaps active `Rr` with `Sr`.
    - `XCHGALL`: Swaps `R1`–`R15` with `S1`–`S15`.
    - `XCHGMOST`: Swaps `R1`–`R14` with `S1`–`S14` while preserving `SP` (`R15`) for instantaneous zero-memory-spill interrupt/trap entry.
- **RBASE Register Windowing**:
  - Shifts logical register index decoding into a 32-register physical file (`R0` remains fixed at physical 0; `R1`–`R15` offset by `rbase`).
  - `RBASE Imm4` / `RBASE Imm8` (`0xD3`): Load window offset directly from constant.
  - `RBASE Rr` (`0xD4`): Load window offset dynamically from register `Rr`.
- **Flagless Design**: No traditional ALU condition code flags. Branching evaluates registers directly (`FBRA.Z`, `FBRA.NZ`, `FBRA.P`, `BBRA.Z`, etc.), while relational evaluations yield integer boolean results (`0` or `1`) directly in destination registers.

---

## 3. Direct Stride Vector Table
Vectors are computed without indirect pointer memory fetches using a direct 64-byte (32-instruction) stride:
$$\text{Target} = \text{TRAP\_TABLE\_BASE} + (\text{Vector} \times 64)$$

- Base Address: `0x00000100`
- Stride: 64 bytes (`0x40`)
- Vector 0 (`0x00000100`): Cold Power-On Reset
- Vector 1 (`0x00000140`): Inbound MBOX / Inter-Core Hardware Strobe Notification
- Vectors 2–13 (`0x00000180`–`0x0000047F`): Software & User-defined Traps
- Vector 14 (`0x00000480`): Memory Bus Misalignment Fault
- Vector 15 (`0x000004C0`): Undefined / Illegal Opcode Decoded

---

## 4. Complete Instruction Set Architecture (ISA) Map
Instructions are 16 bits wide: `[15:8] Opcode`, `[7:4] Rr`, `[3:0] Rl / Imm4`. Memory operations support standard load/store addressing modes. In `pasm.py`, stores are assembled using load mnemonics with a memory destination (`LD32 (Rr), Rl`) or `ST*` mnemonics.

### 4.1 Loads & Immediates (0x00 - 0x06)
- `0x00`: `LD Rr, Rl` — $Rr \leftarrow Rl$
- `0x01`: `LD Rr, Imm4` — $Rr \leftarrow \text{zero\_ext}(Imm4)$
- `0x02`: `LD R14, Imm8` — $R14 \leftarrow \text{zero\_ext}(Imm8)$
- `0x03`: `LD Rr, -Imm4` — $Rr \leftarrow -Imm4$
- `0x04`: `LD R14, -Imm8` — $R14 \leftarrow -Imm8$
- `0x05`: `PUSH4 Rr, Imm4` — $Rr \leftarrow (Rr \ll 4) \mid Imm4$
- `0x06`: `PUSH8 R14, Imm8` — $R14 \leftarrow (R14 \ll 8) \mid Imm8$

### 4.2 Memory Loads & Stores (0x10 - 0x39)
- `0x10`: `LD8 Rr, (Rl)` — $Rr \leftarrow \text{zero\_ext}(\text{Mem8}[Rl])$
- `0x11`: `LD8 (Rr), Rl` / `ST8 (Rr), Rl` — $\text{Mem8}[Rr] \leftarrow Rl[7:0]$
- `0x12`: `LD8 Rr, (Rl++)` — Post-increment load byte
- `0x13`: `LD8 (Rr++), Rl` / `ST8 (Rr++), Rl` — Post-increment store byte
- `0x14`: `LD8 Rr, (--Rl)` — Pre-decrement load byte
- `0x15`: `LD8 (--Rr), Rl` / `ST8 (--Rr), Rl` — Pre-decrement store byte
- `0x16`: `LD8 Rr, (Rl + Imm4)` — Base + offset load byte
- `0x17`: `LD8 (Rr + Imm4), Rl` / `ST8 (Rr + Imm4), Rl` — Base + offset store byte
- `0x18`: `LD8 Rr, (SP + Imm4)` — Stack-relative load byte
- `0x19`: `LD8 (SP + Imm4), Rl` / `ST8 (SP + Imm4), Rl` — Stack-relative store byte

- `0x20`: `LD16 Rr, (Rl)` — $Rr \leftarrow \text{zero\_ext}(\text{Mem16}[Rl])$
- `0x21`: `LD16 (Rr), Rl` / `ST16 (Rr), Rl` — $\text{Mem16}[Rr] \leftarrow Rl[15:0]$
- `0x22`: `LD16 Rr, (Rl++)` — Post-increment load halfword
- `0x23`: `LD16 (Rr++), Rl` / `ST16 (Rr++), Rl` — Post-increment store halfword
- `0x24`: `LD16 Rr, (--Rl)` — Pre-decrement load halfword
- `0x25`: `LD16 (--Rr), Rl` / `ST16 (--Rr), Rl` — Pre-decrement store halfword
- `0x26`: `LD16 Rr, (Rl + Imm4)` — Base + offset load halfword
- `0x27`: `LD16 (Rr + Imm4), Rl` / `ST16 (Rr + Imm4), Rl` — Base + offset store halfword
- `0x28`: `LD16 Rr, (SP + Imm4)` — Stack-relative load halfword
- `0x29`: `LD16 (SP + Imm4), Rl` / `ST16 (SP + Imm4), Rl` — Stack-relative store halfword

- `0x30`: `LD32 Rr, (Rl)` — $Rr \leftarrow \text{Mem32}[Rl]$
- `0x31`: `LD32 (Rr), Rl` / `ST32 (Rr), Rl` — $\text{Mem32}[Rr] \leftarrow Rl$
- `0x32`: `LD32 Rr, (Rl++)` — Post-increment load word
- `0x33`: `LD32 (Rr++), Rl` / `ST32 (Rr++), Rl` — Post-increment store word
- `0x34`: `LD32 Rr, (--Rl)` — Pre-decrement load word
- `0x35`: `LD32 (--Rr), Rl` / `ST32 (--Rr), Rl` — Pre-decrement store word
- `0x36`: `LD32 Rr, (Rl + Imm4)` — Base + offset load word
- `0x37`: `LD32 (Rr + Imm4), Rl` / `ST32 (Rr + Imm4), Rl` — Base + offset store word
- `0x38`: `LD32 Rr, (SP + Imm4)` — Stack-relative load word
- `0x39`: `LD32 (SP + Imm4), Rl` / `ST32 (SP + Imm4), Rl` — Stack-relative store word

### 4.3 Unsigned & Signed Arithmetic (0x40 - 0x57)
- `0x40`: `ADD Rr, Rl` — $Rr \leftarrow Rr + Rl$
- `0x41`: `SUB Rr, Rl` — $Rr \leftarrow Rr - Rl$
- `0x42`: `DIV Rr, Rl` — $Rr \leftarrow Rr / Rl$ (Unsigned integer divide)
- `0x43`: `MOD Rr, Rl` — $Rr \leftarrow Rr \pmod{Rl}$ (Unsigned remainder)
- `0x44`: `ADD Rr, Imm4` — $Rr \leftarrow Rr + Imm4$
- `0x45`: `SUB Rr, Imm4` — $Rr \leftarrow Rr - Imm4$
- `0x46`: `DIV Rr, Imm4` — $Rr \leftarrow Rr / Imm4$
- `0x47`: `MOD Rr, Imm4` — $Rr \leftarrow Rr \pmod{Imm4}$
- `0x48`: `NEG Rr` — Unary arithmetic negate: $Rr \leftarrow 0 - Rr$
- `0x50`: `SADD Rr, Rl` — Signed addition
- `0x51`: `SSUB Rr, Rl` — Signed subtraction
- `0x52`: `SDIV Rr, Rl` — Signed integer division
- `0x53`: `SMOD Rr, Rl` — Signed modulus remainder
- `0x54`: `SADD Rr, Imm4` — Signed addition with immediate
- `0x55`: `SSUB Rr, Imm4` — Signed subtraction with immediate
- `0x56`: `SDIV Rr, Imm4` — Signed division with immediate
- `0x57`: `SMOD Rr, Imm4` — Signed modulus with immediate

### 4.4 Logic, Shifts, Sign-Extension & Inversions (0x60 - 0x73)
- `0x60`: `SHIFTL Rr, Rl` — Logical left shift: $Rr \leftarrow Rr \ll (Rl \ \& \ 0x1F)$
- `0x61`: `SEXT8 Rr` — Sign extend byte: $Rr \leftarrow \text{sign\_ext8}(Rr[7:0])$
- `0x62`: `SHIFTR Rr, Rl` — Logical right shift: $Rr \leftarrow Rr \gg (Rl \ \& \ 0x1F)$
- `0x63`: `ASHIFTR Rr, Rl` — Arithmetic right shift: $Rr \leftarrow Rr \ggg (Rl \ \& \ 0x1F)$
- `0x64`: `ROTL Rr, Rl` — Rotate left
- `0x65`: `ROTR Rr, Rl` — Rotate right
- `0x66`: `AND Rr, Rl` — $Rr \leftarrow Rr \ \& \ Rl$
- `0x67`: `OR Rr, Rl` — $Rr \leftarrow Rr \mid Rl$
- `0x68`: `XOR Rr, Rl` — $Rr \leftarrow Rr \oplus Rl$
- `0x69`: `SHIFTL Rr, Imm4` — Logical left shift by immediate: $Rr \leftarrow Rr \ll Imm4$
- `0x6A`: `SEXT16 Rr` — Sign extend halfword: $Rr \leftarrow \text{sign\_ext16}(Rr[15:0])$
- `0x6B`: `SHIFTR Rr, Imm4` — Logical right shift by immediate: $Rr \leftarrow Rr \gg Imm4$
- `0x6C`: `ASHIFTR Rr, Imm4` — Arithmetic right shift by immediate: $Rr \leftarrow Rr \ggg Imm4$
- `0x6D`: `ROTL Rr, Imm4` — Rotate left by immediate
- `0x6E`: `ROTR Rr, Imm4` — Rotate right by immediate
- `0x6F`: `AND Rr, Imm4` — $Rr \leftarrow Rr \ \& \ Imm4$
- `0x70`: `OR Rr, Imm4` — $Rr \leftarrow Rr \mid Imm4$
- `0x71`: `XOR Rr, Imm4` — $Rr \leftarrow Rr \oplus Imm4$
- `0x72`: `NOT Rr` — Bitwise NOT: $Rr \leftarrow \sim Rr$
- `0x73`: `NEZ Rr` — Set on Not Equal Zero: $Rr \leftarrow (Rr \ne 0) \ ? \ 1 : 0$

### 4.5 Multipliers (0x78 - 0x7F)
- `0x78`: `MULL Rr, Rl` — Unsigned $32 \times 32 \to \text{Lower } 32$ bits
- `0x79`: `MULH Rr, Rl` — Unsigned $32 \times 32 \to \text{Upper } 32$ bits
- `0x7A`: `SMULH Rr, Rl` — Signed $32 \times 32 \to \text{Upper } 32$ bits
- `0x7B`: `MULHSU Rr, Rl` — Signed $\times$ Unsigned $32 \times 32 \to \text{Upper } 32$ bits
- `0x7C`: `MULL Rr, Imm4` — Lower 32-bit multiply by immediate
- `0x7D`: `MULH Rr, Imm4` — Unsigned high multiply by immediate
- `0x7E`: `SMULH Rr, Imm4` — Signed high multiply by immediate
- `0x7F`: `MULHSU Rr, Imm4` — Signed $\times$ Unsigned high multiply by immediate

### 4.6 Bit Manipulation, System Operations & Endian Swapping (0x80 - 0x8C)
- `0x80`: `BEXTR Rr, Rl` — Bit extract: $Rr \leftarrow (Rr \gg (Rl \ \& \ 0x1F)) \ \& \ 1$
- `0x81`: `JTBL Rr, Rl` — Jump table dispatch: $PC \leftarrow (PC + 2) + (Rr \times 2)$
- `0x82`: `CLZ Rr, Rl` — Count leading zeros of $Rr$
- `0x83`: `BSET Rr, Rl` — Bit set: $Rr \leftarrow Rr \mid (1 \ll (Rl \ \& \ 0x1F))$
- `0x84`: `BSET Rr, Imm4` — Bit set by immediate: $Rr \leftarrow Rr \mid (1 \ll Imm4)$
- `0x85`: `BCLR Rr, Rl` — Bit clear: $Rr \leftarrow Rr \ \& \ \sim(1 \ll (Rl \ \& \ 0x1F))$
- `0x86`: `BCLR Rr, Imm4` — Bit clear by immediate: $Rr \leftarrow Rr \ \& \ \sim(1 \ll Imm4)$
- `0x87`: `BINV Rr, Rl` — Bit invert: $Rr \leftarrow Rr \oplus (1 \ll (Rl \ \& \ 0x1F))$
- `0x88`: `BINV Rr, Imm4` — Bit invert by immediate: $Rr \leftarrow Rr \oplus (1 \ll Imm4)$
- `0x89`: `BGET Rr, Rl` — Bit get: $Rr \leftarrow (Rr \gg (Rl \ \& \ 0x1F)) \ \& \ 1$
- `0x8A`: `BGET Rr, Imm4` — Bit get by immediate: $Rr \leftarrow (Rr \gg Imm4) \ \& \ 1$
- `0x8B`: `TAS (Rr), Rl` — Atomic Test-and-Set / Swap
- `0x8C`: `REV32 Rr` — Endianness byte-swap: $Rr \leftarrow \{Rr[7:0], Rr[15:8], Rr[23:16], Rr[31:24]\}$

### 4.7 Relational Comparisons (0x90 - 0x9D)
- `0x90`: `SLT Rr, Rl` — Unsigned less than: $Rr \leftarrow (Rr_{\text{unsigned}} < Rl_{\text{unsigned}}) \ ? \ 1 : 0$
- `0x91`: `SLT Rr, Imm4` — Unsigned less than immediate
- `0x92`: `SLT Rr, -Imm4` — Unsigned less than negative immediate
- `0x93`: `SLT R14, Imm8` — Unsigned less than 8-bit immediate
- `0x94`: `SLT R14, -Imm8` — Unsigned less than negative 8-bit immediate
- `0x95`: `SSLT Rr, Rl` — Signed less than: $Rr \leftarrow (Rr_{\text{signed}} < Rl_{\text{signed}}) \ ? \ 1 : 0$
- `0x96`: `SSLT Rr, Imm4` — Signed less than immediate
- `0x97`: `SSLT Rr, -Imm4` — Signed less than negative immediate
- `0x98`: `SSLT R14, Imm8` — Signed less than 8-bit immediate
- `0x99`: `SSLT R14, -Imm8` — Signed less than negative 8-bit immediate
- `0x9A`: `SEQ Rr, Rl` — Set on Equal: $Rr \leftarrow (Rr == Rl) \ ? \ 1 : 0$
- `0x9B`: `SNE Rr, Rl` — Set on Not Equal: $Rr \leftarrow (Rr \ne Rl) \ ? \ 1 : 0$
- `0x9C`: `SLE Rr, Rl` — Set on Less/Equal (Unsigned): $Rr \leftarrow (Rr_{\text{unsigned}} \le Rl_{\text{unsigned}}) \ ? \ 1 : 0$
- `0x9D`: `SSLE Rr, Rl` — Set on Less/Equal (Signed): $Rr \leftarrow (Rr_{\text{signed}} \le Rl_{\text{signed}}) \ ? \ 1 : 0$

### 4.8 Control Flow (0xA0 - 0xA4)
- `0xA0`: `JMP Rr, Rl` — Indirect Jump and Link ($Rl \leftarrow PC + 2; PC \leftarrow Rr$)
- `0xA1`: `RJUMP Rr, Rl` — Relative Jump and Link ($Rl \leftarrow PC + 2; PC \leftarrow PC + (Rr \times 2)$)
- `0xA2`: `TRAP Rr` — Enter trap vector indexed by $Rr$
- `0xA3`: `TRAP Imm4` — Enter trap vector indexed by immediate
- `0xA4`: `BRANCH Rr` — Relative Branch without linking ($PC \leftarrow PC + (\text{signed}(Rr) \times 2)$)

### 4.9 Relative Branches (0xB0 - 0xCB)
Displacements shift left by 1 (halfword instruction units).

#### Forward Branches (0xB0 - 0xBB)
- `0xB0`: `FBRA Imm8` — Unconditional forward branch: $PC \leftarrow PC + (Imm8 \times 2)$
- `0xB4`: `FBRA.Z Rr, Imm4` — If $Rr == 0$: $PC \leftarrow PC + (Imm4 \times 2)$
- `0xB5`: `FBRA.N Rr, Imm4` — If $Rr < 0$ (Bit 31 is 1): $PC \leftarrow PC + (Imm4 \times 2)$
- `0xB6`: `FBRA.P Rr, Imm4` — If $Rr > 0$ (Signed positive): $PC \leftarrow PC + (Imm4 \times 2)$
- `0xB7`: `FBRA.Z R14, Imm8` — If $R14 == 0$: $PC \leftarrow PC + (Imm8 \times 2)$
- `0xB8`: `FBRA.N R14, Imm8` — If $R14 < 0$: $PC \leftarrow PC + (Imm8 \times 2)$
- `0xB9`: `FBRA.P R14, Imm8` — If $R14 > 0$: $PC \leftarrow PC + (Imm8 \times 2)$
- `0xBA`: `FBRA.NZ Rr, Imm4` — If $Rr \ne 0$: $PC \leftarrow PC + (Imm4 \times 2)$
- `0xBB`: `FBRA.NZ R14, Imm8` — If $R14 \ne 0$: $PC \leftarrow PC + (Imm8 \times 2)$

#### Backward Branches (0xC0 - 0xCB)
- `0xC0`: `BBRA Imm8` — Unconditional backward branch: $PC \leftarrow PC - (Imm8 \times 2)$
- `0xC4`: `BBRA.Z Rr, Imm4` — If $Rr == 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xC5`: `BBRA.N Rr, Imm4` — If $Rr < 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xC6`: `BBRA.P Rr, Imm4` — If $Rr > 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xC7`: `BBRA.Z R14, Imm8` — If $R14 == 0$: $PC \leftarrow PC - (Imm8 \times 2)$
- `0xC8`: `BBRA.N R14, Imm8` — If $R14 < 0$: $PC \leftarrow PC - (Imm8 \times 2)$
- `0xC9`: `BBRA.P R14, Imm8` — If $R14 > 0$: $PC \leftarrow PC - (Imm8 \times 2)$
- `0xCA`: `BBRA.NZ Rr, Imm4` — If $Rr \ne 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xCB`: `BBRA.NZ R14, Imm8` — If $R14 \ne 0$: $PC \leftarrow PC - (Imm8 \times 2)$

### 4.10 Context, Register Windowing & Interconnect Operations (0xD0 - 0xE5)
- `0xD0`: `XCHG Rr` — Exchange active $Rr$ with shadow register $Sr$
- `0xD1`: `XCHGALL` — Swap $R1$–$R15$ with $S1$–$S15$
- `0xD2`: `XCHGMOST` — Fast interrupt context swap: swap $R1$–$R14$ with $S1$–$S14$ (preserving $SP$)
- `0xD3`: `RBASE Imm8` — Set register bank window offset ($rbase \leftarrow Imm8[4:0]$)
- `0xD4`: `RBASE Rr` — Set register bank window offset dynamically ($rbase \leftarrow Rr[4:0]$)
- `0xE0`: `FIFO.R Rr, Chan` — Blocking read from streaming FIFO channel (stalls pipeline until data valid)
- `0xE1`: `FIFO.W Rr, Chan` — Write word to streaming FIFO channel
- `0xE2`: `FIFO.STAT Rr, Chan` — Read channel FIFO status word (`bit[0]` = empty, `bit[1]` = full)
- `0xE3`: `FIFO.TRYR Rr, Chan` — Non-blocking read (returns 0 if channel empty)
- `0xE4`: `FIFO.TRYW Rr, Chan` — Non-blocking write to channel
- `0xE5`: `MBOX Rr, Vector` — Trigger cross-core hardware strobe interrupt to target core $Rr$ with 4-bit vector