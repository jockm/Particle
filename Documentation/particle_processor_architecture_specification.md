I am starting a brand-new, standalone CPU and toolchain project called "Particle".

Below is the complete architectural specification for Particle (`particle_spec.md`). 
Review it thoroughly and keep all invariants in mind:

### Strict Architectural Invariants & Rules:
1. PURE ROHD (DART): The hardware implementation must use Intel ROHD in Dart (sdk >= 3.0.0). No Verilog or SystemVerilog source code should be written.
2. NO CODE YET: Do not generate any project files, Dart code, or Python scripts in this turn. First, confirm your understanding, list any architectural edge cases or ambiguities, and provide an initial phased implementation roadmap.
3. COMMENT PRESERVATION: All delivered files must include full documentation headers, register conventions, and detailed inline comments. Never strip, shorten, or compress comments.
4. INDEPENDENT TOOLING: The toolchain consists of:
   - `pasm.py`: Two-pass macro assembler supporting `.if/.else/.endif`, `.ifdef/.ifndef`, and macro expansions.
   - `psim.py`: Instruction-accurate Python simulator with an interactive debugger.
   - `act16c.py`: High-level systems compiler supporting signed and unsigned 8-, 16-, and 32-bit types (`u8`, `s8`, `u16`, `s16`, `u32`, `s32`).
   - `lib/common.inc`: Standard macros including tiered immediate loads (`LOAD16`, `LOAD24`, `LOAD32`).
5. INCREMENTAL DELIVERY: Once we finalize the roadmap, we will build the project one component at a time (Project scaffolding -> Toolchain -> Core ROHD datapath -> Verification).

---
## 1. System Overview & Architectural Philosophy

**Particle** is a 32-bit load/store RISC processor architecture utilizing compact 16-bit instructions, inspired by the Hitachi SH-2, ARM Thumb, and lessons learned from the MiniRISC4 computing fabric. It is targeted for synthesis on modern FPGAs (specifically Lattice ECP5 on the ULX3S platform and modern SoC FPGAs) and implemented cleanly in **Intel ROHD (Rapid Open Hardware Development in Dart)** without legacy Verilog codebases.

### 1.1 Key Architectural Dimensions

* **Word Size**: Native 32-bit datapath, registers, arithmetic units, and address space.
* **Unified Memory System**: Byte-addressed, unified code/data address space mapped to an on-chip True Dual-Port (TDP) Block RAM.
  * **Port A**: Synchronous instruction fetch port (driven by the Program Counter, $PC[0] = 0$).
  * **Port B**: Synchronous data read/write, MMIO, and atomic access port.
* **Instruction Format**: Fixed 16-bit instruction encoding, fetched sequentially on Port A without slot packing.
* **Register File**: 16 registers ($R0$–$R15$) of 32-bit width, paired with dedicated hardware shadow banks.
* **Direct Stride Vectoring**: Hardware reset and exception vectors utilize a 32-instruction (64-byte) stride per slot, jumping directly to handler code without indirect memory pointer reads.
* **Multi-Core & Streaming Support**: Native point-to-point hardware FIFO instructions (`FIFO.R`, `FIFO.W`, `FIFO.STAT`, `FIFO.TRYR`, `FIFO.TRYW`) and cross-core hardware strobe signaling (`MBOX`).

## 2. Register File & Architectural State

| Register | Width | Architectural Role & Conventions |
| :--- | :--- | :--- |
| **R0** | 32-bit | **Hardwired Zero**: Always reads as `0x00000000`. Writes to `R0` are discarded (used to discard links or evaluation side-effects). |
| **R1 – R13** | 32-bit | **General Purpose Registers**: Callee/caller saved per compiler conventions, used for computation, pointers, and local variables. |
| **R14** | 32-bit | **Volatile Scratch / Link / Trap Target**: High-activity scratchpad register. Used by hardware as the default return link register for traps/exceptions ($R14 \leftarrow PC + 2$), target for 8-bit immediate operations, and status returns. Preserved in hardware shadow bank across context switches. |
| **R15** | 32-bit | **Stack Pointer (SP)**: Architectural stack pointer by software convention. Preserved across `XCHGMOST` operations. |
| **shadow_r[1..15]** | 32-bit | **Hardware Shadow Register Bank**: Instant single-cycle context switching via `XCHG`, `XCHGALL`, and `XCHGMOST`. |
| **PC** | 32-bit | **Program Counter**: Byte-addressed, must be 2-byte aligned ($PC[0] = 0$). Fetching from an odd address triggers Trap 14 (Alignment Error). |

## 3. Memory Model & Memory Access Semantics

Particle features native byte addressing with hardware support for 8-bit, 16-bit, and 32-bit data access.

### 3.1 Alignment Constraints

* `LD8` / store operations can access any byte boundary without restriction.
* `LD16` / store operations require 2-byte alignment ($Addr[0] = 0$). Accessing an odd address triggers **Trap 14 (Alignment Error)**.
* `LD32` / store operations require 4-byte alignment ($Addr[1:0] = 00$). Unaligned accesses trigger **Trap 14 (Alignment Error)**.

### 3.2 Sub-Word Zero Extension

All sub-word memory loads (`LD8`, `LD16`) **zero-extend** into the 32-bit destination register. Dedicated instructions (`SEXT8`, `SEXT16`, `SEXTB`) provide sign-extension when dealing with signed two's-complement values.

### 3.3 Addressing Modes

Particle natively supports:
* **Register Indirect**: `(Rl)`
* **Pre-Increment**: `(++Rl)` / `(++Rr)` (scaled by data width: $+1$ for 8-bit, $+2$ for 16-bit, $+4$ for 32-bit)
* **Post-Increment**: `(Rl++)` / `(Rr++)` (scaled by data width)
* **Pre-Decrement**: `(--Rl)` / `(--Rr)` (scaled by data width)
* **Post-Decrement**: `(Rl--)` / `(Rr--)` (scaled by data width)

