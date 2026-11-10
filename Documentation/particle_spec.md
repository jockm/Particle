# Particle Processor Architecture & System Engineering Specification

## 1. Overview
Particle is a high-efficiency 32-bit load/store RISC processor architecture utilizing compact, fixed-width 16-bit instructions, inspired by the Hitachi SH-2, ARM Thumb, and MiniRISC4 architectures. It is implemented in pure Intel ROHD (Rapid Open Hardware Development in Dart) without legacy Verilog codebases, synthesizing directly to SystemVerilog for modern FPGA platforms (such as Lattice ECP5 on the ULX3S).

This revision of the specification is aligned with the reference simulator `psim.py`. Where the two disagree, the simulator's behaviour is normative.

---

## 2. Register & Execution Architecture
- **Registers**: 16 native 32-bit general-purpose registers:
  - `R0`: Hardwired Constant Zero. Reads return `0x00000000`; writes are safely discarded.
  - `R1`–`R4`: Function argument passing and return value registers (Caller-saved).
  - `R5`–`R10`: Preserved general-purpose registers (Callee-saved).
  - `R11`–`R13`: Scratchpad / temporary registers (Caller-saved).
  - `R14`: Subroutine link register (`JMP`/`RJUMP` link, `RCALL`/`RRET` aliases), immediate accumulator, trap link register, and FIFO try-status register.
  - `R15` (`SP`): Architectural stack pointer (full-descending, 4-byte aligned).
- **Hardware Shadow Register Bank**:
  - 16 duplicate 32-bit shadow registers (`S0`–`S15`).
  - Single-cycle exchange operations:
    - `XCHG Rr`: Swaps active `Rr` with `Sr` (`XCHG R0` is a no-op).
    - `XCHGALL`: Swaps `R1`–`R15` with `S1`–`S15`.
    - `XCHGMOST`: Swaps `R1`–`R14` with `S1`–`S14` while preserving `SP` (`R15`) for instantaneous zero-memory-spill interrupt/trap entry.
- **RBASE Register Windowing**:
  - Shifts logical register index decoding into a 32-register physical file (`R0` remains fixed at physical 0; `R1`–`R15` map to physical `(index + rbase) mod 32`).
  - `RBASE Imm8` (`0xD3`): Load window offset from constant ($rbase \leftarrow Imm8[4:0]$).
  - `RBASE Rr` (`0xD4`): Load window offset dynamically from register ($rbase \leftarrow Rr[4:0]$).
- **Flagless Design**: No traditional ALU condition code flags. Branching evaluates registers directly (`FBRA.Z`, `FBRA.NZ`, `FBRA.P`, `BBRA.Z`, etc.), while relational evaluations yield integer boolean results (`0` or `1`) directly in destination registers.
- **Immediates**: `Imm4` and `Imm8` are zero-extended unless an instruction is marked **(signed imm)**, in which case `Imm4` is sign-extended to $-8 \ldots 7$ and `Imm8` to $-128 \ldots 127$. The `-Imm4` / `-Imm8` forms encode a magnitude ($0 \ldots 15$ / $0 \ldots 255$) and use its negation.
- **Alignment**: Instruction fetch requires an even PC. 16-bit memory accesses require 2-byte alignment and 32-bit accesses require 4-byte alignment; a misaligned access or fetch raises Vector 14. Byte accesses have no alignment requirement.
- **Endianness**: Little-endian (instructions and data).

---

## 3. Direct Stride Vector Table
Vectors are computed without indirect pointer memory fetches using a direct 64-byte (32-instruction) stride:
$$\text{Target} = \text{TRAP\_TABLE\_BASE} + (\text{Vector} \times 64)$$

- Base Address: `0x00000100`
- Stride: 64 bytes (`0x40`)
- Vector 0 (`0x00000100`): Cold Power-On Reset (reset PC)
- Vector 1 (`0x00000140`): Inbound MBOX / Inter-Core Hardware Strobe Notification
- Vectors 2–13 (`0x00000180`–`0x0000047F`): Software & User-defined Traps
- Vector 14 (`0x00000480`): Memory Bus Misalignment Fault
- Vector 15 (`0x000004C0`): Undefined / Illegal Opcode Decoded

**Trap entry**: $R14 \leftarrow \text{return PC}$; $PC \leftarrow \text{Target}$. For `TRAP` instructions the return PC is the following instruction ($PC + 2$). For a misalignment fault the return PC is the address of the faulting instruction.

---

