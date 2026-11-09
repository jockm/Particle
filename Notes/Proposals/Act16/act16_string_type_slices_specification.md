# Prompt & Engineering Specification: ACT16 String Type & Null-Terminated Slice Support

**Target:** `tools/act16c.py` (ACT16 Systems Programming Compiler)  
**Architecture:** Particle 32-bit RISC ISA (16-bit instruction format)  
**Usage Instructions:** Provide this document directly as a prompt to an AI agent or systems developer to implement fixed-capacity, null-terminated strings, string slices, and standard C-interoperability routines in `act16c.py`.

---

## 1. Context & Architectural Principles

ACT16 is a bare-metal, statically-typed systems language targeting the Particle 32-bit RISC core. The language prohibits hidden heap allocations and guarantees deterministic stack and memory layout.

The language currently supports:
- Fixed-size primitive arrays (`u8 arr[32]`) with compile-time `.len` and runtime bounds checking (`TRAP 15`).
- Open array reference parameters (`fn process(u8 buf[])`) passing pointer in primary register $R_n$ and dynamic count in companion register $R_{n+1}$.
- Array slices (`buf[start..end]`).

### Core String Requirements
1. **Array Parity & Fixed Storage:** Strings must behave like byte arrays (`u8[]`), allocated inline on the stack or in `.data` with a fixed capacity known at compile time.
2. **Implicit Null Termination:** Strings must guarantee a terminating `0x00` byte internally to allow seamless zero-copy passing to external libraries, UART drivers, and C ABI routines (`const char*`).
3. **Decoupled Length vs. Capacity:** 
   - `.capacity`: The total allocated buffer size $N$ (including the sentinel `\0`).
   - `.len`: The dynamic payload length (count of bytes before the first `0x00`).
4. **Coherent Slicing:** Sub-slicing a string produces an open byte view (`u8[]`) passed via register pairs $(R_n, R_{n+1})$, preserving memory safety without mutating the original null terminator.

---

## 2. Syntax & Type System Specifications

### 2.1 Declarations
The `string` keyword is introduced as a built-in fixed-capacity byte array type:

```c
// Local or global declaration with fixed capacity (32 bytes total)
string[32] name = "particle";

// Uninitialized string (zero-filled, capacity 64, len 0)
string[64] buffer;

// Physical memory mapping via existing @ operator
string[128] vram_banner @ 0x8000;
```

#### Size Semantics
- In `string[N]`, $N$ is the **buffer capacity** in bytes.
- The maximum string payload length is $N - 1$. The slot at index $N - 1$ is permanently reserved for `0x00`.
- An initialization literal exceeding $N - 1$ characters produces a compile-time error:
  `act16c: error: string literal length (8) exceeds capacity (8) with null-terminator requirement in string[8]`.

### 2.2 Introspection Properties
Strings support two introspection member properties:

| Property | Return Type | Evaluation Mode | Meaning |
|---|---|---|---|
| `s.capacity` | `u32` | Compile-Time Constant | Total buffer allocation $N$ bytes (folds to immediate). |
| `s.len` | `u32` | Dynamic / Runtime or Folded | Number of non-null bytes prior to `0x00`. If initialized with a constant and unmodified, can fold at compile time; otherwise emits an inline scan. |

### 2.3 Indexing & Mutation Invariant
Strings allow element indexing (`s[i]`) and assignment (`s[i] = 'A'`):
- **Bounds Checking:** Indexing enforces $i < s.\text{capacity} - 1$ if bounds checking is active (`-fbounds-check`).
- **Null Safety:** User code cannot index or overwrite the terminal sentinel slot at $s[\text{capacity} - 1]$. Writing a `0x00` at $i < \text{capacity} - 1$ dynamically shrinks the logical `s.len`.

### 2.4 Slices & Open Array Compatibility
Strings directly interface with ACT16's open array and slice architecture:

```c
void uart_write(u8 buf[]) {
    // buf.len holds the dynamic slice length passed in companion register
}

string[32] msg = "hello world";

// Slicing produces a companion-pair open array (base_ptr in R1, length 5 in R2)
uart_write(msg[0..5]); 

// Passing whole string to an open array automatically forwards (base_ptr, msg.len)
uart_write(msg);
```

#### The Null-Termination Invariant on Slices:
- An interior slice `msg[0..5]` is passed as `(ptr, 5)`. It **cannot** be null-terminated without mutating the source buffer.
- Passing to external C functions expecting `const char*` requires either:
  1. Passing the root string `msg` directly.
  2. Slicing to the natural end: `msg[start..msg.len]`, which remains validly terminated at `\0`.

---

## 3. ABI & Code Generation Lowering

### 3.1 Memory Layout
For `string[16] s = "hello";`:

```
Stack Offset (R15):
+00   'h' (0x68)
+01   'e' (0x65)
+02   'l' (0x6C)
+03   'l' (0x6C)
+04   'o' (0x6F)
+05   0x00
+06..+15  0x00 (Zero-padded to capacity 16)
```

