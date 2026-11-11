# Prompt & Engineering Specification: Action Zero-Macro Systems Language Upgrades

## Objective & Scope
This specification provides complete engineering instructions to upgrade the **Action compiler** (`tools/act16c.py`) targeting the Particle 32-bit RISC architecture. 

The primary architectural goal is to **completely eliminate all C-style preprocessor directives and macros** (`#define`, `#include`, `#ifdef`, `#ifndef`, `#endif`) by replacing them with first-class, zero-overhead language constructs:
1. **Module Import System (`import`)**: Canonical single-inclusion module semantics replacing textual `#include` and `#ifndef` include guards.
2. **Enumerations (`enum`)**: Typed, auto-incrementing compile-time integer constants.
3. **Multiple Scalar Return Tuples & Wildcard (`_`)**: Native register-bound scalar tuples (`R1`–`R4`) with underscore discards.
4. **Compile-Time Static Assertions (`static_assert`)**: Layout and constant validation at compile time with zero emitted machine code.
5. **Memory Volatility (`volatile`)**: Barrier against register caching and dead store elimination for MMIO and `@`-bound variables.
6. **Constant Expression Branch Pruning (`if const`)**: AST-level dead code elimination of unreachable branches, replacing `#if`/`#ifdef`/`#else`/`#endif`.
7. **Type & Memory Introspection (`sizeof`)**: Compile-time byte-size evaluation for types and expressions.

---

## 1. Feature Specifications & Semantics

### 1.1 Module System: `import`
* **Syntax**:
  ```c
  import "lib/protokernel.act";
  import "drivers/uart.act";
  ```
* **Grammar & Lexer**:
  * Add `import` as a reserved keyword.
  * Parser recognizes `import <STRING_LITERAL> ;` at the top-level declaration stage.
* **Compiler Semantics**:
  * Replaces raw file concatenation and `#include`.
  * The compiler driver maintains a global tracking set: `imported_files = set()`.
  * Path resolution checks:
    1. Direct relative path to the current file's directory.
    2. Working project root / `-I` include search paths.
    3. Canonicalize resolved path using `os.path.realpath` / `os.path.abspath`.
  * **Idempotency**: If `resolved_path` exists in `imported_files`, the AST ingestion step evaluates immediately to a no-op. If not seen, add to `imported_files`, tokenize, parse into the root AST, and continue. Cyclic dependencies are automatically broken without infinite recursion.

---

### 1.2 Enumerations: `enum`
* **Syntax**:
  ```c
  enum Status {
      OK = 0,
      BUSY,
      TIMEOUT = 10,
      ERROR
  };
  ```
* **Grammar**:
  ```text
  EnumDecl := 'enum' IDENT '{' EnumMemberList '}' ';'
  EnumMemberList := EnumMember (',' EnumMember)* ','?
  EnumMember := IDENT ('=' ConstExpr)?
  ```
* **Compiler Semantics**:
  * Evaluated during symbol registration.
  * Defaults start at `0` if the first entry lacks an initializer. Subsequent entries without an initializer evaluate to `previous_val + 1`.
  * Enum member names enter the symbol table as compile-time typed integer constants (`self.constants[name] = val`).
  * Emits **zero** memory in `.word` or stack allocation. Accessing an enum identifier lowers directly into immediate register loads (`LD`, `LOAD16`, `LOAD32`).

---

### 1.3 Multiple Scalar Return Tuples & Wildcard Discard (`_`)
* **Syntax**:
  ```c
  (u32, u16) read_uart(u16 port) {
      if (fifo_empty(port)) {
          return (0, 1);
      }
      return (UART_DATA @ port, 0);
  }

  void main() {
      // Unpack all values
      (u32 data, u16 err) = read_uart(0);

      // Discard error code
      (u32 raw_val, _) = read_uart(1);

      // Discard return value, keep status
      (_, u16 status) = read_uart(2);
  }
  ```
* **Calling Convention & Register Mapping**:
  * Action preserves the strict invariant: **No aggregate copies on the stack/heap**. Return tuples are limited strictly to primitive scalars (`u8`, `s8`, `u16`, `s16`, `u32`, `s32`, pointers). Maximum return tuple size is 4 elements.
  * Tuple return values map directly to Particle calling convention return registers:
    * Element 0 $\rightarrow$ `R1`
    * Element 1 $\rightarrow$ `R2`
    * Element 2 $\rightarrow$ `R3`
    * Element 3 $\rightarrow$ `R4`
* **Wildcard Discard (`_`)**:
  * `_` is a contextual reserved token representing a sink discard.
  * The compiler allocates **no stack slot** and assigns **no local symbol entry** for `_`.
  * When assigning or unpacking from return registers, the slot corresponding to `_` simply skips emitting the memory store (`ST32`, `ST16`, `ST8`) or register move.

---

### 1.4 Compile-Time Static Assertions: `static_assert`
* **Syntax**:
  ```c
  static_assert(sizeof(Window) == 24, "Window layout mismatch");
  static_assert(BUFFER_SIZE <= 1024, "Buffer exceeds maximum frame");
  ```
* **Compiler Semantics**:
  * Parsed at top-level or inside function block scopes.
  * Evaluated strictly in the compiler semantic verification pass after constant folding and struct/type layout calculations.
  * The predicate expression must fold to an integer constant.
  * If the condition evaluates to `0` (false), compilation aborts immediately with a clear compiler error citing file, line number, and the assertion string.
  * Emits **zero machine instructions** in the target `.asm` file.

---

