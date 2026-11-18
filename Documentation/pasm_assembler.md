# Particle Macro Assembler (`pasm`)

`pasm` is the two-pass macro assembler for the Particle 32-bit RISC processor, written in Dart (`apps/tools/pasm`, built into `build/tools/pasm` by `make pasm` or `make tools`). It parses assembly source files, resolves forward and backward labels and symbols, expands macros, processes nested conditionals, and emits a raw binary image or 16-bit hexadecimal words, with a listing file beside it.

---

## Command-Line Usage

```bash
build/tools/pasm [options] <source.asm> [<source.asm> ...]
```

### Arguments and Flags
* `<source.asm>`: One or more assembly source files, assembled as one image in the order given.
* `-h`, `--help`: Show the usage and exit.
* `-o`, `--output <file>`: Output emission destination (default: `a.out`).
* `-I`, `--include <dir>`: Add directory to include search path for `.include` directives.
* `-D`, `--define <SYM>[=<VAL>]`: Predefine a symbol before parsing (e.g. `-DDEBUG`, `-DCORE_ID=1`). `<VAL>` is a decimal number; without one the symbol is 1.
* `--format {bin,hex}`: Output format (default: `bin`):
  * `bin`: Raw little-endian machine code binary.
  * `hex`: One 16-bit hexadecimal word per line (for FPGA Block RAM initialization).

A listing, with each line's address, bytes and source line number and a symbol table, is always written beside the output, with the same name and the extension `.lst`.

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
* `.asciz "<string>"` (or `.string`): Emits a null-terminated UTF-8 ASCII string.

### File Inclusion
* `.include "<filename>"`: Searches current directory and `-I` search paths to inline include source files (e.g. `.include "lib/common.inc"`).

### Preprocessor Conditionals
Conditionals may be nested:
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

An error in a line a macro expands to is reported at the line that calls the macro, and names the macro and the line of its definition. For a macro called from another macro, it names each, innermost first:

```text
main.asm:11: error: Unknown register 'R99' (in macro INNER, defs.inc:2, from macro OUTER, defs.inc:7) [register]
```

In the editor the error is on the calling line, with links to the macro lines.

---

## Errors

The preprocessor (includes, conditionals and macros) and pass 1 (laying out addresses, including `.org` and `.align`) stop at the first error, because an error there changes everything after it. Pass 2 (encoding each line) reports every error it finds, up to 20; a line with an error keeps the room pass 1 gave it, so the lines after it keep their addresses. Nothing is written when there are errors.

A symbol that is not defined is reported once, naming the other lines that use it:

```text
main.asm:12: error: undefined symbol '_main' (also used on lines 14, 18) [undefined-symbol]
```

The editor marks every use.

### Codes

Every error and warning, from `pasm` and from `pasm_lint`, ends with a code in brackets. The editor shows it with the message.

| Code | Kind | What it covers |
|------|------|----------------|
| `syntax` | error | Unknown mnemonic, wrong number of operands, a malformed operand, branch condition or string |
| `register` | error | An unknown or out-of-range register |
| `range` | error | An immediate or data value out of range (`.byte`, `.half`, LDI, LDIS, LD, 4-bit immediates, trap numbers, bit indexes) |
| `undefined-symbol` | error | A symbol or branch target that is not defined |
| `expression` | error | A malformed expression |
| `branch-range` | error | A branch target too far away |
| `branch-direction` | error | A forward branch that goes backward, or a backward branch that goes forward |
| `jump` | error | A `JUMP` to an odd address, or `JUMP` sizes that do not settle |
| `include` | error | An include file that is not found |
| `reserved-name` | error | A label with the name the assembler defines for the end of the image |
| `r0-write` | error | An instruction that writes `R0` |
| `stack-misaligned` | error | `SP` adjusted by something other than a multiple of 4 |
| `external-call` | warning | An `RCALL` target not defined in the file or its includes |
| `r14-clobbered` | warning | `R14` read after something overwrote it |
| `misaligned` | warning | Data or code after byte-sized data with no `.align` |
| `stack-balance` | warning | Pushes and pops that do not match |

---

## Hiding Errors and Warnings

`pasm_lint` and the language server (`pasm_lsp`) hide the errors and warnings on lines marked by these comments:

* `; pasm-disable-line` at the end of a line: that line.
* `; pasm-disable-next-line` on a line of its own: the next line.
* `; pasm-disable` ... `; pasm-enable`: every line between them.
* `; pasm-disable-file` anywhere in the file: the whole file.

Without codes they hide every diagnostic on those lines. With codes after them, separated by commas or spaces, they hide only those; text after the codes, such as a reason, is ignored:

```assembly
    LOAD32  R14, _main  ; pasm-disable-line undefined-symbol: _main is in the program
```

The assembler itself does not read them: an error still stops the build. In the editor, once a preprocessor or pass 1 error is hidden, nothing after it is checked by the assembler; the lint checks still cover the whole file.

---

## Pseudo-Instructions

### `JUMP <label>`
An unconditional jump to `<label>` at any distance. The assembler chooses the smallest form that reaches the target:

| Distance to the target | Assembled as | Size |
|---|---|---|
| Up to 255 halfwords forward or back | `FBRA <label>` / `BBRA <label>` | 1 halfword |
| Further, target below `0x10000` | `LDI R14, <label>` + `JMP R14, R0` | 3 halfwords |
| Further, any target | `LDI R14, <label> >> 16` + `PUSH8` + `PUSH8` + `JMP R14, R0` | 5 halfwords |

The longer forms overwrite `R14`. A `JUMP`'s size depends on where its target ends up, and other `JUMP`s change those addresses, so pass 1 repeats until no `JUMP` needs to grow. The Action compiler writes its unconditional jumps this way.

---

## Register Syntax
Registers are specified as `R0` through `R15` (case-insensitive) or `SP` (alias for `R15`).
* `R0`: Hardwired Zero.
* `R1`–`R4`: Parameter passing / return values.
* `R5`–`R10`: Callee-saved general registers.
* `R11`–`R13`: Caller-saved scratchpad registers.
* `R14`: Return address link register and immediate loading accumulator.
* `R15`: Stack pointer by convention (full-descending, 4-byte aligned).
