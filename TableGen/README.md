# Particle LLVM backend: TableGen description

These files go in `llvm/lib/Target/Particle/`. They describe the whole Particle ISA to LLVM: registers, encodings, assembly syntax, instruction selection patterns and the calling convention.

| File | Contents |
|---|---|
| `Particle.td` | Top level: target, asm parser/writer, processors (`generic`, `ulx3s`) |
| `ParticleRegisterInfo.td` | R0–R15 (alt names `zero`, `lr`, `sp`), `GPR`, single-register `R14C`, `SPC` |
| `ParticleInstrFormats.td` | 16-bit formats `FRR`, `FRI4`, `FR`, `FI4`, `FI8`, `FN`, `FSPMem`, `Pseudo` |
| `ParticleInstrInfo.td` | Every opcode in spec §4, SDNodes, operands, pseudos, ISel patterns |
| `ParticleCallingConv.td` | Arguments/returns in R1–R4, then the stack; callee-saved R5–R10 and R14 |
| `CMakeLists.txt` | The `tablegen()` calls |
| `check.sh` | Runs all 10 backends: `./check.sh <llvm/include> [llvm-tblgen]` |

## Verification

Tested with `llvm-tblgen` 18.1.3 and the matching `llvm/include` headers. All 10 backends generate cleanly: register-info, instr-info, emitter, asm-writer, asm-matcher, disassembler, dag-isel, callingconv, subtarget and pseudo-lowering.

- **Opcodes:** every opcode in the spec is defined with its spec encoding (diffed mechanically against the markdown). The six exceptions are listed as question 1 below.
- **Selection patterns:** the generated selector has 132 patterns.

## Spec questions (please confirm; each one maps to a single spot in the .td)

1. **`LDx Rr, (Rl + Imm4)` / `STx (Rr + Imm4), Rl` (0x16, 0x17, 0x26, 0x27, 0x36, 0x37) are left out.** Opcode (8 bits) + Rr (4) + Rl (4) already fills all 16 bits, so there is no room for Imm4. How does the hardware encode these? Until then, codegen uses `(Rl)` plus `ADD`.
2. **SP+Imm4 displacement scaling.** The default is a byte offset (0–15), which is the literal reading of the spec. If the hardware scales by access size like SH-2 does, set `SPDispShift16 = 1` and `SPDispShift32 = 2` at the top of `ParticleInstrInfo.td`. The encoder and decoder follow automatically (checked).
3. **CLZ.** The spec says "count leading zeros of Rr" but the instruction takes `Rr, Rl`. I modelled it as `Rr ← clz(Rl)` with `clz(0) = 32`.
4. **TAS.** Modelled as an atomic swap, `Rl ↔ Mem32[Rr]`, and used for `atomicrmw xchg`.
5. **`jmp r14, r14`.** The direct-call sequence assumes JMP reads Rr before writing the link into Rl.
6. **SADD/SSUB vs ADD/SUB.** These are identical in two's complement, so SADD/SSUB get no patterns. If they trap on overflow, say so.
7. **Indexed addressing.** Post-increment and pre-decrement are assumed to step by the access size.
8. **Branch displacement base** (address of the branch, or of the branch + 2). This lives in C++ fixup code, not the .td, but it needs deciding.

## Design choices

- **Two-address ALU.** `Rr ← Rr op Rl` uses a tied `$rr_in` operand. `>`/`>=` compares swap operands, e.g. `setugt a,b → slt b,a`.
- **Implicit-R14 forms** (`ld r14, imm8`, `push8`, `slt r14, imm8`, `fbra.z r14, imm8`, …) use a one-register class `R14C`. ISel can then produce values in R14 and the register allocator inserts the copies. Assembly is written `ld r14, 200`.
- **R14 is in the callee-saved list.** Like RISC-V's `ra`, the return address is saved only when a function overwrites R14 (with a call or an 8-bit constant).
- **Constants:**

  | Range | Sequence | Instructions |
  |---|---|---|
  | 0–15, −15…−1 | `ld rN, imm4` | 1 |
  | ±255 | `ld r14, imm8` | 1 |
  | 16-bit | + `push8` | 2 |
  | 24-bit | + `push8` | 3 |
  | anything else | + `push8` | 4 |

  The negative-prefix forms are covered too, e.g. −1000 = `ld r14,-4 ; push8 r14,0x18`.
