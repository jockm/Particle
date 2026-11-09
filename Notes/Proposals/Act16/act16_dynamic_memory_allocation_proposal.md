# ACT16 Compiler Architectural Proposal
## Dynamic Memory Allocation, Pluggable Backends, and Static Null Safety

**Document Version:** 1.0  
**Target System:** Particle 32-bit RISC Architecture / LLVM IR  
**Compiler:** `tools/act16c.py`

---

## 1. Executive Summary

ACT16 was originally designed for bare-metal execution on the Particle 32-bit compact RISC architecture, where memory allocation is strictly static (`.data`, `.bss`, hardware stack, or absolute `@` address bindings).

This proposal establishes a technical roadmap for:
1. **Dynamic Memory Allocation Semantics**: Uniform, object-oriented syntax via `Type.create()` and `Type.createArray(N)`.
2. **Pluggable Backend Architecture**: Decoupling code generation so that the same frontend AST compiles to:
   * **Particle Bare-Metal Assembly** (`.asm` via `tools/pasm.py`) backed by an ultra-lightweight bump/freelist allocator.
   * **LLVM Intermediate Representation** (`.ll`) backed by standard target OS libraries (`malloc`/`free`).
3. **Zero-Overhead Null Safety**: Eliminating null and dangling references without runtime magic headers or garbage collection by combining hardware guard trapping, single-ownership affine move semantics, and the `.exists()` introspection pseudo-method.

---

## 2. Syntax & Language Semantics

### 2.1 Dynamic Instantiation Syntax

Dynamic allocation is expressed via type-bound pseudo-constructor methods rather than raw operators (`malloc`, `new`):

```c
// Dynamic record allocation
Point p = Point.create();

// Dynamic contiguous array allocation
Point pts[] = Point.createArray(20);
```

### 2.2 Companion Deallocation Syntax

To prevent memory leaks on bare metal without a heavy tracing garbage collector, types provide matching pseudo-destructors:

```c
p.destroy();
pts.destroyArray();
```

* Calling `p.destroy()` frees the underlying memory block and statically invalidates `p`.
* Calling `pts.destroyArray()` frees the dynamic array block (including the array header) and invalidates `pts`.

---

## 3. Semantic Analysis & Type System Invariants

### 3.1 Preservation of the "No Aggregate Return by Value" Invariant

In ACT16, functions and expressions **never return aggregate records by value** to avoid hidden stack or frame-copying overhead on bare-metal RISC hardware.

* `Point.create()` evaluates to an **implicit reference** (`is_reference: True`).
* The variable `p` is allocated a 32-bit register or stack slot storing the allocated heap pointer.
* All subsequent field accesses (`p.x`, `p.y`) use standard dot notation (`.`) and are automatically dereferenced by the code generator—the arrow operator (`->`) remains deprecated and removed.

### 3.2 Dynamic Array Layout & Header Contract

Static arrays in ACT16 evaluate `.len` at compile time and trap on out-of-bounds indexing. For dynamic arrays created via `Type.createArray(count)`, the length is dynamic.

#### Memory Layout
Dynamic arrays use a single 4-byte prefix header containing the element count:

```
[ Offset -4: u32 length ] [ Offset 0: elem 0 ] [ Offset 4: elem 1 ] ...
```

* **Allocation Lowering**:
  $$\text{bytes\_needed} = 4 + (\text{count} \times \text{sizeof}(T))$$
  The runtime allocator allocates this block, stores `count` at byte 0, and returns the pointer to `byte 4`.
* **Length Introspection (`pts.len`)**:
  Lowered to read `*(pts - 4)`. Callee frames treat it identically to open array reference parameters.
* **Bounds Verification**:
  Indexed accesses `pts[i]` load the runtime length from `*(pts - 4)`, execute Particle single-cycle comparison `SLT`, and branch to `TRAP 15` if $i \ge \text{len}$.

---

## 4. Zero-Overhead Null Safety Model

Traditional dynamic languages use heavy runtime tagging or per-object magic headers (`0xAA55AA55`) to verify allocation. In resource-constrained embedded systems, headers waste RAM and consume memory-read cycles.

