# Addendum 02: Particle 64-Bit Architecture Extension Proposal

**Document Identifier:** ARCH-PROP-ADDENDUM-02  
**Status:** Proposed / Draft  
**Target Architecture:** Particle Processor ISA & Parcore Multi-Core Fabric  
**Primary Target HDL:** Intel ROHD (Dart sdk >= 3.0.0)  
**Target Hardware:** Lattice ECP5 (ULX3S) / Modern FPGA Platforms  

---

## 1. Executive Summary

This addendum investigates the feasibility and architectural definition of extending the native **Particle** processor architecture from a 32-bit datapath ($W = 32$) to a native 64-bit datapath ($W = 64$, **Particle-64**). 

The primary objectives are:
1. Preserve Particle's compact, uniform 16-bit instruction format (`[15:8] Opcode`, `[7:4] Rr`, `[3:0] Rl / Imm4`).
2. Provide native support for 64-bit integer registers, wide memory addressing, 64-bit doubleword arithmetic/logic, and sub-word (32-bit) integer operations for modern OS runtimes and emulation.
3. Validate that the remaining unallocated opcode budget within the Particle 8-bit opcode space (`0x00`–`0xFF`) is sufficient to accommodate these additions without requiring breaking architectural changes.

---

## 2. Opcode Map Audit & Space Feasibility Analysis

The Particle architecture allocates the high byte (`inst[15:8]`) as the canonical opcode, providing exactly 256 instruction slots. The table below audits current allocations across the master specification (`particle_spec.md`):

| Opcode Range | Primary Functional Group | Allocated Slots | Free / Unallocated Slots |
| :--- | :--- | :---: | :---: |
| `0x00` – `0x0F` | Register moves, Immediate loads (`LD`, `PUSH4`, `PUSH8`) | 7 | **9 free** (`0x07`–`0x0F`) |
| `0x10` – `0x3F` | Memory loads & stores (`LD8`/`16`/`32`, `ST8`/`16`/`32`, auto-indexing) | 30 | **18 free** (`0x1A`–`0x1F`, `0x2A`–`0x2F`, `0x3A`–`0x3F`) |
| `0x40` – `0x5F` | Unsigned/Signed Arithmetic (`ADD`, `SUB`, `DIV`, `MOD`, `NEG`) | 17 | **15 free** (`0x49`–`0x4F`, `0x58`–`0x5F`) |
| `0x60` – `0x7F` | Shifts, Logic, Bitwise Inversions, DSP Multipliers | 32 | **0 free** (dense) |
| `0x80` – `0x8F` | Bit manipulation, `JTBL`, `TAS`, `REV32` | 13 | **3 free** (`0x8D`–`0x8F`) |
| `0x90` – `0x9F` | Relational Comparisons (`SLT`, `SSLT`, `SEQ`, `SNE`, `SLE`, `SSLE`) | 14 | **2 free** (`0x9E`–`0x9F`) |
| `0xA0` – `0xAF` | Control Flow (`JMP`, `RJUMP`, `TRAP`, `WAIT`, `BRANCH`) | 5 | **11 free** (`0xA5`–`0xAF`) |
| `0xB0` – `0xCF` | Relative Branches (`FBRA.*`, `BBRA.*`) | 18 | **14 free** (`0xBC`–`0xBF`, `0xCC`–`0xCF`) |
| `0xD0` – `0xDF` | Shadow register exchange, `RBASE` windowing | 5 | **11 free** (`0xD5`–`0xDF`) |
| `0xE0` – `0xFE` | Interconnect (`FIFO.*`, `MBOX`) & System Expansion | 6 | **24 free** (`0xE6`–`0xFD`) |
| `0xFF` | Escape Prefix (`XTRA`) | 1 | Dedicated 32-bit Prefix Hook |
| **Total** | | **148 Allocated** | **108 Free Slots (42.2%)** |