## 4. Complete Instruction Set Architecture (ISA) Map
Instructions are 16 bits wide: `[15:8] Opcode`, `[7:4] Rr`, `[3:0] Rl / Imm4`. Imm8 forms use `[7:0]` for the immediate and operate implicitly on `R14`. In `pasm.py`, stores are assembled using load mnemonics with a memory destination (`LD32 (Rr), Rl`) or `ST*` mnemonics.

### 4.1 Loads & Immediates (0x00 - 0x06)
- `0x00`: `LD Rr, Rl` — $Rr \leftarrow Rl$ (`LD R0, R0` = `0x0000` is the canonical NOP)
- `0x01`: `LD Rr, Imm4` — $Rr \leftarrow \text{zero\_ext}(Imm4)$
- `0x02`: `LD R14, Imm8` — $R14 \leftarrow \text{zero\_ext}(Imm8)$
- `0x03`: `LD Rr, -Imm4` — $Rr \leftarrow -Imm4$
- `0x04`: `LD R14, -Imm8` — $R14 \leftarrow -Imm8$
- `0x05`: `PUSH4 Rr, Imm4` — $Rr \leftarrow (Rr \ll 4) \mid Imm4$
- `0x06`: `PUSH8 R14, Imm8` — $R14 \leftarrow (R14 \ll 8) \mid Imm8$

### 4.2 Memory Loads & Stores (0x10 - 0x39)
Register-indirect addressing only (no displacement modes). Each width uses the same ten-slot layout; increment/decrement steps equal the access size (1, 2, or 4 bytes). Loads write `Rr` from memory addressed by `Rl`; stores write `Rl` to memory addressed by `Rr`. Byte and halfword loads zero-extend.

| Offset | Form | Semantics |
|---|---|---|
| `+0` | `LDx Rr, (Rl)` | $Rr \leftarrow \text{Mem}[Rl]$ |
| `+1` | `LDx Rr, (++Rl)` | $Rl \leftarrow Rl + n;\ Rr \leftarrow \text{Mem}[Rl]$ |
| `+2` | `LDx Rr, (Rl++)` | $Rr \leftarrow \text{Mem}[Rl];\ Rl \leftarrow Rl + n$ |
| `+3` | `LDx Rr, (--Rl)` | $Rl \leftarrow Rl - n;\ Rr \leftarrow \text{Mem}[Rl]$ |
| `+4` | `LDx Rr, (Rl--)` | $Rr \leftarrow \text{Mem}[Rl];\ Rl \leftarrow Rl - n$ |
| `+5` | `STx (Rr), Rl` | $\text{Mem}[Rr] \leftarrow Rl$ |
| `+6` | `STx (++Rr), Rl` | $Rr \leftarrow Rr + n;\ \text{Mem}[Rr] \leftarrow Rl$ |
| `+7` | `STx (Rr++), Rl` | $\text{Mem}[Rr] \leftarrow Rl;\ Rr \leftarrow Rr + n$ |
| `+8` | `STx (--Rr), Rl` | $Rr \leftarrow Rr - n;\ \text{Mem}[Rr] \leftarrow Rl$ |
| `+9` | `STx (Rr--), Rl` | $\text{Mem}[Rr] \leftarrow Rl;\ Rr \leftarrow Rr - n$ |

Register-update ordering: the address register is updated before the data register is written (loads) or read (stores). With `Rr = Rl`, an indexed load leaves the loaded value in the register, and an indexed store writes the *updated* address. Software should not rely on either case.

#### 8-bit (n = 1)
- `0x10`: `LD8 Rr, (Rl)`
- `0x11`: `LD8 Rr, (++Rl)` — Pre-increment load byte
- `0x12`: `LD8 Rr, (Rl++)` — Post-increment load byte
- `0x13`: `LD8 Rr, (--Rl)` — Pre-decrement load byte
- `0x14`: `LD8 Rr, (Rl--)` — Post-decrement load byte
- `0x15`: `ST8 (Rr), Rl` / `LD8 (Rr), Rl` — $\text{Mem8}[Rr] \leftarrow Rl[7:0]$
- `0x16`: `ST8 (++Rr), Rl` — Pre-increment store byte
- `0x17`: `ST8 (Rr++), Rl` — Post-increment store byte
- `0x18`: `ST8 (--Rr), Rl` — Pre-decrement store byte
- `0x19`: `ST8 (Rr--), Rl` — Post-decrement store byte