ACT16 avoids null pointers and dangling references through a **four-pillar compile-time and architectural design**:

### 4.1 Unallocated Sentinel Representation (`0x00000000`)
* Unallocated reference variables are initialized to `0` (`PUSH32 R0`).
* Particle's memory map places trap vectors and interrupt tables starting at `0x00000100`. The first 256 bytes (`0x00000000`–`0x000000FF`) are unmapped hardware guard pages.
* Any read/write through an unallocated pointer triggers an immediate hardware alignment or vector trap (`TRAP 14` / `TRAP 15`), catching accidental dereferences with **zero software check overhead**.

### 4.2 Single Ownership & Move Semantics (Preventing Aliased Dangling Pointers)
If two variables point to the same heap object (`b = a`) and `a.destroy()` is called, `b` would become a dangling pointer. Rather than paying for reference counting or handle indirection tables, the compiler enforces **affine move semantics**:

```c
Point a = Point.create();
Point b = a;  // Ownership MOVED from 'a' to 'b'

a.x = 10;     // Compile-time Error: Attempt to access moved reference 'a'
a.destroy();  // Compile-time Error: 'a' no longer owns this reference
b.destroy();  // Valid: 'b' owns the reference
```

#### Compiler Implementation:
* In `act16c.py`, dynamic reference symbols have a state attribute: `UNINITIALIZED`, `VALID`, or `MOVED_OR_DESTROYED`.
* Simple variable assignment moves ownership and marks the source symbol as `MOVED_OR_DESTROYED`.
* After `.destroy()`, the variable is marked `MOVED_OR_DESTROYED` in the local symbol table, and the compiler emits instructions to zero out the variable's register/stack slot.

### 4.3 Borrowing for Function and Method Calls
To allow functions and methods to inspect or mutate dynamic objects without transferring ownership, ACT16's existing pass-by-reference calling convention serves as **borrowing**:

```c
void Point.translate(Point self, u16 dx, u16 dy) {
    self.x += dx;
    self.y += dy;
}

void main() {
    Point p = Point.create();
    p.translate(5, 10); // Borrowed: 'p' retains ownership
    p.destroy();        // Valid
}
```
* **Borrowing Rule**: Callee functions and methods cannot call `.destroy()` on borrowed reference parameters. Only the owning scope can invoke destruction.

### 4.4 The `.exists()` Pseudo-Method
For checking whether an optional or conditionally allocated reference is active:

```c
if (p.exists()) {
    p.x = 42;
}
```

* **Lowering**: Because move semantics guarantee no dangling aliases exist, testing `.exists()` simplifies to verifying that the local pointer slot is non-zero:
  ```assembly
  ; p.exists() evaluated to R1
  LD32    R1, (offset_p + R15)  ; Load reference slot
  NEZ     R1, R1                ; R1 = (R1 != 0) ? 1 : 0
  ```
* **Cost**: Single cycle, zero memory overhead.

---

## 5. Pluggable Backend Architecture

To support compilation for both bare-metal Particle microcontrollers and mature hosted platforms, code generation in `act16c.py` is abstracted into an interface:

```
                          ┌────────────────────────┐
                          │    act16c Frontend     │
                          │   (Parser & AST Pass)  │
                          └───────────┬────────────┘
                                      │
              ┌───────────────────────┴───────────────────────┐
              ▼                                               ▼
  ┌─────────────────────────┐                     ┌────────────────────────┐
  │   ParticleAsmBackend    │                     │      LLVMIRBackend     │
  ├─────────────────────────┤                     ├────────────────────────┤
  │ Target: Particle RISC   │                     │ Target: Target Triple  │
  │ ABI: R1-R4 Regs, R15 SP │                     │ ABI: Standard C ABI    │
  │ Alloc: _rt_alloc (bump) │                     │ Alloc: @malloc / @free │
  └─────────────────────────┘                     └────────────────────────┘
```

### 5.1 Abstract Backend Interface (`BackendBase`)
```python
class BackendBase:
    def gen_heap_alloc(self, target_reg, size_expr, count_expr=None):
        """Emit instructions to allocate memory and assign base address."""
        raise NotImplementedError

    def gen_heap_free(self, addr_reg, is_array=False):
        """Emit instructions to deallocate memory."""
        raise NotImplementedError
```