### Feasibility Conclusion
The architecture has **108 unallocated opcodes**. A comprehensive 64-bit extension requires between **18 and 24 new primary opcodes**. Therefore, **Particle-64 fits comfortably within the existing 16-bit encoding space** without breaking changes to opcode dispatch.

---

## 3. Required ISA Additions & Proposed Opcode Mapping

### 3.1 64-Bit Memory Operations (Doubleword Loads & Stores)
To match Particle's standard 10-instruction load/store pattern (register indirect, post/pre increment/decrement, base+offset, stack-relative), 10 contiguous opcodes are assigned from the free memory block `0x3A`–`0x3F` and `0x2A`–`0x2D`:

| Opcode | Mnemonic | Format | Description / Semantics |
| :--- | :--- | :---: | :--- |
| `0x3A` | `LD64 Rr, (Rl)` | R-R | Doubleword Load: $Rr \leftarrow \text{Mem64}[Rl]$ |
| `0x3B` | `LD64 (Rr), Rl` / `ST64 (Rr), Rl` | R-R | Doubleword Store: $\text{Mem64}[Rr] \leftarrow Rl[63:0]$ |
| `0x3C` | `LD64 Rr, (Rl++)` | R-R | Post-increment load doubleword ($Rl \leftarrow Rl + 8$) |
| `0x3D` | `LD64 (Rr++), Rl` / `ST64 (Rr++), Rl` | R-R | Post-increment store doubleword ($Rr \leftarrow Rr + 8$) |
| `0x3E` | `LD64 Rr, (--Rl)` | R-R | Pre-decrement load doubleword ($Rl \leftarrow Rl - 8$) |
| `0x3F` | `LD64 (--Rr), Rl` / `ST64 (--Rr), Rl` | R-R | Pre-decrement store doubleword ($Rr \leftarrow Rr - 8$) |
| `0x2A` | `LD64 Rr, (Rl + Imm4)` | R-Imm4 | Base + scaled offset load ($Addr = Rl + (Imm4 \times 8)$) |
| `0x2B` | `LD64 (Rr + Imm4), Rl` | R-Imm4 | Base + scaled offset store ($Addr = Rr + (Imm4 \times 8)$) |
| `0x2C` | `LD64 Rr, (SP + Imm4)` | R-Imm4 | Stack-relative load doubleword ($Addr = SP + (Imm4 \times 8)$) |
| `0x2D` | `LD64 (SP + Imm4), Rl` | R-Imm4 | Stack-relative store doubleword ($Addr = SP + (Imm4 \times 8)$) |

*Memory Alignment Invariant:* Doubleword accesses require 8-byte alignment ($Addr[2:0] == 000$). Any violation triggers **Trap 14 (Alignment Error)**.

### 3.2 32-Bit Sub-Word Arithmetic & Sign Extension
In a 64-bit architecture, 32-bit computation requires explicit sign-extension semantics (analogous to RISC-V `*W` instructions) to prevent arithmetic errors when executing standard 32-bit integer code:

| Opcode | Mnemonic | Format | Description / Semantics |
| :--- | :--- | :---: | :--- |
| `0x49` | `ADDW Rr, Rl` | R-R | 32-bit Add with Sign Extension: $Rr \leftarrow \text{sign\_ext64}(Rr[31:0] + Rl[31:0])$ |
| `0x4A` | `SUBW Rr, Rl` | R-R | 32-bit Sub with Sign Extension: $Rr \leftarrow \text{sign\_ext64}(Rr[31:0] - Rl[31:0])$ |
| `0x4B` | `ADDW Rr, Imm4` | R-Imm4 | 32-bit Add Immediate with Sign Extension |
| `0x4C` | `SUBW Rr, Imm4` | R-Imm4 | 32-bit Sub Immediate with Sign Extension |
| `0x58` | `DIVW Rr, Rl` | R-R | 32-bit Unsigned Division (Sign Extended) |
| `0x59` | `MODW Rr, Rl` | R-R | 32-bit Unsigned Modulo (Sign Extended) |
| `0x5A` | `SDIVW Rr, Rl` | R-R | 32-bit Signed Division (Sign Extended) |
| `0x5B` | `SMODW Rr, Rl` | R-R | 32-bit Signed Modulo (Sign Extended) |
| `0x8D` | `SEXTD Rr` / `SEXT32 Rr`| R-Only | Sign-extend word: $Rr \leftarrow \text{sign\_ext64}(Rr[31:0])$ |
| `0x8E` | `REV64 Rr` | R-Only | 64-bit Endianness byte reverse across all 8 bytes |

