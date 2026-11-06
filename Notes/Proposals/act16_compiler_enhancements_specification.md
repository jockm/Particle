# Prompt & Engineering Specification: ACT16 Compiler Enhancements
## Native Comparisons, Compound Assignments, and Array / Multi-Field Struct Layout Engine

> **Usage Instructions:** Provide this document directly as a prompt to the AI or developer agent to implement the next generation of features in `tools/act16c.py`.

---

## 1. Context & Objectives

The Particle ACT16 toolchain (`tools/act16c.py`) currently compiles a C-subset systems programming language targeting Particle's compact 16-bit RISC architecture. Recent milestones established:
1. Scalar primitive struct layouts (`u8`, `u16`, `u32`, pointers) and typed arrow dereferencing (`expr->member`).
2. Multiline macros (`\`) and nested `#include` macro persistence.
3. Arbitrary Duff's Device continuations (`case` and `default` statements nested inside arbitrary control blocks and loops).
4. Non-destructive register-based `SwitchNode` comparisons and 1-hop branch trampolines (`FBRA.Z` over 8-bit `FBRA`).

The goal of this phase is to upgrade `tools/act16c.py` with three core features:
1. **Direct Emission of Particle Native Comparisons**: Replace multi-instruction conditional branch sequences with single-cycle native instructions (`SEQ`, `SNE`, `SLE`, `SSLE`, `NOT`, `NEZ`).
2. **Compound Assignment Operators**: Full support for `+=`, `-=`, `*=`, `/=`, `&=`, `|=`, `^=`, `<<=`, and `>>=`.
3. **Array Layouts & Indexing**: Array declarations (`u32 arr[N]`, `struct pt tasks[N]`) and dereferencing (`arr[i]`, `arr[i].member`).

---

## 2. Technical Requirements

### 2.1 Native Comparison & Relational Codegen
Currently, `act16c.py` compiles boolean and relational expressions (`==`, `!=`, `<=`) by jumping through branch trampolines:
```assembly
    SUB     R1, R2
    FBRA.Z  R1, ._rel_true_1
    LD      R1, 0
    FBRA    ._rel_done_2
._rel_true_1:
    LD      R1, 1
._rel_done_2:
```
Particle ISA has dedicated, single-cycle R-R relational and bitwise instructions:
* `0x9A`: `SEQ Rr, Rl` — $Rr \leftarrow (Rr == Rl) \; ? \; 1 : 0$
* `0x9B`: `SNE Rr, Rl` — $Rr \leftarrow (Rr \ne Rl) \; ? \; 1 : 0$
* `0x9C`: `SLE Rr, Rl` — $Rr \leftarrow (Rr \le Rl) \; ? \; 1 : 0$ (Unsigned)
* `0x9D`: `SSLE Rr, Rl` — $Rr \leftarrow (Rr \le Rl) \; ? \; 1 : 0$ (Signed)
* `0x72`: `NOT Rr` — $Rr \leftarrow \sim Rr$ (Bitwise Inversion)
* `0x73`: `NEZ Rr` — $Rr \leftarrow (Rr \ne 0) \; ? \; 1 : 0$ (Logical Not-Equal-Zero)

**Action Items:**
1. In `CodeGen.gen_expr()` for `BinaryOpNode`:
   * For `==`: Emit `SEQ R1, R2` directly into the target register.
   * For `!=`: Emit `SNE R1, R2` directly.
   * For `<=`: Emit `SSLE R1, R2` (signed) or `SLE R1, R2` (unsigned).
   * For `>=`: Swap operands and emit `SSLE R1, R2` or `SLE R1, R2`.
2. In `CodeGen.gen_expr()` for `UnaryOpNode`:
   * For `~`: Emit `NOT R1`.
   * For `!`: If operand is relational, invert instruction opcode; otherwise evaluate operand, emit `NEZ R1`, then `NOT R1` (or `SEQ R1, R0`).

---

### 2.2 Compound Assignment Operators
In `Lexer`, `Parser`, and `CodeGen`:
1. **Lexer:** Tokenize `+=`, `-=`, `*=`, `/=`, `&=`, `|=`, `^=`, `<<=`, `>>=`.
2. **Parser:** Extend `parse_assignment()`:
   * Map `lhs op= rhs` to an AST `CompoundAssignNode(op, lhs, rhs)` or desugar to `lhs = lhs op rhs` while ensuring single-evaluation of complex LHS addresses (`arr[i]` or `p->member`).
3. **CodeGen:**
   * Evaluate destination address / register.
   * Fetch current value.
   * Compute operation with RHS.
   * Emit appropriate typed store (`LD8`, `LD16`, `LD32`).

---

### 2.3 Arrays & Indexed Member Access
Extend the type system and struct layout engine:
1. **Declarations:**
   * Global: `u32 g_buf[16];`
   * Local: `u16 local_arr[8];`
   * Struct members:
     ```c
     struct channel {
         u8 id;
         u32 data[4];
     };
     ```
2. **AST Additions:**
   * `ArrayAccessNode(base_expr, index_expr)`
3. **Code Generation:**
   * Determine element size $S \in \{1, 2, 4\}$.
   * Compute base pointer into `R14`.
   * Evaluate `index_expr` into `R1`.
   * If $S = 2$: `SHIFTL R1, 1`. If $S = 4$: `SHIFTL R1, 2`.
   * `ADD R14, R1`.
   * Emit load (`LD8`, `LD16`, `LD32`) or store depending on whether the node is an L-value or R-value.

---

## 3. Verification & Acceptance Criteria

1. **Unit Test (`apps/act16/native_ops_test.act`):**
   * Verifies `SEQ`, `SNE`, `SLE`, `NOT`, and `NEZ` execute with cycle-count reduction compared to branch trampolines.
   * Validates all compound operators `+=`, `-=`, `&=`, `|=`, `<<=`.
2. **Array & Struct Test (`apps/act16/array_struct_test.act`):**
   * Declares an array of `struct pt` coroutine descriptors: `struct pt g_tasks[4];`.
   * Implements a round-robin task scheduler driving all 4 tasks via array indexing.
3. **Toolchain Verification:**
   * Must pass `tools/pasm_lint.py` with zero branch direction, register clobber, or displacement warnings.
   * Binary must assemble cleanly via `tools/pasm.py` and run to `trap(14)` under `tools/psim.py`.