- **`select`** has no branch: `f ^ ((t ^ f) & -c)`. This needs `ZeroOrOneBooleanContent`.
- **Branches.** ISel emits direction-agnostic `PseudoBR`, `PseudoBRZ`, `PseudoBRNZ`, `PseudoBRN` and `PseudoBRP`. A pre-emit pass (after branch relaxation) picks FBRA or BBRA and the Imm4 or Imm8 form. `brcond (x==0 / x!=0 / x<0 / x>0)` maps straight to these pseudos.
- **Calls:**
  - Direct: `PseudoCALL` is `ld r14,b3 ; push8 r14,b2 ; push8 r14,b1 ; push8 r14,b0 ; jmp r14, r14`, 10 bytes, with no scratch register needed.
  - Indirect: `jmp rX, r14`.
  - Return: `jmp r14, r0`, which prints as `rret`.
- **NOP** is `ld r0, r0` (0x0000).
- **Not used by codegen:** XCHG, XCHGALL, XCHGMOST, RBASE, FIFO.*, JTBL, BRANCH, RJUMP and MULHSU. They are assemble/disassemble only, for inline asm and hand-written handlers. `CSR_Particle_Shadow` is provided for handlers entered via `xchgmost`.

## C++ the generated code calls (names must match)

- **MCCodeEmitter:** `getNegImmOpValue` (store the magnitude) and `getBranchTargetOpValue` (pick the fixup kind from the opcode: forward/back × 4/8-bit).
- **Disassembler:**
  - `DecodeGPRRegisterClass`
  - `decodeUImmOperand<N>`
  - `decodeNegImmOperand<N>`
  - `decodeImplicitR14Insn`: walk the `MCInstrDesc`, add R14 for each `R14C` operand, and decode `Inst{7-0}` for the immediate or branch target. It exists because LLVM 18's decoder generator silently drops operands that have no encoding bits.
- **InstPrinter:** `printBranchOperand`.
- **AsmParser operand:**
  - Predicates: `isUImm4`, `isUImm8`, `isNImm4`, `isNImm8`, `isSPOff8`, `isSPOff16`, `isSPOff32`, `isBrTarget4`, `isBrTarget8`
  - Renderers: `addImmOperands`, `addExprOperands`, `addRegOperands`
  - `Match_Invalid*` diagnostics
  - `sp` must come through as a token inside `(sp + N)`
- **ISelLowering:**
  - Nodes: `ParticleISD::CALL`, `RET_GLUE`, `WRAPPER`
  - `LowerCall`, `LowerReturn` and `LowerFormalArguments` using `CC_Particle` and `RetCC_Particle`
  - `setBooleanContents(ZeroOrOneBooleanContent)`
  - Expand `BR_CC` and `SELECT_CC`
  - Custom-lower `GlobalAddress` and friends to `WRAPPER`
  - `setIndexedStoreAction` if you want the post-increment/pre-decrement stores
  - Select indexed loads in `Select()`
- **RegisterInfo / FrameLowering:**
  - Reserve R0 and R15
  - `eliminateFrameIndex` for `PseudoFRAMEADDR` and the `*_SP` forms (rewrite to `(Rl)` + scratch register when the offset overflows Imm4)
  - Prologue and epilogue
- **InstrInfo:**
  - `copyPhysReg` uses `LDrr`
  - Stack-slot spills and reloads use `ST32_SP` / `LD32_SP`
  - `analyzeBranch` / `insertBranch` work on the pseudo branches
  - `getInstSizeInBytes`
- **MCInstLower:** expand `PseudoLA` and `PseudoCALL` into byte-select fixups. The rest are handled by the generated `PseudoInstExpansion`.
