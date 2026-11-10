# Particle LLVM backend: TableGen description

These files go in `llvm/lib/Target/Particle/`. They describe the whole Particle ISA to LLVM: registers, encodings, assembly syntax, instruction selection patterns and the calling convention.

| File | Contents |
|---|---|
| `Particle.td` | Top level: target, asm parser/writer, processors (`generic`, `ulx3s`) |
| `ParticleRegisterInfo.td` | R0–R15 (alt names `zero`, `lr`, `sp`), `GPR`, single-register `R14C` |
| `ParticleInstrFormats.td` | 16-bit formats `FRR`, `FRI4`, `FR`, `FI4`, `FI8`, `FN`, `Pseudo` |
| `ParticleInstrInfo.td` | Every opcode in spec §4, SDNodes, operands, pseudos, ISel patterns |
| `ParticleCallingConv.td` | Arguments/returns in R1–R4, then the stack; callee-saved R5–R10 and R14 |
| `CMakeLists.txt` | The `tablegen()` calls |
| `check.sh` | Runs all 10 backends: `./check.sh <llvm/include> [llvm-tblgen]` |

## Verification

Tested with `llvm-tblgen` 18.1.3 and the matching `llvm/include` headers. All 10 backends generate cleanly: register-info, instr-info, emitter, asm-writer, asm-matcher, disassembler, dag-isel, callingconv, subtarget and pseudo-lowering.

- **Opcodes:** the opcode set matches psim.py exactly (diffed mechanically).
- **Selection patterns:** the generated selector has 132 patterns.

## Source of truth

Encodings and semantics follow **psim.py**. Every opcode it decodes is defined here, and nothing else (checked mechanically: 149 opcodes). Where psim.py and the markdown spec disagree, psim.py wins:

| Area | Markdown spec | psim.py (implemented) |
|---|---|---|
| Memory map (0xN0–0xN9) | Loads and stores interleave; base+offset and SP+offset forms | `+0` (Rl), `+1` (++Rl), `+2` (Rl++), `+3` (--Rl), `+4` (Rl--) loads; `+5…+9` the same for stores. No offset modes. |
| FIFO (0xE0–0xE7) | E2 stat, E3 tryr, E4 tryw | E4 stat (chan in Rl), E5 stat (chan imm), E6 tryr and E7 tryw (chan in Rl, R14 ← 1 success / 0 fail) |
| 0xB1–B3, 0xC1–C3 | Not listed | Conditional branches with the displacement in Rl |
| BEXTR | Single bit | Bit field: Rl[4:0] = position, Rl[9:5] = length |
| Signed Imm4/Imm8 | Not stated | Sign-extended for SADD, SSUB, SDIV, SMOD, SMULH and SSLT (−8…7 and −128…127) |
| TRAP | Not stated | Writes PC + 2 into R14 |

Questions resolved by psim.py: CLZ is `Rr ← clz(Rl)` with clz(0) = 32. TAS is a 32-bit atomic swap. JMP reads Rr before writing Rl, so `jmp r14, r14` is safe. SADD and SSUB give the same result as ADD and SUB. Indexed addressing steps by the access size. Branch displacements are relative to the address of the branch itself.

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
- **Stack access.** With no offset addressing modes, stack slots go through `PseudoLD{8,16,32}FI` / `PseudoST{8,16,32}FI`. `eliminateFrameIndex` expands them to `ld rT, sp ; add rT, off ; ld32 rD, (rT)`. Loads reuse the destination as rT; stores need a scavenged register. Pushes and pops use `st32 (--sp), rX` and `ld32 rX, (sp++)`. Indexed stores carry an earlyclobber, because the hardware reads the data register after updating the base.
- **Not used by codegen:** XCHG, XCHGALL, XCHGMOST, RBASE, FIFO.*, JTBL, BRANCH, RJUMP, BEXTR, the register-displacement branches and MULHSU. They are assemble/disassemble only, for inline asm and hand-written handlers. `CSR_Particle_Shadow` is provided for handlers entered via `xchgmost`.

## C++ the generated code calls (names must match)

- **MCCodeEmitter:** `getNegImmOpValue` (store the magnitude) and `getBranchTargetOpValue` (pick the fixup kind from the opcode: forward/back × 4/8-bit; displacement = (target − branch address) / 2).
- **Disassembler:**
  - `DecodeGPRRegisterClass`
  - `decodeUImmOperand<N>`, `decodeSImmOperand<N>`
  - `decodeNegImmOperand<N>`
  - `decodeImplicitR14Insn`: walk the `MCInstrDesc`, add R14 for each `R14C` operand, and decode `Inst{7-0}` for the immediate or branch target. It exists because LLVM 18's decoder generator silently drops operands that have no encoding bits.
- **InstPrinter:** `printBranchOperand`.
- **AsmParser operand:**
  - Predicates: `isUImm4`, `isUImm8`, `isSImm4`, `isSImm8`, `isNImm4`, `isNImm8`, `isBrTarget4`, `isBrTarget8`
  - Renderers: `addImmOperands`, `addExprOperands`, `addRegOperands`
  - `Match_Invalid*` diagnostics
- **ISelLowering:**
  - Nodes: `ParticleISD::CALL`, `RET_GLUE`, `WRAPPER`
  - `LowerCall`, `LowerReturn` and `LowerFormalArguments` using `CC_Particle` and `RetCC_Particle`
  - `setBooleanContents(ZeroOrOneBooleanContent)`
  - Expand `BR_CC` and `SELECT_CC`
  - Custom-lower `GlobalAddress` and friends to `WRAPPER`
  - `setIndexedStoreAction` for all four modes (pre/post × inc/dec)
  - `allowsMisalignedMemoryAccesses` → false (16/32-bit misalignment traps)
  - Select indexed loads in `Select()`
- **RegisterInfo / FrameLowering:**
  - Reserve R0 and R15
  - `eliminateFrameIndex` for `PseudoFRAMEADDR` and the `PseudoLDxFI` / `PseudoSTxFI` pseudos
  - Prologue and epilogue
- **InstrInfo:**
  - `copyPhysReg` uses `LDrr`
  - Stack-slot spills and reloads use `PseudoST32FI` / `PseudoLD32FI`
  - `analyzeBranch` / `insertBranch` work on the pseudo branches
  - `getInstSizeInBytes`
- **MCInstLower:** expand `PseudoLA` and `PseudoCALL` into byte-select fixups. The rest are handled by the generated `PseudoInstExpansion`.
