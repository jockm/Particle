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
* `--no-long-branches`: Assemble for a core built without the 2-word PC-relative instructions (`CpuConfig.enableLongBranches` off). `BRA`, `BRA.Z`/`NZ`/`N`/`P`, `RJUMP label, Rl`, `BEQ`, `BNE` and `LEA` are errors (`long-branch`); `JUMP`, `JUMP.cc` and `RCALL` use the forms without them. It predefines `__NO_LONG_BRANCHES`, which `-D __NO_LONG_BRANCHES` does too, and which macros can test with `.ifdef`.

A listing, with each line's address, bytes and source line number, each label with its address, and a symbol table, is always written beside the output, with the same name and the extension `.lst`.

---

## Source Format

Each line holds at most one label, instruction, directive or macro call; `;` starts a comment. A label is a name followed by `:` (`loop:`), and may share its line with an instruction. Mnemonics, directives and register names are not case-sensitive; labels and symbols are. Operands are separated by commas.

### Registers

`R0` through `R15`, or `SP` for `R15`. `R0` always reads zero. For their roles in the calling convention, see `memory_map_and_conventions.md`.

### Memory operands

Loads, stores (`LD8`/`LD16`/`LD32`, `ST8`/`ST16`/`ST32`) and `TAS` address memory through a register in parentheses:

| Operand | Address used | Afterwards |
|---|---|---|
| `(Rr)` | `Rr` | — |
| `(Rr++)` | `Rr` | `Rr` += the access size |
| `(Rr--)` | `Rr` | `Rr` −= the access size |
| `(++Rr)` | `Rr` + the access size | `Rr` holds that address |
| `(--Rr)` | `Rr` − the access size | `Rr` holds that address |

A load names the register first (`LD32 R1, (R2)`); a store names the memory operand first (`ST32 (R2), R1`, or `LD32 (R2), R1`). `TAS` takes only `(Rr)`.

### Values and expressions

Where an instruction or directive takes a value, it may be a number, a label, a `.define`d symbol, or an expression of them:

* **Numbers**: decimal (`42`, `-3`), hexadecimal (`0x2A`) or binary (`0b101010`).
* **Operators**, from the highest precedence to the lowest: parentheses; unary `~` and `-`; `*`, `/`, `%`; `+`, `-`; `<<`, `>>`; `&`; `^`; `|`. Arithmetic is on whole numbers.
* **Labels** are the address of the line they mark. The assembler also defines `__image_end`, the address just past the last byte of the image (the allocator in `lib/alloc.asm` starts the heap there).

Register names cannot appear in a value. Each instruction's range of values is checked (see *Errors*).

### Branch operands

A conditional branch's second operand is its target or, for `.Z`, `.N` and `.P`, a register holding the displacement:

| Written | Encodes |
|---|---|
| `FBRA.Z R3, label` | The Imm4 form (`0xB4`): up to 15 halfwords. When the register is `R14` and the target is 16 to 255 halfwords away, the R14 Imm8 form (`0xB7`) |
| `FBRA.Z R3, R5` | The register form (`0xB1`): branch to PC + `R5` × 2 when `R3` is zero |
| `BBRA.N R3, R5` | The register form (`0xC2`): branch to PC − `R5` × 2 when `R3` is negative |

`FBRA.NZ` and `BBRA.NZ` have no register form.

The 2-word branches take a target either way, up to 32K halfwords off (`branch-range` beyond that), and a target at an odd address is an error (`jump`):

