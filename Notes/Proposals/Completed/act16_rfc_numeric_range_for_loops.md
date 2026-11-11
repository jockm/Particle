# RFC: Numeric Range `for` Loops in Action

- **Status:** Proposed
- **Author:** Particle & Parcore
- **Target Subsystem:** `tools/act16c.py` (Lexer, Parser, AST, CodeGen)
- **Target Architecture:** Particle 32-bit RISC

---

## 1. Summary

This proposal specifies the syntax, semantics, and compiler lowering for unit-stride numeric range `for` loops in the Action systems language. The construct provides a structured, idiomatic way to iterate over half-open integer intervals `[start, end)` without introducing new English keywords, custom step operators, or dynamic stack allocation during iteration.

---

## 2. Motivation

Currently, Action relies strictly on `while` loops for iteration:

```c
u32 i = 0;
while (i < myArray.len) {
    myArray[i] = i * 2;
    i += 1;
}
```

While functional, this approach has drawbacks in systems code:
1. **Verbosity & Boilerplate:** Every iteration requires manual induction variable declaration, explicit condition checks, and explicit increment statements.
2. **Accidental Variable Leakage:** Induction variables declared prior to `while` remain in scope longer than necessary.
3. **Stack Drift Risks:** Declaring induction variables inside nested control flow previously led to frame desynchronization. A structured loop ensures induction storage is registered during pre-scan frame calculation.

---

## 3. Syntax Specification

### 3.1 Grammar

The `for` statement uses colon `:` as the binding delimiter and the existing range slice operator `..` (`OP_RANGE`):

```text
ForRangeStmt := "for" "(" Type IDENT ":" Expr ".." Expr ")" Statement
```

### 3.2 Canonical Examples

#### Array Index Iteration
```c
for (u32 i : 0..myArray.len) {
    myArray[i] = i * 2;
}
```

#### Constant Range Iteration
```c
for (u16 n : 1..100) {
    process_slot(n);
}
```

### 3.3 Deliberate Design Decisions
- **No `in` or `step` Keywords:** To preserve Action's grammar minimalism, no ad-hoc English keywords are introduced.
- **No Non-Unit Stride Modifiers:** Iteration is strictly single-step (`+1`). Arbitrary step sizes, negative strides, and complex sequences remain the domain of explicit `while` loops.
- **Half-Open Intervals `[start, end)`:** Directly consistent with array slicing syntax `arr[start..end]`. A loop `0..N` executes exactly $N$ iterations ($0 \le i < N$).

---

## 4. Semantics & Scope

1. **Pre-loop Evaluation:**
   - The expression for `start` is evaluated once before loop entry and stored into the induction variable.
   - The expression for `end` is evaluated **once** before entering the loop and cached in a compiler-allocated temporary register or local slot. It is not re-evaluated across iterations.

2. **Frame Allocation & Lifetime:**
   - The induction variable is scoped to the loop body.
   - To guarantee zero stack drift on Particle RISC, the induction variable slot is pre-allocated in the function frame during `_collect_local_decls`.

3. **Loop Control Flow:**
   - `break;` immediately exits the innermost enclosing `for` loop (jumping to `lbl_end`).
   - If `continue;` is subsequently implemented, it targets the induction increment step.

---

## 5. Particle RISC Lowering & Code Generation

### 5.1 Lowering Architecture

The loop lowers using the standard trampoline branch pattern used for `while` and relational expressions in `tools/act16c.py`:

```text
       ; --- Loop Prologue ---
       ; 1. Evaluate start_expr into induction variable slot
       ; 2. Evaluate end_expr into scratch register / cached frame slot (R2)

.L_for_start:
       ; --- Condition Check ---
       ; Load induction variable into R1
       SLT      R1, R2                 ; Unsigned less-than: R1 < R2
       FBRA.NZ  R1, .L_for_body        ; Short skip into body if true
       FBRA     .L_for_end             ; Exit if false (8-bit reach)

.L_for_body:
       ; --- Loop Body ---
       ; ... Body statements ...

       ; --- Induction Step (+1) ---
       ; Load induction variable into R1
       ADD      R1, 1                  ; Unit stride
       ; Store R1 back to induction variable slot

       BBRA     .L_for_start           ; Loop back

.L_for_end:
```

---

## 6. Implementation Plan in `tools/act16c.py`

### 6.1 AST Node Definition
Add to AST nodes:
```python
class ForRangeNode(ASTNode):
    def __init__(self, var_type, var_name, start_expr, end_expr, body):
        self.var_type = var_type
        self.var_name = var_name
        self.start_expr = start_expr
        self.end_expr = end_expr
        self.body = body
```

### 6.2 Parser Integration (`Parser.parse_statement`)
```python
        if tok.val == 'for':
            self.consume('KEYWORD', 'for')
            self.consume('PUNCT', '(')

            var_type = self.parse_type()
            var_name = self.consume('IDENT').val
            self.consume('PUNCT', ':')

            start_expr = self.parse_expr()
            self.consume('OP_RANGE', '..')
            end_expr = self.parse_expr()

            self.consume('PUNCT', ')')
            body = self.parse_statement()
            return ForRangeNode(var_type, var_name, start_expr, end_expr, body)
```

### 6.3 Local Frame Pre-Scanning (`CodeGen._collect_local_decls`)
```python
        elif isinstance(node, ForRangeNode):
            decls.append(VarDeclNode(node.var_type, node.var_name, None))
            self._collect_local_decls(node.body, decls)
```

### 6.4 Statement Generation (`CodeGen.gen_stmt`)
Handle `ForRangeNode` by emitting the bounds evaluation, trampoline loop condition check, body execution, unit stride increment, and back-branch `BBRA`.

---

## 7. Verification & Test Plan

Create `apps/act/for_range_test.act` covering:
1. **Basic Numeric Accumulation:** Iterating `0..10` and summing values.
2. **Fixed Array Indexing:** Iterating `0..arr.len` to initialize and transform elements.
3. **Nested Loops:** Independent outer and inner `for` ranges validating stack slot isolation.
4. **Early Termination:** Verifying `break;` correctly jumps out of the range loop.