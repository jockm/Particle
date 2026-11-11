# The Action Programming Language

**Tutorial · User Guide · Reference**

Action is a small, C-like systems language for the **Particle** 32-bit RISC processor (16-bit compact instruction set). The Action compiler turns one or more source files into Particle assembly. Action is built for bare-metal work: memory-mapped I/O, hardware FIFOs, traps, inline assembly and cooperative multitasking. It also gives you conveniences that C does not have: bounds-checked arrays, methods attached to types, multiple return values, compile-time assertions and ownership-checked heap allocation.

This document has three parts:

1. **Tutorial**: a guided tour, from "hello" to coroutines.
2. **User Guide**: running the compiler, organizing projects, the generated code and the runtime.
3. **Reference**: the complete language definition, plus known limitations.

---

## Contents

- [Part 1: Tutorial](#part-1-tutorial)
  - [1.1 Your first program](#11-your-first-program)
  - [1.2 Variables and types](#12-variables-and-types)
  - [1.3 Control flow](#13-control-flow)
  - [1.4 Functions](#14-functions)
  - [1.5 Arrays and strings](#15-arrays-and-strings)
  - [1.6 User-defined types and methods](#16-user-defined-types-and-methods)
  - [1.7 Multiple return values](#17-multiple-return-values)
  - [1.8 Constants, enums and compile-time checks](#18-constants-enums-and-compile-time-checks)
  - [1.9 Talking to hardware](#19-talking-to-hardware)
  - [1.10 Heap memory and ownership](#110-heap-memory-and-ownership)
  - [1.11 Cooperative tasks](#111-cooperative-tasks)
- [Part 2: User Guide](#part-2-user-guide)
  - [2.1 Running the compiler](#21-running-the-compiler)
  - [2.2 Multi-file projects](#22-multi-file-projects)
  - [2.3 Bounds checking](#23-bounds-checking)
  - [2.4 Understanding the output](#24-understanding-the-output)
  - [2.5 The runtime support files](#25-the-runtime-support-files)
  - [2.6 Calling convention and inline assembly](#26-calling-convention-and-inline-assembly)
  - [2.7 Error messages](#27-error-messages)
- [Part 3: Reference](#part-3-reference)
  - [3.1 Lexical structure](#31-lexical-structure)
  - [3.2 Preprocessor](#32-preprocessor)
  - [3.3 Types](#33-types)
  - [3.4 Declarations](#34-declarations)
  - [3.5 Expressions and operators](#35-expressions-and-operators)
  - [3.6 Statements](#36-statements)
  - [3.7 Functions](#37-functions)
  - [3.8 User-defined types](#38-user-defined-types)
  - [3.9 Arrays, strings and slices](#39-arrays-strings-and-slices)
  - [3.10 Heap allocation and ownership](#310-heap-allocation-and-ownership)
  - [3.11 Coroutines](#311-coroutines)
  - [3.12 Hardware intrinsics](#312-hardware-intrinsics)
  - [3.13 Compile-time evaluation](#313-compile-time-evaluation)
  - [3.14 Keywords](#314-keywords)
  - [3.15 Known limitations and pitfalls](#315-known-limitations-and-pitfalls)

---

# Part 1: Tutorial

## 1.1 Your first program

Action programs start at `main`. On bare metal there is nowhere to "return to", so when `main` finishes, the processor sits in a halt loop.

Save this as `hello.act`:

```c
// hello.act: write a greeting to a memory-mapped UART
u8 UART_TX @ 0x40000000;      // a variable bound to a hardware address

void main() {
    string msg[16] = "Hello, Particle";
    for (u32 i : 0..msg.len) {
        UART_TX = msg[i];
    }
}
```

Compile it {tktk fix me}:

```sh
actionc hello.act          # {tktk fix me}
```

This writes Particle assembly to `build/hello.asm`. You then assemble it with your Particle assembler, along with the runtime support files (see [2.5](#25-the-runtime-support-files)).

The example already shows several features:

- `u8 UART_TX @ 0x40000000;` declares a variable that **lives at a fixed address**, so writing to it writes to the device.
- `string msg[16]` is a 16-byte string buffer, initialized from a literal.
- `for (u32 i : 0..msg.len)` is a **range loop**. It counts from 0 up to, but not including, `msg.len`.
- `msg[i]` is **bounds-checked** at run time by default.

## 1.2 Variables and types

Action has six integer types, a string type and `void`:

| Type | Size | Range |
|------|------|-------|
| `u8`  | 1 byte  | 0 … 255 |
| `s8`  | 1 byte  | −128 … 127 |
| `u16` | 2 bytes | 0 … 65 535 |
| `s16` | 2 bytes | −32 768 … 32 767 |
| `u32` | 4 bytes | 0 … 4 294 967 295 |
| `s32` | 4 bytes | −2 147 483 648 … 2 147 483 647 |
| `string` | 1 byte per character | null-terminated character buffer |

```c
void main() {
    u32 count = 10;
    s16 delta = -3;
    u8  ch = 'A';           // character literals are integers (65)
    u32 mask = 0xFF00;      // hex literals use a lowercase 0x

    count = count + delta;
    count += 1;             // compound assignment
}
```

All arithmetic is done in 32-bit registers. Narrow values are zero-extended (unsigned) or sign-extended (signed) when loaded, and truncated when stored.

Local variables are **zero-initialized** automatically when the function is entered.

Pointers to scalars use `*`. `&` takes an address and `*` dereferences it:

```c
void main() {
    u32 x = 1;
    u32* p = &x;
    *p = 5;          // x is now 5
    u32 y = p[0];    // indexing a pointer also works (scaled by element size)
}
```

## 1.3 Control flow

```c
u32 classify(u32 n) {
    if (n == 0) {
        return 0;
    } else if (n < 10) {
        return 1;
    } else {
        return 2;
    }
}

void main() {
    u32 i = 0;
    while (i < 100) {
        i += 1;
        if (i == 42) break;
    }

    for (u32 k : 0..8) {        // k = 0, 1, ..., 7
        // ...
    }

    switch (i) {
        case 1:
            i = 10;
            break;
        case 0x2A:
            i = 20;
            break;
        default:
            i = 0;
    }
}
```

A few things to know:

- `for` only counts **upward by 1**, and its upper bound is **exclusive**. The bound is evaluated once, before the first iteration.
- `case` values must be **integer literals** (or integer `#define` macros). As in C, execution **falls through** to the next case unless you `break`.
- `continue` is a reserved word but is **not supported yet**. Structure the loop with `if` instead.

## 1.4 Functions

```c
u32 add(u32 a, u32 b) {
    return a + b;
}

void reset(u32* counter) {
    *counter = 0;
}

void main() {
    u32 total = add(2, 3);
    reset(&total);
}
```

Functions may be declared before they are defined, using a prototype:

```c
u32 add(u32 a, u32 b);
```

Arguments travel in registers. A function can take **at most four register-sized arguments** (see [3.7](#37-functions)).

**Inline functions** are expanded at each call site instead of being called:

```c
inline u32 twice(u32 v) { return v * 2; }
```

An inline function must not declare local variables.

**Function types** let you store and call functions indirectly:

```c
type BinOp = fn(u32, u32) -> u32;

u32 add(u32 a, u32 b) { return a + b; }
u32 mul(u32 a, u32 b) { return a * b; }

u32 apply(BinOp op, u32 x, u32 y) { return op(x, y); }

void main() {
    BinOp f = add;          // signature is checked at compile time
    u32 r = apply(f, 6, 7);
    f = mul;
    r = f(6, 7);
}
```

## 1.5 Arrays and strings

Fixed-size arrays can have one or more dimensions:

```c
void main() {
    u32 values[8];
    u8  grid[4][4];

    values[3] = 99;
    grid[1][2] = 7;

    u32 n = values.len;      // 8, known at compile time
}
```

An out-of-range index raises **trap 15** at run time, unless you compile with bounds checking off.

A function can accept an array of **any length** through an **open array parameter**, written `T name[]`. The array's length travels with it:

```c
u32 sum(u32 data[]) {
    u32 total = 0;
    for (u32 i : 0..data.len) {
        total += data[i];
    }
    return total;
}

void main() {
    u32 a[10];
    u32 all  = sum(a);          // whole array
    u32 part = sum(a[2..5]);    // elements 2, 3, 4
    u32 head = sum(a[..3]);     // elements 0, 1, 2
    u32 tail = sum(a[7..]);     // elements 7, 8, 9
}
```

**Slices** (`a[start..end]`) can only be used as arguments to open-array parameters.

**Strings** are byte buffers with a fixed capacity:

```c
void main() {
    string name[32] = "Particle";
    u32 length = name.len;        // 8: scans to the null terminator
    u32 room   = name.capacity;   // 32
    name[0] = 'p';
}
```

The literal must fit in the capacity, and the compiler checks this. Writes to a string are bounds-checked so that the final byte stays free for the null terminator.

## 1.6 User-defined types and methods

Declare a record type with `type`:

```c
type Point {
    s32 x;
    s32 y;
}
```

Attach a **method** by writing `TypeName.method`. Inside the method, the receiver is called `this`:

```c
void Point.move(s32 dx, s32 dy) {
    this.x += dx;
    this.y += dy;
}

s32 Point.manhattan() {
    s32 ax = this.x;
    s32 ay = this.y;
    if (ax < 0) ax = -ax;
    if (ay < 0) ay = -ay;
    return ax + ay;
}

void main() {
    Point p;
    p.x = 3;
    p.y = -4;
    p.move(1, 1);
    s32 d = p.manhattan();
}
```

Values of user-defined types are **passed by reference automatically**. A function that receives a `Point` sees, and can change, the caller's `Point`. For this reason you may not write `Point*`. Doing so is a compile error.

**Embedding** places one type inside another, without a field name. The embedded type's fields and methods become available directly on the outer type:

```c
type Sprite {
    Point;          // embedded: Sprite gets x, y and move()
    u8 frame;
}

void main() {
    Sprite s;
    s.x = 10;           // promoted field
    s.move(2, 0);       // promoted method, called on the embedded Point
    s.frame = 1;
}
```

## 1.7 Multiple return values

A function can return up to four values as a tuple:

```c
(u32, u32) divmod(u32 a, u32 b) {
    return (a / b, a % b);
}

void main() {
    (u32 q, u32 r) = divmod(17, 5);   // declare and assign: q = 3, r = 2
    (q, r) = divmod(9, 4);            // assign to existing variables
    (u32 only_q, _) = divmod(8, 3);   // '_' discards a value
}
```

## 1.8 Constants, enums and compile-time checks

```c
const u32 BUFFER_SIZE = 64;
const u32 HALF = BUFFER_SIZE / 2;     // constant expressions are allowed

enum Mode { IDLE, RUNNING, STOPPED = 10, FAULT }   // 0, 1, 10, 11

type Header { u16 id; u16 flags; u32 length; }

verify(sizeof(Header) == 8, "Header must be 8 bytes");
verify(FAULT == 11, "enum numbering changed");
```

- `const` values and `enum` members exist only at compile time and use no memory.
- `verify(condition, "message")` stops compilation with your message if the condition is false. It works at the top level and inside functions.

Use the preprocessor when you need a constant in a place that requires a literal, such as array sizes or `case` labels:

```c
#define CMD_READ  1
#define CMD_WRITE 2
#define SLOTS     16

u32 slots[SLOTS];

void handle(u32 cmd) {
    switch (cmd) {
        case CMD_READ:  break;
        case CMD_WRITE: break;
    }
}
```

## 1.9 Talking to hardware

**Memory-mapped registers and buffers** are declared with `@ address`:

```c
u32 TIMER_CTRL   @ 0x40001000;
u32 TIMER_COUNT  @ 0x40001004;
u8  FRAMEBUFFER[1024] @ 0x00080000;

void main() {
    TIMER_CTRL = 1;
    FRAMEBUFFER[0] = 0xFF;
}
```

**Hardware FIFOs** have built-in functions:

```c
void main() {
    u32 word = readfifo(1);       // blocking read from channel 1
    writefifo(0, word + 1);       // write to channel 0

    u32 got;
    u32 ok = tryreadfifo(2, &got); // non-blocking attempt
}
```

**Traps** and **inline assembly**:

```c
void main() {
    trap(3);                        // executes TRAP 3
    asm("NOP");
    asm("LD      R1, 5\nNOP");      // \n separates lines
}
```

## 1.10 Heap memory and ownership

Action provides heap allocation through built-in "constructors" and checks at compile time that you do not use or free memory after you have given it away.

```c
void main() {
    u32 samples = u32.createArray(100);   // heap array of 100 u32
    samples[0] = 42;                      // bounds-checked against the real length
    u32 n = samples.len;                  // 100, read from the array header

    samples.resize(200);                  // grow (contents preserved by the allocator)

    string line = string.create(80);      // heap string with capacity 80

    samples.destroyArray();               // free
    u32 alive = samples.exists();         // 0: the handle was cleared
}
```

Heap handles are **affine**: each one has exactly one owner. Assigning a handle to another variable **moves** it:

```c
void main() {
    u32 a = u32.createArray(4);
    u32 b = 0;
    b = a;              // ownership moves to b
    u32 c = a;          // compile error: use of moved reference 'a'
}
```

The compiler also rejects freeing the same handle twice, and freeing an array that was only **borrowed** as a parameter:

```c
void process(u32 data[]) {
    data.destroyArray();   // compile error: cannot destroy borrowed parameter
}
```

> **Caution:** In this version of the compiler, `TypeName.create()` allocates heap memory, but field access on the resulting variable reads and writes the local stack copy, not the heap object. Until this is fixed, use heap allocation for arrays and strings only. See [3.15](#315-known-limitations-and-pitfalls).

## 1.11 Cooperative tasks

Action has built-in **stackless coroutines** for cooperative multitasking. A task function can pause with `yield` or `wait_until` and later resume where it left off.

The task's state lives in a record whose **first field is a 16-bit continuation counter**:

```c
type Blinker {
    u16 lc;          // continuation counter: must be the first field
    u32 toggles;
}

u32 LED @ 0x40002000;

u32 blink(Blinker t) {
    while (1) {
        LED = 1;
        yield(t, 1);                          // pause; resume here next call
        LED = 0;
        wait_until(t, 2, readfifo(0) == 1);   // pause until a condition holds
        t.toggles += 1;
    }
}

void main() {
    Blinker b;
    while (1) {
        u32 status = blink(b);    // run the task until it pauses
        // ... run other tasks here ...
    }
}
```

Each call runs the task until its next pause point and returns a status:

| Status | Meaning |
|--------|---------|
| 0 | waiting: a `wait_until` condition was false |
| 1 | yielded: the task reached a `yield` |
| 3 | ended: the task ran off the end and was reset to the start |

**Important:** local variables are *not* preserved across a pause, because they are re-zeroed every time the function is entered. Keep any state you need in the task record.

---

# Part 2: User Guide

## 2.1 Running the compiler

{tktk fix me} The general form is:

```sh
actionc [options] source.act [more.act ...]     # {tktk fix me}
```

| Option | Meaning |
|--------|---------|
| `-o FILE`, `--output FILE` | Write the assembly to `FILE`. Default: `build/<first-source-name>.asm`. The output directory is created if needed. |
| `-D NAME` | Predefine `NAME` with the value 1, as if by `#define NAME 1`. |
| `-D NAME=VALUE` | Predefine `NAME` with `VALUE`. Decimal and `0x` hex values become integers. |
| `-fbounds-check` | Enable run-time array bounds checks (the default). |
| `-fno-bounds-check` | Disable run-time bounds checks. |
| `-h`, `--help` | Show usage. |

Examples {tktk fix me}:

```sh
actionc main.act                                  # {tktk fix me}  -> build/main.asm
actionc main.act -o out/firmware.asm              # {tktk fix me}
actionc -D DEBUG -D BAUD=115200 main.act          # {tktk fix me}
actionc -fno-bounds-check main.act                # {tktk fix me}
```

The usual file extension is `.act`.

## 2.2 Multi-file projects

You can pass several source files in one compiler invocation {tktk fix me}. They are compiled into a **single** assembly file.

- Each file is tokenized and preprocessed separately, then all declarations are merged.
- A function may have **only one definition** across all files. Defining it twice is an error that names both files.
- **Prototypes** (`u32 f(u32 x);`) can appear anywhere, so put shared prototypes and types in a header.
- Integer `#define` values and `-D` symbols carry over from one file to the next. Function-like macros do not.

A typical layout:

```
project/
├── lib/
│   ├── common.inc      (assembler support, see 2.5)
│   ├── alloc.asm       (heap allocator, see 2.5)
│   └── uart.ah         (your shared Action header)
├── main.act
└── drivers.act
```

```c
// main.act
#include "uart.ah"      // found via the lib/ search path
```

`#include` searches these places, in order:

1. the path exactly as written (relative to the current working directory)
2. the directory of the file that contains the `#include`
3. `lib/`
4. `../`

## 2.3 Bounds checking

With bounds checking on (the default), every array index is checked:

| Array kind | Checked against |
|------------|-----------------|
| Fixed array `T a[N]` | `N` for each dimension |
| Open array parameter `T a[]` | the length passed by the caller |
| Heap array or string | the length or capacity stored in the heap header |
| String write | capacity − 1, so the null terminator always fits |

An out-of-range index executes `TRAP 15`. Install a handler for trap 15 in your system to report or recover from the fault.

`-fno-bounds-check` {tktk fix me} removes the checks, which makes the code smaller and faster.

## 2.4 Understanding the output

The generated assembly is organized as follows:

1. A header comment, then `.include "lib/common.inc"`.
2. **If the program defines `main`:** startup code at `.org 0x00000100`:
   - `_vector_reset`: sets the stack pointer to `0x00010000` and jumps to `_main`
   - `_vector_mbox`: a mailbox trap vector stub (`FAST_ENTER_TRAP` / `FAST_EXIT_TRAP`)
   - each vector is aligned to 64 bytes
3. One block per function, with label `_name`. Methods use the label `_Type_method`.
4. **Global variable section**: one label `_name` per global, word-aligned.
5. **String literal table**: `.asciz` entries.
6. `.include "lib/alloc.asm"` for the heap runtime.

Inline functions and prototypes produce no code of their own. `const` and `enum` produce no data.

## 2.5 The runtime support files

The output refers to two files that you provide to the **assembler**:

- **`lib/common.inc`**: assembler macros and definitions that the generated code relies on (for example `FAST_ENTER_TRAP` / `FAST_EXIT_TRAP`).
- **`lib/alloc.asm`**: the heap allocator. It must provide:

| Routine | Input | Output |
|---------|-------|--------|
| `_rt_alloc`   | R1 = size in bytes | R1 = pointer to block |
| `_rt_free`    | R1 = pointer to block | — |
| `_rt_realloc` | R1 = pointer to block, R2 = new size in bytes | R1 = pointer to (possibly moved) block |

Heap arrays and strings store a 4-byte header (element count or capacity) **immediately before** the data pointer that your program sees.

## 2.6 Calling convention and inline assembly

You need this when you write `asm(...)` blocks or link to hand-written assembly.

| Register | Role |
|----------|------|
| R0 | always zero |
| R1–R4 | arguments, in order. R1 holds the return value. R1–R4 hold tuple return values. |
| R13 | compiler scratch |
| R14 | link register (return address) and compiler scratch |
| R15 | stack pointer (grows downward) |

- Calls use `RCALL _name`, and returns use `RRET`. The callee pushes R14 on entry and restores it before returning.
- Indirect calls through function values use `JMP Rn, R14`.
- Scalars are passed by value. User-defined types are passed by **address**. An open array takes **two** registers: data pointer, then length. A method's receiver (`this`) takes the first register.
- **No registers are preserved across calls.** Assume R1–R14 are clobbered.
- Labels: functions and globals are `_name`. Methods are `_Type_method`, so a free function named `Point_move` would collide with method `Point.move`.

Inline assembly is copied verbatim into the output, one instruction per line:

```c
asm("PUSH32  R1\nTRAP    7\nPOP32   R1");
```

## 2.7 Error messages

The compiler stops at the first error and exits with status 1. Most messages include `file:line:column`. Common ones:

| Message (abridged) | Cause |
|--------------------|-------|
| `Unexpected token '…'` | Syntax error, or an unsupported keyword such as `continue`. |
| `Expected integer constant after 'case'` | A `case` used an enum or `const` name. Use a literal or a `#define`. |
| `String literal length (N) exceeds capacity (M)` | The initializer does not fit in the buffer. |
| `aggregate types are implicit references; pointer syntax '*' is invalid` | `Point*` was used with a user-defined type. |
| `Compile-time verification failed: '…'` | A `verify` condition was false. |
| `use of moved or deallocated affine reference 'x'` | A heap handle was used after a move or free. |
| `cannot destroy borrowed reference parameter 'x'` | A parameter was freed inside the function that borrowed it. |
| `Function signature mismatch: cannot assign …` | A function value does not match the function type. |
| `Maximum 4 scalar return values supported` | A tuple has more than four elements. |
| `Tuple return arity mismatch` | `return (…)` has the wrong number of values. |
| `Redefinition of function 'f' in …` | `f` is defined in two source files. |
| `Included file '…' not found` | No search location contains the file. |
| `'struct' is deprecated; use 'type Name { ... }'` | Old syntax was used. |
| `Circular dependency or unknown type in struct/type definition` | Types contain each other by value, or a field's type is undefined. |
| `'break' outside of loop or switch block` | A `break` has no enclosing loop or `switch`. |

---

# Part 3: Reference

## 3.1 Lexical structure

**Comments:** `// to end of line` and `/* block */`. Block comments do not nest.

**Identifiers:** a letter or `_`, followed by letters, digits or `_`. Identifiers are case-sensitive. A lone `_` is the wildcard in tuple assignment.

**Integer literals:**
- Decimal: `0`, `42`, `65535`
- Hexadecimal: `0x1F`, `0xdeadBEEF`. The prefix must be lowercase `0x`.
- There are no negative literals. `-5` is unary minus applied to `5`.

**Character literals:** a single character or escape in single quotes: `'A'`, `'\n'`, `'\0'`, `'\x41'`. The value is the character code.

**String literals:** `"text"`, with escapes `\n \r \t \\ \" \0 \xNN`.

**Operators and punctuation:**

```
+  -  *  /  %  &  |  ^  ~  !  <  >  =
== != <= >= << >> && || -> ..
+= -= *= /= &= |= ^= <<= >>=
:  ;  ,  (  )  {  }  [  ]  @  .
```

## 3.2 Preprocessor

Directives start with `#` or `.` (for example `#define` or `.define`). Directive names are lowercase.

| Directive | Effect |
|-----------|--------|
| `#define NAME` | Defines `NAME` with the value 1. |
| `#define NAME value` | Object-like macro (see note below). |
| `#define NAME(a, b) body` | Function-like macro. Parameters are replaced as whole words. |
| `#include "file"` or `#include <file>` | Inserts a file (search order in [2.2](#22-multi-file-projects)). |
| `#ifdef NAME` / `#ifndef NAME` | Conditional on whether `NAME` is defined. |
| `#if expr` | Conditional on an integer expression. |
| `#else`, `#endif` | Ends or flips the current conditional. Conditionals nest. |

A trailing `\` continues a `#define` onto the next line.

**Object-like macros only substitute integer values.** `#define SIZE 64`, `#define MASK 0xFF` and `#define OFFSET -4` are replaced wherever the name appears. A non-integer value, such as `#define NAME "text"` or `#define REG UART_TX`, is recorded but **never substituted**. Use a function-like macro with no parameters for those cases:

```c
#define GREETING() "hello"
#define LED_ON()   LED = 1
```

**`#if` expressions** may use integers, defined names, `+ - * / % < > & | ^ ~` and parentheses. There is **no** `defined()`, `#elif`, `&&` or `||`. An expression that cannot be evaluated, such as one using an undefined name, counts as false.

**Predefined names:** `__LINE__` (current line number) and `__FILE__` (current file name, as a string). Lowercase `__line__` and `__file__` also work.

## 3.3 Types

### Scalar types

| Type | Bytes | Signed | Load | Store |
|------|-------|--------|------|-------|
| `u8`  | 1 | no  | zero-extend | low 8 bits |
| `s8`  | 1 | yes | sign-extend | low 8 bits |
| `u16` | 2 | no  | zero-extend | low 16 bits |
| `s16` | 2 | yes | sign-extend | low 16 bits |
| `u32` | 4 | no  | — | — |
| `s32` | 4 | yes | — | — |

Expressions are evaluated at 32 bits. Literals, and expressions whose type the compiler cannot determine, are treated as `u32`.

### `string`

A sequence of bytes ending in a null terminator. It is declared as a fixed buffer (`string s[N]`), as a heap string (`string.create(N)`), or as a parameter. `sizeof(string)` is 1 (one character).

### `void`

Used for functions that return nothing, and for an empty parameter list: `void f(void)`.

### Pointer types

`T*`, where `T` is a scalar or `string`. A pointer holds a 32-bit address.

- `*p` loads or stores a `T`. `p[i]` indexes with scaling by `sizeof(T)`.
- Plain arithmetic on a pointer (`p + 1`) adds **bytes** and is not scaled. Use `p[i]` for element access.
- Pointers to user-defined types are not allowed, because those types are already references.

### User-defined record types

```
type Name { fields }
```

See [3.8](#38-user-defined-types).

### Function types

```
type Name = fn(ParamType, ...) -> ReturnType;
type Name = fn(ParamType, ...);              // returns void
```

A function type is a 4-byte code address. See [3.7](#37-functions).

### Enum types

`enum Name { ... }` defines integer constants (see [3.4](#34-declarations)). The enum name is not a distinct type. Declare variables that hold enum values as `u32` (or another integer type).

## 3.4 Declarations

### Variables

```
Type name;
Type name = expression;
Type* name;
Type name[D1][D2]...;          // fixed array; dimensions are integer literals
Type name @ ADDRESS;           // bound to a fixed memory address
Type name[D] @ ADDRESS;        // bound array
```

- Array dimensions and `@` addresses must be **integer literal tokens**. An integer `#define` counts as a literal. A `const` does not.
- **Locals** are allocated in the function's stack frame and zero-filled each time the function is entered. Every local in a function shares one frame, even if it is declared inside a nested block. Do not reuse a name with a different type in the same function.
- **Globals** are emitted after the code. A global scalar may have a non-negative integer literal initializer. Any other initializer is ignored, and the global starts at 0. Global arrays start zero-filled.
- **Bound variables** (`@`) allocate no storage. Every access goes to the given address. Bound variables can be declared at the top level or inside functions.
- `volatile` is accepted before a top-level declaration and has no effect. Accesses to bound variables are never optimized away.

### Constants

```
const Type NAME = constant-expression;
```

The value is computed at compile time (see [3.13](#313-compile-time-evaluation)) and no storage is created. A constant can be used anywhere an expression is allowed, but not where a literal token is required (array dimensions, `case`, `@`, coroutine step numbers).

### Enums

```
enum Name { A, B, C = expr, D }
```

Members are numbered from 0, or from the last explicit value plus one. Here A=0, B=1, C=expr, D=expr+1. The members become **global** constants. They are not qualified by the enum name: write `C`, not `Name.C`. The trailing `;` is optional.

### Compile-time assertions

```
verify(constant-expression, "message");
```

`verify` is allowed at the top level and as a statement. Compilation fails with `message` if the expression evaluates to 0.

## 3.5 Expressions and operators

### Precedence (lowest to highest)

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 | `=` `+=` `-=` `*=` `/=` `&=` `\|=` `^=` `<<=` `>>=` | right |
| 2 | `\|\|` | left |
| 3 | `&&` | left |
| 4 | `==` `!=` `<` `<=` `>` `>=` | left |
| 5 | `&` `\|` `^` | left |
| 6 | `<<` `>>` | left |
| 7 | `+` `-` | left |
| 8 | `*` `/` `%` | left |
| 9 | unary `-` `~` `!` `*` (dereference) `&` (address-of) | right |
| 10 | postfix `()` `[]` `[a..b]` `.` `->` | left |

**This differs from C:** bitwise `& | ^` bind **tighter** than comparisons, and all three share one level. `flags & MASK == 0` therefore means `(flags & MASK) == 0`, while `a | b & c` means `(a | b) & c`. Use parentheses when you mix them.

### Arithmetic and bitwise

`+ - * / %`, `& | ^ ~`, `<< >>`, and unary `-` (negation). There is no `%=` operator.

### Comparison

`== != < <= > >=` produce 0 or 1. The comparison is **signed** if either operand is a variable, field or function result of a signed type (`s8`, `s16`, `s32`), and unsigned otherwise. Literals are unsigned, so `-1 < 0` is false. Store the value in an `s32` first if you need a signed comparison.

### Logical

- `!x` produces 1 if `x` is 0, and 0 otherwise.
- `a && b` and `a || b` produce 0 or 1, **but**:
  - **both operands are always evaluated** (there is no short-circuit)
  - they combine their operands **bitwise** before testing for non-zero, so `1 && 2` is **0**

  Use them only with operands that are already 0 or 1, such as comparison results: `(a != 0) && (b != 0)`.

### Assignment

`=` stores into a variable, field, array element or `*pointer`, and yields the stored value. Chaining (`a = b = 0`) works. Compound operators load the target, apply the operation and store the result.

### Member access

`.` and `->` mean the same thing. Both access a field or call a method. The special members are:

| Member | Applies to | Value |
|--------|-----------|-------|
| `.len` | fixed array | first dimension (compile-time) |
| `.len` | open array parameter | length passed by the caller |
| `.len` | heap array | element count from the header |
| `.len` | string (any kind) | characters before the null terminator (scanned at run time) |
| `.capacity` | fixed array or string | last dimension (compile-time) |
| `.capacity` | heap array or heap string | value from the header |
| `.capacity` | open array parameter | length passed by the caller |

The heap operations `.create()`, `.createArray()`, `.destroy()`, `.destroyArray()`, `.resize()` and `.exists()` are described in [3.10](#310-heap-allocation-and-ownership).

### `sizeof`

- `sizeof(u8)`, `sizeof(s8)`, `sizeof(string)` → 1
- `sizeof(u16)`, `sizeof(s16)` → 2
- `sizeof(u32)`, `sizeof(s32)`, `sizeof(void)`, `sizeof(FnType)` → 4
- `sizeof(RecordType)` → the record's packed size
- `sizeof(expression)` → the size of the expression's **element** type. For an array, this is the size of one element, not the whole array.

`sizeof` is a compile-time constant.

### Calls

`f(args)` calls a function, an inline function or a function-typed variable. A function's bare name (`f`) evaluates to its address and can be assigned to a variable of a matching function type.

## 3.6 Statements

| Statement | Form |
|-----------|------|
| Block | `{ statements }` |
| Empty | `;` |
| Expression | `expression;` |
| Declaration | see [3.4](#34-declarations) |
| If | `if (cond) stmt` or `if (cond) stmt else stmt` |
| While | `while (cond) stmt` |
| Range for | `for (Type var : start..end) stmt` |
| Switch | `switch (expr) stmt` |
| Case label | `case INT:` or `default:` (only inside a switch body) |
| Break | `break;` (exits the innermost loop or switch) |
| Return | `return;`, `return expr;` or `return (e1, e2, …);` |
| Tuple assign | `(targets) = call;` |
| Assembly | `asm("text");` |
| Yield | `yield(task, STEP);` |
| Wait | `wait_until(task, STEP, cond);` |
| Assertion | `verify(const-expr, "msg");` |

**Conditions** are true when non-zero.

**Range `for`:** `var` is declared by the loop header and must have a type. It starts at `start` and the body runs while `var < end`. `end` is evaluated **once**, before the loop starts. After each pass, `var` increases by 1. The body may change `var`.

**Switch:** each `case` label must be followed by an integer literal or an integer `#define`. After matching, control continues until a `break` or the end of the body, so cases fall through. If no case matches, control goes to `default:` if there is one, and otherwise past the switch.

**Tuple targets** can be `Type name` (declares a new variable), `name` (an existing variable) or `_` (discard). There can be up to four.

## 3.7 Functions

```
ReturnType name(params) { body }
ReturnType name(params);                       // prototype
(T1, T2, ...) name(params) { body }            // tuple return, up to 4
inline ReturnType name(params) { body }
ReturnType TypeName.method(params) { body }    // method, see 3.8
```

**Parameters:**

| Parameter form | Passed as | Register slots |
|----------------|-----------|----------------|
| `u32 x` (any scalar) | value | 1 |
| `u32* p` | address | 1 |
| `Point p` (record type) | address of caller's object | 1 |
| `T a[]` (open array) | data address + length | 2 |
| `BinOp f` (function type) | code address | 1 |
| `string s` | address | 1 |

A function may use **at most four register slots** in total. A method's `this` uses one slot, and each open array uses two. The compiler does not report extra parameters, which are silently mishandled.

**Return values:** a scalar, pointer or function value is returned in R1. Tuples return in R1 to R4. In a tuple-returning function, every `return` must give the declared number of values. In a scalar function, `return (a, b)` is an error. The compiler does not check that a non-`void` function returns a value on every path.

**Inline functions** are expanded at each call site. They have no address, cannot be recursive and must not declare local variables.

**`main`** is special. It sets up the stack and runs, and when it returns the processor enters a halt loop. `main` may be declared `void` or `u32`.

**Function values:** a variable of function type `F` can be assigned a function whose parameter types and return type **exactly** match `F`, or a value of the same function type. Assigning a function to a non-function variable, or a non-function to a function variable, is a compile-time error. Calling `v(args)` on a function variable `v` makes an indirect call.

## 3.8 User-defined types

```
type Name {
    Type field;
    Type* field;
    Type field[D1][D2];
    OtherType field;        // nested by value
    OtherType;              // embedded (anonymous)
}
```

- Field semicolons are optional, and so is the `;` after the closing brace.
- **Layout:** fields are placed in declaration order with **no padding or alignment**. A `u8` followed by a `u32` puts the `u32` at offset 1. Order fields from largest to smallest if alignment matters. Use `verify(sizeof(Name) == N, "...")` to pin a layout.
- Types may be declared in any order. Types that contain each other by value are an error.
- Embedding a scalar type (`u32;`) is not allowed.

**Embedding:** `OtherType;` inlines `OtherType`'s fields at that position. Its fields can then be accessed directly on the outer type. If the outer type declares a field with the same name, the outer field wins. Methods of the embedded type can be called on the outer type, and the receiver is adjusted to point at the embedded part. You can also refer to the embedded part as a whole by its type name: `sprite.Point`.

**Methods:** `ReturnType TypeName.method(params)` defines a function with an implicit first parameter `this` of type `TypeName`, passed by reference. Call it as `obj.method(args)`.

**Method references:** `TypeName.method` (on the type name, not on an instance) evaluates to the method's address. Its signature is `fn(TypeName, params...) -> ReturnType`. Writing `instance.method` without calling it is an error.

**Pass-by-reference:** record-typed variables and parameters always refer to the object. A record-typed parameter modifies the caller's object.

The keyword `struct` is not accepted. Use `type`.

## 3.9 Arrays, strings and slices

**Fixed arrays:** `T a[N]`, or multi-dimensional `T a[N][M]` (row-major). `a[i][j]` addresses element `i*M + j`. `.len` gives `N`, and `.capacity` gives the last dimension.

**Open arrays:** `T a[]` is allowed only as a parameter. It accepts:

| Argument | Length passed |
|----------|---------------|
| a fixed array | its first dimension |
| another open array | its length |
| a string variable | its current `.len` |
| a slice `x[s..e]` | `e − s` |
| a slice `x[s..]` | `x.len − s` |
| a slice `x[..e]` | `e` |
| a slice `x[..]` | `x.len` |

Slices are valid **only** as open-array arguments.

**Strings:**
- `string s[N] = "literal";` creates an N-byte buffer. The literal is copied in at run time and must not be longer than N. Keep it at most N−1 characters so the terminator fits inside the buffer.
- `.len` scans for the null terminator. `.capacity` is N.
- Indexing gives single bytes. Writes are bounds-checked against N−1.
- A string literal used in an expression evaluates to the address of a read-only copy in the string table. You can pass it to a `string s` parameter. Do not pass it to a `string s[]` open-array parameter, because its length would be 0.

## 3.10 Heap allocation and ownership

### Operations

| Expression | Effect |
|------------|--------|
| `T.createArray(n)` | Allocates an array of `n` elements of type `T` (any scalar or record type). Returns a handle. |
| `string.create(cap)` | Allocates a string buffer of capacity `cap`, initially empty. |
| `T.create()` | Allocates one `T` record. (Field access is broken, see [3.15](#315-known-limitations-and-pitfalls).) |
| `h.resize(n)` | Resizes heap array `h` to `n` elements and updates `h`. |
| `h.destroyArray()` / `h.destroy()` | Frees `h` and sets the variable to 0. |
| `h.exists()` | 1 if `h` is non-zero, else 0. |

Declare the handle with the element type:

```c
u32 buf = u32.createArray(64);
string s = string.create(128);
```

Heap arrays and strings carry a 4-byte header that holds the length (arrays) or capacity (strings). `.len`, `.capacity` and bounds checks read this header.

### Ownership rules

These rules are checked at compile time, within each function:

1. A variable that receives a heap allocation **owns** it.
2. `b = a`, where `a` owns a handle, **moves** ownership to `b`. Reading `a` afterward is an error.
3. After `destroy`/`destroyArray`, the variable counts as moved. Destroying or resizing it again is an error.
4. Parameters are **borrowed**. They cannot be destroyed, and cannot be moved into a variable that already owns a handle.

The checks follow the source text from top to bottom and do not account for branches or loops. They only apply to direct uses of the variable name: indexing a moved array (`a[0]`) is not caught. Nothing frees memory automatically.

## 3.11 Coroutines

```
yield(task, STEP);
wait_until(task, STEP, condition);
```

- `task` is an expression that names the task state. This is usually a record parameter whose **first field is `u16`**. The continuation counter is stored in those first 16 bits.
- `STEP` is an integer literal (or integer `#define`), unique within the function and not 0. Step 0 is the initial entry.
- Every `yield` and `wait_until` in one function must refer to the **same** task.

**Behavior:**
- On entry, the function reads the counter. If it is 0, the function starts at the top. Otherwise it jumps to the matching step.
- `yield(task, N)` stores N, returns **1**, and resumes just after the `yield` on the next call.
- `wait_until(task, N, cond)` evaluates `cond`. If it is true, execution continues. If it is false, the function stores N and returns **0**. On the next call, the function resumes at this `wait_until` and evaluates `cond` again.
- Falling off the end of the function resets the counter to 0 and returns **3**. An explicit `return` skips the reset and returns its own value.

**Restrictions:**
- `yield` and `wait_until` may appear in plain blocks, `if`/`else` and `while` bodies, but **not** inside `for` or `switch`. Use `while` loops in coroutine bodies.
- Locals are re-zeroed on every entry. Persistent state must be stored in the task record.
- Declare the function's return type as `u32` so callers can read the status.

## 3.12 Hardware intrinsics

| Call | Generates | Notes |
|------|-----------|-------|
| `trap(N)` | `TRAP N` | `N` must be an integer literal. Evaluates to 0. |
| `readfifo(CH)` | `FIFO.R` | Blocking read from channel `CH`. Returns the word read. |
| `writefifo(CH, value)` | `FIFO.W` | Writes `value` to channel `CH`. |
| `tryreadfifo(CH, addr)` | `FIFO.TRYR` | Non-blocking read. Stores the word at `addr` (for example `&x`) and returns the hardware's status indication. |
| `asm("text")` | verbatim | Each line of `text` becomes one assembly line. |

`CH` must be an integer literal. Any other expression silently selects channel 0.

## 3.13 Compile-time evaluation

Constant expressions are used by `const`, `verify` and explicit `enum` values. They may contain:

- integer literals and character literals
- names of `const` values and `enum` members (defined earlier)
- `sizeof(...)`
- unary `- ~ !`
- binary `+ - * / % & | ^ << >> == != < <= > >= && ||` (`&&` and `||` are true logical operators here)

Arithmetic is done modulo 2³². Division or modulo by zero yields 0.

## 3.14 Keywords

**In use:** `asm` `break` `case` `const` `default` `else` `enum` `fn` `for` `if` `inline` `return` `s8` `s16` `s32` `sizeof` `string` `switch` `type` `u8` `u16` `u32` `verify` `void` `volatile` `wait_until` `while` `yield`

**Reserved, not yet supported:** `continue`, `import`

**Built-in names** (identifiers with special meaning): `this`, `trap`, `readfifo`, `writefifo`, `tryreadfifo`, `__LINE__`, `__FILE__`, and the methods `create`, `createArray`, `destroy`, `destroyArray`, `resize`, `exists`, `len`, `capacity`.

## 3.15 Known limitations and pitfalls

These come from the current compiler's behavior. Most are worth fixing in the compiler, but until then, code around them.

| Issue | What happens | Workaround |
|-------|-------------|------------|
| `&&` and `\|\|` are bitwise-then-test, with no short-circuit | `1 && 2` is 0, and both sides always run | Use them only on 0/1 values, such as comparisons. Use nested `if` for short-circuit behavior. |
| Field assignment evaluates the right side twice | `p.x = next();` calls `next()` twice | Assign to a local first: `u32 v = next(); p.x = v;` |
| `T.create()` field access | Fields are read and written in the stack slot, not the heap object | Avoid heap-allocated records for now. Use arrays. |
| More than 4 parameter slots | Extra parameters are silently lost | Pass a record (by reference) that holds the extra values. |
| `continue` | Syntax error | Restructure the loop with `if`. |
| `case` with `const`/`enum` | Compile error | Use `#define` integer macros. |
| `const` as array size, `@` address or step number | Compile error | Use `#define` integer macros. |
| Non-integer object-like `#define` | Never substituted | Use a zero-parameter function-like macro: `#define X() ...` |
| No `#elif`, `defined()`, `&&`, `\|\|` in `#if` | Unsupported, or evaluates to false | Nest `#if`/`#ifdef`, and use `&`/`\|` in `#if` expressions. |
| Global initializers | Only non-negative integer literals. Anything else becomes 0. | Initialize at the start of `main`. |
| Global record-typed variables | Only one word of storage is reserved | Use locals in `main` passed by reference, or bound (`@`) storage. |
| Record layout has no padding | Fields can be misaligned | Order fields largest-first, and check with `verify(sizeof(...))`. |
| Inline functions with locals | The compiler crashes | Keep inline bodies to expressions over their parameters. |
| `yield`/`wait_until` inside `for` or `switch` | Resume point is not registered | Use `while`. |
| Literal comparisons are unsigned | `-1 < 0` is false | Put the value in a signed variable. |
| `&` of a field or array element | Generates no address | Take `&` only of plain variables. Pass records directly, since they are already references. |
| Pointer `+` is byte-based | `p + 1` is one byte further | Use `p[i]`. |
| Ownership checks don't follow branches | Moves inside `if` affect later code as if always taken | Keep ownership transfers straight-line where possible. |
| Locals are function-scoped | Same name in two blocks shares storage | Use distinct names. |