| Written | Encodes |
|---|---|
| `BRA label` | `0xCC` |
| `BRA.Z R3, label` (`.NZ`, `.N`, `.P`) | `0xBC`–`0xBF`: branch when `R3` is zero (not zero, negative, positive) |
| `BEQ R3, R5, label`, `BNE R3, R5, label` | `0xCE`, `0xCF`: branch when `R3` equals (doesn't equal) `R5` |
| `RJUMP label, R9` | `0xCD`: jump, with `R9` = the address after it (PC + 4). `RJUMP R2, R9` is still the 1-word register form (`0xA1`) |
| `LEA R6, label` | `0x09`: `R6` = the address of `label`, up to 32 KiB either way (in bytes; `branch-range` beyond) |

---

## Directives Reference

### Symbol & Origin Control
* `.org <expr>`: Sets the program emission counter to `<expr>`. Used to locate code at vector slots (e.g., `.org 0x00000100`).
* `.align <boundary>`: Pads emission with zero bytes until the current address is aligned to an integer multiple of `<boundary>` bytes. The boundary must be positive; it need not be a power of two.
* `.define <symbol> <expression>`: Defines a compile-time numeric constant or label alias. A symbol can be defined only once, and a register name (`R0`–`R15`, `SP`) cannot be defined.
* `.global <symbol>` and `.data`: Accepted and ignored (every label is visible to every file already). Any other unknown directive is an error.

Labels must be unique, and cannot be register names. Instructions must be at even addresses, and bytes cannot be emitted twice at the same address (an `.org` back over earlier code is an error).

Register names cannot appear in expressions: `BBRA R1` and `LDI R2, R3 + 4` are errors, not the numbers 1 and 7.

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
Macros support parameter substitution via `%parameter` syntax and unique local label generation using `._label_%`. A macro must be called with exactly as many arguments as it has parameters, and every `.macro` needs its `.endmacro` (and every `.if`, `.ifdef` and `.ifndef` its `.endif`):
```assembly
.macro LOAD16 reg, value
    LD      R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro
```

Conditionals (`.if`, `.ifdef`, `.ifndef`, `.else`, `.endif`) and `.define` inside a macro are evaluated each time the macro is expanded, after its arguments are substituted, so a macro can choose what to emit from its arguments:
```assembly
.macro SLOT n
.ifdef HANDLER_%n
    LD      R1, 1
.else
    LD      R1, 2
.endif
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
| `syntax` | error | Unknown mnemonic or directive, wrong number of operands or macro arguments, a memory operand where none is allowed, a malformed operand, branch condition or string, an unmatched `.macro` or `.if` |
| `register` | error | An unknown or out-of-range register, a register where a value is needed (including inside an expression), or a value where a register is needed |
| `range` | error | An immediate or data value out of range (`.byte`, `.half`, `.word`, LDI, LDIS, LD, PUSH4, PUSH8, 4-bit immediates (`-8..7` for the signed forms of SADD, SSUB, SDIV, SMOD, SMULH and SSLT), trap numbers, window offsets, MBOX vectors, bit indexes, `.align`) |
| `undefined-symbol` | error | A symbol or branch target that is not defined |
| `expression` | error | A malformed expression |
| `branch-range` | error | A branch target too far away |
| `branch-direction` | error | A forward branch that goes backward, or a backward branch that goes forward |
| `jump` | error | A `JUMP`, `JUMP.cc` or 2-word branch to an odd address, or `JUMP` sizes that do not settle |
| `long-branch` | error | A 2-word branch, `RJUMP label` or `LEA` assembled with `--no-long-branches` |
| `include` | error | An include file that is not found |
| `reserved-name` | error | A label with the name the assembler defines for the end of the image, or a label or `.define` named like a register |
| `duplicate-symbol` | error | A label or `.define` defined twice |
| `overlap` | error | Bytes emitted at an address already used (an `.org` back over earlier code) |
| `r0-write` | error | An instruction that writes `R0` |
| `stack-misaligned` | error | `SP` adjusted by something other than a multiple of 4 |
| `external-call` | warning | An `RCALL` target not defined in the file or its includes |
| `r14-clobbered` | warning | `R14` read after something overwrote it |
| `misaligned` | error / warning | An instruction at an odd address (error, from the assembler); data or code after byte-sized data with no `.align` (warning, from the linter) |
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
| Up to 32K halfwords forward or back | `BRA <label>` | 2 halfwords |
| Further (or with `--no-long-branches`), target below `0x10000` | `LDI R14, <label>` + `JMP R14, R0` | 3 halfwords |
| Further, any target | `LDI R14, <label> >> 16` + `PUSH8` + `PUSH8` + `JMP R14, R0` | 5 halfwords |

The `LDI` forms overwrite `R14`. A `JUMP`'s size depends on where its target ends up, and other `JUMP`s change those addresses, so pass 1 repeats until no `JUMP` needs to grow. The Action compiler writes its unconditional jumps this way.

---

---

### `JUMP.Z Rr, <label>` (and `JUMP.NZ`, `JUMP.N`, `JUMP.P`)
A conditional branch to `<label>` at any distance, sized the same way:

| Distance to the target | Assembled as | Size |
|---|---|---|
| Up to 15 halfwords (255 when `Rr` is `R14`) | `FBRA.Z Rr, <label>` / `BBRA.Z Rr, <label>` | 1 halfword |
| Up to 32K halfwords | `BRA.Z Rr, <label>` | 2 halfwords |
| Further, or with `--no-long-branches` | `.Z`/`.NZ`: the opposite short branch past the `JUMP` far form. `.N`/`.P` (which have no opposite): `FBRA.N Rr` to the far form, and an `FBRA` past it | 4 or 6 halfwords (`.Z`/`.NZ`), 5 or 7 (`.N`/`.P`) |

The far forms overwrite `R14` when the branch is taken.

## Standard Macros (`lib/common.inc`)

`lib/common.inc` defines the trap constants (`TRAP_TABLE_BASE` = `0x100`, `TRAP_STRIDE_BYTES` = 16, and the vector numbers `TRAP_RESET` 0, `TRAP_MBOX` 1, `TRAP_ALIGN` 14, `TRAP_ILLEGAL` 15) and these macros. Most of them use `R14` as scratch, so they overwrite it.

| Macro | Expands to | Effect |
|---|---|---|
| `LOAD16 reg, value` | `LDI` | `reg` = a 16-bit value, zero-extended |
| `LOAD16S reg, value` | `LDIS` | `reg` = a 16-bit value, sign-extended |
| `LOAD24 reg, value` | `LDI R14` + `PUSH8` + `LD` | `reg` = a 24-bit value (overwrites `R14`) |
| `LOAD32 reg, value` | `LDI R14` + 2 × `PUSH8` + `LD` | `reg` = any 32-bit value (overwrites `R14`) |
| `LOAD_R14_16 value` | `LDI R14` | `R14` = a 16-bit value |
| `LOAD_R14_32 value` | `LDI R14` + 2 × `PUSH8` | `R14` = any 32-bit value |
| `LDZP reg, addr` | `LD R14` + `LD` | `reg` = a zero-page address (0–255), in 2 instructions |
| `LDZP32 reg, addr` | `LD R14` + `LD32` | `reg` = the 32-bit word at a zero-page address |
| `STZP32 addr, reg` | `LD R14` + `ST32` | stores `reg` at a zero-page address |
| `START_PROGRAM` | `LOAD32 R15` + `LDI R14` + `JMP` | sets the stack pointer to `0x00010000` and jumps to `_main` |
| `LJMP target` | `LDI R14` + `JMP R14, R0` | jumps to a target below `0x10000` |
| `RCALL target` | `RJUMP target, R14`; `LDI R14` + `JMP R14, R14` with `--no-long-branches` | calls a routine up to 32K halfwords away (below `0x10000` with `--no-long-branches`); the return address is in `R14` |
| `RLCALL target` | `LDI R14` + `JMP R14, R14` | as the old `RCALL`: a routine below `0x10000`, on any core |
| `RRET` | `JMP R14, R0` | returns to the address in `R14` |
| `PUSH32 reg` | `LD32 (--R15), reg` | pushes a register |
| `POP32 reg` | `LD32 reg, (R15++)` | pops a register |
| `FAST_ENTER_TRAP` | `XCHGMOST` | starts a trap handler: `R1`–`R14` swap with the shadow bank |
| `FAST_EXIT_TRAP` | `XCHGMOST` + `JMP R14, R0` | ends a trap handler and returns |

`JUMP` (above) reaches any address; `LJMP` reaches targets below `0x10000`, and `RCALL` targets up to 32K halfwords away (below `0x10000` with `--no-long-branches`).

## Vector Tables (`lib/vectors.inc`)

Every program fills all 16 vector slots (16 bytes each, `0x100`–`0x1FF`), so a trap never lands in code that isn't meant for it. `lib/vectors.inc` includes `lib/common.inc` and provides:

| Macro | Slot contents | Use |
|---|---|---|
| `VECTOR_TABLE reset` | the whole table | reset jumps to `reset`, vectors 1–15 are unexpected, and `_unexpected_trap` follows at `0x200`. For programs that handle no traps |
| `RESET_SLOT handler` | `LOAD_R14_32` + `JMP` | slot 0 |
| `TRAP_SLOT n, handler` | `XCHGMOST` + `LOAD_R14_32` + `JMP` | a handler that returns with `FAST_EXIT_TRAP`; the return PC waits in the shadow `R14`, so the handler may use `R1`–`R14` |
| `TRAP_SLOT_BRANCH n, handler` | `FBRA handler` | changes no register (`R14` is still the return PC). `handler` must start within 510 bytes after the slot |
| `TRAP_SLOT_UNEXPECTED n` | `XCHGMOST`, `LD R1, n`, jump to `_unexpected_trap` | a vector the program doesn't use |
| `UNEXPECTED_TRAP_ROUTINE` | `_unexpected_trap`, at `0x200` | stores the return PC at `UNEXPECTED_TRAP_PC` (`0xF4`) and the vector at `UNEXPECTED_TRAP_VECTOR` (`0xF8`), then spins |

Each slot macro starts with `.org` at its slot, so slots are written in order and a slot that overflows is an assembler error. A program with handlers writes the 16 slots out, then `UNEXPECTED_TRAP_ROUTINE`:

```assembly
.include "lib/vectors.inc"
    RESET_SLOT _start
    TRAP_SLOT 1, _on_mbox
    TRAP_SLOT_UNEXPECTED 2
    ; ... 3 to 15
    UNEXPECTED_TRAP_ROUTINE
```

`MBOX_VALUE` (`0xFC`) is the word where a core stored the value of the last `MBOX` it received, before `Documentation/mbox_design.md`; it is kept for old programs, and nothing writes it now. The value and the sender come from the network interface's registers instead; `lib/common.inc` defines their addresses as `NI_FLUSH`, `NI_MBOX_VALUE`, `NI_MBOX_SOURCE` and `NI_CONFIG` (`0xFF00`–`0xFF0C`, for `LDIS`, which sign-extends them to `0xFFFF_FF00`–`0xFFFF_FF0C`).