### 1.5 Memory Volatility: `volatile`
* **Syntax**:
  ```c
  volatile u32 flag;
  volatile u16 tx_ready @ 0xFFFF0102;
  ```
* **Semantics & Optimization Protection**:
  * All hardware `@`-bound address declarations are treated as implicitly `volatile`.
  * Variables declared with the `volatile` modifier must adhere to:
    1. **Strict Load Generation**: Reads must issue an explicit hardware read (`LD8`, `LD16`, `LD32`) from the memory or stack address; values may never be cached across statements in scratch registers `R5`–`R13`.
    2. **Strict Store Generation**: Writes must immediately emit the store instruction (`ST8`, `ST16`, `ST32`) to the target address, preventing dead-store elimination.
    3. **Order Preservation**: No reordering of volatile memory accesses across statement boundaries.

---

### 1.6 Constant Expression Branch Pruning (`if const`)
* **Syntax**:
  ```c
  const bool DEBUG_LOGS = false;

  void handle_event(u32 code) {
      if (DEBUG_LOGS) {
          log_event(code);
      }
      process(code);
  }
  ```
* **Compiler Lowering**:
  * During the AST code generation pre-pass, when an `IfNode` is encountered:
    1. Inspect `stmt.cond`.
    2. Attempt compile-time constant evaluation via `_eval_const_expr(stmt.cond)`.
    3. If the expression evaluates to a known compile-time integer:
       * If **non-zero (true)**: Emit only `stmt.then_body`. Skip condition comparison and jump instructions entirely. If `stmt.else_body` exists, discard it.
       * If **zero (false)**: Do not emit `stmt.then_body`. If `stmt.else_body` exists, emit only `stmt.else_body`.
  * Replaces preprocessor `#ifdef`, `#ifndef`, `#else`, and `#endif` conditional compilation blocks.

---

### 1.7 Built-In Type Introspection: `sizeof`
* **Syntax**:
  ```c
  u32 s1 = sizeof(u16);        // Evaluates to 2
  u32 s2 = sizeof(Window);     // Evaluates to calculated byte size of Window
  u32 s3 = sizeof(pt.x);       // Evaluates to byte size of member expression (2)
  ```
* **Compiler Lowering**:
  * Parsed as a primary expression.
  * Resolves argument:
    * If a primitive identifier (`u8`, `u16`, `u32`, etc.): returns known byte width (1, 2, or 4).
    * If a pointer type: returns 4 (32-bit address).
    * If a user `type`: returns `self.structs[type_name]['__size__']`.
    * If an expression: resolves type via `_get_expr_type(expr)` and calculates size.
  * Folds immediately into an `IntLitNode` during parsing/constant folding. Emits direct immediate loads (`emit_immediate`).

---

## 2. Implementation Checklist for `tools/act16c.py`

### Step 1: Lexer & Tokenizer
- [ ] Add keywords: `import`, `enum`, `static_assert`, `volatile`, `sizeof`.
- [ ] Add punctuation: `_` as wildcard identifier token or special token `TOKEN_WILDCARD`.

### Step 2: Parser & AST Nodes
- [ ] **AST Nodes**:
  - `ImportNode(path)`
  - `EnumDeclNode(name, members)`
  - `StaticAssertNode(cond_expr, message)`
  - `TupleAssignNode(lhs_targets, rhs_call)`
  - Update `FuncDeclNode`: support tuple return type list `ret_types`.
  - Update `ReturnNode`: support tuple expression list `exprs`.
  - Update `VarDeclNode`: add `is_volatile=False`.
- [ ] **Parser Logic**:
  - `parse_import()`: parse `import <STRING>;`.
  - `parse_enum()`: parse enum declaration and member value expressions.
  - `parse_static_assert()`: parse condition and string message.
  - `parse_type()` / `parse_func()`: parse multiple return syntax `(type1, type2) func_name(...)`.
  - `parse_statement()`: parse tuple destructuring `(var1, _) = func(...);`.
  - `parse_primary()`: parse `sizeof(...)`.

### Step 3: Type Engine & Semantic Validation
- [ ] Implement `self.imported_files = set()` to manage recursive and cyclic inclusion.
- [ ] Fold enum symbols into `self.constants[member_name] = value`.
- [ ] Evaluate `StaticAssertNode` during layout phase; raise `SystemExit` with diagnostic if false.
- [ ] Fold `sizeof(T)` into constant integer nodes.

### Step 4: Code Generation (`CodeGen`)
- [ ] **`IfNode` Pruning**: Evaluate condition constants; prune dead branches before label/jump emission.
- [ ] **Tuple Returns**:
  - Callee: Evaluate return expressions in sequence, emitting values into `R1`, `R2`, `R3`, `R4`.
  - Caller: Unpack registers `R1`..`R4` into destination locals, skipping any element matched to `_`.
- [ ] **`volatile` Enforcement**: Check `is_volatile` flag or bound address table on variable accesses to prevent dead-store elimination or register caching.

---

## 3. Test & Verification Suites

Create the following automated tests in `apps/act/`:

1. `apps/act/test_import.act`: Verify module inclusion and idempotent multiple imports.
2. `apps/act/test_enum_assert.act`: Verify enum auto-numbering and compile-time `static_assert(sizeof(...) == ...)`.
3. `apps/act/test_multi_return.act`: Verify `(u32, u16)` return passing via `R1`/`R2` with wildcard `_` ignoring values.
4. `apps/act/test_const_pruning.act`: Verify `if (false)` blocks generate zero instructions in the disassembly.
5. `apps/act/test_volatile.act`: Verify sequential writes to volatile memory addresses are never omitted.