#### 16-bit (n = 2)
- `0x20`: `LD16 Rr, (Rl)`
- `0x21`: `LD16 Rr, (++Rl)` — Pre-increment load halfword
- `0x22`: `LD16 Rr, (Rl++)` — Post-increment load halfword
- `0x23`: `LD16 Rr, (--Rl)` — Pre-decrement load halfword
- `0x24`: `LD16 Rr, (Rl--)` — Post-decrement load halfword
- `0x25`: `ST16 (Rr), Rl` / `LD16 (Rr), Rl` — $\text{Mem16}[Rr] \leftarrow Rl[15:0]$
- `0x26`: `ST16 (++Rr), Rl` — Pre-increment store halfword
- `0x27`: `ST16 (Rr++), Rl` — Post-increment store halfword
- `0x28`: `ST16 (--Rr), Rl` — Pre-decrement store halfword
- `0x29`: `ST16 (Rr--), Rl` — Post-decrement store halfword

#### 32-bit (n = 4)
- `0x30`: `LD32 Rr, (Rl)`
- `0x31`: `LD32 Rr, (++Rl)` — Pre-increment load word
- `0x32`: `LD32 Rr, (Rl++)` — Post-increment load word (stack pop: `LD32 Rr, (SP++)`)
- `0x33`: `LD32 Rr, (--Rl)` — Pre-decrement load word
- `0x34`: `LD32 Rr, (Rl--)` — Post-decrement load word
- `0x35`: `ST32 (Rr), Rl` / `LD32 (Rr), Rl` — $\text{Mem32}[Rr] \leftarrow Rl$
- `0x36`: `ST32 (++Rr), Rl` — Pre-increment store word
- `0x37`: `ST32 (Rr++), Rl` — Post-increment store word
- `0x38`: `ST32 (--Rr), Rl` — Pre-decrement store word (stack push: `ST32 (--SP), Rl`)
- `0x39`: `ST32 (Rr--), Rl` — Post-decrement store word

### 4.3 Unsigned & Signed Arithmetic (0x40 - 0x57)
- `0x40`: `ADD Rr, Rl` — $Rr \leftarrow Rr + Rl$
- `0x41`: `SUB Rr, Rl` — $Rr \leftarrow Rr - Rl$
- `0x42`: `DIV Rr, Rl` — $Rr \leftarrow Rr / Rl$ (Unsigned; $\div 0 \rightarrow$ `0xFFFFFFFF`)
- `0x43`: `MOD Rr, Rl` — $Rr \leftarrow Rr \bmod Rl$ (Unsigned; $\bmod 0 \rightarrow Rr$ unchanged)
- `0x44`: `ADD Rr, Imm4` — $Rr \leftarrow Rr + Imm4$
- `0x45`: `SUB Rr, Imm4` — $Rr \leftarrow Rr - Imm4$
- `0x46`: `DIV Rr, Imm4` — $Rr \leftarrow Rr / Imm4$ ($\div 0 \rightarrow$ `0xFFFFFFFF`)
- `0x47`: `MOD Rr, Imm4` — $Rr \leftarrow Rr \bmod Imm4$ ($\bmod 0 \rightarrow Rr$)
- `0x48`: `NEG Rr` — Unary arithmetic negate: $Rr \leftarrow 0 - Rr$
- `0x50`: `SADD Rr, Rl` — Signed addition (32-bit result identical to `ADD`; no overflow trap)
- `0x51`: `SSUB Rr, Rl` — Signed subtraction (32-bit result identical to `SUB`; no overflow trap)
- `0x52`: `SDIV Rr, Rl` — Signed division, truncating toward zero ($\div 0 \rightarrow -1$)
- `0x53`: `SMOD Rr, Rl` — Signed remainder, sign of dividend ($\bmod 0 \rightarrow Rr$)
- `0x54`: `SADD Rr, Imm4` — **(signed imm)** $Rr \leftarrow Rr + \text{sext}(Imm4)$
- `0x55`: `SSUB Rr, Imm4` — **(signed imm)** $Rr \leftarrow Rr - \text{sext}(Imm4)$
- `0x56`: `SDIV Rr, Imm4` — **(signed imm)** Signed division by $\text{sext}(Imm4)$ ($\div 0 \rightarrow -1$)
- `0x57`: `SMOD Rr, Imm4` — **(signed imm)** Signed remainder by $\text{sext}(Imm4)$ ($\bmod 0 \rightarrow Rr$)

