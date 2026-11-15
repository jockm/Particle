# Particle Architecture Specification — Addendum 03: Load Immediate (`LDI` & `LDIS`)

**Document Status:** Draft / Proposed ISA Extension  
**Target Architecture:** Particle 32-bit RISC Core (`ParticleCpuCore`)  
**Affects:** ISA Specification (Section 4.1), ROHD Hardware Core (`cpu_core.dart`), Assembler (`pasm` / `pasm.py`), Simulator (`psim.py`), Compiler (`act16c.py`), Standard Library (`lib/common.inc`)

---

## 1. Overview & Motivation

In the baseline Particle ISA, instructions are strictly 16 bits wide (`[15:8]` Opcode, `[7:4]` $Rr$, `[3:0]` $Rl / Imm4$). Loading immediate values outside the 4-bit range ($-15 \dots 15$) requires either:
* Using `R14`-restricted 8-bit immediate loads (`LD R14, Imm8` / `LD R14, -Imm8`), or
* Expanding multi-instruction macros (`LOAD16`, `LOAD24`, `LOAD32`) that synthesize constants via `LD R14` followed by `PUSH8` shifts and a final register move.

Across multi-core Parcore firmware (where instruction/data TCM addresses and control constants predominantly fit within 16 bits), the 3-instruction `LOAD16` macro introduces three major penalties:
1. **Code Bloat:** Every 16-bit constant or jump target consumes 6 bytes (3 instruction words).
2. **Execution Latency:** Every 16-bit load requires 3 instruction fetch/execute cycles.
3. **`R14` Clobbering:** `LOAD16` unconditionally overwrites `R14` (the architectural subroutine and trap return link register), creating register allocation pressure and requiring careful instruction ordering around calls and traps.

This addendum introduces two 32-bit (two-word) immediate load instructions—**`LDI`** (Load Immediate Unsigned) and **`LDIS`** (Load Immediate Signed)—allowing any register $R0\text{–}R15$ to be loaded directly from a trailing 16-bit instruction word without disturbing `R14`.

---

## 2. Instruction Encoding & Opcode Allocation

### 2.1 Opcode Assignment (Section 4.1: Loads & Immediates)
Section 4.1 currently allocates opcodes `0x00` through `0x06`. `LDI` and `LDIS` are assigned to the adjacent unallocated slots **`0x07`** and **`0x08`**:

| Opcode (Hex) | Mnemonic & Syntax | Width | Format | Operation / Semantics |
| :--- | :--- | :--- | :--- | :--- |
| **`0x07`** | `LDI Rl, Imm16` | 32-bit (2 words) | `Op-Rl + Imm16` | $Rl \leftarrow \text{ZeroExtend}(\text{Mem16}[PC + 2]);\ PC \leftarrow PC + 4$ |
| **`0x08`** | `LDIS Rl, Imm16` | 32-bit (2 words) | `Op-Rl + Imm16` | $Rl \leftarrow \text{SignExtend}(\text{Mem16}[PC + 2]);\ PC \leftarrow PC + 4$ |

### 2.2 Binary Layout (Little-Endian)
Each instruction consists of two consecutive 16-bit words in instruction memory (Port A):

* **Word 0 (`PC + 0`) — Instruction Header:**
  ```text
   15             8 7       4 3       0
  +----------------+---------+---------+
  |  Opcode (8b)   | 0000(4b)|  Rl (4b)|
  +----------------+---------+---------+
  ```
  * Bits `[15:8]`: `0x07` (`LDI`) or `0x08` (`LDIS`).
  * Bits `[7:4]`: Reserved (`0b0000`).
  * Bits `[3:0]`: Destination register index $Rl \in [0..15]$ (`R0`–`R15`). *(Note: Writing to `R0` discards the result per standard architectural rules while still advancing `PC` by 4).*