### 5.2 Particle Bare-Metal Backend (`ParticleAsmBackend`)
The Particle backend links with a lightweight runtime allocator (`lib/alloc.asm`).

#### Memory Map & Bump Allocator Layout
```
0x00000100 ┌─────────────────────────────────────────┐
           │ Vector Table (Direct Stride, 64 B)      │
0x00000500 ├─────────────────────────────────────────┤
           │ Code & Constants (.text / .rodata)      │
           ├─────────────────────────────────────────┤
           │ Global Data (.data / .bss)              │
_heap_start├─────────────────────────────────────────┤
           │ HEAP (Grows UP)                         │
           │        ▼                                │
           │                                         │
           │        ▲                                │
           │ STACK (Grows DOWN from RAM top)         │
0x00010000 └─────────────────────────────────────────┘ (64 KB BRAM Top)
```

#### Assembly Implementation (`lib/alloc.asm`)
```assembly
; ==============================================================================
; Particle Lightweight Bump Allocator
; Input:  R1 = requested size in bytes
; Output: R1 = pointer to block, or 0 (NULL) if out of memory
; ==============================================================================
_rt_alloc:
    LOAD32  R14, _heap_ptr
    LD32    R2, (R14)           ; Current heap break
    ADD     R1, 3
    AND     R1, -4              ; 4-byte word alignment
    ADD     R1, R2              ; Proposed new heap break

    ; Verify proposal does not collide with active stack pointer (R15)
    SLT     R3, R1, R15
    FBRA.Z  R3, ._alloc_oom     ; Out of memory if break >= SP

    LD32    (R14), R1           ; Advance _heap_ptr
    LD      R1, R2              ; Return previous break
    RRET

._alloc_oom:
    LD      R1, 0               ; Return 0 (failure)
    RRET
```

### 5.3 LLVM IR Backend (`LLVMIRBackend`)
For hosted desktop or server targets, the backend emits clean LLVM IR text (`.ll`):

```llvm
; External OS runtime declarations
declare noalias i8* @malloc(i64)
declare void @free(i8*)

; Point.create() lowering:
%pt_size = getelementptr %struct.Point, %struct.Point* null, i32 1
%bytes = ptrtoint %struct.Point* %pt_size to i64
%raw_mem = call noalias i8* @malloc(i64 %bytes)
%p = bitcast i8* %raw_mem to %struct.Point*

; Point.createArray(20) lowering:
; Allocate 4 bytes header + (20 * sizeof(Point))
%array_bytes = add i64 4, 160
%raw_arr = call noalias i8* @malloc(i64 %array_bytes)
%hdr = bitcast i8* %raw_arr to i32*
store i32 20, i32* %hdr
%payload = getelementptr i8, i8* %raw_arr, i64 4
%pts = bitcast i8* %payload to %struct.Point*
```

---

## 6. Implementation Roadmap

| Phase | Milestone | Description |
| :---: | :--- | :--- |
| **1** | **Lexer & Parser Additions** | Recognize `.create()`, `.createArray(N)`, `.destroy()`, `.destroyArray()`, and `.exists()` on type identifiers and expressions. |
| **2** | **Symbol Ownership Tracking** | Extend symbol table entries with affine states (`VALID`, `MOVED_OR_DESTROYED`). Reject aliasing or post-destroy usage. |
| **3** | **Backend Refactoring** | Separate existing assembly emission in `tools/act16c.py` into `ParticleAsmBackend` under an abstract `BackendBase` interface. |
| **4** | **Particle Runtime Allocator** | Implement `lib/alloc.asm` with bump/freelist routines; add out-of-memory trap handling. |
| **5** | **LLVM IR Text Backend** | Add `-target=llvm` switch to emit LLVM assembly (`.ll`) targeting the standard C library runtime. |
| **6** | **Verification Suite** | Add test applications (`apps/act16/dyn_alloc_test.act`, `dyn_array_test.act`) verifying lifecycle and bounds enforcement. |