### 3.3 64-Bit Wide Multipliers & Division
Particle-32 utilizes single-cycle $32 \times 32$ multipliers yielding high and low 32-bit words. Particle-64 defines $64 \times 64$ multiplication yielding a 128-bit product:

| Opcode | Mnemonic | Format | Description / Semantics |
| :--- | :--- | :---: | :--- |
| `0x1A` | `DMULL Rr, Rl` | R-R | Doubleword Multiply Low: Lower 64 bits of unsigned $Rr \times Rl$ |
| `0x1B` | `DMULH Rr, Rl` | R-R | Doubleword Multiply High: Upper 64 bits of unsigned $Rr \times Rl$ |
| `0x1C` | `SDMULH Rr, Rl` | R-R | Doubleword Signed Multiply High: Upper 64 bits of signed $Rr \times Rl$ |
| `0x1D` | `DMULHSU Rr, Rl` | R-R | Doubleword Signed $\times$ Unsigned Multiply High |

*Divider Pipeline:* The hardware divider (`ParticleDivider`) scales from a 34-cycle 32-bit non-restoring divider to a parameterized 66-cycle 64-bit non-restoring divider. The existing unsigned `DIV`/`MOD` (`0x42`/`0x43`) and signed `SDIV`/`SMOD` (`0x52`/`0x53`) opcodes execute natively across full 64-bit registers.

---

## 4. Immediate Construction & Field Encoding Strategy

Because Particle maintains a strict 16-bit instruction format, immediate fields are subject to architectural constraints:

### 4.1 Register-Based Shifts vs. Immediate Shifts
* **Register-Register Shifts (`SHIFTL`, `SHIFTR`, `ASHIFTR`, `ROTL`, `ROTR`):**  
  In Particle-32, the shift amount is read from `Rl[4:0]` (0–31). In Particle-64, the datapath is updated to sample `Rl[5:0]` (0–63). **This requires 0 new opcodes.**
* **Immediate Shifts (`SHIFTL Rr, Imm4`, etc.):**  
  The 4-bit immediate field (`[3:0] Imm4`) can only express offsets $0 \le N \le 15$. For immediate shifts $>15$, software either:
  1. Loads the shift count into a scratch register (`R14` or general register) and executes register-based shifts.
  2. Uses the 32-bit escaped instruction prefix (`0xFF` / `XTRA`) described below.

### 4.2 Loading 64-Bit Literals
In Particle-32, loading a 32-bit immediate requires a 4-instruction sequence via `PUSH8` into `R14` (`LOAD32`). In Particle-64, loading a full 64-bit constant requires an expanded macro sequence:

```assembly
; LOAD64 Rr, 0x0123456789ABCDEF
LD      R14, 0x01
PUSH8   R14, 0x23
PUSH8   R14, 0x45
PUSH8   R14, 0x67
PUSH8   R14, 0x89
PUSH8   R14, 0xAB
PUSH8   R14, 0xCD
PUSH8   R14, 0xEF
LD      Rr,  R14
```

To optimize code size for address loading:
1. **Sign-Extended 32-bit Literals (`LOAD32S`):** Execute a 4-instruction `LOAD32` into `Rr` followed by `SEXTD Rr` (5 instructions total for any address in the negative or positive 2 GB ranges).
2. **Coprocessor / Escape Prefix (`XTRA 0xFF`):** Multi-word literals can be streamed directly via two-halfword prefix formats.

---