## 4. Exception, Trap & Vector Table Architecture

Particle adopts the **Direct Stride Vector Architecture** pioneered in MR4, scaled for a 32-bit system:

* **Vector Base Address**: `0x00000100` (configurable parameter `TRAP_TABLE_BASE`).
* **Slot Stride**: **32 words (64 bytes)** per vector slot.
* **Vector Dispatch Target**:
  $$\text{PC} \leftarrow \text{TRAP\_TABLE\_BASE} + (\text{Vector} \times 64)$$
* **Return Address Linkage**: Hardware latches the address of the next sequential instruction ($PC + 2$) into $R14$.
* **Interruptible Stall with Re-execution**: If an external `MBOX` trap interrupts a core stalled on an empty FIFO or multi-cycle divider, the stall is cancelled immediately and the faulting/stalled instruction's address ($PC$) is saved into $R14$. Upon returning from the trap handler (`JMP R14, R0`), the core cleanly restarts and re-executes the operation.

### 4.1 Vector Table Layout

| Vector Index | Byte Address | Exception / Interrupt Cause |
| :--- | :--- | :--- |
| **Trap 0** | `0x00000100` | **Hardware Reset**: Core initializes and begins execution here. |
| **Trap 1** | `0x00000140` | **MBOX Strobe 1 / FIFO Inbound Message Ready** |
| **Trap 2 – 13** | `0x00000180` – `0x00000440` | **Software / Inter-Core Traps (User / OS Defined)** |
| **Trap 14** | `0x00000480` | **Alignment Error Trap** (Misaligned 16/32-bit load/store or odd PC) |
| **Trap 15** | `0x000004C0` | **Illegal Instruction Trap** (Unassigned opcode decoded) |

## 5. Complete Instruction Set Architecture (ISA) Map

All instructions are encoded in uniform 16-bit words. The two-digit hexadecimal opcode in bits `[15:8]` is canonical.

```text
Instruction Field Encodings:
  Format R-R:   [15:8] Opcode  [7:4] Rr       [3:0] Rl
  Format R-Imm4:[15:8] Opcode  [7:4] Rr       [3:0] Imm4
  Format Imm8:  [15:8] Opcode  [7:0] Imm8
  Format R-Only:[15:8] Opcode  [7:4] 0000     [3:0] Rr
```

