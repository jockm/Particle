# Particle Processor Architecture Specification

## 1. System Overview
Particle is a 32-bit load/store RISC processor architecture utilizing compact, fixed-width 16-bit instructions, implemented purely in Intel ROHD (Dart sdk >= 3.0.0).

---

## 2. Register Model
* `R0`: Hardwired Constant Zero.
* `R1`–`R4`: Function argument passing and return value registers.
* `R5`–`R10`: Preserved callee-saved general registers.
* `R11`–`R13`: Scratchpad caller-saved registers.
* `R14`: Subroutine link register (`RCALL`/`RRET`), immediate accumulator, and wide branch register.
* `R15` (`SP`): Architectural stack pointer (full-descending, 4-byte aligned).

---

## 3. Control Flow & Relative Branch Instructions

### 3.1 Control Flow (0xA0 - 0xAF)
* `0xA0`: `JMP Rr, Rl` — Indirect jump and link ($Rl \leftarrow PC + 2; PC \leftarrow Rr$)
* `0xA1`: `RJUMP Rr, Rl` — Relative jump and link ($Rl \leftarrow PC + 2; PC \leftarrow PC + (Rr \times 2)$)
* `0xA2`: `TRAP Rr` — Software trap on register vector
* `0xA3`: `TRAP Imm4` — Software trap on immediate vector
* `0xA4`: **`BRANCH Rr`** — Arbitrary relative branch forward or backward without linking. $Rr$ is treated as a signed 32-bit integer representing 16-bit word offset ($PC \leftarrow PC + (\text{signed}(Rr) \times 2)$).

### 3.2 Forward Branches (0xB0 - 0xBB)
All offsets represent 16-bit halfwords added to the current PC ($PC \leftarrow PC + (\text{offset} \times 2)$).

| Opcode | Mnemonic & Syntax | Format | Reach | Condition |
| :--- | :--- | :--- | :--- | :--- |
| `0xB0` | `FBRA <label>` | Imm8 | 0..255 halfwords | Unconditional |
| `0xB4` | `FBRA.Z Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr == 0$ |
| `0xB5` | `FBRA.N Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr < 0$ |
| `0xB6` | `FBRA.P Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr > 0$ |
| `0xBA` | `FBRA.NZ Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr \ne 0$ |
| `0xB7` | `FBRA.Z R14, <label>` | Imm8 | 0..255 halfwords | If $R14 == 0$ |
| `0xB8` | `FBRA.N R14, <label>` | Imm8 | 0..255 halfwords | If $R14 < 0$ |
| `0xB9` | `FBRA.P R14, <label>` | Imm8 | 0..255 halfwords | If $R14 > 0$ |
| `0xBB` | `FBRA.NZ R14, <label>` | Imm8 | 0..255 halfwords | If $R14 \ne 0$ |

### 3.3 Backward Branches (0xC0 - 0xCB)
All offsets represent 16-bit halfwords subtracted from current PC ($PC \leftarrow PC - (\text{offset} \times 2)$).

| Opcode | Mnemonic & Syntax | Format | Reach | Condition |
| :--- | :--- | :--- | :--- | :--- |
| `0xC0` | `BBRA <label>` | Imm8 | 0..255 halfwords | Unconditional |
| `0xC4` | `BBRA.Z Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr == 0$ |
| `0xC5` | `BBRA.N Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr < 0$ |
| `0xC6` | `BBRA.P Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr > 0$ |
| `0xCA` | `BBRA.NZ Rr, <label>` | R-Imm4 | 0..15 halfwords | If $Rr \ne 0$ |
| `0xC7` | `BBRA.Z R14, <label>` | Imm8 | 0..255 halfwords | If $R14 == 0$ |
| `0xC8` | `BBRA.N R14, <label>` | Imm8 | 0..255 halfwords | If $R14 < 0$ |
| `0xC9` | `BBRA.P R14, <label>` | Imm8 | 0..255 halfwords | If $R14 > 0$ |
| `0xCB` | `BBRA.NZ R14, <label>` | Imm8 | 0..255 halfwords | If $R14 \ne 0$ |