## 5. ROHD Hardware Datapath & Resource Impact (Lattice ECP5)

Extending the hardware datapath in Intel ROHD (`cpu_core.dart`, `alu.dart`, `register_file.dart`) impacts FPGA resource utilization as follows:

| Subsystem Module | Particle-32 (Baseline) | Particle-64 (Proposed) | Resource Delta / Analysis |
| :--- | :--- | :--- | :--- |
| **Register File** (`register_file.dart`) | 16 registers $\times$ 32 bits (512 flip-flops) | 16 registers $\times$ 64 bits (1,024 flip-flops) | Doubles register flip-flops; ~850–1,100 LUT4s on ECP5. |
| **ALU & Shifter** (`alu.dart`) | 32-bit CCU2C adder + 32-bit barrel shifter | 64-bit CCU2C adder + 64-bit barrel shifter | Adder: ~68 LUT4s. 64-bit barrel shifter grows to ~550 LUT4s. |
| **DSP Multipliers** (`multiplier.dart`) | $32 \times 32$ multiplier (4 $\times$ MULT18X18D) | $64 \times 64$ multiplier (16 $\times$ MULT18X18D or iterative) | High DSP cost if fully unrolled; recommended 2-cycle or 4-cycle DSP sequencing. |
| **Divider Engine** (`divider.dart`) | 34-cycle non-restoring divider (~220 LUT4s) | 66-cycle non-restoring divider (~380 LUT4s) | Counter widens to 7 bits; subtractor widens to 65 bits. |
| **Memory Bus** (`memory_bus.dart`) | 4-bit byte enables (`bEn`), 32-bit alignment | 8-bit byte enables (`bEn`), 64-bit alignment | Addr[2:0] checking; 8-way byte lane formatting. |
| **Estimated Total Core LUTs** | **~2,200 – 3,000 LUT4s** | **~3,800 – 4,900 LUT4s** | Consumes ~5.8% of Lattice ECP5-85F logic space. |

---

## 6. Parcore Multi-Core Integration

When Particle-64 cores are incorporated into the **Parcore** multi-core cluster (e.g., as emulators for RV64IMZbb or x86-64 long mode):
1. **Inter-Stage FIFOs (`fifo_subsystem.dart`):** Widened to 64 bits data width. Packet protocols preserve existing 2-to-4 word transfers while doubling register payload capacity.
2. **Shared Architectural Register Fabric (SARF):** Storage cells expand from $64 \times 32\text{-bit}$ to $64 \times 64\text{-bit}$, allowing full 64-bit architectural register updates without splitting into high/low register pairs.
3. **True Dual-Port TCM (`parcore_tcm.dart`):** Port A remains 16 bits wide (instruction fetch stream is unaltered); Port B widens to 64 bits data width with 8-bit byte-enable lanes.

---

## 7. Implementation Checklist

- [ ] **ROHD Constants (`constants.dart`):** Define `ParticleWidths.doubleWord = 64`, add memory opcodes `0x3A`–`0x3F`, `0x2A`–`0x2D`, sub-word arithmetic `0x49`–`0x4C`, `0x58`–`0x5B`, and `DMULL`/`DMULH` (`0x1A`–`0x1D`).
- [ ] **ALU Datapath (`alu.dart`):** Expand operand busses to 64 bits; implement 6-bit shift amounts (`shiftAmt6`) and 32-bit sign-extending arithmetic (`ADDW`, `SUBW`).
- [ ] **Register File (`register_file.dart`):** Expand data registers and shadow bank to 64 bits.
- [ ] **Memory Interface (`memory_bus.dart`):** Implement 8-byte alignment verification (Trap 14 on `Addr[2:0] != 000`) and 8-bit byte enables.
- [ ] **Assembler (`tools/pasm.py`):** Register new 64-bit mnemonics and synthesize `LOAD64` macro expansions.
- [ ] **Simulator (`tools/psim.py`):** Update architectural register masks to `0xFFFFFFFFFFFFFFFF` and add 64-bit execution semantics.