### 4.4 Logic, Shifts, Sign-Extension & Inversions (0x60 - 0x73)
- `0x60`: `SHIFTL Rr, Rl` — Logical left shift: $Rr \leftarrow Rr \ll (Rl \ \& \ 0x1F)$
- `0x61`: `SEXT8 Rr` — Sign extend byte: $Rr \leftarrow \text{sign\_ext8}(Rr[7:0])$
- `0x62`: `SHIFTR Rr, Rl` — Logical right shift: $Rr \leftarrow Rr \gg (Rl \ \& \ 0x1F)$
- `0x63`: `ASHIFTR Rr, Rl` — Arithmetic right shift: $Rr \leftarrow Rr \ggg (Rl \ \& \ 0x1F)$
- `0x64`: `ROTL Rr, Rl` — Rotate left by $(Rl \ \& \ 0x1F)$
- `0x65`: `ROTR Rr, Rl` — Rotate right by $(Rl \ \& \ 0x1F)$
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
- `0x78`: `MULL Rr, Rl` — $32 \times 32 \to \text{Lower } 32$ bits
- `0x79`: `MULH Rr, Rl` — Unsigned $32 \times 32 \to \text{Upper } 32$ bits
- `0x7A`: `SMULH Rr, Rl` — Signed $32 \times 32 \to \text{Upper } 32$ bits
- `0x7B`: `MULHSU Rr, Rl` — Signed $Rr$ $\times$ Unsigned $Rl$ $\to \text{Upper } 32$ bits
- `0x7C`: `MULL Rr, Imm4` — Lower 32-bit multiply by immediate
- `0x7D`: `MULH Rr, Imm4` — Unsigned high multiply by immediate
- `0x7E`: `SMULH Rr, Imm4` — **(signed imm)** Signed high multiply by $\text{sext}(Imm4)$
- `0x7F`: `MULHSU Rr, Imm4` — Signed $Rr$ $\times$ unsigned $Imm4$ high multiply

### 4.6 Bit Manipulation, System Operations & Endian Swapping (0x80 - 0x8C)
- `0x80`: `BEXTR Rr, Rl` — Bit-field extract: $pos = Rl[4:0]$, $len = Rl[9:5]$; $Rr \leftarrow (Rr \gg pos) \ \& \ ((1 \ll len) - 1)$
- `0x81`: `JTBL Rr` — Jump table dispatch: $PC \leftarrow (PC + 2) + (Rr \times 2)$ (`Rl` field ignored)
- `0x82`: `CLZ Rr, Rl` — Count leading zeros: $Rr \leftarrow \text{clz}(Rl)$; $\text{clz}(0) = 32$
- `0x83`: `BSET Rr, Rl` — Bit set: $Rr \leftarrow Rr \mid (1 \ll (Rl \ \& \ 0x1F))$
- `0x84`: `BSET Rr, Imm4` — Bit set by immediate: $Rr \leftarrow Rr \mid (1 \ll Imm4)$
- `0x85`: `BCLR Rr, Rl` — Bit clear: $Rr \leftarrow Rr \ \& \ \sim(1 \ll (Rl \ \& \ 0x1F))$
- `0x86`: `BCLR Rr, Imm4` — Bit clear by immediate: $Rr \leftarrow Rr \ \& \ \sim(1 \ll Imm4)$
- `0x87`: `BINV Rr, Rl` — Bit invert: $Rr \leftarrow Rr \oplus (1 \ll (Rl \ \& \ 0x1F))$
- `0x88`: `BINV Rr, Imm4` — Bit invert by immediate: $Rr \leftarrow Rr \oplus (1 \ll Imm4)$
- `0x89`: `BGET Rr, Rl` — Bit get: $Rr \leftarrow (Rr \gg (Rl \ \& \ 0x1F)) \ \& \ 1$
- `0x8A`: `BGET Rr, Imm4` — Bit get by immediate: $Rr \leftarrow (Rr \gg Imm4) \ \& \ 1$
- `0x8B`: `TAS (Rr), Rl` — Atomic 32-bit swap: $tmp \leftarrow \text{Mem32}[Rr];\ \text{Mem32}[Rr] \leftarrow Rl;\ Rl \leftarrow tmp$ (word-aligned)
- `0x8C`: `REV32 Rr` — Endianness byte-swap: $Rr \leftarrow \{Rr[7:0], Rr[15:8], Rr[23:16], Rr[31:24]\}$