* **Word 1 (`PC + 2`) — 16-Bit Immediate Payload:**
  ```text
   15                                 0
  +------------------------------------+
  |            Imm16 [15:0]            |
  +------------------------------------+
  ```
  * Stored in little-endian byte order (`[7:0]` at `PC + 2`, `[15:8]` at `PC + 3`).

---

## 3. Instruction Semantics

### 3.1 `LDI Rl, value` (Opcode `0x07`)
* **Assembly Syntax:** `LDI Rl, <expr>`
* **Valid Immediate Range:** Unsigned 16-bit integer: $0 \le \text{value} \le 65535$ (`0x0000` to `0xFFFF`).
* **Architectural Effect:**
  $$Rl \leftarrow \{16\text{'b}0,\ \text{Imm16}[15:0]\}$$
  $$PC \leftarrow PC + 4$$
* **Notes:** Bits `[31:16]` of $Rl$ are guaranteed to be zeroed (`0x0000`). Ideal for 16-bit TCM addresses, jump targets, and unsigned bitmasks (`0x0000..0xFFFF`).

### 3.2 `LDIS Rl, value` (Opcode `0x08`)
* **Assembly Syntax:** `LDIS Rl, <expr>`
* **Valid Immediate Range:** Signed 16-bit two's-complement integer: $-32768 \le \text{value} \le 32767$ (or raw 16-bit hex `0x0000..0xFFFF` interpreted as signed).
* **Architectural Effect:**
  $$Rl \leftarrow \{\{16\{\text{Imm16}[15]\}\},\ \text{Imm16}[15:0]\}$$
  $$PC \leftarrow PC + 4$$
* **Notes:** Bit `15` of `Imm16` is replicated across bits `[31:16]` of $Rl$. Enables single-instruction loading of negative integers (`-32768..-16`) and upper-bit sign-extended masks (e.g., `LDIS R7, -4096` produces `0xFFFFF000`).

---

## 4. Hardware Implementation (`ParticleCpuCore` / ROHD)

Introducing a 32-bit instruction transitions the instruction fetch unit from strictly fixed-width 16-bit fetch to variable-length (16/32-bit) fetch over the existing 16-bit Port A instruction bus.

### 4.1 Fetch & Execution State Machine
1. **`stateFetch`:**
   * `memPortAAddr <= pc`
   * Latches Word 0 (`instWord`) from `memPortARData`.
   * Transitions to `stateExec`.
2. **`stateExec` (Decode `0x07` / `0x08`):**
   * Detects `opcode == 0x07 || opcode == 0x08`.
   * Captures destination register `targetReg <= instWord[3:0]` and `isSigned <= (opcode == 0x08)`.
   * Issues second instruction read on Port A: `memPortAAddr <= pc + 2`.
   * Transitions to `stateFetchImm` (or reuses `stateWait` with an immediate-fetch sub-state flag).
3. **`stateFetchImm` (Latch & Writeback):**
   * Reads `imm16 = memPortARData[15:0]`.
   * Computes 32-bit writeback value:
     * If `isSigned`: `rfWData <= imm16.signExtend(32)`
     * Else: `rfWData <= imm16.zeroExtend(32)`
   * Asserts `rfWEn <= 1`, `rfWAddr <= targetReg`.
   * Updates program counter: `pc <= pc + 4`.
   * Transitions back to `stateFetch`.

### 4.2 Alignment & Interrupt Invariants
* **PC Alignment:** Because normal instructions increment `PC` by `+2` and `LDI`/`LDIS` increment `PC` by `+4`, 16-bit instruction alignment (`PC[0] == 0`) is strictly preserved.
* **Trap / Mailbox Interrupt Precision:** Inbound `MBOX` interrupts must only be sampled at instruction boundaries (after `stateFetchImm` completes and `PC` has advanced to `pc + 4`), or if sampled mid-instruction, must save the original `PC` of Word 0 into `R14`—never `pc + 2`—so trap return (`JMP R14, R0`) does not execute Word 1 (`Imm16`) as an opcode.
* **`JTBL` Interaction:** Jump table entries (`JTBL`) compute relative byte offsets from `PC + 2`. Existing `JTBL` tables remain valid as long as the jump table itself immediately follows the `JTBL` instruction.

---

## 5. Toolchain & Compiler Updates

### 5.1 Assembler (`tools/pasm.py` & `apps/tools/pasm/`)
* **Pass 1 (Symbol Resolution & PC Tracking):**
  * When encountering `LDI` or `LDIS`, advance `cur_pc` by **`4`** instead of `2` so all downstream labels and `FBRA`/`BBRA` relative branch displacements remain exact.
* **Pass 2 (Code Emission):**
  * Emit two 16-bit words:
    * Word 0: `(0x07 << 8) | rl` for `LDI`, or `(0x08 << 8) | rl` for `LDIS`.
    * Word 1: `val & 0xFFFF`.
* **Range Checking:**
  * `LDI`: Raise `AssemblerError` if `val < 0` or `val > 0xFFFF`.
  * `LDIS`: Raise `AssemblerError` if `val < -32768` or `val > 0xFFFF` (accepting both signed `-32768..32767` and unsigned 16-bit bit-patterns `0x8000..0xFFFF` if specified in hex).
* **Listing Output (`.lst`):**
  * Display both emitted 16-bit words alongside the source line (e.g., `00000100  070A 0500      LDI R10, 0x0500`).

### 5.2 Linter (`pasm_lint`) & Simulator (`psim.py`)
* **`pasm_lint`:** Add `LDI` and `LDIS` to the valid mnemonic table with 2-operand signature `(Register, Immediate)`.
* **`psim.py`:** In the instruction execution loop, when `opcode` is `0x07` or `0x08`, fetch `imm16 = read_mem16(pc + 2)`, zero-extend (`0x07`) or sign-extend (`0x08`) into `regs[rl]`, increment `pc += 4`, and account for `3` execution cycles.

### 5.3 Compiler Code Generation (`act16c.py`)
Update immediate literal selection rules for integer constant $N$:
1. $0 \le N \le 15$: `LD Rr, N` (2 bytes)
2. $-15 \le N \le -1$: `LD Rr, N` (2 bytes)
3. $16 \le N \le 65535$: **`LDI Rr, N`** (4 bytes, no `R14` clobber)
4. $-32768 \le N \le -16$: **`LDIS Rr, N`** (4 bytes, no `R14` clobber)
5. All other 32-bit values: `LOAD32 Rr, N` (or `LDI` + `SHIFTL` + `OR` sequence).

---

## 6. Standard Library (`lib/common.inc`) Migration

Once `LDI` and `LDIS` are implemented in hardware and `pasm`, `lib/common.inc` can be simplified immediately:

```assembly
; --- Macro: LOAD16 reg, value ---
; Loads a 16-bit unsigned constant or symbol directly into reg.
; Consumes 1 instruction (4 bytes) and does NOT clobber R14.
.macro LOAD16 reg, value
    LDI     %reg, %value
.endmacro

; --- Macro: LOAD16S reg, value ---
; Loads a 16-bit signed constant (-32768..32767) sign-extended to 32 bits.
; Consumes 1 instruction (4 bytes) and does NOT clobber R14.
.macro LOAD16S reg, value
    LDIS    %reg, %value
.endmacro

; --- Macro: RCALL target ---
; Calls a subroutine within the 64 KB firmware address space.
.macro RCALL target
    LDI     R14, %target
    JMP     R14, R14            ; Link address PC+2 placed in R14
.endmacro
```

### Summary of Architectural Impact
* **Code Density:** Reduces every 16-bit constant/address load from **6 bytes $\to$ 4 bytes** (-33%) and every `RCALL` from **12 bytes $\to$ 6 bytes** (-50%).
* **Latency:** Cuts 16-bit constant load execution from **6 cycles $\to$ 3 cycles** (-50%).
* **Register Freedom:** Frees `R14` from acting as an implicit scratch accumulator during constant synthesis across all firmware modules.