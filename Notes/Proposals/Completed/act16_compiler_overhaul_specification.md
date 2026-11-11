# Prompt & Engineering Specification: Action Systems Compiler Overhaul

## Unified Types, Bound Procedures, Memory-Mapped Arrays, and Particle Native Codegen

> **Usage Instructions:** Provide this document directly as a prompt to the AI agent or developer to implement the combined language ergonomics, memory semantics, and backend code-generation upgrades in `tools/act16c.py`.

## 1. Context & Objectives

The Particle Action toolchain (`tools/act16c.py`) compiles a typed systems language targeting Particle's compact 16-bit RISC ISA over a 32-bit datapath. Previous milestones established:

1. Scalar primitive types (`u8`, `s8`, `u16`, `s16`, `u32`, `s32`, pointers).
2. Top-level struct declarations with member offset tracking.
3. Preprocessor expressions and conditional compilation (`#ifdef`, `#ifndef`, `#else`, `#endif`, `#include`).
4. Duff's Device arbitrary continuation points (`case` labels nested in arbitrary control blocks and loops).
5. Non-destructive switch branch ladders with short-hop skips over 8-bit `FBRA` displacements.

This specification unifies the next evolution of Action, addressing language syntax, memory semantics, and machine code efficiency:

1. **The Unified `type` System:** Replace `struct` with `type`, supporting recursive nesting, arrays as fields, implicit pass-by-reference semantics, and auto-dereferenced member access (`.`).
2. **Fixed-Size Arrays, Bounds Checking, and `.len` Introspection:** Introduce fixed arrays with compile-time bounds checking, direct address binding via `@` (`u8 vram[64] @ 0x8000;`), and zero-overhead length introspection via `arr.len`.
3. **First-Class Function Types:** Replace C-style pointer declarator syntax with linear definitions (`type Handler = fn(pt) -> u16;`).
4. **Oberon-Style Type-Bound Procedures:** Provide zero-cost syntactic sugar for methods via qualified identifiers (`void Type.method(Type self, ...)`).
5. **Macro Elimination Triad:** Eliminate textual macro fragility in favor of typed constants (`const`), typed inline functions (`inline`), and native coroutine intrinsics (`yield`, `wait_until`).
6. **Backend Optimization:** Emit native single-cycle comparisons (`SEQ`, `SNE`, `SLE`, `SSLE`, `NOT`, `NEZ`), eliminate branch trampolines, and implement compound assignment operators (`+=`, `-=`, etc.).

---

## 2. Language Semantics & Grammar Extensions

### 2.1 Unified `type` Keyword and Struct Layout Engine

The keyword `struct` is removed from the lexer and parser. User-defined aggregates use `type`:

```c
type Point {
    u16 x;
    u16 y;
};

type Window {
    Point origin;
    u16 width;
    u16 height;
    u8 title[16];
};
```

#### Layout Rules:

* User-defined type names are added to the compiler's type table upon declaration.
* Offsets within aggregates are calculated recursively:
  $$\text{offset}(\text{outer}.\text{inner}.\text{field}) = \text{offset}(\text{outer}.\text{inner}) + \text{offset}(\text{inner}.\text{field})$$
* Direct circular inclusion by value is forbidden at compile time (detected via cycle check during layout calculation). Pointers to types (`Point*`) remain scalar 32-bit addresses.

### 2.2 Implicit Pass-by-Reference & Auto-Dereference

When a user-defined `type` appears in a function parameter list:

```c
void move_point(Point p, u16 dx, u16 dy) {
    p.x += dx;
    p.y += dy;
}
```

* **Caller Semantics:** The caller evaluates `&p` (the 32-bit base address) and places it into the target argument register (`R1`–`R4`).
* **Callee Semantics:** The parameter symbol is flagged with `is_reference: True`.
* **Member Access (`.`):** Both local type instances and reference parameters use `.` for field access. The arrow operator (`->`) is completely removed from the language:
  * For local variables: Base address is $R15 + \text{stack\_offset}$.
  * For reference parameters: Base address is loaded from the parameter's stack slot into scratch register `R14`.

### 2.3 Fixed Arrays, Address Binding (`@`), Bounds Checking, and `.len`

Arrays have compile-time fixed dimensions:

```c
// Local or global stack/bss allocation:
u32 tx_buffer[32];

// Bound to a physical address (Option 1 syntax):
u8 vram[256] @ 0x8000;
u32 fifo_status[4] @ 0xF0000000;
```

#### 2.3.1 Grammar Rule:

$$\text{ArrayDecl} \rightarrow \text{Type} \; \text{IDENT} \; \text{"["} \; \text{INT} \; \text{"]"} \; [\text{"@"} \; \text{Expr}] \; \text{";"}$$