### 4.7 Relational Comparisons (0x90 - 0x9D)
- `0x90`: `SLT Rr, Rl` — Unsigned less than: $Rr \leftarrow (Rr_{\text{unsigned}} < Rl_{\text{unsigned}}) \ ? \ 1 : 0$
- `0x91`: `SLT Rr, Imm4` — Unsigned less than $Imm4$ ($0 \ldots 15$)
- `0x92`: `SLT Rr, -Imm4` — Unsigned less than $(2^{32} - Imm4)$
- `0x93`: `SLT R14, Imm8` — Unsigned less than $Imm8$ ($0 \ldots 255$)
- `0x94`: `SLT R14, -Imm8` — Unsigned less than $(2^{32} - Imm8)$
- `0x95`: `SSLT Rr, Rl` — Signed less than: $Rr \leftarrow (Rr_{\text{signed}} < Rl_{\text{signed}}) \ ? \ 1 : 0$
- `0x96`: `SSLT Rr, Imm4` — **(signed imm)** Signed less than $\text{sext}(Imm4)$ ($-8 \ldots 7$)
- `0x97`: `SSLT Rr, -Imm4` — Signed less than $-Imm4$ ($0 \ldots -15$)
- `0x98`: `SSLT R14, Imm8` — **(signed imm)** Signed less than $\text{sext}(Imm8)$ ($-128 \ldots 127$)
- `0x99`: `SSLT R14, -Imm8` — Signed less than $-Imm8$ ($0 \ldots -255$)
- `0x9A`: `SEQ Rr, Rl` — Set on Equal: $Rr \leftarrow (Rr == Rl) \ ? \ 1 : 0$
- `0x9B`: `SNE Rr, Rl` — Set on Not Equal: $Rr \leftarrow (Rr \ne Rl) \ ? \ 1 : 0$
- `0x9C`: `SLE Rr, Rl` — Set on Less/Equal (Unsigned): $Rr \leftarrow (Rr_{\text{unsigned}} \le Rl_{\text{unsigned}}) \ ? \ 1 : 0$
- `0x9D`: `SSLE Rr, Rl` — Set on Less/Equal (Signed): $Rr \leftarrow (Rr_{\text{signed}} \le Rl_{\text{signed}}) \ ? \ 1 : 0$

### 4.8 Control Flow (0xA0 - 0xA4)
All PC-relative targets below are relative to the address of the instruction itself (written $PC$).
- `0xA0`: `JMP Rr, Rl` — Indirect Jump and Link: $tmp \leftarrow Rr;\ Rl \leftarrow PC + 2;\ PC \leftarrow tmp$. `Rr` is read before `Rl` is written, so `JMP R14, R14` is valid.
  - Alias `RCALL Rr` = `JMP Rr, R14`; alias `RRET` = `JMP R14, R0`.
- `0xA1`: `RJUMP Rr, Rl` — Relative Jump and Link: $Rl \leftarrow PC + 2;\ PC \leftarrow PC + (\text{signed}(Rr) \times 2)$
- `0xA2`: `TRAP Rr` — Enter trap vector $Rr[3:0]$; $R14 \leftarrow PC + 2$
- `0xA3`: `TRAP Imm4` — Enter trap vector $Imm4$; $R14 \leftarrow PC + 2$
- `0xA4`: `BRANCH Rr` — Relative branch without linking: $PC \leftarrow PC + (\text{signed}(Rr) \times 2)$

### 4.9 Relative Branches (0xB0 - 0xCB)
Displacements are unsigned halfword counts added to (forward) or subtracted from (backward) the address of the branch instruction itself. A displacement of 0 branches to itself.