- **Stack Allocation:** `words = (capacity + 3) // 4`. Allocates words via `PUSH32 R0`.
- **Literal Initialization:** The compiler places string literals in the `.asciz` pool and generates a runtime byte copy or pushes constant words directly into the frame.

### 3.2 Calling C-ABI / External Functions
When a `string[N]` argument is passed to a parameter expecting a raw pointer (`u8*` or `void*`):
- Compute the base address into primary register $R_n$.
- Companion register $R_{n+1}$ is not emitted for non-open array signatures.
- Register $R_n$ points directly to a valid C-compatible null-terminated buffer.

```assembly
; Passing string 'name' to c_puts(u8* s) in R1:
ADD     R1, R15, 8          ; Compute effective address &name[0]
RCALL   c_puts
```

### 3.3 Dynamic `.len` Calculation Lowering
When `s.len` cannot be resolved statically at compile time, the code generator emits a short, single-cycle branch loop to find `0x00`:

```assembly
; Evaluating s.len -> target_reg (e.g., R1)
; Base pointer in R14
ADD     R14, R15, offset_s  ; Base address
LD      R1, 0               ; len_counter = 0

._scan_str_len_1:
LD8     R2, (R14)           ; Read byte
FBRA.Z  R2, ._scan_done_2   ; If byte == 0, terminate
ADD     R1, 1               ; len_counter++
ADD     R14, 1              ; ptr++
FBRA    ._scan_str_len_1

._scan_done_2:
; Target register R1 contains runtime length
```

---

## 4. Parser & AST Modifications in `tools/act16c.py`

### 4.1 Tokenizer & Grammar Updates
1. Recognize `string` as a primitive type keyword in `parse_type()`.
2. Recognize `string[N]` in declarations:
   - When token is `string`, consume `[`, evaluate constant capacity expression $N$, and consume `]`.
   - Store AST node: `StringDeclNode(name, capacity, init_expr, bound_addr)`.

### 4.2 AST Node Structure
```python
class StringDeclNode(ASTNode):
    def __init__(self, name, capacity, init_val=None, bound_addr=None):
        self.name = name
        self.capacity = capacity
        self.init_val = init_val
        self.bound_addr = bound_addr

class StringViewNode(ASTNode):
    """Represents a slice of a string or array into an open array pair."""
    def __init__(self, base_expr, start_expr, end_expr):
        self.base_expr = base_expr
        self.start_expr = start_expr
        self.end_expr = end_expr
```

### 4.3 CodeGen Symbol Table Additions
In `CodeGen.__init__()`:
```python
self.string_caps = {}    # name -> capacity (int)
self.string_lens = {}    # name -> static length if known (int or None)
```

In `_get_expr_type()`:
- If target is a string symbol, return `('string', False)`.
- If accessing `.capacity`, return `('u32', False)` and resolve to static immediate.
- If accessing `.len`, return `('u32', False)`.

---

## 5. Verification & Acceptance Criteria

### Test 1: Stack Allocation & Null Termination
Create `apps/act16/string_basic_test.act`:
- Declare `string[16] greeting = "Particle";`.
- Assert `greeting.capacity == 16`.
- Assert `greeting.len == 8`.
- Verify byte at `greeting[8] == 0`.
- Verify writing `greeting[0] = 'p'` updates the string without clobbering the terminator.

### Test 2: C-ABI Interoperability
Create `apps/act16/string_c_abi_test.act`:
- Declare a driver routine `void uart_puts(u8* s)` that iterates until `*s == 0`.
- Pass a `string[32]` to `uart_puts`.
- Verify simulation halts cleanly at `TRAP 14` (`0xCAFE`) without buffer overruns.

### Test 3: String Slicing into Open Arrays
Create `apps/act16/string_slice_test.act`:
- Define `u32 sum_bytes(u8 buf[])`.
- Pass `greeting[0..4]` into `sum_bytes`.
- Verify primary register carries `&greeting[0]` and companion register carries `4`.
- Validate dynamic `.len` and runtime bounds checking (`TRAP 15`) inside `sum_bytes`.

---

## 6. Implementation Checklist
- [ ] Add `string` keyword to `parse_type()` in `tools/act16c.py`.
- [ ] Implement `parse_string_decl()` supporting `string[N] name = "literal";`.
- [ ] Add capacity check enforcing `len(literal) < capacity`.
- [ ] Register `self.string_caps` and `self.string_lens` in compiler symbol tables.
- [ ] Implement constant folding for `str.capacity`.
- [ ] Implement scan loop or constant folding for `str.len`.
- [ ] Lower `str[start..end]` to `SliceNode` companion register passing for `u8[]`.
- [ ] Enforce bounds check trapping on `str[capacity - 1]` mutations.
- [ ] Pass all test suites under `python3 tools/psim.py build/<test>.bin`.