#### 2.3.2 The `arr.len` Length Introspection:

Array lengths can be read using member access syntax: `arr.len`.
* **For Statically Declared Arrays (Locals, Globals, MMIO-Bound, Type Fields):**
  * `arr.len` is evaluated strictly at compile time.
  * No metadata header, fat pointer, or length integer is allocated in RAM.
  * In code generation, `arr.len` resolves immediately to an immediate constant load (`LD R1, N` or `LOAD16 R1, N`).
  * In constant expressions (e.g., bounds calculations, loop termination conditions), `arr.len` folds into a literal integer constant with zero instructions emitted.
* **For Open Array Function Parameters (if passing `type arr[]`):**
  * When a function declares an unsized array argument (`void process(u32 arr[])`), the caller passes element 0 in `R1` and the caller's compile-time `arr.len` in companion register `R2`.
  * Within the function, `arr.len` references the value stored in the `R2` parameter register.

```c
u32 buf[16];

// arr.len compiles directly to immediate literal 16:
for (u16 i = 0; i < buf.len; i += 1) {
    buf[i] = 0;
}
```

#### 2.3.3 Code Generation & Bounds Verification:

1. **Compile-Time Checks:** If an index expression is a constant literal ($i < N$), an index equal to or exceeding `arr.len` triggers a fatal compiler error. If valid, no runtime check instructions are emitted.
2. **Runtime Bounds Checks:** For dynamic indices evaluated in a register ($R_{\text{idx}}$):
   ```assembly
   LOAD16  R14, <N>          ; Array upper bound (from symbol table arr.len)
   SUB     R14, R_idx
   FBRA.LS ._bounds_trap     ; Unsigned lower or same: trap if R_idx >= N
   ```
   *(Bounds check emission can be globally disabled via a compiler CLI switch `-Ounchecked` or `#pragma no_bounds_check`)*.
3. **Hardware Memory Binding (`@`):**
   * If `@ <address>` is specified, no local stack space is reserved ($R15$ is not decremented).
   * The symbol table binds the identifier directly to the constant address.

### 2.4 Function Pointer Types (`fn(...) -> RetType`)

Function pointers are defined linearly using `type`:

```c
type Handler = fn(u32, u32) -> u32;
type TaskFn = fn(pt) -> u16;
type Callback = fn();
```

* **Invocation:** Calling an indirect function variable uses identical syntax to direct calls (`op(a, b)`).
* **Code Generation:**
  ```assembly
  ; Target function pointer evaluated into R13
  MOV     R14, R13
  JMP     R14, R14          ; Particle indirect call with link (PC+2 -> R14)
  ```

### 2.5 Oberon-Style Type-Bound Procedures

Methods are declared using qualified identifier syntax, associating a function with a type:

```c
void Point.move(Point self, u16 dx, u16 dy) {
    self.x += dx;
    self.y += dy;
}
```

* **Symbol Lowering:** Lowered internally into a mangled global symbol (`_Point_move`).
* **Invocation:**
  ```c
  Point pt;
  pt.move(10, 20);
  ```
  The parser checks if `move` is a field in `Point`. If not, it looks up `Point_move`, desugaring the call to `_Point_move(&pt, 10, 20)`.

### 2.6 The Macro Elimination Triad

Textual `#define` substitutions for values and code blocks are replaced with typed primitives:

1. **Typed Constants (`const`):**
   ```c
   const u16 PK_WAITING = 0;
   const u16 PK_YIELDED = 1;
   ```
   Values are folded directly into tiered immediates (`LD`, `LOAD16`, `LOAD32`) during compilation.
2. **Typed Inline Functions (`inline`):**
   ```c
   inline u16 pk_schedule(u16 status) {
       return status < PK_EXITED;
   }
   ```
   The compiler directly inlines the AST body at the call site, eliminating call overhead without preprocessor leaks.
3. **Coroutine Intrinsics (`yield`, `wait_until`):**
   Replaces Duff's Device macro blocks with native compiler statements:
   * `yield(task_ref, step_const);`
   * `wait_until(task_ref, step_const, condition_expr);`

---

## 3. Compiler Backend & Particle ISA Upgrades

### 3.1 Native Single-Cycle Comparisons & Logic

Replace branch-trampoline boolean evaluation with native Particle instructions in `CodeGen.gen_expr()`:

