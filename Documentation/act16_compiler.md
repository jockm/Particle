# ACT16 Systems Compiler (`act16c.py`)

`act16c.py` is the optimizing systems compiler for the ACT16 language, targeted directly at the Particle 32-bit architecture. ACT16 provides an Action!-inspired, systems-level syntax with low-level hardware control, explicit word/sub-word typing, pointer mechanics, and native streaming primitives.

---

## Command-Line Usage

```bash
python3 tools/act16c.py <input.act> [options]
```

### Options
* `<input.act>`: ACT16 source file.
* `-o`, `--output <file.asm>`: Output Particle assembly source file (default: `out.asm`).
* `-D`, `--define <SYM>`: Predefine preprocessor conditionals (e.g., `-DMULTICORE_ENABLE`).

---

## Language Specifications

### 1. Primitive Data Types
| Type | Bit Width | Signedness | Value Range |
|---|---|---|---|
| `u8` | 8 | Unsigned | $0 \dots 255$ |
| `s8` | 8 | Two's-complement signed | $-128 \dots 127$ |
| `u16`| 16 | Unsigned | $0 \dots 65535$ |
| `s16`| 16 | Two's-complement signed | $-32768 \dots 32767$ |
| `u32`| 32 | Unsigned | $0 \dots 4294967295$ |
| `s32`| 32 | Two's-complement signed | $-2^{31} \dots 2^{31}-1$ |
| `void`| 0 | Return type | N/A |

### 2. Pointers & Arithmetic
Pointers are declared with standard asterisk syntax: `u8*`, `u16*`, `u32*`, `s8*`, `s16*`, `s32*`.
* **Automatic Scaling**: Adding or subtracting an integer to a pointer automatically scales the byte offset according to the target element size ($+1$ for byte, $+2$ for halfword, $+4$ for word).
* **Dereferencing**: Emits appropriate sub-word instructions:
  * Loading `u8`: `LD8 Rr, (Rl)` (natively zero-extended).
  * Loading `s8`: `LD8 Rr, (Rl)` followed by `SEXT8 Rr`.
  * Loading `u16`: `LD16 Rr, (Rl)` (natively zero-extended).
  * Loading `s16`: `LD16 Rr, (Rl)` followed by `SEXT16 Rr`.
  * Loading `u32`/`s32`: `LD32 Rr, (Rl)`.

### 3. Immediate Literal Selection Rules
The code generator optimizes literal constant generation based on magnitude:
* $0 \le N \le 15$: Emits single-cycle `LD Rr, Imm4`.
* $-15 \le N \le -1$: Emits single-cycle `LD Rr, -Imm4`.
* $N \le 	ext{0xFFFF}$: Emits 3-instruction sequence `LOAD16 Rr, value`.
* $N \le 	ext{0xFFFFFF}$: Emits 4-instruction sequence `LOAD24 Rr, value`.
* $N > 	ext{0xFFFFFF}$: Emits 5-instruction sequence `LOAD32 Rr, value`.

### 4. Streaming Channel Primitives
ACT16 exposes built-in language routines mapping to hardware streaming instructions:
```c
u32 data = readfifo(0);               // Compiles to: FIFO.R R1, 0
writefifo(1, packet);                 // Compiles to: FIFO.W R1, 1
if (tryreadfifo(0, &val)) { ... }     // Compiles to: FIFO.TRYR R2, 0 + status flag in R14
```
