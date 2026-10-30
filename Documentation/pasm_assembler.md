# Particle Macro Assembler (`pasm.py`)

`pasm.py` is the official two-pass macro assembler for the Particle 32-bit RISC processor. It parses human-readable assembly source files, resolves forward/backward labels and symbols, expands macros, processes nested conditionals, and emits raw binary images, Intel-style hexadecimal listings, or C header arrays.

---

## Command-Line Usage

```bash
python3 tools/pasm.py <source.asm> [options]
```

### Arguments and Flags
* `<source.asm>`: Primary assembly input file.
* `-o`, `--output <file>`: Output emission destination (default: `a.out`).
* `-I`, `--include <dir>`: Add directory to include search path for `.include` directives.
* `-D`, `--define <SYM>[=<VAL>]`: Predefine symbols/macros before parsing (e.g. `-DDEBUG`, `-DCORE_ID=1`).
* `--format {bin,hex,c}`: Output format:
  * `bin`: Raw little-endian machine code binary.
  * `hex`: 16-bit hexadecimal words per line (for FPGA Block RAM initialization).
  * `c`: C-style array `const uint16_t particle_rom[] = { ... };`.

---

## Directives Reference

### Symbol & Origin Control
* `.org <expr>`: Sets the program emission counter to `<expr>`. Used to locate code at vector slots (e.g., `.org 0x00000100`).
* `.align <boundary>`: Pads emission with zero bytes until the current address is aligned to an integer multiple of `<boundary>` bytes.
* `.define <symbol> <expression>`: Defines a compile-time numeric constant or label alias.

### Data Allocation Directives
* `.byte <v1>, <v2>, ...`: Emits one or more 8-bit bytes.
* `.half <v1>, <v2>, ...`: Emits one or more 16-bit halfwords (little-endian).
* `.word <v1>, <v2>, ...`: Emits one or more 32-bit words (little-endian).
* `.asciz "<string>"`: Emits a null-terminated UTF-8 ASCII string.

### File Inclusion
* `.include "<filename>"`: Searches current directory and `-I` search paths to inline include source files (e.g. `.include "lib/common.inc"`).

### Preprocessor Conditionals
Conditionals may be nested up to 16 levels deep:
* `.ifdef <symbol>` ... `.else` ... `.endif`
* `.ifndef <symbol>` ... `.else` ... `.endif`
* `.if <expression>` ... `.else` ... `.endif`

### Macro Engine
Macros support parameter substitution via `%parameter` syntax and unique local label generation using `._label_%`:
```assembly
.macro LOAD16 reg, value
    LD      R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro
```

---

## Register Syntax
Registers are specified as `R0` through `R15` (case-insensitive) or `SP` (alias for `R15`).
* `R0`: Hardwired Zero.
* `R1`–`R4`: Parameter passing / return values.
* `R5`–`R10`: Callee-saved general registers.
* `R11`–`R13`: Caller-saved scratchpad registers.
* `R14`: Return address link register and immediate loading accumulator.
* `R15`: Architectural stack pointer (full-descending).