| Operation | Native Particle Instruction | Opcode | Semantics |
| :--- | :--- | :--- | :--- |
| `==` | `SEQ Rr, Rl` | `0x9A` | $Rr \leftarrow (Rr == Rl) \; ? \; 1 : 0$ |
| `!=` | `SNE Rr, Rl` | `0x9B` | $Rr \leftarrow (Rr \ne Rl) \; ? \; 1 : 0$ |
| `<=` (unsigned) | `SLE Rr, Rl` | `0x9C` | $Rr \leftarrow (Rr_{\text{unsigned}} \le Rl_{\text{unsigned}}) \; ? \; 1 : 0$ |
| `<=` (signed) | `SSLE Rr, Rl` | `0x9D` | $Rr \leftarrow (Rr_{\text{signed}} \le Rl_{\text{signed}}) \; ? \; 1 : 0$ |
| `>=` | `SLE` / `SSLE` (swapped) | `0x9C` / `0x9D` | Evaluated as $Rl \le Rr$ |
| `~` | `NOT Rr` | `0x72` | Bitwise inversion |
| `!` | `NEZ Rr` + `XOR Rr, 1` | `0x73` | Logical boolean inversion |

### 3.2 Compound Assignment Operators

In `Lexer`, `Parser`, and `CodeGen`, support:
`+=`, `-=`, `*=`, `/=`, `&=`, `|=`, `^=`, `<<=`, `>>=`

* **Parser:** Map `lhs op= rhs` to `CompoundAssignNode(op, lhs, rhs)`.
* **Single Evaluation:** When `lhs` is a complex target (e.g., `arr[i]` or `outer.inner.field`), evaluate the address pointer once into a register, load the current value, compute with RHS, and store back to the address.

### 3.3 Scaled Array Index Addressing

For indexed expressions `arr[idx]`:

* Base pointer calculated into `R14`.
* Dynamic index evaluated into `R1`.
* Scaled by element size $S \in \{1, 2, 4\}$:
  * If $S = 2$: Emit `SHIFTL R1, 1`.
  * If $S = 4$: Emit `SHIFTL R1, 2`.
* `ADD R14, R1`.
* Perform typed load/store (`LD8`, `LD16`, `LD32`).

---

## 4. ProtoKernel Reference Implementation (`lib/protokernel.h`)

Under this updated compiler specification, ProtoKernel is expressed without preprocessor hacks:

```c
#ifndef _PROTOKERNEL_H_
#define _PROTOKERNEL_H_

// Lifecycle constants
const u16 PK_WAITING = 0;
const u16 PK_YIELDED = 1;
const u16 PK_EXITED  = 2;
const u16 PK_ENDED   = 3;

// Minimal Continuation Control Block
type pt {
    u16 lc;
};

// Function type for task coroutines
type TaskFn = fn(pt) -> u16;

// Type-bound initialization method
inline void pt.init(pt self) {
    self.lc = 0;
}

// Scheduling predicate
inline u16 pk_schedule(u16 status) {
    return status < PK_EXITED;
}

#endif
```

---

## 5. Implementation Roadmap & Verification

### Step 1: Lexer & AST Restructuring

* Remove `struct`, `->`, and textual macro regexes.
* Add tokens: `type`, `fn`, `@`, and compound operators (`+=`, etc.).
* Implement AST nodes: `TypeDeclNode`, `ArrayAccessNode`, `CompoundAssignNode`, `MethodDeclNode`, `YieldNode`, and `WaitUntilNode`.
* Add postfix rule for member `.len` access on array symbols.

### Step 2: Parser & Semantic Engine

* Implement symbol table tracking for user-defined types and arrays with explicit size attributes.
* Add recursive offset calculation for nested types and arrays.
* Enforce pass-by-reference semantics for function parameters of aggregate types.
* Implement qualified identifier parsing for `Type.method(...)`.
* Resolve `arr.len` to a compile-time constant for static arrays, folding directly into integer expressions.

### Step 3: Backend CodeGen & Optimization

* Update `BinaryOpNode` to emit `SEQ`, `SNE`, `SLE`, and `SSLE`.
* Implement bounds-check code generator using the symbol table length constant.
* Support indirect calls for `fn(...)` types via `JMP R14, R14`.

### Step 4: Verification Suite

1. **Language Ergonomics & Array Test (`apps/act/type_method_test.act`):**
   * Tests nested types, `Type.method()` invocation, `arr.len` loop evaluation, and array bounds checking.
2. **Native Comparisons & Compound Ops (`apps/act/native_ops_test.act`):**
   * Tests single-cycle comparisons (`SEQ`, `SNE`, `SLE`) and operators (`+=`, `<<=`).
3. **ProtoKernel Concurrency Test (`apps/act/pk_concurrency_test.act`):**
   * Multi-task cooperative scheduling using `TaskFn tasks[4];`, `yield`, and `wait_until`.
4. **Assembler & Simulator Pass:**
   * Binaries must compile cleanly via `tools/pasm.py` and pass execution in `tools/psim.py` to `trap(14)` with register verification (`R1 == 0xCAFE`).