| Hex | Bit Pattern (16-bit) | Mnemonic | Operands | Operation & Semantics |
| :--- | :--- | :--- | :--- | :--- |
| **00** | `00000000rrrrllll` | `LD` | Rr, Rl | $Rr \leftarrow Rl$ |
| **01** | `00000001rrrriiii` | `LD` | Rr, Imm4 | $Rr \leftarrow \text{ZeroExtend}(Imm4)$ |
| **02** | `00000010iiiiiiii` | `LD` | R14, Imm8 | $R14 \leftarrow \text{ZeroExtend}(Imm8)$ |
| **03** | `00000011rrrriiii` | `LD` | Rr, -Imm4 | $Rr \leftarrow \text{Two'sComplement}(-Imm4)$ |
| **04** | `00000100iiiiiiii` | `LD` | R14, -Imm8 | $R14 \leftarrow \text{Two'sComplement}(-Imm8)$ |
| **05** | `00000101rrrriiii` | `PUSH4` | Rr, Imm4 | $Rr \leftarrow (Rr \ll 4) \mid Imm4$ |
| **06** | `00000110iiiiiiii` | `PUSH8` | R14, Imm8 | $R14 \leftarrow (R14 \ll 8) \mid Imm8$ |
| **10** | `00010000rrrrllll` | `LD8` | Rr, (Rl) | $Rr \leftarrow \text{ZeroExtend}(\text{PEEK8}(Rl))$ |
| **11** | `00010001rrrrllll` | `LD8` | (Rr), Rl | $\text{POKE8}(Rr, Rl[7:0])$ |
| **12** | `00010010rrrrllll` | `LD8` | Rr, (Rl++) | $Rr \leftarrow \text{ZeroExtend}(\text{PEEK8}(Rl));\ Rl \leftarrow Rl + 1$ |
| **13** | `00010011rrrrllll` | `LD8` | Rr, (++Rl) | $Rl \leftarrow Rl + 1;\ Rr \leftarrow \text{ZeroExtend}(\text{PEEK8}(Rl))$ |
| **14** | `00010100rrrrllll` | `LD8` | Rr, (Rl--) | $Rr \leftarrow \text{ZeroExtend}(\text{PEEK8}(Rl));\ Rl \leftarrow Rl - 1$ |
| **15** | `00010101rrrrllll` | `LD8` | Rr, (--Rl) | $Rl \leftarrow Rl - 1;\ Rr \leftarrow \text{ZeroExtend}(\text{PEEK8}(Rl))$ |
| **16** | `00010110rrrrllll` | `LD8` | (--Rr), Rl | $Rr \leftarrow Rr - 1;\ \text{POKE8}(Rr, Rl[7:0])$ |
| **17** | `00010111rrrrllll` | `LD8` | (Rr--), Rl | $\text{POKE8}(Rr, Rl[7:0]);\ Rr \leftarrow Rr - 1$ |
| **18** | `00011000rrrrllll` | `LD8` | (Rr++), Rl | $\text{POKE8}(Rr, Rl[7:0]);\ Rr \leftarrow Rr + 1$ |
| **19** | `00011001rrrrllll` | `LD8` | (++Rr), Rl | $Rr \leftarrow Rr + 1;\ \text{POKE8}(Rr, Rl[7:0])$ |
| **20** | `00100000rrrrllll` | `LD16` | Rr, (Rl) | $Rr \leftarrow \text{ZeroExtend}(\text{PEEK16}(Rl))$ |
| **21** | `00100001rrrrllll` | `LD16` | (Rr), Rl | $\text{POKE16}(Rr, Rl[15:0])$ |
| **22** | `00100010rrrrllll` | `LD16` | Rr, (Rl++) | $Rr \leftarrow \text{ZeroExtend}(\text{PEEK16}(Rl));\ Rl \leftarrow Rl + 2$ |
| **23** | `00100011rrrrllll` | `LD16` | Rr, (++Rl) | $Rl \leftarrow Rl + 2;\ Rr \leftarrow \text{ZeroExtend}(\text{PEEK16}(Rl))$ |
| **24** | `00100100rrrrllll` | `LD16` | Rr, (Rl--) | $Rr \leftarrow \text{ZeroExtend}(\text{PEEK16}(Rl));\ Rl \leftarrow Rl - 2$ |
| **25** | `00100101rrrrllll` | `LD16` | Rr, (--Rl) | $Rl \leftarrow Rl - 2;\ Rr \leftarrow \text{ZeroExtend}(\text{PEEK16}(Rl))$ |
| **26** | `00100110rrrrllll` | `LD16` | (--Rr), Rl | $Rr \leftarrow Rr - 2;\ \text{POKE16}(Rr, Rl[15:0])$ |
| **27** | `00100111rrrrllll` | `LD16` | (Rr--), Rl | $\text{POKE16}(Rr, Rl[15:0]);\ Rr \leftarrow Rr - 2$ |
| **28** | `00101000rrrrllll` | `LD16` | (Rr++), Rl | $\text{POKE16}(Rr, Rl[15:0]);\ Rr \leftarrow Rr + 2$ |
| **29** | `00101001rrrrllll` | `LD16` | (++Rr), Rl | $Rr \leftarrow Rr + 2;\ \text{POKE16}(Rr, Rl[15:0])$ |
| **30** | `00110000rrrrllll` | `LD32` | Rr, (Rl) | $Rr \leftarrow \text{PEEK32}(Rl)$ |
| **31** | `00110001rrrrllll` | `LD32` | (Rr), Rl | $\text{POKE32}(Rr, Rl)$ |
| **32** | `00110010rrrrllll` | `LD32` | Rr, (Rl++) | $Rr \leftarrow \text{PEEK32}(Rl);\ Rl \leftarrow Rl + 4$ |
| **33** | `00110011rrrrllll` | `LD32` | Rr, (++Rl) | $Rl \leftarrow Rl + 4;\ Rr \leftarrow \text{PEEK32}(Rl)$ |
| **34** | `00110100rrrrllll` | `LD32` | Rr, (Rl--) | $Rr \leftarrow \text{PEEK32}(Rl);\ Rl \leftarrow Rl - 4$ |
| **35** | `00110101rrrrllll` | `LD32` | Rr, (--Rl) | $Rl \leftarrow Rl - 4;\ Rr \leftarrow \text{PEEK32}(Rl)$ |
| **36** | `00110110rrrrllll` | `LD32` | (--Rr), Rl | $Rr \leftarrow Rr - 4;\ \text{POKE32}(Rr, Rl)$ |
| **37** | `00110111rrrrllll` | `LD32` | (Rr--), Rl | $\text{POKE32}(Rr, Rl);\ Rr \leftarrow Rr - 4$ |
| **38** | `00111000rrrrllll` | `LD32` | (Rr++), Rl | $\text{POKE32}(Rr, Rl);\ Rr \leftarrow Rr + 4$ |
| **39** | `00111001rrrrllll` | `LD32` | (++Rr), Rl | $Rr \leftarrow Rr + 4;\ \text{POKE32}(Rr, Rl)$ |
| **40** | `01000000rrrrllll` | `Add` | Rr, Rl | $Rr \leftarrow Rr + Rl$ |
| **41** | `01000001rrrrllll` | `Sub` | Rr, Rl | $Rr \leftarrow Rr - Rl$ |
| **42** | `01000010rrrrllll` | `Div` | Rr, Rl | $Rr \leftarrow Rr \text{ UnsignedDiv } Rl$ (Divide-by-zero returns `0xFFFFFFFF`) |
| **43** | `01000011rrrrllll` | `Mod` | Rr, Rl | $Rr \leftarrow Rr \text{ UnsignedMod } Rl$ (Divide-by-zero returns $Rr$) |
| **44** | `01000100rrrriiii` | `Add` | Rr, Imm4 | $Rr \leftarrow Rr + \text{ZeroExtend}(Imm4)$ |
| **45** | `01000101rrrriiii` | `Sub` | Rr, Imm4 | $Rr \leftarrow Rr - \text{ZeroExtend}(Imm4)$ |
| **46** | `01000110rrrriiii` | `Div` | Rr, Imm4 | $Rr \leftarrow Rr \text{ UnsignedDiv } Imm4$ |
| **47** | `01000111rrrriiii` | `Mod` | Rr, Imm4 | $Rr \leftarrow Rr \text{ UnsignedMod } Imm4$ |
| **50** | `01010000rrrrllll` | `SAdd` | Rr, Rl | $Rr \leftarrow Rr + Rl$ (Signed wrap-around) |
| **51** | `01010001rrrrllll` | `SSub` | Rr, Rl | $Rr \leftarrow Rr - Rl$ (Signed wrap-around) |
| **52** | `01010010rrrrllll` | `SDiv` | Rr, Rl | $Rr \leftarrow Rr \text{ SignedDiv } Rl$ (RISC-V conventions) |
| **53** | `01010011rrrrllll` | `SMod` | Rr, Rl | $Rr \leftarrow Rr \text{ SignedMod } Rl$ |
| **54** | `01010100rrrriiii` | `SAdd` | Rr, Imm4 | $Rr \leftarrow Rr + \text{SignExtend}(Imm4)$ |
| **55** | `01010101rrrriiii` | `SSub` | Rr, Imm4 | $Rr \leftarrow Rr - \text{SignExtend}(Imm4)$ |
| **56** | `01010110rrrriiii` | `SDiv` | Rr, Imm4 | $Rr \leftarrow Rr \text{ SignedDiv } \text{SignExtend}(Imm4)$ |
| **57** | `01010111rrrriiii` | `SMod` | Rr, Imm4 | $Rr \leftarrow Rr \text{ SignedMod } \text{SignExtend}(Imm4)$ |
| **60** | `01100000rrrrllll` | `ShiftL` | Rr, Rl | $Rr \leftarrow Rr \ll (Rl \ \& \ 31)$ |
| **61** | `011000010000rrrr` | `SEXT8` | Rr | $Rr \leftarrow \text{SignExtend32}(Rr[7:0])$ |
| **62** | `01100010rrrrllll` | `ShiftR` | Rr, Rl | $Rr \leftarrow Rr \gg (Rl \ \& \ 31)$ (Logical Shift, zero fill) |
| **63** | `01100011rrrrllll` | `AShiftR` | Rr, Rl | $Rr \leftarrow Rr \ggg (Rl \ \& \ 31)$ (Arithmetic Shift, sign fill) |
| **64** | `01100100rrrrllll` | `RotL` | Rr, Rl | $Rr \leftarrow \text{RotateLeft32}(Rr, Rl \ \& \ 31)$ |
| **65** | `01100101rrrrllll` | `RotR` | Rr, Rl | $Rr \leftarrow \text{RotateRight32}(Rr, Rl \ \& \ 31)$ |
| **66** | `01100110rrrrllll` | `And` | Rr, Rl | $Rr \leftarrow Rr \ \& \ Rl$ |
| **67** | `01100111rrrrllll` | `Or` | Rr, Rl | $Rr \leftarrow Rr \mid Rl$ |
| **68** | `01101000rrrrllll` | `Xor` | Rr, Rl | $Rr \leftarrow Rr \oplus Rl$ |
| **69** | `01101001rrrriiii` | `ShiftL` | Rr, Imm4 | $Rr \leftarrow Rr \ll Imm4$ |
| **6A** | `011010100000rrrr` | `SEXT16` | Rr | $Rr \leftarrow \text{SignExtend32}(Rr[15:0])$ |
| **6B** | `01101011rrrriiii` | `ShiftR` | Rr, Imm4 | $Rr \leftarrow Rr \gg Imm4$ |
| **6C** | `01101100rrrriiii` | `AShiftR` | Rr, Imm4 | $Rr \leftarrow Rr \ggg Imm4$ |
| **6D** | `01101101rrrriiii` | `RotL` | Rr, Imm4 | $Rr \leftarrow \text{RotateLeft32}(Rr, Imm4)$ |
| **6E** | `01101110rrrriiii` | `RotR` | Rr, Imm4 | $Rr \leftarrow \text{RotateRight32}(Rr, Imm4)$ |
| **6F** | `01101111rrrriiii` | `And` | Rr, Imm4 | $Rr \leftarrow Rr \ \& \ \text{ZeroExtend}(Imm4)$ |
| **70** | `01110000rrrriiii` | `Or` | Rr, Imm4 | $Rr \leftarrow Rr \mid \text{ZeroExtend}(Imm4)$ |
| **71** | `01110001rrrriiii` | `Xor` | Rr, Imm4 | $Rr \leftarrow Rr \oplus \text{ZeroExtend}(Imm4)$ |
| **78** | `01111000rrrrllll` | `MULL` | Rr, Rl | $Rr \leftarrow \text{Lower32}(Rr \times Rl)$ |
| **79** | `01111001rrrrllll` | `MULH` | Rr, Rl | $Rr \leftarrow \text{Upper32}(Rr_{\text{unsigned}} \times Rl_{\text{unsigned}})$ |
| **7A** | `01111010rrrrllll` | `SMULH` | Rr, Rl | $Rr \leftarrow \text{Upper32}(Rr_{\text{signed}} \times Rl_{\text{signed}})$ |
| **7B** | `01111011rrrrllll` | `MULHSU` | Rr, Rl | $Rr \leftarrow \text{Upper32}(Rr_{\text{signed}} \times Rl_{\text{unsigned}})$ |
| **7C** | `01111100rrrriiii` | `MULL` | Rr, Imm4 | $Rr \leftarrow \text{Lower32}(Rr \times \text{ZeroExtend}(Imm4))$ |
| **7D** | `01111101rrrriiii` | `MULH` | Rr, Imm4 | $Rr \leftarrow \text{Upper32}(Rr_{\text{unsigned}} \times \text{ZeroExtend}(Imm4))$ |
| **7E** | `01111110rrrriiii` | `SMULH` | Rr, Imm4 | $Rr \leftarrow \text{Upper32}(Rr_{\text{signed}} \times \text{SignExtend}(Imm4))$ |
| **7F** | `01111111rrrriiii` | `MULHSU` | Rr, Imm4 | $Rr \leftarrow \text{Upper32}(Rr_{\text{signed}} \times \text{ZeroExtend}(Imm4))$ |
| **80** | `10000000rrrrllll` | `BEXTR` | Rr, Rl | Bitfield Extract: $Rr \leftarrow (Rr \gg Rl[4:0]) \ \& \ ((1 \ll Rl[9:5]) - 1)$ |
| **81** | `10000001rrrrllll` | `JTBL` | Rr, Rl | Direct Jump Table: $\text{PC} \leftarrow \text{PEEK32}(Rr + (Rl \ll 2))$ |
| **82** | `10000010rrrrllll` | `CLZ` | Rr, Rl | Count Leading Zeros: $Rr \leftarrow \text{CLZ32}(Rl)$ |
| **83** | `10000011rrrrllll` | `BSET` | Rr, Rl | $Rr \leftarrow Rr \mid (1 \ll (Rl \ \& \ 31))$ |
| **84** | `10000100rrrriiii` | `BSET` | Rr, Imm4 | $Rr \leftarrow Rr \mid (1 \ll Imm4)$ |
| **85** | `10000101rrrrllll` | `BCLR` | Rr, Rl | $Rr \leftarrow Rr \ \& \ \sim(1 \ll (Rl \ \& \ 31))$ |
| **86** | `10000110rrrriiii` | `BCLR` | Rr, Imm4 | $Rr \leftarrow Rr \ \& \ \sim(1 \ll Imm4)$ |
| **87** | `10000111rrrrllll` | `BINV` | Rr, Rl | $Rr \leftarrow Rr \oplus (1 \ll (Rl \ \& \ 31))$ |
| **88** | `10001000rrrriiii` | `BINV` | Rr, Imm4 | $Rr \leftarrow Rr \oplus (1 \ll Imm4)$ |
| **89** | `10001001rrrrllll` | `BGET` | Rr, Rl | $Rr \leftarrow (Rr \gg (Rl \ \& \ 31)) \ \& \ 1$ |
| **8A** | `10001010rrrriiii` | `BGET` | Rr, Imm4 | $Rr \leftarrow (Rr \gg Imm4) \ \& \ 1$ |
| **8B** | `10001011rrrrllll` | `TAS` | (Rr), Rl | **Atomic Swap**: $\text{Temp} \leftarrow \text{PEEK32}(Rr);\ \text{POKE32}(Rr, Rl);\ Rl \leftarrow \text{Temp}$ |
| **8C – 8F** | `100011...` | *(Reserved)* | | Reserved for future extensions |
| **90** | `10010000rrrrllll` | `SLT` | Rr, Rl | $Rr \leftarrow (Rr_{\text{unsigned}} < Rl_{\text{unsigned}}) \ ?\ 1 : 0$ |
| **91** | `10010001rrrriiii` | `SLT` | Rr, Imm4 | $Rr \leftarrow (Rr_{\text{unsigned}} < \text{ZeroExtend}(Imm4)) \ ?\ 1 : 0$ |
| **92** | `10010010rrrriiii` | `SLT` | Rr, -Imm4 | $Rr \leftarrow (Rr_{\text{unsigned}} < \text{Two'sComp}(-Imm4)) \ ?\ 1 : 0$ |
| **93** | `10010011iiiiiiii` | `SLT` | R14, Imm8 | $R14 \leftarrow (R14_{\text{unsigned}} < \text{ZeroExtend}(Imm8)) \ ?\ 1 : 0$ |
| **94** | `10010100iiiiiiii` | `SLT` | R14, -Imm8 | $R14 \leftarrow (R14_{\text{unsigned}} < \text{Two'sComp}(-Imm8)) \ ?\ 1 : 0$ |
| **95** | `10010101rrrrllll` | `SSLT` | Rr, Rl | $Rr \leftarrow (Rr_{\text{signed}} < Rl_{\text{signed}}) \ ?\ 1 : 0$ |
| **96** | `10010110rrrriiii` | `SSLT` | Rr, Imm4 | $Rr \leftarrow (Rr_{\text{signed}} < \text{SignExtend}(Imm4)) \ ?\ 1 : 0$ |
| **97** | `10010111rrrriiii` | `SSLT` | Rr, -Imm4 | $Rr \leftarrow (Rr_{\text{signed}} < -\text{ZeroExtend}(Imm4)) \ ?\ 1 : 0$ |
| **98** | `10011000iiiiiiii` | `SSLT` | R14, Imm8 | $R14 \leftarrow (R14_{\text{signed}} < \text{SignExtend}(Imm8)) \ ?\ 1 : 0$ |
| **99** | `10011001iiiiiiii` | `SSLT` | R14, -Imm8 | $R14 \leftarrow (R14_{\text{signed}} < -\text{ZeroExtend}(Imm8)) \ ?\ 1 : 0$ |
| **A0** | `10100000rrrrllll` | `JMP` | Rr, Rl | $\text{PC} \leftarrow Rr;\ Rl \leftarrow \text{PC} + 2$ (If $Rl == R0$, link discarded) |
| **A1** | `10100001rrrrllll` | `RJUMP` | Rr, Rl | $\text{PC} \leftarrow \text{PC} + (Rr \times 2);\ Rl \leftarrow \text{PC} + 2$ |
| **A2** | `101000100000rrrr` | `TRAP` | Rr | Dispatch vector $Rr \ \& \ 0xF$; $R14 \leftarrow \text{PC} + 2$ |
| **A3** | `101000110000iiii` | `TRAP` | Imm4 | Dispatch vector $Imm4$; $R14 \leftarrow \text{PC} + 2$ |
| **B0** | `10110000iiiiiiii` | `FBRA` | Imm8 | $\text{PC} \leftarrow \text{PC} + (Imm8 \times 2)$ |
| **B1** | `10110001rrrrllll` | `FBRA.Z` | Rr, Rl | $\text{if } Rr == 0 \implies \text{PC} \leftarrow \text{PC} + (Rl \times 2)$ |
| **B2** | `10110010rrrrllll` | `FBRA.N` | Rr, Rl | $\text{if } Rr < 0 \implies \text{PC} \leftarrow \text{PC} + (Rl \times 2)$ |
| **B3** | `10110011rrrrllll` | `FBRA.P` | Rr, Rl | $\text{if } Rr > 0 \implies \text{PC} \leftarrow \text{PC} + (Rl \times 2)$ |
| **B4** | `10110100rrrriiii` | `FBRA.Z` | Rr, Imm4 | $\text{if } Rr == 0 \implies \text{PC} \leftarrow \text{PC} + (Imm4 \times 2)$ |
| **B5** | `10110101rrrriiii` | `FBRA.N` | Rr, Imm4 | $\text{if } Rr < 0 \implies \text{PC} \leftarrow \text{PC} + (Imm4 \times 2)$ |
| **B6** | `10110110rrrriiii` | `FBRA.P` | Rr, Imm4 | $\text{if } Rr > 0 \implies \text{PC} \leftarrow \text{PC} + (Imm4 \times 2)$ |
| **B7** | `10110111iiiiiiii` | `FBRA.Z` | R14, Imm8 | $\text{if } R14 == 0 \implies \text{PC} \leftarrow \text{PC} + (Imm8 \times 2)$ |
| **B8** | `10111000iiiiiiii` | `FBRA.N` | R14, Imm8 | $\text{if } R14 < 0 \implies \text{PC} \leftarrow \text{PC} + (Imm8 \times 2)$ |
| **B9** | `10111001iiiiiiii` | `FBRA.P` | R14, Imm8 | $\text{if } R14 > 0 \implies \text{PC} \leftarrow \text{PC} + (Imm8 \times 2)$ |
| **C0** | `11000000iiiiiiii` | `BBRA` | Imm8 | $\text{PC} \leftarrow \text{PC} - (Imm8 \times 2)$ |
| **C1** | `11000001rrrrllll` | `BBRA.Z` | Rr, Rl | $\text{if } Rr == 0 \implies \text{PC} \leftarrow \text{PC} - (Rl \times 2)$ |
| **C2** | `11000010rrrrllll` | `BBRA.N` | Rr, Rl | $\text{if } Rr < 0 \implies \text{PC} \leftarrow \text{PC} - (Rl \times 2)$ |
| **C3** | `11000011rrrrllll` | `BBRA.P` | Rr, Rl | $\text{if } Rr > 0 \implies \text{PC} \leftarrow \text{PC} - (Rl \times 2)$ |
| **C4** | `11000100rrrriiii` | `BBRA.Z` | Rr, Imm4 | $\text{if } Rr == 0 \implies \text{PC} \leftarrow \text{PC} - (Imm4 \times 2)$ |
| **C5** | `11000101rrrriiii` | `BBRA.N` | Rr, Imm4 | $\text{if } Rr < 0 \implies \text{PC} \leftarrow \text{PC} - (Imm4 \times 2)$ |
| **C6** | `11000110rrrriiii` | `BBRA.P` | Rr, Imm4 | $\text{if } Rr > 0 \implies \text{PC} \leftarrow \text{PC} - (Imm4 \times 2)$ |
| **C7** | `11000111iiiiiiii` | `BBRA.Z` | R14, Imm8 | $\text{if } R14 == 0 \implies \text{PC} \leftarrow \text{PC} - (Imm8 \times 2)$ |
| **C8** | `11001000iiiiiiii` | `BBRA.N` | R14, Imm8 | $\text{if } R14 < 0 \implies \text{PC} \leftarrow \text{PC} - (Imm8 \times 2)$ |
| **C9** | `11001001iiiiiiii` | `BBRA.P` | R14, Imm8 | $\text{if } R14 > 0 \implies \text{PC} \leftarrow \text{PC} - (Imm8 \times 2)$ |
| **D0** | `110100000000rrrr` | `XCHG` | Rr | Swap $Rr$ with $shadow\_r[r]$ in 1 cycle |
| **D1** | `1101000100000000` | `XCHGALL` | | Swap registers $R1$–$R15$ with shadow bank |
| **D2** | `1101001000000000` | `XCHGMOST` | | Swap registers $R1$–$R14$ with shadow bank ($R15$ SP preserved) |
| **E0** | `11100000rrrrllll` | `FIFO.R` | Rr, Rl | $Rr \leftarrow \text{ReadFIFO}(Rl)$ (Stalls core if empty) |
| **E1** | `11100001rrrriiii` | `FIFO.R` | Rr, Imm4 | $Rr \leftarrow \text{ReadFIFO}(Imm4)$ (Stalls core if empty) |
| **E2** | `11100010rrrrllll` | `FIFO.W` | Rr, Rl | $\text{WriteFIFO}(Rl, Rr)$ (Stalls core if full) |
| **E3** | `11100011rrrriiii` | `FIFO.W` | Rr, Imm4 | $\text{WriteFIFO}(Imm4, Rr)$ (Stalls core if full) |
| **E4** | `11100100rrrrllll` | `FIFO.STAT` | Rr, Rl | $Rr \leftarrow \text{FIFO\_Status}(Rl)$ (Bit 0: Empty, Bit 1: Full, [15:8]: Depth) |
| **E5** | `11100101rrrriiii` | `FIFO.STAT` | Rr, Imm4 | $Rr \leftarrow \text{FIFO\_Status}(Imm4)$ |
| **E6** | `11100110rrrrllll` | `FIFO.TRYR` | Rr, Rl | Try Read: $\text{if (!Empty) } \{ Rr \leftarrow \text{Pop}();\ R14 \leftarrow 1; \} \text{ else } \{ R14 \leftarrow 0; \}$ |
| **E7** | `11100111rrrrllll` | `FIFO.TRYW` | Rr, Rl | Try Write: $\text{if (!Full) } \{ \text{Push}(Rl, Rr);\ R14 \leftarrow 1; \} \text{ else } \{ R14 \leftarrow 0; \}$ |
| **E8** | `11101000rrrrllll` | `MBOX` | Rr, Rl | Strobe Trap Vector $Rl \ \& \ 0xF$ on Core $Rr[7:0]$ |
| **E9** | `11101001rrrriiii` | `MBOX` | Rr, Imm4 | Strobe Trap Vector $Imm4$ on Core $Rr[7:0]$ |

## 6. Project Structure (Pure ROHD Framework)

To maintain clean engineering practices, **Particle contains zero Verilog source files**. The core, peripherals, interconnect, and synthesis targets are developed exclusively in Intel ROHD (Dart). When targeting physical FPGA synthesis (e.g., Yosys/nextpnr on ULX3S), the ROHD generator emits clean, synthesizable SystemVerilog.

```text
particle/
├── Documentation/
│   ├── particle_spec.md                   # This master specification
│   ├── memory_map_and_conventions.md      # Memory map & calling conventions
│   └── act16_compiler_reference.md        # ACT16 language & compiler guide
│
├── hdl/
│   └── rohd/                              # Exclusive Hardware Implementation
│       ├── pubspec.yaml                   # Dart dependencies (rohd: ^0.5.0, test: ^1.24.0)
│       ├── Makefile                       # Test execution & synthesis automation
│       ├── bin/
│       │   └── generate.dart              # Generates particle_top.sv for Yosys
│       ├── lib/
│       │   ├── constants.dart             # Opcode definitions, vector bases, widths
│       │   ├── cpu_config.dart            # Parameterized CPU configuration
│       │   ├── cpu_core.dart              # Particle 32-bit execution core & FSM
│       │   ├── alu.dart                   # 32-bit ALU, Barrel Shifter, CLZ, Bit-Op
│       │   ├── multiplier.dart            # Single-cycle DSP-backed 32x32 multiplier
│       │   ├── divider.dart               # Multi-cycle Radix-4 restoring divider
│       │   ├── register_file.dart         # 16x32 register file with shadow banks
│       │   ├── fifo_subsystem.dart        # Parameterized multi-channel streaming FIFOs
│       │   ├── memory_bus.dart            # TDP BRAM interface & alignment checker
│       │   └── uart.dart                  # High-speed UART transceiver
│       └── test/                          # Unit & System Testbenches
│           ├── alu_test.dart              # Arithmetic, logic, shifts, bit-ops
│           ├── branch_test.dart           # Forward/backward branches & traps
│           ├── memory_test.dart           # LD8/16/32, alignment faults, post-inc/dec
│           ├── mult_div_test.dart         # Signed/unsigned division & multiplication
│           ├── fifo_mbox_test.dart        # Inter-core streaming & trap strobing
│           └── cpu_core_test.dart         # End-to-end instruction execution
│
├── lib/
│   ├── common.inc                         # Standard architectural macros & registers
│   └── particle_runtime.asm               # System startup, stack init, helper routines
│
├── tools/
│   ├── pasm.py                            # Two-pass Particle macro assembler
│   ├── psim.py                            # Instruction-level simulator with p4db debugger
│   └── act16c.py                          # ACT16 systems compiler
│
└── apps/
    ├── asm/                               # Assembly programs & boot monitors
    └── act16/                             # ACT16 application sources
```

## 7. Software Toolchain Requirements

### 7.1 Two-Pass Macro Assembler (`pasm.py`)

* **Syntax Support**: Supports 16-bit register syntax (`R0`–`R15`, case-insensitive).
* **Directives**:
  * `.org <expr>`: Set emission origin.
  * `.define <symbol> <expr>`: Compile-time numeric and label constants.
  * `.macro <name> <params>` ... `.endmacro`: Macro expansion with `%param` substitution and unique local labels `._label_%`.
  * `.word <val>` / `.half <val>` / `.byte <val>` / `.asciz "<str>"`: Memory data emission.
  * `.align <bytes>`: Pad until boundary alignment is met (e.g., `.align 4`).
* **Conditional Assembly Directives**:
  * `.ifdef <symbol>` ... `.else` ... `.endif`
  * `.ifndef <symbol>` ... `.else` ... `.endif`
  * `.if <expression>` ... `.else` ... `.endif`
  * Supports nesting up to 16 levels deep. Command-line defines accepted via `-D<symbol>[=<val>]`.

### 7.2 Instruction-Level Simulator & Debugger (`psim.py`)

* Full functional simulation of the 32-bit datapath and memory array.
* Synchronous simulation of the parameterized hardware streaming FIFOs and `MBOX` strobes.
* **Interactive Debugger (`pdb`)**:
  * Breakpoints (`b <addr>`), single-step (`s`), step-over (`n`).
  * Register display (`r`) showing all 16 active registers and shadow bank.
  * Memory inspection (`m <addr> <count>`) with 8, 16, and 32-bit formatting.
  * FIFO inspection (`fifo`) displaying queue occupancy, empty/full flags, and head words.
  * Memory dump and load commands: `load <filename> <addr>` and `save <addr> <length> <filename>`.

## 8. Common Macro Library (`lib/common.inc`)

`lib/common.inc` provides core architectural constants, context-switching utilities, and tiered immediate loading macros (`LOAD16`, `LOAD24`, `LOAD32`):

```assembly
; ==============================================================================
; Particle Common Architectural Include File
; ==============================================================================

; --- Hardware Trap Vectors (Direct Stride: Base 0x0100, Stride 64 bytes) ---
.define TRAP_RESET        0
.define TRAP_MBOX         1
.define TRAP_ALIGN        14
.define TRAP_ILLEGAL      15
.define TRAP_TABLE_BASE   0x00000100
.define TRAP_STRIDE_BYTES 64

; --- Macro: LOAD16 reg, value ---
; Loads a 16-bit constant/symbol into reg using R14 accumulator.
; Consumes 3 instructions (6 bytes).
.macro LOAD16 reg, value
    LD      R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

; --- Macro: LOAD24 reg, value ---
; Loads a 24-bit constant/symbol into reg using R14 accumulator.
; Consumes 4 instructions (8 bytes).
.macro LOAD24 reg, value
    LD      R14, ((%value) >> 16) & 0xFF
    PUSH8   R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

; --- Macro: LOAD32 reg, value ---
; Loads a full 32-bit constant/symbol into reg using R14 accumulator.
; Consumes 5 instructions (10 bytes).
.macro LOAD32 reg, value
    LD      R14, ((%value) >> 24) & 0xFF
    PUSH8   R14, ((%value) >> 16) & 0xFF
    PUSH8   R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

; --- Macro: START_PROGRAM ---
; Initializes Stack Pointer (R15) to top of RAM and jumps to _main
.macro START_PROGRAM
    LOAD32  R15, 0x00010000     ; 64 KB RAM Top (stack grows down)
    LOAD32  R14, _main
    JMP     R14, R0             ; Jump to _main without linking
.endmacro

; --- Macro: RCALL & RRET ---
.macro RCALL target
    LOAD32  R14, %target
    JMP     R14, R14            ; Link address PC+2 placed in R14
.endmacro

.macro RRET
    JMP     R14, R0             ; Return through R14
.endmacro

; --- Macro: PUSH & POP (Full Descending on R15) ---
.macro PUSH32 reg
    LD32    (--R15), %reg
.endmacro

.macro POP32 reg
    LD32    %reg, (R15++)
.endmacro

; --- Macro: FAST_ENTER_TRAP & FAST_EXIT_TRAP ---
; Zero-memory-spill context switch using hardware shadow bank
.macro FAST_ENTER_TRAP
    XCHGMOST                    ; Preserve R1-R14 in shadow bank; SP kept
.endmacro

.macro FAST_EXIT_TRAP
    XCHGMOST                    ; Restore original application thread state
    JMP     R14, R0             ; Return to interrupted application code
.endmacro
```

## 9. The ACT16 Systems Language & Compiler Specification

The ACT16 language evolves the Action!-style systems programming model designed in ACT4 to support a full 32-bit datapath with rich sub-word integer types and conditional compilation.

### 9.1 Data Types

ACT16 provides native signed and unsigned integer widths:
* `u8` / `s8`: 8-bit unsigned and two's-complement signed byte ($0..255$, $-128..127$).
* `u16` / `s16`: 16-bit unsigned and two's-complement signed halfword ($0..65535$, $-32768..32767$).
* `u32` / `s32`: 32-bit unsigned and two's-complement signed word ($0..4294967295$, $-2^{31}..2^{31}-1$).
* `void`: Unspecified or empty return type.
* Pointers: `u8*`, `u16*`, `u32*`, `s8*`, `s16*`, `s32*`. Pointer arithmetic scales automatically by element width ($+1, +2, +4$).

### 9.2 Conditional Compilation Directives

ACT16 source files support preprocessor conditionals:
```c
#ifdef MULTICORE_ENABLE
    const u32 NODE_ID = 1;
#else
    const u32 NODE_ID = 0;
#endif

#ifndef BUFFER_SIZE
    const u32 BUFFER_SIZE = 1024;
#endif
```

### 9.3 Code Generation Rules & Native Instruction Selection

* **Immediate Literal Optimization**:
  * Values $0 \le N \le 15$: Emits `LD Rr, Imm4`.
  * Values $-15 \le N \le -1$: Emits `LD Rr, -Imm4`.
  * Values $\le \text{0xFFFF}$: Emits `LOAD16 Rr, value`.
  * Values $\le \text{0xFFFFFF}$: Emits `LOAD24 Rr, value`.
  * Values $> \text{0xFFFFFF}$: Emits `LOAD32 Rr, value`.
* **Sub-Word Loads**:
  * Loading `u8`: Emits `LD8 Rr, (Rl)` (natively zero-extended).
  * Loading `s8`: Emits `LD8 Rr, (Rl)` followed by `SEXT8 Rr`.
  * Loading `u16`: Emits `LD16 Rr, (Rl)` (natively zero-extended).
  * Loading `s16`: Emits `LD16 Rr, (Rl)` followed by `SEXT16 Rr`.
  * Loading `u32` / `s32`: Emits `LD32 Rr, (Rl)`.
* **Sub-Word Stores**:
  * Emits `LD8 (Rr), Rl`, `LD16 (Rr), Rl`, or `LD32 (Rr), Rl` directly.
* **Arithmetic & Math**:
  * Addition/Subtraction: Emits `Add` / `Sub` (or `SAdd` / `SSub`).
  * Unsigned Multiplication: Emits `MULL Rr, Rl` (lower 32) and `MULH Rr, Rl` (upper 32).
  * Signed Multiplication: Emits `MULL Rr, Rl` (lower 32) and `SMULH Rr, Rl` (upper 32).
  * Division & Modulo: Emits `Div` / `Mod` for unsigned operands; emits `SDiv` / `SMod` for signed operands.
* **Fast Relational Branches**:
  * Equality tests against zero compile down to single 1-cycle branches (`FBRA.Z`, `BBRA.Z`).
  * Signed ordering ($<, \le, >, \ge$) uses `SSLT` followed by `FBRA.P` / `BBRA.P`.
  * Unsigned ordering uses `SLT` followed by `FBRA.P` / `BBRA.P`.
* **Multi-Core FIFO Primitives**:
  Native language primitives for streaming channel access:
  ```c
  u32 data = readfifo(0);           // Compiles to: FIFO.R R1, 0
  writefifo(1, packet);             // Compiles to: FIFO.W R1, 1
  if (tryreadfifo(0, &val)) { ... } // Compiles to: FIFO.TRYR R1, 0
  ```
 ---

 Please confirm that you understand the architecture, invariants, and project structure, and propose the Phase 1 implementation checklist.# Particle Processor Architecture & System Engineering Specification

 