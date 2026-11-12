# The Action Programming Language

**Tutorial · User Guide · Reference**

Action is a small systems language. It is built for work close to the hardware: memory-mapped I/O, hardware FIFOs, trap handlers, inline assembly and cooperative multitasking. It also provides bounds-checked arrays, methods attached to types, multiple return values, type aliases, compile-time assertions and ownership-checked heap allocation. Action has **no pointers**: instances of user-defined types and arrays are passed by reference automatically.

Today the compiler generates code for the **Particle** processor, and the parts of this guide about generated code, the runtime and the tools describe that target. Support for other platforms is planned.

This document has three parts:

1. **Tutorial**: a guided tour, from "hello" to tasks.
2. **User Guide**: building and running programs, organizing projects, the generated code and the runtime.
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
  - [2.1 Building and running programs](#21-building-and-running-programs)
  - [2.2 Multi-file projects](#22-multi-file-projects)
  - [2.3 Bounds and reference checking](#23-bounds-and-reference-checking)
  - [2.4 Understanding the output](#24-understanding-the-output)
  - [2.5 The runtime support files](#25-the-runtime-support-files)
  - [2.6 Calling convention and inline assembly](#26-calling-convention-and-inline-assembly)
  - [2.7 Running in the simulator](#27-running-in-the-simulator)
  - [2.8 Error messages](#28-error-messages)
  - [2.9 Editor support](#29-editor-support)
- [Part 3: Reference](#part-3-reference)
  - [3.1 Lexical structure](#31-lexical-structure)
  - [3.2 Modules and imports](#32-modules-and-imports)
  - [3.3 Types](#33-types)
  - [3.4 Declarations](#34-declarations)
  - [3.5 Expressions and operators](#35-expressions-and-operators)
  - [3.6 Statements](#36-statements)
  - [3.7 Functions](#37-functions)
  - [3.8 User-defined types](#38-user-defined-types)
  - [3.9 Arrays, strings and slices](#39-arrays-strings-and-slices)
  - [3.10 Heap allocation and ownership](#310-heap-allocation-and-ownership)
  - [3.11 Tasks](#311-tasks)
  - [3.12 Hardware intrinsics and traps](#312-hardware-intrinsics-and-traps)
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
build/tools/action hello.act          # {tktk fix me}
```

This writes Particle assembly to `build/hello.asm`. To get a binary you assemble it with `pasm`, which needs the runtime support files (see [2.5](#25-the-runtime-support-files)). The `pbuild` script does all of this in one step, and can also run the result in the simulator (see [2.1](#21-building-and-running-programs)):

```sh
./pbuild hello.act --sim              # {tktk fix me}
```

The example already shows several features:

- `u8 UART_TX @ 0x40000000;` declares a variable that **lives at a fixed address**, so writing to it writes to the device.
- `string msg[16]` is a 16-byte string buffer, initialized from a literal.
- `for (u32 i : 0..msg.len)` is a **range loop**. It counts from 0 up to, but not including, `msg.len`.
- `msg[i]` is **bounds-checked** at run time by default.

## 1.2 Variables and types

Action has six integer types, `bool`, a string type and `void`:

| Type | Size | Range |
|------|------|-------|
| `u8`  | 1 byte  | 0 … 255 |
| `s8`  | 1 byte  | −128 … 127 |
| `u16` | 2 bytes | 0 … 65 535 |
| `s16` | 2 bytes | −32 768 … 32 767 |
| `u32` | 4 bytes | 0 … 4 294 967 295 |
| `s32` | 4 bytes | −2 147 483 648 … 2 147 483 647 |
| `bool` | 1 byte  | 0 (`false`) or 1 (`true`) |
| `string` | 1 byte per character | null-terminated character buffer |

```c
void main() {
    u32 count = 10;
    s16 delta = -3;
    u8  ch = 'A';           // character literals are integers (65)
    u32 mask = 0xFF00;      // hex literals use a lowercase 0x

    count = count + delta;
    count += 1;             // compound assignment
    count %= 4;             // every arithmetic operator has one
}
```

`true` and `false` are built-in constants, 1 and 0. A `bool` always holds 0 or 1: storing any other constant in one is an error, and a value of another type is stored as 1 if it is non-zero and 0 if it is zero:

```c
bool ready = false;
u32 flags = 0x40;
bool any = flags;       // stored as 1
bool big = flags > 10;  // comparisons already give 0 or 1
bool bad = 2;           // error: the constant 2 does not fit in bool
```

All arithmetic is done in 32-bit registers. Narrow values are zero-extended (unsigned) or sign-extended (signed) when loaded, and truncated when stored. Division, remainder, right shift and comparisons are **signed** when an operand has a signed type (see [3.5](#35-expressions-and-operators)).

Local variables are **zero-initialized** automatically when the function is entered.

Action has **no pointers**. There is no `*`, `&` or `->` for addresses. Instances of user-defined types and arrays are passed to functions by reference automatically, and heap allocations are handled through references (see [1.6](#16-user-defined-types-and-methods) and [1.10](#110-heap-memory-and-ownership)).

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
        if (i % 2 == 0) continue;   // skip to the next iteration
    }

    for (u32 k : 0..8) {        // k = 0, 1, ..., 7
        // ...
    }

    switch (i) {
        case 1:
            i = 10;             // each case ends here: no break needed
        case 0x2A:
            i = 20;
            continue;           // fall through into the next case
        default:
            i = 0;
    }
}
```

A few things to know:

- `for` only counts **upward by 1**, and its upper bound is **exclusive**. The bound is evaluated once, before the first iteration.
- Each `case` ends with an **implicit `break`**. To fall through into the next case, end the case with `continue`. `break` still leaves the `switch` early.
- `continue` in a loop goes to the next iteration. Directly inside a `switch` case (even one inside a loop) it means "fall through". `continue` in the last case simply leaves the `switch`.
- `case` labels can be any integer constant: a literal, a character, a `const`, an `enum` member, or a constant expression.

## 1.4 Functions

```c
type Counter {
    u32 value;
}

u32 add(u32 a, u32 b) {
    return a + b;
}

void reset(Counter c) {     // c refers to the caller's Counter
    c.value = 0;
}

void main() {
    u32 total = add(2, 3);
    Counter k;
    k.value = total;
    reset(k);               // k.value is now 0
}
```

Functions may be declared before they are defined, using a prototype:

```c
u32 add(u32 a, u32 b);
```

The first four argument slots travel in registers R1–R4, and any further arguments go on the stack, so there is no fixed limit on parameters (see [2.6](#26-calling-convention-and-inline-assembly)).

**Inline functions** are expanded at each call site instead of being called. They may declare local variables:

```c
inline u32 twice(u32 v) {
    u32 r = v * 2;
    return r;
}
```

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

`lib/string.act` provides `string_copy`, `string_concat`, `string_compare`, `string_equals` and `string_find`. Bring it in with `import "lib/string.act";`.

## 1.6 User-defined types and methods

In Action, a type is a collection of fields, much like what other languages call a structure. Declare one with `type`:

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

Values of user-defined types are **passed by reference automatically**. A function that receives a `Point` sees, and can change, the caller's `Point`.

A variable of a user-defined type is either **stored in place** or a **reference**:

- `Point p;` with nothing assigned to it is **stored on the stack** (or in the data section, for a global).
- `Point r = Point.create();` is a **reference** to a `Point` on the heap (see [1.10](#110-heap-memory-and-ownership)). So is a variable given `0` (null), another reference, or the result of a function that returns a `Point`.

Instances are **never copied**. Assigning to a variable stored in place is a compile error, and so is making a reference point at an instance stored on the stack.

A field can hold a reference too. `ref T name;` refers to a `T` stored elsewhere, and `T name[];` refers to a heap array (see [1.10](#110-heap-memory-and-ownership)). Without `ref`, a field of a user-defined type is stored in place, inside the outer value:

```c
type Node {
    u32 value;
    ref Node next;      // a reference: a type can refer to itself this way
    u8 payload[];       // a reference to a heap array
}
```

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

Fields are laid out in order, each **aligned to its size** (`u16` on 2 bytes, `u32` and references on 4), and a type's size is padded to its most-aligned field. So `sizeof(Sprite)` is 12, not 9.

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
- A constant can be used **anywhere a literal can**: array sizes, `case` labels, `@` addresses, trap numbers and FIFO channels.
- `verify(condition, "message")` stops compilation with your message if the condition is false. It works at the top level and inside functions.

**How constants get their types.** A literal, an `enum` member, a `sizeof`, or an expression made only of those is **untyped**: it takes the type of whatever it is used with, and it is an error if the value does not fit. A `const` has the type it is declared with, and its value must fit that type.

```c
u8 b = 300;            // error: the constant 300 does not fit in u8
u32 m = ~0;            // error: ~0 is -1, which does not fit in u32; write 0xFFFFFFFF
const u32 X = -1;      // error: -1 does not fit in u32
s32 x = -1;            // fine
if (x < -1) { }        // -1 takes x's type, s32, so the comparison is signed
```

Expressions made only of constants are computed exactly, without wrapping at 32 bits, so `-1 < 0` is true and `(1 << 40) >> 20` is `0x100000`. Only the result has to fit where it is used. See [3.13](#313-compile-time-evaluation) for the full rules.

```c
const u32 CMD_READ  = 1;
const u32 CMD_WRITE = 2;
const u32 SLOTS     = 16;

u32 slots[SLOTS];

void handle(u32 cmd) {
    switch (cmd) {
        case CMD_READ:  slots[0] = 1;
        case CMD_WRITE: slots[1] = 1;
    }
}
```

**Type aliases** give another name to an existing type, the way C programs use `size_t` or `time_t`:

```c
type size_t = u32;
type millis = u32;

millis elapsed(millis start, millis now) {
    return now - start;
}
```

An alias is interchangeable with its type: a `size_t` can be used anywhere a `u32` can. Aliases can name scalars, `string`, user-defined types and function types, but not arrays.

There is no preprocessor. Constants replace `#define`, `import` replaces `#include` (see [3.2](#32-modules-and-imports)), and `-D NAME=VALUE` on the command line defines a constant (see [2.1](#21-building-and-running-programs)).

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

    u32 got = 0;
    u32 ok = tryreadfifo(2, got); // non-blocking: if data is waiting, got = data and ok = 1
}
```

**Trap handlers** run when a trap is taken, whether raised by the `trap(N)` intrinsic, by hardware (such as a misaligned access, trap 14), or by another core:

```c
u32 ticks = 0;

trap(3) on_tick() {
    ticks += 1;
}

void main() {
    trap(3);                        // executes TRAP 3: on_tick runs
    asm("NOP");
    asm("LD      R1, 5\nNOP");      // \n separates lines
}
```

A trap handler has no return value and takes no arguments, and the empty `()` is required. It runs only as a trap: calling it directly is an error.

## 1.10 Heap memory and ownership

Action provides heap allocation through built-in "constructors" and checks at compile time that you do not use or free memory after you have given it away.

```c
type Point { s32 x; s32 y; }

void main() {
    u32 samples[] = u32.createArray(100); // heap array of 100 u32
    samples[0] = 42;                      // bounds-checked against the real length
    u32 n = samples.len;                  // 100, read from the array header

    samples.resize(200);                  // grow (contents preserved by the allocator)

    string line = string.create(80);      // heap string with capacity 80

    Point p = Point.create();             // a Point on the heap: p is a reference
    p.x = 5;

    samples.destroyArray();               // free
    u32 alive = samples.exists();         // 0: the handle was cleared
    line.destroy();
    p.destroy();
}
```

A heap array is always declared with `[]` (`u32 samples[]`). Giving `createArray` to a plain `u32` or to a fixed-size array is a compile error.

A heap reference has exactly one owner. Assigning it to another variable **moves** it:

```c
void main() {
    u32 a[] = u32.createArray(4);
    u32 b[] = a;        // ownership moves to b
    u32 n = a.len;      // compile error: 'a' was moved to another variable and can no longer be used
}
```

The compiler follows each reference held in a function's variables along **every path** through the function, through branches and loops, and knows at each point whether it is valid, null (set to 0, destroyed, or never given a value) or moved. Using a reference that is not **definitely valid** is an error:

```c
type Item { u32 id; }

Item find(u32 id) {
    if (id == 0) {
        return 0;               // so a call to find may give null
    }
    Item it = Item.create();
    it.id = id;
    return it;
}

void main() {
    Item a = find(7);
    a.id = 1;                   // compile error: 'a' may be null here; check it with 'a.exists()' first
    if (a.exists()) {
        a.id = 1;               // fine: a is valid here
        a.destroy();
    }
    a.id = 2;                   // compile error: 'a' is null here
}
```

- `create()` and `createArray()` always give a valid reference. If the heap is exhausted, the program traps instead (see [2.3](#23-bounds-and-reference-checking)).
- A function whose every `return` gives a valid reference returns a valid reference. Otherwise its result may be null and has to be checked.
- `x.exists()` makes `x` valid where the test is true and null where it is false. `!x.exists()`, `x.exists() != 0`, `x.exists() == 1` and `x != 0` work too, and so do `&&` and `||`: `if (a.exists() && a.id == 7)` is fine.
- A reference held in a global or a field cannot be followed this way, so a variable given one may be null. Using a null reference held in a global or a field traps at run time (see [2.3](#23-bounds-and-reference-checking)).
- Memory from `create()`, `createArray()` and `string.create()` is zeroed, so the reference fields of a new value start out null.

Storing a reference in a field **moves** it into the field, which then owns it:

```c
void main() {
    Node head = Node.create();
    Node second = Node.create();
    head.next = second;         // head.next now owns it
    second.value = 2;           // compile error: 'second' was moved to another variable or field
    head.next.value = 2;        // fine (checked for null at run time)
    head.next.destroy();        // frees it and sets head.next to 0
    head.destroy();             // does not free anything head's fields refer to
}
```

Reading a field into a variable (`Node n = head.next;`) copies the reference: both then refer to the same value, and the compiler does not stop you from destroying it through one and then using the other.

The compiler also rejects freeing an array that was only **borrowed** as a parameter:

```c
void process(u32 data[]) {
    data.destroyArray();   // compile error: cannot destroy borrowed parameter
}
```

## 1.11 Cooperative tasks

A **task** is a function that can pause and later resume where it left off, so several tasks can share one core without threads: a loop calls each in turn, and each runs until it pauses. Tasks are declared with `task`. They pause with `yield` or `wait_until`, or start over with `pk_exit`. These operations come from `lib/protokernel.act`, which you import.

A task's first parameter is its **state**: an instance of a type whose first field is a `u16`, where the task keeps its place. `protokernel.act` provides `type pt { u16 lc; }`, or you can declare your own with a `u16` first:

```c
import "lib/protokernel.act";

type Blinker {
    u16 lc;          // where the task resumes: must be the first field
    u32 toggles;
}

u32 LED @ 0x40002000;

task blink(Blinker t) {
    while (1) {
        LED = 1;
        yield(t);                          // pause; resume here next call
        LED = 0;
        wait_until(t, readfifo(0) == 1);   // pause until a condition holds
        t.toggles += 1;
        if (t.toggles == 100) {
            pk_exit(t);                    // stop; the next call starts from the top
        }
    }
}

void main() {
    Blinker b;
    while (1) {
        u16 status = blink(b);    // run the task until it pauses
        // ... run other tasks here ...
    }
}
```

Each call runs the task until its next pause and returns a `u16` status, which `protokernel.act` names:

| Status | Constant | Meaning |
|--------|----------|---------|
| 0 | `PK_WAITING` | a `wait_until` condition was false |
| 1 | `PK_YIELDED` | the task reached a `yield` |
| 2 | `PK_EXITED`  | the task called `pk_exit` |
| 3 | `PK_ENDED`   | the task ran off the end or ran `return;`, and was reset to the start |

**Local variables do not survive a pause.** Keep anything you need after a pause in the task's state. The compiler enforces this: reading a local after a pause, when it was set before the pause and not set again, is an error. A `for` loop whose body pauses is also an error, because its counter is a local; use a `while` loop with the counter in the state:

```c
type Counter { u16 lc; u32 i; }

task count(Counter c) {
    c.i = 0;
    while (c.i < 10) {
        yield(c);
        c.i += 1;
    }
}
```

---

# Part 2: User Guide

## 2.1 Building and running programs

The tools are Dart programs, built into `build/tools` with `make tools` (or one at a time: `make action`, `make pasm`, `make pasm-lint`, `make psim`).

| Tool | Does |
|------|------|
| `build/tools/action` | compiles Action to Particle assembly |
| `build/tools/pasm` | assembles to a binary |
| `build/tools/pasm_lint` | checks assembly for common mistakes |
| `build/tools/psim` | simulates a binary |
| `pbuild` | runs all of the above in one step |

### The compiler

{tktk fix me} The general form is:

```sh
build/tools/action [options] source.act [more.act ...]     # {tktk fix me}
```

| Option | Meaning |
|--------|---------|
| `-o FILE`, `--output FILE` | Write the assembly to `FILE`. Default: `build/<first-source-name>.asm`. The output directory is created if needed. |
| `-D NAME` | Define the constant `NAME` with the value 1. |
| `-D NAME=VALUE` | Define the constant `NAME` with an integer `VALUE` (decimal or `0x` hex). It overrides a `const` of the same name in the source. |
| `-I DIR`, `--include-dir DIR` | Add a directory to search for `import` (repeatable). |
| `-fbounds-check` | Enable run-time array bounds checks (the default). |
| `-fno-bounds-check` | Disable run-time bounds checks. |
| `-freference-check` | Enable run-time reference checks (the default). |
| `-fno-reference-check` | Disable run-time reference checks. |
| `-h`, `--help` | Show usage. |

The compiler stops at the first error, printing `action: error: …` and exiting with status 1. A command-line mistake exits with status 2.

Examples {tktk fix me}:

```sh
build/tools/action main.act                              # {tktk fix me}  -> build/main.asm
build/tools/action main.act -o out/firmware.asm          # {tktk fix me}
build/tools/action -D DEBUG -D BAUD=115200 main.act      # {tktk fix me}
build/tools/action -fno-bounds-check main.act            # {tktk fix me}
```

The usual file extension is `.act`.

### pbuild

`pbuild` compiles, lints, assembles and optionally simulates in one step {tktk fix me}:

```sh
./pbuild main.act -o build/main.bin --sim                # {tktk fix me}
./pbuild main.act drivers.act asmlib.asm -o build/fw.bin # {tktk fix me}
```

It accepts `.act` and `.asm` sources together, and passes `-D`, `-I`, the bounds-check flags and the reference-check flags through to the tools. `--sim` runs the binary in psim, `--debug` runs it under psim's debugger, and `--no-exit-on-reset` is passed to psim. If a tool it needs has not been built, pbuild says which `make` target builds it. If a tool fails, pbuild exits with that tool's status; after `--sim` it exits with psim's status (see [2.7](#27-running-in-the-simulator)).

## 2.2 Multi-file projects

There is no linker, so a program is built from **all of its source files at once**: `.act` files named on the command line or brought in with `import`, plus any `.asm` files given to `pbuild`. The Action files are compiled into a **single** assembly file.

- `import "file.act";` loads another module (see [3.2](#32-modules-and-imports)). Each file is loaded only once, so repeated or circular imports are harmless.
- All declarations are merged. Types, constants and functions from any file can be used in any other.
- A function may have **only one definition** across all files. Defining it twice is an error that names both files.
- **Prototypes** (`u32 f(u32 x);`) can appear anywhere. Every prototype must have a definition in some Action file, or the compiler reports it.
- **Routines written in assembly** are declared with `asm` in front of the prototype: `asm u32 checksum(u32 data[]);`. Calls to them become `RCALL _checksum`, and the `.asm` file given to `pbuild` must provide the label.
- **Assembly libraries** (`.asm` files given to `pbuild`) are assembled after the compiled program. The heap starts after everything assembled, so they are safe from it.

A typical layout:

```
project/
├── lib/
│   ├── common.inc      (assembler support, see 2.5)
│   ├── alloc.asm       (heap allocator, see 2.5)
│   ├── protokernel.act (task support)
│   ├── string.act      (string functions)
│   └── uart.act        (your shared Action module)
├── main.act
└── drivers.act
```

```c
// main.act
import "lib/uart.act";
```

## 2.3 Bounds and reference checking

With bounds checking on (the default), every array index is checked:

| Array kind | Checked against |
|------------|-----------------|
| Fixed array `T a[N]` | `N` for each dimension |
| Open array parameter `T a[]` | the length passed by the caller |
| Heap array or string | the length or capacity stored in the heap header |
| String write | capacity − 1, so the null terminator always fits |

An out-of-range index executes `TRAP 15`. On hardware, trap 15 goes to its vector, so a `trap(15)` handler can report the fault. In psim, a `TRAP 15` instruction ends the run with exit status 15.

`-fno-bounds-check` {tktk fix me} removes the checks, which makes the code smaller and faster.

### Reference checks

The compiler checks the references in a function's variables at compile time (see [3.10](#310-heap-allocation-and-ownership)). With reference checking on (the default), it adds run-time checks for what it cannot check there:

- Before a reference held in a global or a field is used (a field or element read or written, `.len`, `.capacity`, a method call, passing it to a function, destroying or resizing it), it is checked to be non-null.
- After `create()`, `createArray()`, `string.create()` and `resize()`, the allocator's result is checked, so running out of heap traps rather than giving a null reference.

A failed check executes `TRAP 15`, like a failed bounds check. `-fno-reference-check` {tktk fix me} removes these checks.

## 2.4 Understanding the output

The generated assembly is organized as follows:

1. A header comment, then `.include "lib/common.inc"`.
2. **If the program defines `main`:** the trap vector table at `.org 0x00000100`, one vector every 64 bytes:
   - vector 0, `_vector_reset`: sets the stack pointer to `0x00010000` and jumps to `_main`
   - vectors 1–15 (`_vector_mbox`, then `_vector_2` … `_vector_15`): each is `FAST_ENTER_TRAP`, then `RCALL` of the trap handler if one is declared, then `FAST_EXIT_TRAP`

   Every vector is emitted, so no trap can land in the middle of code. The program's code starts at `0x500`.
3. One block per function, with label `_name`. Methods use the label `_Type_method`.
4. **Global variable section**: one label `_name` per global, each a whole number of words.
5. **String literal table**: `.asciz` entries.
6. `.include "lib/alloc.asm"` for the heap runtime.

Inline functions and prototypes produce no code of their own. `const` and `enum` produce no data.

## 2.5 The runtime support files

The output refers to two files that you provide to the **assembler**:

- **`lib/common.inc`**: assembler macros and definitions that the generated code relies on (for example `FAST_ENTER_TRAP` / `FAST_EXIT_TRAP`, `LOAD32`, `RCALL`).
- **`lib/alloc.asm`**: the heap allocator. It provides:

| Routine | Input | Output |
|---------|-------|--------|
| `_rt_alloc`   | R1 = size in bytes | R1 = pointer to block |
| `_rt_free`    | R1 = pointer to block | — |
| `_rt_realloc` | R1 = pointer to block, R2 = new size in bytes | R1 = pointer to (possibly moved) block |

The heap starts at `__image_end`, a symbol that `pasm` defines as the first free byte after **everything** it assembled (rounded up to 4), and grows up toward the stack. Build with the Dart `pasm`, which defines it.

Heap arrays and strings store a 4-byte header (element count or capacity) **immediately before** the data that your program sees.

These Action modules are also in `lib/`:

- **`lib/protokernel.act`**: the task operations and status constants (see [3.11](#311-tasks)).
- **`lib/string.act`**: `string_copy(dst[], src)`, `string_concat(dst[], src)`, `string_compare(a, b)`, `string_equals(a, b)` and `string_find(s, ch)`.

## 2.6 Calling convention and inline assembly

You need this when you write `asm(...)` blocks or link to hand-written assembly.

| Register | Role |
|----------|------|
| R0 | always zero |
| R1–R4 | argument slots 1–4, in order. R1 holds the return value. R1–R4 hold tuple return values. |
| R13 | compiler scratch |
| R14 | link register (return address) and compiler scratch. The `LOAD16`/`LOAD24`/`LOAD32` and `RCALL` macros overwrite it. |
| R15 | stack pointer (grows downward) |

- Calls use `RCALL _name`, and returns use `RRET`. The callee pushes R14 on entry and restores it before returning.
- Indirect calls through function values use `JMP Rn, R14`.
- Scalars are passed by value. Instances of user-defined types are passed by **address**. An open array takes **two** slots: data address, then length. A method's receiver (`this`) takes the first slot.
- **Slots 1–4** go in R1–R4. **Slots 5 and up** go on the stack: before evaluating the arguments, the caller reserves 4 bytes per extra slot below its stack pointer, with slot 5 at the lowest address, and releases the area after the call. The callee finds slot 5 just above its saved return address.
- **No registers are preserved across calls.** Assume R1–R14 are clobbered.
- Labels: functions and globals are `_name`. Methods are `_Type_method`, so a free function named `Point_move` would collide with method `Point.move`.
- **Trap handlers** are called from their vector after `FAST_ENTER_TRAP` swaps R1–R14 with the shadow registers, so the interrupted code's registers are untouched.

Inline assembly is copied verbatim into the output, one instruction per line:

```c
asm("PUSH32  R1\nTRAP    7\nPOP32   R1");
```

## 2.7 Running in the simulator

psim runs a binary until it ends. Only two trap **instructions** end a run; every other trap, and every fault (such as a misaligned access), goes to its vector as on hardware.

| Exit status | Meaning |
|-------------|---------|
| 0 | a `TRAP 0` instruction (reset) ended the run |
| 1–14 | reserved |
| 15 | a `TRAP 15` instruction ended the run (for example a failed bounds check) |
| 16 | psim error: file not found, bad arguments |
| 17 | the cycle limit (10,000,000) was reached |
| 18 | the PC ran past the end of memory without a trap |

`--no-exit-on-reset` makes `TRAP 0` jump to the reset vector instead of ending the run. Under `--debug`, `TRAP 0` and `TRAP 15` stop at the debugger prompt.

Programs used as tests end with `trap(0)` on success and `trap(15)` on failure:

```c
void main() {
    u32 ok = 1;
    if (1 + 1 != 2) ok = 0;
    if (ok == 1) {
        trap(0);
    } else {
        trap(15);
    }
}
```

## 2.8 Error messages

Every message is printed as `action: error: …`. A message about the program starts with the `file:line:column` it refers to, such as `main.act:12:8:`. Common ones:

| Message (abridged) | Cause |
|--------------------|-------|
| `Unexpected character '…'` | A character that is not part of Action, such as `#` from a C preprocessor line. |
| `Unexpected token '…'` | A syntax error. |
| `pointer type '…*' is not supported; Action has no pointers` | `T*` was used. `*x`, `&x` and `->` give similar messages. |
| `undefined identifier '…'` | A name that is not a variable, constant or function in scope. |
| `String literal length (N) exceeds capacity (M)` | The initializer does not fit in the buffer. |
| `Compile-time verification failed: '…'` | A `verify` condition was false. |
| `Cannot assign array allocation to non-array variable '…'` | `createArray` was given to a plain variable. Declare it with `[]`. |
| `Cannot assign array allocation to fixed-size array '…'` | `createArray` was given to `T x[N]`. Declare it as `T x[]`. |
| `cannot assign to '…': it is a '…' stored on the stack` | Instances are never copied. Make the variable a reference. |
| `cannot assign '…', a '…' stored on the stack, to reference '…'` | A reference cannot point at an instance stored on the stack. The same applies to a reference field. |
| `cannot assign a '…' stored inside another type or an array to reference '…'` | A reference cannot point into another value. |
| `cannot destroy '…': it is a '…' stored on the stack` | Only references from `.create()` can be destroyed. |
| `'ref' needs a user-defined type` | `ref` was used with a scalar or `string`. For an array reference write `T name[]`. |
| `global '…' of type '…' cannot have an initializer unless it is a reference` | A global stored in place cannot be initialized. |
| `the constant N does not fit in bool` | A `bool` holds only 0 or 1. |
| `-D true=…: 'true' is built in and cannot be redefined` | `true` and `false` cannot be defined with `-D`. |
| `'…' is null here (it was set to 0, destroyed, or never given a value)` | A reference was used where it is certainly null. |
| `'…' may be null here; check it with '….exists()' first` | A reference was used where it is null on some path, or came from a global or from a function that can return null. |
| `'…' was moved to another variable or field and can no longer be used` | A reference was used after it was assigned to another variable or stored in a field (`may have been moved` if on some paths only). |
| `argument N of '…' is null` | `0` was passed for a parameter of a user-defined type. |
| `variable '…': the constant N does not fit in T` | An untyped constant does not fit the type it is used as. Assignments, arguments, return values, `case` labels and operands give the same message with their own description. |
| `constant '…': the value N does not fit in T` | A `const`'s value does not fit its declared type. |
| `constant expression overflows T` | An expression on typed constants gave a result outside its type. |
| `division by zero` | Division or remainder by a constant 0. |
| `cannot destroy borrowed reference parameter '…'` | A parameter was freed inside the function that borrowed it. |
| `Function signature mismatch: cannot assign …` | A function value does not match the function type. |
| `Maximum 4 scalar return values supported` | A tuple has more than four elements. |
| `Tuple return arity mismatch` | `return (…)` has the wrong number of values. |
| `The initializer of global variable '…' must be a constant expression` | A global was initialized from a non-constant. |
| `Global array '…' cannot have an initializer` | Global arrays always start zero-filled. |
| `Redefinition of function 'f' in …` | `f` is defined in two source files. |
| `Imported file '…' not found` | No search location contains the file. |
| `'struct' is deprecated; use 'type Name { ... }'` | Old syntax was used. |
| `Circular dependency or unknown type in struct/type definition` | Types contain each other by value, or a field's type is undefined. |
| `'break' outside of loop or switch block` | A `break` has no enclosing loop or `switch`. `continue` has the same rule. |
| `the channel must be a constant` | A FIFO channel was not a constant. |
| `'…' is a trap handler; it runs only when its trap is taken` | A trap handler was called or used as a function value. |
| `trap N is bound to both '…' and '…'` | Two handlers for the same trap. |
| `'…' returns from the task; use it as a statement` | `yield`, `wait_until` or `pk_exit` was used inside an expression. |
| `'…' can only be used in a task function` | `yield`, `wait_until` or `pk_exit` was used outside a `task`. |
| `task '…': '…' is read after a pause but was set before it` | A local's value was expected to survive a pause. Keep it in the task's state. |
| `task '…': the 'for' loop over '…' pauses` | A `for` loop's counter does not survive a pause. Use a `while` loop with the counter in the state. |
| `task '…' cannot return a value` | A task returns its status; `return;` ends it. |
| `'…' is declared but never defined` | A prototype has no definition. If the routine is written in assembly, declare it with `asm`. |
| `trap number N is out of range (0-15)` | `trap(N)` with a number outside 0–15. |
| `type alias '…' names unknown type '…'` | The alias's target is not a type. |

## 2.9 Editor support

`build/tools/action_lsp` is a language server for Action: an editor starts it and talks to it over the Language Server Protocol. It uses the compiler itself, so the editor shows the same errors the compiler would. `make tools` builds it (or `make action-lsp` on its own).

It provides:

- **Errors as you type:** the compiler's first error, shown after typing pauses, on open and on save. Unsaved changes are checked.
- **Hover:** the type of a variable, parameter or field; a function's signature; a constant's value; a type's layout, with each field's offset and size; and the `//` comment lines written just above a declaration.
- **Go to definition:** for local variables, parameters, globals, functions and methods, types, fields, constants and enum members, across imported files. On an `import` line, it opens the imported file.
- **Completion:** after `.`, the fields, methods and built-in members (`len`, `exists()`, …) of what is before it; elsewhere, the names in scope, keywords, types and built-in functions.
- **Outline:** the functions, methods, tasks, trap handlers, types, enums, globals and constants of the file.

While the text does not parse, hover, definition, completion and the outline use the last version that did.

### VS Code

`editors/vscode` holds the Particle extension. It adds syntax highlighting for `.act` files, starts the language server, and checks `action.json`. To build and install it (this needs Node.js and npm):

```sh
make tools
make vscode-ext
code --install-extension build/particle.vsix
```

The extension expects the server at `build/tools/action_lsp` in the workspace. The setting `particle.action.serverPath` changes that. After rebuilding the server, run **Particle: Restart Action Language Server** from the command palette.

### The project file: `action.json`

A file is checked the way the compiler would check it. By default, that means the file and everything it imports, with imports searched for in the file's own directory, the workspace root and `lib`. Since there is no linker, a program built from several files named on the command line needs to be described, along with any `-I` directories and `-D` values. That goes in `action.json` at the workspace root:

```json
{
  "action": {
    "includeDirs": ["lib", "apps/act"],
    "defines": { "DEBUG": 1, "BAUD": 115200 },
    "programs": [
      { "files": ["apps/act/multi_file_main.act", "apps/act/multi_file_math.act"] }
    ]
  }
}
```

| Key | Meaning |
|-----|---------|
| `includeDirs` | Directories searched by `import`, like `-I`. The workspace root and `lib` are always searched. |
| `defines` | Constants, like `-D NAME=VALUE`. |
| `programs` | Groups of files compiled together. A file in a group is checked with the rest of it; any other file is checked on its own. |

Paths are relative to `action.json`. A mistake in the file is shown as an error on it, and the defaults are used until it is fixed.

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
+= -= *= /= %= &= |= ^= <<= >>=
:  ;  ,  (  )  {  }  [  ]  @  .
```

`->` appears only in function types (`fn(u32) -> u32`). `*` and `&` are only multiplication and bitwise AND.

Any other character, including `#`, is an error.

## 3.2 Modules and imports

```c
import "lib/protokernel.act";
```

`import` loads another Action file and merges its declarations into the program. The trailing `;` is optional. The file is searched for in these places, in order:

1. the directory of the file that contains the `import`
2. the path exactly as written (relative to the current working directory)
3. each `-I` directory, in order
4. `lib/`
5. the current directory

Each file is loaded once, however many times it is imported, so circular imports are harmless. There is no preprocessor: no `#define`, `#include`, `#if` or predefined names such as `__LINE__`.

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
| `bool` | 1 | no | zero-extend | 0 or 1 (non-zero becomes 1) |

Expressions are evaluated at 32 bits. Constants take the type they are used with (see [3.13](#313-compile-time-evaluation)). `true` and `false` are the constants 1 and 0.

### `string`

A sequence of bytes ending in a null terminator. It is declared as a fixed buffer (`string s[N]`), as a heap string (`string.create(N)`), or as a parameter. `sizeof(string)` is 1 (one character).

### `void`

Used for functions that return nothing, and for an empty parameter list: `void f(void)`.

### References

There are no pointer types. A **reference** is a 4-byte address managed by the compiler:

- parameters of user-defined types, and variables of those types given a reference value (see [3.8](#38-user-defined-types))
- heap arrays and strings (`T x[] = T.createArray(n)`)
- open array parameters (`T a[]`)
- fields declared `ref T name` or `T name[]` (see [3.8](#38-user-defined-types))

### User-defined types

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

### Type aliases

```
type Name = Type;
```

`Name` becomes another name for `Type`. They are interchangeable: values of one can be used wherever the other is expected, and `sizeof`, signedness, methods and `create()` behave identically.

- `Type` can be a scalar, `string`, a user-defined type, a function type or another alias. Arrays cannot be aliased.
- Aliases can be declared in any order and in any module, like types.
- An alias whose target does not exist, an alias that refers back to itself, and a name that is already a type are errors.
- Defining a method through an alias (`void Pos.shift(...)` with `type Pos = Point;`) defines it on the aliased type.

## 3.4 Declarations

### Variables

```
Type name;
Type name = expression;
Type name[D1][D2]...;          // fixed array
Type name[] = Type.createArray(n);   // heap array (a reference)
Type name @ ADDRESS;           // bound to a fixed memory address
Type name[D] @ ADDRESS;        // bound array
```

- Array dimensions and `@` addresses are **constant expressions**: literals, `const` and `enum` names, `sizeof`, and operators over them.
- **Locals** are allocated in the function's stack frame and zero-filled each time the function is entered. Every local in a function shares one frame, even if it is declared inside a nested block. Do not reuse a name in the same function.
- **Globals** are emitted after the code. A global scalar may have a **constant-expression** initializer; anything else is an error. Global arrays cannot have an initializer and start zero-filled. A global of a user-defined type is stored in the data section, unless it is a reference.
- **Bound variables** (`@`) allocate no storage. Every access goes to the given address. Bound variables can be declared at the top level or inside functions.
- `volatile` is accepted before a top-level declaration and has no effect. Accesses to bound variables are never optimized away.

### Constants

```
const Type NAME = constant-expression;
```

The value is computed at compile time (see [3.13](#313-compile-time-evaluation)) and no storage is created. The value must fit `Type`, and the constant has that type. A constant can be used anywhere a literal can. A `-D NAME=VALUE` on the command line defines a constant, and overrides a `const` of the same name (taking its type).

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
| 1 | `=` `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | right |
| 2 | `\|\|` | left |
| 3 | `&&` | left |
| 4 | `==` `!=` `<` `<=` `>` `>=` | left |
| 5 | `&` `\|` `^` | left |
| 6 | `<<` `>>` | left |
| 7 | `+` `-` | left |
| 8 | `*` `/` `%` | left |
| 9 | unary `-` `~` `!` | right |
| 10 | postfix `()` `[]` `[a..b]` `.` | left |

**This differs from C:** bitwise `& | ^` bind **tighter** than comparisons, and all three share one level. `flags & MASK == 0` therefore means `(flags & MASK) == 0`, while `a | b & c` means `(a | b) & c`. Use parentheses when you mix them.

### Arithmetic and bitwise

`+ - * / %`, `& | ^ ~`, `<< >>`, and unary `-` (negation). Each binary arithmetic and bitwise operator has a compound assignment form, such as `%=`.

`/`, `%` and `>>` are **signed** (truncating division, remainder with the sign of the dividend, arithmetic shift) when either operand is signed: a variable, field or function result of type `s8`, `s16` or `s32`, or arithmetic involving one, such as `(a - b) / 2` with `s32 a`. Otherwise they are unsigned.

### Comparison

`== != < <= > >=` produce 0 or 1. The comparison is **signed** under the same rule as above, and unsigned otherwise. A constant operand takes the other operand's type (see [3.13](#313-compile-time-evaluation)), so `x < -1` is a signed comparison when `x` is signed, and an error when `x` is unsigned. A comparison of two constants is computed exactly: `-1 < 0` is true.

### Logical

- `!x` produces 1 if `x` is 0, and 0 otherwise.
- `a && b` and `a || b` produce 0 or 1 and **short-circuit**: the right side is evaluated only when it decides the result. `1 && 2` is 1.

### Assignment

`=` stores into a variable, field or array element, and yields the stored value. Chaining (`a = b = 0`) works. The right side is evaluated once. Compound operators load the target, apply the operation and store the result.

### Member access

`.` accesses a field or calls a method. The special members are:

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
- `sizeof(TypeName)` → the size of a user-defined type, including alignment padding (see [3.8](#38-user-defined-types))
- `sizeof(expression)` → the size of the expression's **element** type. For an array, this is the size of one element, not the whole array.

`sizeof` is a compile-time constant.

### Calls

`f(args)` calls a function, an inline function or a function-typed variable. A function's bare name (`f`) evaluates to its address and can be assigned to a variable of a matching function type. Arguments are evaluated left to right.

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
| Case label | `case CONST:` or `default:` (only inside a switch body) |
| Break | `break;` (exits the innermost loop or switch) |
| Continue | `continue;` (next iteration, or fall through to the next case) |
| Return | `return;`, `return expr;` or `return (e1, e2, …);` |
| Tuple assign | `(targets) = call;` |
| Assembly | `asm("text");` |
| Task operation | `yield(t);`, `wait_until(t, cond);`, `pk_exit(t);`, only in a task (see [3.11](#311-tasks)) |
| Assertion | `verify(const-expr, "msg");` |

**Conditions** are true when non-zero.

**Range `for`:** `var` is declared by the loop header and must have a type. It starts at `start` and the body runs while `var < end`, compared signed if `var` has a signed type. `end` is evaluated **once**, before the loop starts. After each pass, `var` increases by 1. The body may change `var`.

**Switch:** each `case` label is a constant expression. Control jumps to the matching label, or to `default:` if none matches, or past the switch if there is no `default`. Each case ends with an implicit `break`. A `continue` that is directly inside the switch (not inside a loop within it) jumps to the next case label in source order, or out of the switch from the last case. `break` leaves the switch.

**Continue in loops:** in a `while`, `continue` re-tests the condition. In a `for`, it steps the variable and re-tests.

**Tuple targets** can be `Type name` (declares a new variable), `name` (an existing variable) or `_` (discard). There can be up to four.

## 3.7 Functions

```
ReturnType name(params) { body }
ReturnType name(params);                       // prototype
asm ReturnType name(params);                   // routine written in assembly
(T1, T2, ...) name(params) { body }            // tuple return, up to 4
inline ReturnType name(params) { body }
ReturnType TypeName.method(params) { body }    // method, see 3.8
trap(N) name() { body }                        // trap handler, see 3.12
```

**Parameters:**

| Parameter form | Passed as | Slots |
|----------------|-----------|-------|
| `u32 x` (any scalar) | value | 1 |
| `Point p` (user-defined type) | address of the caller's instance | 1 |
| `T a[]` (open array) | data address + length | 2 |
| `BinOp f` (function type) | code address | 1 |
| `string s` | address | 1 |

Slots 1–4 travel in R1–R4 and later slots on the stack (see [2.6](#26-calling-convention-and-inline-assembly)), so there is no limit on the number of parameters. A method's `this` uses one slot, and each open array uses two.

**Return values:** a scalar, reference or function value is returned in R1. Tuples return in R1 to R4. In a tuple-returning function, every `return` must give the declared number of values. In a scalar function, `return (a, b)` is an error. The compiler does not check that a non-`void` function returns a value on every path.

**Inline functions** are expanded at each call site. They have no address and cannot be recursive. They may declare locals, which live in their own frame for the duration of the expansion.

**Prototypes:** every prototype must be matched by a definition in the Action sources, which may come later or in another file. A routine written in assembly is declared with `asm` in front of its prototype instead; it must not also be defined in Action. Its label is `_name`, and it follows the calling convention in [2.6](#26-calling-convention-and-inline-assembly).

**`main`** is special. It sets up the stack and runs, and when it returns the processor enters a halt loop. `main` may be declared `void` or `u32`.

**Function values:** a variable of function type `F` can be assigned a function whose parameter types and return type **exactly** match `F`, or a value of the same function type. Assigning a function to a non-function variable, or a non-function to a function variable, is a compile-time error. Calling `v(args)` on a function variable `v` makes an indirect call. Trap handlers cannot be used as function values.

## 3.8 User-defined types

```
type Name {
    Type field;
    Type field[D1][D2];
    Type field[];           // reference to a heap array
    ref OtherType field;    // reference to an OtherType
    OtherType field;        // nested by value
    OtherType;              // embedded (anonymous)
}
```

- Field semicolons are optional, and so is the `;` after the closing brace.
- **Layout:** fields are placed in declaration order, each at the next offset that is a multiple of its **alignment**: 1 for `u8`/`s8`/`bool`/`string`, 2 for `u16`/`s16`, 4 for `u32`/`s32` and references, and for a nested or embedded type, that type's alignment. A type aligns to its most-aligned field, and its size is padded to a multiple of that, so arrays of it stay aligned. Use `verify(sizeof(Name) == N, "...")` to pin a layout.
- Types may be declared in any order. Types that contain each other by value are an error.
- Embedding a scalar type (`u32;`) is not allowed.

**Reference fields:** `ref OtherType field;` and `Type field[];` each hold one pointer-sized reference. `OtherType` may be the type being declared, which is how linked structures are built. `ref` needs a user-defined type; for an array write `Type field[]`.

- A new value from `create()` has its reference fields null, since allocations are zeroed.
- Assigning a reference variable to the field moves it there (see [3.10](#310-heap-allocation-and-ownership)). Assigning `T.create()`, `T.createArray(n)`, `0` or another reference field also works. Assigning a value stored in place is an error.
- `obj.field.member`, `obj.field[i]`, `.len`, `.capacity`, method calls and passing the field to a function go through the reference. With reference checks on, each first checks it is not null; element access is also bounds-checked against the heap header.
- `obj.field.destroy()` or `obj.field.destroyArray()` frees the value and sets the field to 0. `obj.field.resize(n)` updates the field. `obj.field.exists()` tests it.
- Destroying `obj` does not free what its fields refer to.

**Embedding:** `OtherType;` inlines `OtherType`'s fields at that position, aligned as a nested field of that type would be. Its fields can then be accessed directly on the outer type. If the outer type declares a field with the same name, the outer field wins. Methods of the embedded type can be called on the outer type, and the receiver is adjusted to point at the embedded part. You can also refer to the embedded part as a whole by its type name: `sprite.Point`.

**Methods:** `ReturnType TypeName.method(params)` defines a function with an implicit first parameter `this` of type `TypeName`, passed by reference. Call it as `obj.method(args)`.

**Method references:** `TypeName.method` (on the type name, not on an instance) evaluates to the method's address. Its signature is `fn(TypeName, params...) -> ReturnType`. Writing `instance.method` without calling it is an error.

**Stored in place, or a reference:** a variable of a user-defined type is a **reference** if, anywhere in its function, it is given `T.create()`, `0` (null), another reference, or the result of a function that returns that type. Parameters of user-defined types are always references. Every other such variable is **stored in place**: on the stack for a local, in the data section for a global. Instances are never copied, so:

- assigning to a variable stored in place is an error
- assigning a variable stored in place, or a field or array element of a user-defined type, to a reference is an error
- destroying a variable stored in place is an error

The keyword `struct` is not accepted. Use `type`.

## 3.9 Arrays, strings and slices

**Fixed arrays:** `T a[N]`, or multi-dimensional `T a[N][M]` (row-major). `a[i][j]` addresses element `i*M + j`. `.len` gives `N`, and `.capacity` gives the last dimension.

**Open arrays:** `T a[]` as a parameter. It accepts:

| Argument | Length passed |
|----------|---------------|
| a fixed array | its first dimension |
| a heap array | its length, from the heap header |
| another open array | its length |
| a string variable | its current `.len` |
| a slice `x[s..e]` | `e − s` |
| a slice `x[s..]` | `x.len − s` |
| a slice `x[..e]` | `e` |
| a slice `x[..]` | `x.len` |

Slices are valid **only** as open-array arguments. Their bounds may be any expressions.

**Strings:**
- `string s[N] = "literal";` creates an N-byte buffer. The literal is copied in at run time and must not be longer than N. Keep it at most N−1 characters so the terminator fits inside the buffer.
- `.len` scans for the null terminator. `.capacity` is N.
- Indexing gives single bytes. Writes are bounds-checked against N−1.
- For a `string s[]` open-array parameter, `.capacity` is the length passed by the caller, and `.len` still scans for the terminator.
- A string literal used in an expression evaluates to the address of a read-only copy in the string table. You can pass it to a `string s` parameter. Passed to a `string s[]` parameter, its `.len` works but its `.capacity` is 0, so do not write to it.

## 3.10 Heap allocation and ownership

### Operations

| Expression | Effect |
|------------|--------|
| `T.createArray(n)` | Allocates an array of `n` zeroed elements of type `T` (any scalar or user-defined type). Assign it to `T name[]`. |
| `string.create(cap)` | Allocates a string buffer of capacity `cap`, initially empty. |
| `T.create()` | Allocates one `T`, zeroed, and returns a reference to it. |
| `h.resize(n)` | Resizes heap array `h` to `n` elements and updates `h`. |
| `h.destroyArray()` / `h.destroy()` | Frees `h` and sets the variable to 0. |
| `h.exists()` | 1 if `h` is non-zero, else 0. |

Declare the variable to match:

```c
type Point { s32 x; s32 y; }

void main() {
    u32 buf[] = u32.createArray(64);
    Point pts[] = Point.createArray(8);
    string s = string.create(128);        // 'string s[] = ...' also works
    Point p = Point.create();
    p.destroy();
    s.destroy();
    pts.destroyArray();
    buf.destroyArray();
}
```

Heap arrays and strings carry a 4-byte header that holds the length (arrays) or capacity (strings). `.len`, `.capacity` and bounds checks read this header.

### Ownership rules

These rules are checked at compile time, along every path through each function, for the references held in its variables and parameters:

1. A variable that receives a heap allocation **owns** it. `create()`, `createArray()` and `string.create()` give a valid reference.
2. `b = a`, `T b = a;` and `obj.field = a`, where `a` is a reference variable, **move** the reference to `b` or the field. After that, `a` cannot be used at all, not even tested, until it is given a new value.
3. `x = 0`, `x.destroy()` and `x.destroyArray()` make `x` null. A local reference declared without a value is null.
4. A reference must be **definitely valid** to be used: reading or writing a field or element, `.len`, `.capacity`, calling a method on it, passing it to a function, destroying or resizing it. On every path to the use, it must have been allocated, received from a function that always returns a valid reference, or tested with `exists()`.
5. Assigning, returning, comparing (`==`, `!=`) and testing (`exists()`) a reference only require that it has not been moved.
6. Where paths meet (after an `if`, at the top of a loop), a reference that is valid on one path and null or moved on another **may be** null or moved, and must be tested before it is used.
7. A function returns a valid reference when every `return` in it gives a definitely valid one, even when it calls itself. Otherwise a call's result may be null.
8. Parameters are valid on entry and **borrowed**: they cannot be destroyed, and cannot be moved into a variable that owns a reference. Passing `0` for a parameter of a user-defined type is an error.
9. References in globals and fields are not followed. A variable given one may be null. With reference checks on, using a null reference held in a global or a field traps (see [2.3](#23-bounds-and-reference-checking)). Reading a field into a variable copies the reference; using one copy after the value was destroyed through the other is not caught.

Nothing frees memory automatically.

## 3.11 Tasks

```
task name(State t, other parameters...) { body }

yield(t);
wait_until(t, condition);
pk_exit(t);
```

A task is a function that can pause and resume. `lib/protokernel.act` declares the three operations as prototypes, together with the status constants `PK_WAITING` (0), `PK_YIELDED` (1), `PK_EXITED` (2) and `PK_ENDED` (3), the state type `pt` (`u16 lc;`) and the inline initializer `pk_init(p)`.

**Declaring a task:**
- The first parameter is the task's **state**: an instance of a type whose **first field is `u16`**. The resume point is kept there. More parameters are allowed; they are passed afresh on every call.
- A task returns a `u16` status and has no declared return type. `return;` ends the task; `return value;` is an error.
- A task can be called like a function and used as a function value of type `fn(State, ...) -> u16`.
- A task must have a body, and cannot be `inline`.

**Operations:**
- They are allowed only inside a task, and their first argument must be the task's state parameter.
- They are statements, because they return from the task. Using one inside an expression is an error.
- The compiler numbers the resume points itself.

**Behavior:**
- On entry, the task reads its resume point. At the start (0) it runs from the top; otherwise it continues where it paused.
- `yield(t)` returns `PK_YIELDED`. The next call resumes just after it.
- `wait_until(t, cond)` evaluates `cond`. If it is true, execution continues. If it is false, the task returns `PK_WAITING`, and the next call evaluates `cond` again.
- `pk_exit(t)` resets the resume point and returns `PK_EXITED`. The next call starts from the top.
- Running off the end, or `return;`, resets the resume point and returns `PK_ENDED`.

**Locals:**
- Locals do not survive a pause. Reading a local after a pause, when it was set before the pause and not set again since, is an error. Keep such values in the state.
- A `for` loop whose body pauses is an error, because its counter is a local. Use a `while` loop with the counter in the state.
- Parameters other than the state are passed on every call, so they can be read after a pause.

## 3.12 Hardware intrinsics and traps

| Call | Generates | Notes |
|------|-----------|-------|
| `trap(N)` | `TRAP N` | `N` is a constant from 0 to 15; anything else is an error. Evaluates to 0. |
| `readfifo(CH)` | `FIFO.R` | Blocking read from channel `CH`. Returns the word read. |
| `writefifo(CH, value)` | `FIFO.W` | Writes `value` to channel `CH`. |
| `tryreadfifo(CH, x)` | `FIFO.TRYR` | Non-blocking read into the variable, field or element `x`. Returns 1 and stores the word if data was waiting; otherwise returns 0 and leaves `x` unchanged. |
| `asm("text")` | verbatim | Each line of `text` becomes one assembly line. |

`CH` must be a constant.

### Trap handlers

```
trap(N) name() { body }
```

declares the function that runs when trap `N` is taken, whether by a `TRAP N` instruction, by hardware or by another core.

- `N` is a constant from 1 to 15. Binding trap 0 (reset) is not supported yet, since vector 0 runs the startup code.
- A handler has no return value and takes no arguments. The empty `()` is required, and so is a body.
- A handler runs only as a trap. Calling it or using it as a function value is an error.
- At most one handler per trap.

The vectors are defined by the Particle specification:

| Vector | Address | Use |
|--------|---------|-----|
| 0 | `0x100` | reset (the startup code) |
| 1 | `0x140` | inbound mailbox / inter-core notification |
| 2–13 | `0x180`–`0x47F` | software and user-defined traps |
| 14 | `0x480` | misaligned memory access |
| 15 | `0x4C0` | undefined / illegal opcode |

A vector with no handler simply returns. For a fault such as a misaligned access, that returns to the faulting instruction, which faults again.

## 3.13 Compile-time evaluation

Constant expressions are used by `const`, `verify`, `enum` values, array dimensions, `@` addresses, `case` labels, trap numbers, FIFO channels and global initializers. Any other expression made only of constants is also computed at compile time. They may contain:

- integer literals and character literals
- names of `const` values and `enum` members, in any order (a cycle is an error)
- constants defined with `-D`
- `sizeof(...)`
- unary `- ~ !`
- binary `+ - * / % & | ^ << >> == != < <= > >= && ||` (`&&` and `||` are logical operators)

Constant expressions are computed **exactly**, with no limit on size: `-1 < 0` is true, and `(1 << 40) >> 20` is `0x100000`. Division truncates toward zero, and the remainder has the sign of the dividend. Division or remainder by zero is an error, and so is a negative shift count.

**Types of constants:**
- Literals, character literals, `true`, `false`, `enum` members, `sizeof`, constants from `-D`, and expressions made only of those are **untyped**. Comparisons, `!`, `&&` and `||` give an untyped 0 or 1.
- A `const` has its declared type, and its value must fit it. An expression involving a typed constant has that type, and its result must fit: with `const u8 A = 200;`, `A + A` is an error. `~` on an unsigned typed constant flips the bits of its width: with `const u16 M = 0xFFFF;`, `~M` is 0. Two typed constants of different types combine like variables: `s32` if either is signed, otherwise `u32`.
- An untyped constant takes the type it is used as, and must fit it: the variable it initializes or is assigned to (also with `+=` and the like), the parameter it is passed as, the function's return type, the `switch` value's type for a `case` label, or the type of the other operand of a binary operator. The result of an operator on variables is a 32-bit value: `s32` if it is signed under the rule in [3.5](#35-expressions-and-operators), otherwise `u32`. A shift count only has to be non-negative.
- Anywhere else, an untyped value must fit in 32 bits (−2³¹ to 2³²−1).
- A typed constant used where another type is expected behaves like a variable of its type, and is not checked.

| Integer type | Range |
|--------------|-------|
| `bool` | 0 to 1 |
| `u8` | 0 to 255 |
| `s8` | −128 to 127 |
| `u16` | 0 to 65535 |
| `s16` | −32768 to 32767 |
| `u32` | 0 to 4294967295 |
| `s32` | −2147483648 to 2147483647 |

## 3.14 Keywords

**In use:** `asm` `bool` `break` `case` `const` `continue` `default` `else` `enum` `false` `fn` `for` `if` `import` `inline` `ref` `return` `s8` `s16` `s32` `sizeof` `string` `switch` `true` `type` `u8` `u16` `u32` `verify` `void` `volatile` `while`

**Built-in names** (identifiers with special meaning): `this`, `trap`, `readfifo`, `writefifo`, `tryreadfifo`, and the methods `create`, `createArray`, `destroy`, `destroyArray`, `resize`, `exists`, `len`, `capacity`. `task` starts a task declaration when it is followed by a name and `(`. `yield`, `wait_until` and `pk_exit` are task operations when `lib/protokernel.act` is imported.

## 3.15 Known limitations and pitfalls

These come from the current compiler's behavior. Code around them until they change.

| Issue | What happens | Workaround |
|-------|-------------|------------|
| Locals are function-scoped | Same name in two blocks shares storage | Use distinct names. |
| Trap 0 cannot be bound | Compile error | Not decided yet. |