#### Forward Branches (0xB0 - 0xBB)
- `0xB0`: `FBRA Imm8` — Unconditional forward branch: $PC \leftarrow PC + (Imm8 \times 2)$
- `0xB1`: `FBRA.Z Rr, Rl` — If $Rr == 0$: $PC \leftarrow PC + (Rl \times 2)$
- `0xB2`: `FBRA.N Rr, Rl` — If $Rr < 0$: $PC \leftarrow PC + (Rl \times 2)$
- `0xB3`: `FBRA.P Rr, Rl` — If $Rr > 0$: $PC \leftarrow PC + (Rl \times 2)$
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
- `0xC1`: `BBRA.Z Rr, Rl` — If $Rr == 0$: $PC \leftarrow PC - (Rl \times 2)$
- `0xC2`: `BBRA.N Rr, Rl` — If $Rr < 0$: $PC \leftarrow PC - (Rl \times 2)$
- `0xC3`: `BBRA.P Rr, Rl` — If $Rr > 0$: $PC \leftarrow PC - (Rl \times 2)$
- `0xC4`: `BBRA.Z Rr, Imm4` — If $Rr == 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xC5`: `BBRA.N Rr, Imm4` — If $Rr < 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xC6`: `BBRA.P Rr, Imm4` — If $Rr > 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xC7`: `BBRA.Z R14, Imm8` — If $R14 == 0$: $PC \leftarrow PC - (Imm8 \times 2)$
- `0xC8`: `BBRA.N R14, Imm8` — If $R14 < 0$: $PC \leftarrow PC - (Imm8 \times 2)$
- `0xC9`: `BBRA.P R14, Imm8` — If $R14 > 0$: $PC \leftarrow PC - (Imm8 \times 2)$
- `0xCA`: `BBRA.NZ Rr, Imm4` — If $Rr \ne 0$: $PC \leftarrow PC - (Imm4 \times 2)$
- `0xCB`: `BBRA.NZ R14, Imm8` — If $R14 \ne 0$: $PC \leftarrow PC - (Imm8 \times 2)$

### 4.10 Context, Register Windowing & Interconnect Operations (0xD0 - 0xE7)
- `0xD0`: `XCHG Rr` — Exchange active $Rr$ with shadow register $Sr$
- `0xD1`: `XCHGALL` — Swap $R1$–$R15$ with $S1$–$S15$
- `0xD2`: `XCHGMOST` — Fast interrupt context swap: swap $R1$–$R14$ with $S1$–$S14$ (preserving $SP$)
- `0xD3`: `RBASE Imm8` — Set register bank window offset ($rbase \leftarrow Imm8[4:0]$)
- `0xD4`: `RBASE Rr` — Set register bank window offset dynamically ($rbase \leftarrow Rr[4:0]$)

FIFO channels are 256 entries deep. A channel number is taken modulo the number of implemented channels.
- `0xE0`: `FIFO.R Rr, Chan` — Blocking read from channel `Chan` (Imm4); stalls until data is available
- `0xE1`: `FIFO.W Rr, Chan` — Write `Rr` to channel `Chan` (Imm4); dropped if the channel is full
- `0xE4`: `FIFO.STAT Rr, Rl` — Status of channel `Rl` into `Rr`
- `0xE5`: `FIFO.STAT Rr, Chan` — Status of channel `Chan` (Imm4) into `Rr`
  - Status word: `bit[0]` = empty, `bit[1]` = full, `bits[16:8]` = current entry count
- `0xE6`: `FIFO.TRYR Rr, Rl` — Non-blocking read from channel `Rl`: if data, $Rr \leftarrow$ data and $R14 \leftarrow 1$; else $R14 \leftarrow 0$ ($Rr$ unchanged)
- `0xE7`: `FIFO.TRYW Rr, Rl` — Non-blocking write of `Rr` to channel `Rl`: $R14 \leftarrow 1$ if accepted, $0$ if full

---

## 5. Reference Simulator Conventions (`psim.py`)
These behaviours are specific to the simulator and are not architectural:
- Channel 0 is the console: `FIFO.W` to channel 0 prints `Rr[7:0]` to stdout, and `FIFO.R` on an empty channel 0 polls stdin.
- `TRAP 14` halts the simulation (debug quit, reporting `R1`), and `TRAP 15` halts as an out-of-bounds / sentinel trap. Misaligned accesses therefore also halt.
- Execution stops if the PC leaves simulated memory (default 128 KiB, address-wrapped for data accesses).
- Opcodes not listed in this document execute as no-ops in the simulator; on hardware they raise Vector 15.

---

## Revision Notes
Aligned with `psim.py`:
- §4.2: Memory opcode layout replaced. Pre-increment and post-decrement forms were added. The base+offset and SP+offset forms were removed.
- §4.10: FIFO opcodes moved to `0xE4`–`0xE7`. Register-channel forms were added, and TRYR/TRYW now report status in R14.
- §4.9: Register-displacement branches `0xB1`–`0xB3` / `0xC1`–`0xC3` were added. Displacements are now defined relative to the branch address.
- §4.6: BEXTR is now a bit-field extract. CLZ and TAS are now fully specified. JTBL takes only `Rr`.
- §4.3 / §4.5 / §4.7: Signed-immediate forms were marked. Divide-by-zero results were defined.
- §3: Trap entry writes R14.
