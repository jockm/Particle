# The Action Programming Language

**Tutorial · User Guide · Reference**

Action is a small systems language. It is built for work close to the hardware: memory-mapped I/O, hardware FIFOs, trap handlers, inline assembly and cooperative multitasking. It also provides bounds-checked arrays, methods attached to types, multiple return values, type aliases, compile-time assertions and ownership-checked heap allocation. Action has **no pointers**: instances of user-defined types and arrays are passed by reference automatically.

There are two compilers. `action` generates assembly for the **Particle** processor, and `action_llvm` generates LLVM IR, which `clang` turns into a program for your computer (see [2.10](#210-building-for-your-computer-llvm)). Unless a section says otherwise, the parts of this guide about generated code, the runtime and the tools describe the Particle target.

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
  - [2.10 Building for your computer (LLVM)](#210-building-for-your-computer-llvm)
  - [2.11 Code for both targets](#211-code-for-both-targets)
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

Numbers are written in decimal, hexadecimal (`0xFF`) or binary (`0b1010`), with `_` allowed between digits: `1_000_000`, `0b1010_0101`. A value is converted to another type with **`T(x)`**: `u8(x)` keeps the low byte, `s32(x)` reads the same bits as signed, and `bool(x)` is 1 when `x` is non-zero. A constant must fit the type it is converted to, so `u8(300)` is an error.

With the LLVM compiler there are also 64-bit integers (`u64`, `s64`) and floating point (`f32`, `f64`); see [2.10](#210-building-for-your-computer-llvm).

All arithmetic is done in 32-bit registers. Narrow values are zero-extended (unsigned) or sign-extended (signed) when loaded, and truncated when stored. Division, remainder, right shift and comparisons are **signed** when an operand has a signed type (see [3.5](#35-expressions-and-operators)).

A local variable declared without a value starts at **zero**. Locals are **block-scoped**, as in Go: a variable can be used from its declaration to the end of the `{ }` block that declares it, and a variable in an inner block may reuse a name from outside, which it hides until the block ends:

```c
void main() {
    u32 x = 1;
    if (x == 1) {
        u8 x = 200;         // a different x, only in this block
        x += 1;
    }
    // x is 1 here
    for (u32 i : 0..3) {
        u32 t;              // zero on every pass of the loop
        t += i;
    }
    // neither i nor t can be used here
}
```

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

    BinOp table[2] = {add, mul};
    r = table[1](6, 7);     // through an element of an array
}
```

A **lambda** is a function written where a function value is needed. It looks like a function type, with parameter names and a body:

```c
void main() {
    const u32 LIMIT = 10;
    BinOp sub = fn(u32 a, u32 b) -> u32 { return a - b; };
    u32 r = apply(fn(u32 a, u32 b) -> u32 { return a * b + LIMIT; }, 6, 7);

    BinOp power = fn pow(u32 b, u32 e) -> u32 {   // a name lets it call itself
        if (e == 0) return 1;
        return b * pow(b, e - 1);
    };
}
```

A lambda uses its parameters, its own locals, the globals, and the constants of the function it is written in, but not that function's variables: pass them as parameters.

A function whose result type is not `void` must end with a `return` on every path; running off the end is a compile error. A call gives exactly as many arguments as the function has parameters, and the call of a `void` function has no value to use.

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

An array can be given its values in braces. Elements not given are zero, and an array of more dimensions takes a brace list per row:

```c
u8 grid[2][3] = {{1, 2, 3}, {4}};       // grid[1][1] and grid[1][2] are 0
const u16 SQUARES[4] = {0, 1, 4, 9};    // a constant table: it cannot be changed
string names[3][8] = {"ann", "bob"};    // names[2] is empty
```

Arrays are not assigned or compared as a whole: copy and compare their elements.

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

An open array parameter can have more dimensions, `T m[][]`: each length travels with it, and `m.len` and `m[0].len` give them. A row, `m[i]`, can be passed on to a `T row[]` parameter.

```c
u32 total(u32 m[][]) {
    u32 t = 0;
    for (u32 i : 0..m.len) {
        for (u32 j : 0..m[i].len) {
            t += m[i][j];
        }
    }
    return t;
}
```

A function can also hand a heap array (or heap string) it made to its caller: its result type is written `T[]`, as in `u32[] range(u32 n)`.

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

Strings are not compared with `==`: `lib/string.act` provides `stringCopy`, `stringConcat`, `stringCompare`, `stringEquals` and `stringFind`. Bring it in with `import "lib/string.act";`. Each can also be called as a method of its first string: `s.find('c')` calls `stringFind(s, 'c')`, and in general `s.name(...)` calls `stringName(s, ...)`.

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
- `Point r = Point.create();` is a **reference** to a `Point` on the heap (see [1.10](#110-heap-memory-and-ownership)). So is a variable declared `ref Point r;` (which starts empty), or one given another reference or the result of a function that returns a `Point`.

Instances are **never copied** by assignment. Assigning to a variable stored in place is a compile error, and so is making a reference point at an instance stored on the stack. To copy one value's fields into another, use `copyFrom`:

```c
Point a = {x: 3, y: -4};          // stored in place, with its fields given by name
Point b = Point.create(x: 1);     // on the heap; y is 0
a.copyFrom(b);                    // a.x is 1, a.y is 0
b.destroy();
```

Fields not named in `{...}` or `create(...)` are zero. A type that holds references (in a `ref` field, an array of references or a heap array field) cannot be copied, since the copy would be a second owner of what they refer to.

A field can hold a reference too. `ref T name;` refers to a `T` stored elsewhere, and `T name[];` refers to a heap array (see [1.10](#110-heap-memory-and-ownership)). Without `ref`, a field of a user-defined type is stored in place, inside the outer value:

```c
type Node {
    u32 value;
    ref Node next;      // a reference: a type can refer to itself this way
    u8 payload[];       // a reference to a heap array
}
```

A field can also hold a **function value** (see [1.4](#14-functions)), which is called through the field:

```c
type Handler = fn(u32) -> u32;
type Device {
    u32 port;
    Handler onRead;     // called as dev.onRead(x)
}
```

A type cannot have a field and a method of the same name.

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
    u32 word = readFifo(1);       // blocking read from channel 1
    writeFifo(0, word + 1);       // write to channel 0

    u32 got = 0;
    u32 ok = tryReadFifo(2, got); // non-blocking: if data is waiting, got = data and ok = 1
}
```

**Memory at an address computed at run time** (in a monitor or a loader, say) is reached with built-in functions. An `@` address must be a constant; these take any value:

```c
void dump_word(u32 addr) {
    u32 w = peek32(addr);         // read the word at addr
    poke32(addr, w + 1);          // write a word
    poke16(0xF0000010, 217);      // write a halfword
    u8 b = peek8(addr + 1);       // read a byte (peek16 reads a halfword)
    poke8(addr + 3, b);           // write a byte
}

void run(u32 entry) {
    callAddr(entry);             // call the code at entry
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
    u32 alive = samples.exists();         // 0: the reference is now empty
    line.destroy();
    p.destroy();
}
```

A heap array is always declared with `[]` (`u32 samples[]`). Giving `createArray` to a plain `u32` or to a fixed-size array is a compile error.

A reference is never 0: Action has no null. A reference that has no value yet is **empty**. Declare one with `ref` (or, for a heap array or string, just leave out its value), test it with `.exists()`, and empty it again with `.unset()`:

```c
ref Point current;              // an empty reference to a Point
u32 buf[];                      // an empty heap array

void track(Point p) {
    if (!current.exists()) {
        current = Point.create(x: p.x, y: p.y);   // give fields their values by name
    }
}
```

Two references are compared with `a.sameAs(b)`, which tells whether they refer to the same value. `==` and `!=` on references are errors, and so is comparing one with `0`.

A heap reference has exactly one owner. Assigning it to another variable **moves** it:

```c
void main() {
    u32 a[] = u32.createArray(4);
    u32 b[] = a;        // ownership moves to b
    u32 n = a.len;      // compile error: 'a' was moved to another variable and can no longer be used
}
```

The compiler follows each reference held in a function's variables along **every path** through the function, through branches and loops, and knows at each point whether it is valid, empty (emptied with `unset()`, destroyed, or never given a value) or moved. Using a reference that is not **definitely valid** is an error:

```c
type Item { u32 id; }

Item find(u32 id) {
    if (id == 0) {
        ref Item none;
        return none;            // so a call to find may give an empty reference
    }
    Item it = Item.create();
    it.id = id;
    return it;
}

void main() {
    Item a = find(7);
    a.id = 1;                   // compile error: 'a' may be empty here; check it with 'a.exists()' first
    if (a.exists()) {
        a.id = 1;               // fine: a is valid here
        a.destroy();
    }
    a.id = 2;                   // compile error: 'a' is empty here
}
```

- `create()` and `createArray()` always give a valid reference. If the heap is exhausted, the program traps instead (see [2.3](#23-bounds-and-reference-checking)).
- A function whose every `return` gives a valid reference returns a valid reference. Otherwise its result may be empty and has to be checked.
- `x.exists()` makes `x` valid where the test is true and empty where it is false. `!x.exists()`, `x.exists() != 0` and `x.exists() == 1` work too, and so do `&&` and `||`: `if (a.exists() && a.id == 7)` is fine.
- `x.unset()` empties `x`. It is an error while `x` certainly still owns its value: destroy it, or move it somewhere else, first.
- A reference held in a global or a field cannot be followed this way, so a variable given one may be empty. Using an empty reference held in a global or a field traps at run time (see [2.3](#23-bounds-and-reference-checking)).
- Memory from `create()`, `createArray()` and `string.create()` is zeroed, so the reference fields of a new value start out empty.

Storing a reference in a field **moves** it into the field, which then owns it:

```c
void main() {
    Node head = Node.create();
    Node second = Node.create();
    head.next = second;         // head.next now owns it
    second.value = 2;           // compile error: 'second' was moved to another variable or field
    head.next.value = 2;        // fine (checked at run time)
    head.next.destroy();        // frees it and leaves head.next empty
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

A **task** is a function that can pause and later resume where it left off, so several tasks can share one core without threads: a loop calls each in turn, and each runs until it pauses. Tasks are declared with `task`. They pause with `yield` or `waitUntil`, or start over with `pkExit`. These operations come from `lib/protokernel.act`, which you import.

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
        waitUntil(t, readFifo(0) == 1);   // pause until a condition holds
        t.toggles += 1;
        if (t.toggles == 100) {
            pkExit(t);                    // stop; the next call starts from the top
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
| 0 | `PK_WAITING` | a `waitUntil` condition was false |
| 1 | `PK_YIELDED` | the task reached a `yield` |
| 2 | `PK_EXITED`  | the task called `pkExit` |
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
- **Every function called must be declared** somewhere in the program: defined in an Action file, or promised by a prototype. Calling a name that nothing declares is an error. A file of `asm` prototypes, imported where needed, is a convenient way to list the routines an assembly library provides.
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

**In this repository**, a program made of several files lives in a folder of its own under `apps/act/multi/`. `make apps` builds every `.act` and `.asm` file in the folder together into `build/<folder>.bin`, and a folder whose name starts with `test_` is also run by `make compiler-tests`:

```
apps/act/multi/
├── test_multi_file/        → build/test_multi_file.bin
│   ├── multi_file_main.act
│   └── multi_file_math.act
└── test_heap_after_asm/    → build/test_heap_after_asm.bin
    ├── heap_after_asm_main.act
    └── heap_after_asm_lib.asm
```

To add one, make a folder and put the files in it; there is no list to update.

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

- Before a reference held in a global or a field is used (a field or element read or written, `.len`, `.capacity`, a method call, passing it to a function, destroying or resizing it), it is checked to have a value.
- After `create()`, `createArray()`, `string.create()` and `resize()`, the allocator's result is checked, so running out of heap traps rather than giving an empty reference.

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
- **`lib/string.act`**: `stringCopy(dst[], src)`, `stringConcat(dst[], src)`, `stringCompare(a, b)`, `stringEquals(a, b)` and `stringFind(s, ch)`.

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

Every error is printed as `action: error: …`. A message about the program starts with the `file:line:column` it refers to, such as `main.act:12:8:`. The compiler can also print warnings and information, as `action: warning: …` and `action: info: …`; they do not stop compilation or change the exit status, and `pbuild` shows them. (None are reported yet; the mechanism is in place for when they are.) Common errors:

| Message (abridged) | Cause |
|--------------------|-------|
| `Unexpected character '…'` | A character that is not part of Action, such as `#` from a C preprocessor line. |
| `Unexpected token '…'` | A syntax error. |
| `pointer type '…*' is not supported; Action has no pointers` | `T*` was used. `*x`, `&x` and `->` give similar messages. |
| `undefined identifier '…'` | A name that is not a variable, constant or function in scope. When a local of that name exists elsewhere in the function, the message adds where it is declared and that it is not in scope there. |
| `no source files are built for …` | Every file named has a build directive that leaves it out for this compiler (see [2.11](#211-code-for-both-targets)). |
| `//act:build …` | A build directive that is misplaced, repeated, malformed, names something unknown or can never be true. |
| `variable '…' is already declared in this block` | Two declarations of one name in the same block. An inner block may reuse the name. |
| `variable '…' has the name of a parameter of '…'` | A local in a function's outermost block has a parameter's name. |
| `String literal length (N) exceeds capacity (M)` | The initializer does not fit in the buffer. |
| `Compile-time verification failed: '…'` | A `verify` condition was false. |
| `Cannot assign array allocation to non-array variable '…'` | `createArray` was given to a plain variable. Declare it with `[]`. |
| `Cannot assign array allocation to fixed-size array '…'` | `createArray` was given to `T x[N]`. Declare it as `T x[]`. |
| `cannot assign to '…': it is a '…' stored on the stack` | Instances are never copied. Make the variable a reference. |
| `cannot assign '…', a '…' stored on the stack, to reference '…'` | A reference cannot point at an instance stored on the stack. The same applies to a reference field. |
| `cannot assign a '…' stored inside another type or an array to reference '…'` | A reference cannot point into another value. |
| `cannot destroy '…': it is a '…' stored on the stack` | Only references from `.create()` can be destroyed. |
| `'ref' needs a user-defined type` | `ref` was used with a scalar or `string`. For an array reference write `T name[]`. |
| `global '…' of type '…' is given its values as {field: value, ...}, or is a reference` | A global stored in place was given something other than a brace initializer. |
| `the constant N does not fit in bool` | A `bool` holds only 0 or 1. |
| `-D true=…: 'true' is built in and cannot be redefined` | `true` and `false` cannot be defined with `-D`. |
| `'…' is empty here (it was emptied with unset(), destroyed, or never given a value)` | A reference was used where it certainly has no value. |
| `'…' may be empty here; check it with '….exists()' first` | A reference was used where it is empty on some path, or came from a global or from a function that can return an empty one. |
| `'…' still owns its value; destroy it, or move it …, before unset()` | `unset()` would lose the only reference to a value. |
| `'…': a reference cannot be 0; declare one that starts empty as 'ref T …;'` | There is no null; `ref T name;` declares an empty reference, and `T name[];` an empty heap array. `… is a reference, so it cannot be given 0; empty it with ….unset()` is the same for an assignment, and `the result of '…' is a reference, so it cannot be 0` for a `return`. |
| `references are compared with a.sameAs(b), not '=='` | `==` or `!=` on two references. `a reference is not compared with 0; use r.exists()` for a comparison with 0. |
| `strings cannot be compared with '=='; use stringEquals(a, b) or stringCompare(a, b)` | Strings are compared with the functions of `lib/string.act`. |
| `arrays cannot be compared with '=='` / `values of user-defined types cannot be compared` | Compare the elements or fields. |
| `arrays cannot be assigned; '…' is an array, so copy its elements` | A fixed array was assigned to. |
| `'…' takes N arguments, not M` | A call with the wrong number of arguments. |
| `'…' returns nothing, so its call has no value to use` | The call of a `void` function was used as a value. |
| `missing return at the end of '…'` | A function that returns a value can run off the end of its body (see [3.6](#36-statements)). |
| `T(...): the constant N does not fit in T` | A constant conversion that loses its value, such as `u8(300)`. |
| `invalid number '…'` | A malformed number, such as `0b102` or `1__0`. |
| `a slice of a string is an array of u8 characters with no terminator, not a string` | A slice was used as a string. |
| `'…' is a constant; its values cannot be changed` | A write to a constant table or string constant. |
| `constant '…' cannot be passed to '…': it changes its parameter '…'` | A value that must not change (also a string literal or the command line) passed to a parameter the function writes through. |
| `'…' has N elements, but M values are given` | A brace initializer with too many values. |
| `a '…' holds references, so it cannot be copied` | `copyFrom` on a type with references. |
| `type '…' has both a field and a method named '…'` | `t.f(x)` would be ambiguous. |
| `lambda … cannot use '…', a variable of the function it is written in` | Lambdas capture nothing: pass the value as a parameter. |
| `a lambda is a value; give it to a variable, field or parameter` | A lambda was written as a statement on its own. |
| `an array of N dimensions is expected here; '…' has M` | An argument for an open array parameter of more dimensions. |
| `an f32 value and a u32 value do not mix` / `f32 and f64 values do not mix` | Mixed floating-point and integer (or f32 and f64) operands; convert one (LLVM). |
| `'…' was moved to another variable or field and can no longer be used` | A reference was used after it was assigned to another variable or stored in a field (`may have been moved` if on some paths only). |
| `argument N of '…' is 0` | `0` was passed for a parameter of a user-defined type. |
| `variable '…': the constant N does not fit in T` | An untyped constant does not fit the type it is used as. Assignments, arguments, return values, `case` labels and operands give the same message with their own description. |
| `constant '…': the value N does not fit in T` | A `const`'s value does not fit its declared type. |
| `constant expression overflows T` | An expression on typed constants gave a result outside its type. |
| `division by zero` | Division or remainder by a constant 0. |
| `cannot destroy borrowed reference parameter '…'` | A parameter was freed inside the function that borrowed it. |
| `Function signature mismatch: cannot assign …` | A function value does not match the function type. |
| `Maximum 4 scalar return values supported` | A tuple has more than four elements. |
| `Tuple return arity mismatch` | `return (…)` has the wrong number of values. |
| `The initializer of global variable '…' must be a constant expression` | A global was initialized from a non-constant. |
| `global array '…' is given its values in braces` | A global array was given something other than a brace initializer (or, for a string, a string literal). |
| `Redefinition of function 'f' in …` | `f` is defined in two source files. |
| `Imported file '…' not found` | No search location contains the file. |
| `'struct' is deprecated; use 'type Name { ... }'` | Old syntax was used. |
| `Circular dependency or unknown type in struct/type definition` | Types contain each other by value, or a field's type is undefined. |
| `'break' outside of loop or switch block` | A `break` has no enclosing loop or `switch`. `continue` has the same rule. |
| `the channel must be a constant` | A FIFO channel was not a constant. |
| `'…' is a trap handler; it runs only when its trap is taken` | A trap handler was called or used as a function value. |
| `trap N is bound to both '…' and '…'` | Two handlers for the same trap. |
| `'…' returns from the task; use it as a statement` | `yield`, `waitUntil` or `pkExit` was used inside an expression. |
| `'…' can only be used in a task function` | `yield`, `waitUntil` or `pkExit` was used outside a `task`. |
| `task '…': '…' is read after a pause but was set before it` | A local's value was expected to survive a pause. Keep it in the task's state. |
| `task '…': the 'for' loop over '…' pauses` | A `for` loop's counter does not survive a pause. Use a `while` loop with the counter in the state. |
| `task '…' cannot return a value` | A task returns its status; `return;` ends it. |
| `'…' is not declared; import the file that defines it, or declare it with a prototype` | A call to a function that no Action file in the program defines and no prototype declares. |
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

When a file is checked on its own, outside any program listed in `action.json`, the editor cannot see the other files it may be compiled with. The errors "is not declared" and "is declared but never defined" are then shown as information instead, since the definition may be in one of those files. In a listed program they are errors, as in the compiler. Warnings and information from the compiler are shown with those severities.

### VS Code

The Action extension, in `apps/tools/vscode/action`, adds syntax highlighting for `.act` files, starts the language server, and checks `action.json`. The Particle extension beside it does the same for Particle assembly. To build the language servers and both extensions and install them (this needs Node.js 20 or later and npm):

```sh
make vscode-install
```

Then reload any open VS Code windows. If VS Code's `code` command is not available, `make vscode-install` says so; either add it from VS Code (command palette: **Shell Command: Install 'code' command in PATH**), or install `build/action.vsix` with **Install from VSIX…** in the Extensions view. `make vscode-ext` only builds the `.vsix` files.

The extension looks for the server in the setting `action.serverPath`, then at `build/tools/action_lsp` in the workspace, then as `action_lsp` on your `PATH`. After rebuilding the server, run **Action: Restart Language Server** from the command palette.

### The project file: `action.json`

A file is checked the way the compiler would check it. By default, that means the file and everything it imports, with imports searched for in the file's own directory, the workspace root and `lib`. Since there is no linker, a program built from several files named on the command line needs to be described, along with any `-I` directories and `-D` values. That goes in `action.json` at the workspace root:

```json
{
  "action": {
    "includeDirs": ["lib", "apps/act"],
    "defines": { "DEBUG": 1, "BAUD": 115200 },
    "target": ["particle", "llvm"],
    "programFolders": ["apps/act/multi"],
    "programs": [
      { "files": ["tools/gen_main.act", "tools/gen_tables.act"] }
    ]
  }
}
```

| Key | Meaning |
|-----|---------|
| `includeDirs` | Directories searched by `import`, like `-I`. The workspace root and `lib` are always searched. |
| `defines` | Constants, like `-D NAME=VALUE`. |
| `programFolders` | Folders whose subfolders are each one program: all the `.act` files in the subfolder, checked together. Adding a folder or a file needs no change to `action.json`. This repository's `action.json` names `apps/act/multi` (see [2.2](#22-multi-file-projects)). |
| `programs` | Other groups of files compiled together, listed file by file. |
| `target` | The compiler programs are checked for: `"particle"` (the default), `"llvm"` (see [2.10](#210-building-for-your-computer-llvm)), or both as a list. With both, an error found for only one of them is shown as a warning that names it, such as `for llvm: 'readFifo': FIFOs are Particle hardware…`. A file with a build directive, such as `//act:build llvm`, is checked for the targets it is built for (see [2.11](#211-code-for-both-targets)). The editor also warns when a file's name says it is for a target or operating system (`name_llvm.act`) that its directive does not keep it to, or that it has no directive. Types and values shown on hover are those of the first target. |

A file in a program is checked with the rest of it; any other file is checked on its own.

Paths are relative to `action.json`. A mistake in the file is shown as an error on it, and the defaults are used until it is fixed.

## 2.10 Building for your computer (LLVM)

Action programs can also be built to run on the computer you work on (64-bit macOS or Linux), through LLVM. `action_llvm` compiles Action to LLVM IR (a `.ll` file), and **`llbuild`** compiles and links it with clang (LLVM 15 or later):

```sh
make llvm-tools                       # builds build/tools/action_llvm
./llbuild hello.act --run             # builds build/llvm/hello and runs it
./llbuild main.act util.act -o build/llvm/app -O2
./llbuild app.act helpers.c -lm       # with a C source and a C library
```

| Option | Meaning |
|--------|---------|
| `-o FILE` | The program (default `build/llvm/<name>`); the `.ll` is written next to it. |
| `-I DIR`, `-D NAME[=VALUE]` | As for the compiler. |
| `-l LIB`, `-L DIR`, `file.c`, `file.o`, `file.a` | Linked in by clang. |
| `-O0` … `-O3`, `-Os` | Optimization (default `-O0`). |
| `-g` / `-g0` | Debug information (default on). |
| `-fno-bounds-check`, `-fno-reference-check` | As for the compiler. |
| `--emit-llvm` | Stop after the `.ll`. |
| `--run [-- ARGS]` | Run the program; `llbuild` exits with its exit status. |
| `CLANG=…` | Use another clang. |

The language is the same, with these differences:

- **64-bit integers:** `u64` and `s64` can be used. An operation is done in 64 bits when an operand is 64-bit, and is signed when an operand is signed.
- **Floating point:** `f32` and `f64` (IEEE 754 single and double precision) can be used, with literals such as `1.5`, `2.0`, `1e-3` and `6.02e23` (a digit on both sides of the point). The rules:
  - A floating-point literal is an untyped constant that takes the type it is used with, and an untyped integer constant can be used where a float is expected (`x * 2`).
  - Otherwise integers and floats do not mix, and neither do `f32` and `f64`: convert one with `f64(n)`, `s32(x)` and so on. Converting a float to an integer goes toward zero.
  - `%`, the bitwise operators and the shifts are for integers. A float is not a condition: compare it, as in `x != 0.0`.
  - Dividing by zero gives infinity or NaN, as IEEE 754 defines.
  - `const f64 PI = 3.14159;` is worked out in double precision at compile time.
  - After `...` in a C call, an `f32` is passed as a `double`, as C does, so `printf("%f", x)` works for both.

  Particle does not have floating point yet: `f32` and `f64` there are an error.
- **References are 8 bytes**, so types with references are larger: use `sizeof`, not fixed numbers.
- **Arithmetic is the same as on Particle:** overflow wraps; dividing by zero gives all ones (the remainder: the dividend); a shift count is masked to 5 bits (6 for a 64-bit value).
- **`trap(N)`** exits the program with status N, so `trap(0)` is success. `main` may return a `u32`, its exit status, and may take the command line as `ref string args[]` (see [3.7](#37-functions)).
- **Run-time checks** that fail print a message and exit with 15: `action: index 5 is out of range for 'a' (length 4) at main.act:12:8`, `action: null reference in field 'next' at …` (an empty reference), or `action: out of memory at …`.
- **C functions** are declared with `extern`, and may take `...`:

  ```c
  extern s32 printf(string format, ...);
  extern s32 puts(string s);

  void main() {
      u64 big = 0x123456789A;
      printf("%llx\n", big);
  }
  ```

  A `string` is passed as `char *`, a user-defined type as a pointer to it, `u32` as `unsigned`, `s64` as `long long`. After `...`, smaller integers and `bool` are passed as `int`. An open array cannot be passed to C.
- **Particle hardware is not there:** inline assembly, `asm` prototypes, FIFOs and trap handlers are errors. An `@` address is read and written exactly as written (volatile), as are `peek8/16/32` and `poke8/16/32`; on a computer with an operating system, most such addresses are not yours to use.
- **The heap** is the C library's (`calloc`, `realloc`, `free`).
- **Debugging:** the program has full debug information, so lldb or gdb show Action lines, parameters, locals (including arrays and user-defined types) and globals:

  ```sh
  ./llbuild main.act -o build/llvm/main
  lldb build/llvm/main          # breakpoint set -f main.act -l 12, run, frame variable
  ```

`make llvm-tests` builds the test programs with `llbuild` and runs them. A test that needs Particle hardware has the line `//act:build particle` and is skipped (see [2.11](#211-code-for-both-targets)). In the same way, a test that needs what only the LLVM compiler has (such as `f32`) has the line `//act:build llvm`, and `make compiler-tests` skips it.

## 2.11 Code for both targets

A program can be written for both compilers. Two things help: a **build directive**, which says which targets a whole file is for, and **target constants**, for small differences inside a file that is shared.

### Build directives

A file that only makes sense for some targets says so on a line of its own, before its first `import` or declaration:

```c
//act:build llvm

// console_llvm.act - console output through the C library
extern s32 puts(string s);

void print(string s) {
    puts(s);
}
```

```c
//act:build particle

// console_particle.act - console output through FIFO 0
void print(string s) {
    u32 i = 0;
    while (s[i] != 0) {
        writeFifo(0, s[i]);
        i = i + 1;
    }
}
```

A program can import both. Each compiler sees only the file meant for it, so `extern` never reaches Particle and FIFOs never reach LLVM:

```c
import "console_particle.act";
import "console_llvm.act";

void main() {
    print("hello world\n");
}
```

The rules:

- A build is a target and an operating system. The targets are `particle` and `llvm`. The operating systems are `none` (Particle runs without one), and `macos` and `linux` for LLVM, which builds for the computer it runs on. So the builds are `particle` with `none`, and `llvm` with `macos` or `linux`.
- The directive is an expression of those names with `!`, `&&`, `||` and parentheses. `!` binds tightest, then `&&`, then `||`: `//act:build llvm && (macos || linux)`, `//act:build !particle`.
- It is written `//act:build`, with no space after `//`: `// act:build` is an ordinary comment. Only comments and blank lines may come before it, and a file has at most one.
- A file whose directive is false for the build is **left out entirely**. It is read only as far as the directive: it is not parsed or checked, and its declarations do not exist for that build. Importing it adds nothing.
- It is an error when every file named on the command line is left out (`no source files are built for llvm on macos`).
- A misplaced or repeated directive, an unknown name (such as a misspelled `llmv`) and a directive that can never be true (`particle && macos`) are errors.

By convention a file for one target or operating system says so in its name, after the last `_`: the target first, then the operating system, as in `console_llvm.act`, `console_particle.act`, `clock_macos.act` and `clock_llvm_linux.act`. Only the directive decides what is built; the editor warns when a file's name and its directive disagree (see [2.9](#29-editor-support)).

### Target constants

`pbuild` and `llbuild` define these constants (with `-D`) for every build:

| Constant | `pbuild` | `llbuild` on macOS | `llbuild` on Linux |
|----------|----------|--------------------|--------------------|
| `COMPILER_TARGET_PARTICLE` | 1 | 0 | 0 |
| `COMPILER_TARGET_LLVM` | 0 | 1 | 1 |
| `COMPILER_OS_NONE` | 1 | 0 | 0 |
| `COMPILER_OS_MACOS` | 0 | 1 | 0 |
| `COMPILER_OS_LINUX` | 0 | 0 | 1 |

They come after any `-D` of your own, so they cannot be overridden. A constant condition decides at compile time, and the branch that is not taken is not checked, so it may use what only the other target has:

```c
void main() {
    print("hello world\n");
    if (COMPILER_TARGET_PARTICLE) {
        trap(0);        // end the run in psim; on LLVM, main returns
    }
}
```

The compilers themselves (`build/tools/action` and `action_llvm`) do not define them: a program that uses them and is compiled without `pbuild` or `llbuild` needs the same `-D` options.

---

# Part 3: Reference

## 3.1 Lexical structure

**Comments:** `// to end of line` and `/* block */`. Block comments do not nest. A line `//act:build …` before the first declaration is a build directive, not a comment (see [2.11](#211-code-for-both-targets)).

**Identifiers:** a letter or `_`, followed by letters, digits or `_`. Identifiers are case-sensitive. A lone `_` is the wildcard in tuple assignment.

**Integer literals:**
- Decimal: `0`, `42`, `65535`
- Hexadecimal: `0x1F`, `0xdeadBEEF`. The prefix must be lowercase `0x`.
- Binary: `0b1010`. The prefix must be lowercase `0b`.
- `_` may be put between two digits: `1_000_000`, `0xFF_FF`, `0b1010_0101`.
- There are no negative literals. `-5` is unary minus applied to `5`.
- A number followed by letters or digits that do not belong to it (`0b102`, `0xFG`, `12ab`) is an error.

**Floating-point literals** (the LLVM compiler, see [2.10](#210-building-for-your-computer-llvm)): digits, a point and digits (`1.5`, `0.25`), optionally followed by an exponent (`6.02e23`, `1.0e-3`), or digits and an exponent (`1e9`). There must be a digit on both sides of the point, so `1.` and `.5` are not literals.

**Character literals:** a single character or escape in single quotes: `'A'`, `'\n'`, `'\0'`, `'\x41'`. The value is the character code.

**String literals:** `"text"`, with escapes `\n \r \t \\ \" \0 \xNN`.

**Operators and punctuation:**

```
+  -  *  /  %  &  |  ^  ~  !  <  >  =
== != <= >= << >> && || -> ..
+= -= *= /= %= &= |= ^= <<= >>=
:  ;  ,  (  )  {  }  [  ]  @  .
```

`->` appears only in function types (`fn(u32) -> u32`). `*` and `&` are only multiplication and bitwise AND. `{` and `}` also enclose initializers (`{1, 2, 3}`, `{x: 1}`), and `:` names a field in them.

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

Each file is loaded once, however many times it is imported, so circular imports are harmless. There is no preprocessor: no `#define`, `#include`, `#if` or predefined names such as `__LINE__`. A file can be limited to some targets with a build directive; an imported file that is left out adds nothing (see [2.11](#211-code-for-both-targets)).

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
| `u64` | 8 | no | — | — (LLVM only) |
| `s64` | 8 | yes | — | — (LLVM only) |
| `f32` | 4 | — | — | — (LLVM only) |
| `f64` | 8 | — | — | — (LLVM only) |

Expressions are evaluated at 32 bits, or at 64 when an operand is `u64` or `s64` (LLVM only, see [2.10](#210-building-for-your-computer-llvm)). `f32` and `f64` are IEEE 754 floating point; they do not mix with integers or with each other without a conversion (see [3.5](#35-expressions-and-operators)). Constants take the type they are used with (see [3.13](#313-compile-time-evaluation)). `true` and `false` are the constants 1 and 0.

### `string`

A sequence of bytes ending in a null terminator. It is declared as a fixed buffer (`string s[N]`), as a heap string (`string.create(N)`), or as a parameter. `sizeof(string)` is 1 (one character).

### `void`

Used for functions that return nothing, and for an empty parameter list: `void f(void)`.

### References

There are no pointer types and no null. A **reference** is a 4-byte address managed by the compiler, which is either **empty** or refers to a value:

- parameters of user-defined types, variables declared `ref T name;`, and variables of those types given a reference value (see [3.8](#38-user-defined-types))
- heap arrays and strings (`T x[] = T.createArray(n)`)
- open array parameters (`T a[]`)
- fields declared `ref T name` or `T name[]` (see [3.8](#38-user-defined-types))

A reference is never `0`: declaring one as `= 0`, giving it `0`, passing or returning `0` for one, and comparing one with `0` are errors. `r.exists()` tells whether it has a value, `r.unset()` empties it, and `a.sameAs(b)` tells whether two references refer to the same value (`==` and `!=` on references are errors). See [3.10](#310-heap-allocation-and-ownership).

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
Type name[D] = {e1, e2, ...};  // fixed array with its values
Type name = {field: e, ...};   // a user-defined type stored in place, with its values
Type name[] = Type.createArray(n);   // heap array (a reference)
Type name[];                   // an empty heap array (or heap string)
ref Type name;                 // an empty reference to a user-defined type
Type name @ ADDRESS;           // bound to a fixed memory address
Type name[D] @ ADDRESS;        // bound array
ref Type name[D];              // array of references (see 3.9)
```

- Array dimensions and `@` addresses are **constant expressions**: literals, `const` and `enum` names, `sizeof`, and operators over them.
- **Locals** are allocated in the function's stack frame, which is zero-filled each time the function is entered. A local declared without a value is zero; one declared in an inner block is cleared each time its declaration runs (so it is zero on every pass of a loop). Blocks side by side never run at the same time, so their locals share the same words of the frame.
- **Globals** are emitted after the code. A global scalar may have a **constant-expression** initializer, a global string buffer a string literal (`string msg[16] = "hello";`), and a global array or record a brace initializer whose values are constants. Anything not given a value starts zero. A global of a user-defined type is stored in the data section, unless it is a reference.
- `ref Type name;` declares a reference that starts **empty**; `Type name = 0;` is an error (there is no null).
- **Bound variables** (`@`) allocate no storage. Every access goes to the given address. Bound variables can be declared at the top level or inside functions.
- `volatile` is accepted before a top-level declaration and has no effect. Accesses to bound variables are never optimized away.

### Brace initializers

```
u32 a[4] = {1, 2, 3};                  // a[3] is 0
u8 grid[2][3] = {{1, 2, 3}, {4}};      // one brace list per row
string names[3][8] = {"ann", "bob"};   // one string per row
Point p = {x: 1, y: 2};                // fields by name
Shape s = {kind: 1, corners: {{x: 1}, {y: 2}}, label: "box"};
```

- An array takes a brace list of at most as many values as its first dimension; an array of more dimensions takes one brace list per row. A string row takes a string.
- A user-defined type stored in place takes `{field: value, ...}`, each field at most once, in any order.
- Elements and fields not given are zero. In a loop, a local with an initializer starts afresh on every pass.
- A local's values can be any expressions; a global's must be constants. A global's reference fields cannot be given values (they start empty).
- A heap array, a reference and a scalar do not take a brace initializer. A local declared with one must be inside `{ }` (not the whole body of an `if`, `while` or `for`).
- A heap record is given values in the same way through `create`: `Point.create(x: 1, y: 2)` (see [3.10](#310-heap-allocation-and-ownership)).

### Scope of local variables

Local variables follow Go's rules:

- A local can be used from its declaration to the end of the `{ }` block that declares it. Using it before its declaration, or after its block has ended, is an error (`undefined identifier 't'; the 't' declared at main.act:5:9 is not in scope here`).
- The initializer is evaluated before the new name is in scope: `u32 x = x + 1;` in an inner block reads the outer `x`.
- A local declared in an inner block may have the name of a local or parameter from an enclosing block, or of a global variable, constant, enum member or function. It hides that name until its block ends.
- Declaring a name twice in the same block is an error (`variable 'x' is already declared in this block`).
- A function's parameters belong to its outermost block. A local in that block cannot have a parameter's name, but a local in an inner block can.
- The variable of a `for` loop belongs to the loop. Two loops one after the other can each declare `i`, and the loop's `i` may hide an outer `i`.
- Each `switch` case is a block of its own, from its label (or a run of labels together) to the next label. A local declared in one case cannot be used in another, even when the case falls through.
- An `if`, `while` or `for` body written without braces is also a block of its own.

```c
u32 total = 0;              // a global

u32 f(u32 n) {
    // u32 n = 2;           // error: n is a parameter of f
    if (n > 3) {
        u32 n = 3;          // allowed: hides the parameter in this block
        total += n;
    }
    {
        u32 total = n;      // hides the global until the block ends
    }
    {
        u16 total = 1;      // another block may use the same name
    }
    return total;           // the global
}
```

### Constants

```
const Type NAME = constant-expression;
const Type NAME[D] = {e1, e2, ...};    // a constant table
const string NAME = "text";            // a string constant
```

The value is computed at compile time (see [3.13](#313-compile-time-evaluation)) and no storage is created. The value must fit `Type`, and the constant has that type. A constant can be used anywhere a literal can. A `-D NAME=VALUE` on the command line defines a constant, and overrides a `const` of the same name (taking its type).

A `const` declared at the top level of a file is **global**. One declared inside a function is **local**, and follows Go's rule: it can be used from its declaration to the end of the `{ }` block that contains it. It is not seen by other functions, or by an inline function expanded into this one. A constant declared in an inner block hides one of the same name from an enclosing block until the inner block ends, and two separate blocks may each declare their own. Local constants follow the same scope rules as local variables (see above), with one difference: a local constant must not have the name of a global constant, enum member, global variable, function or type. It also cannot have the name of another constant or variable in the same block, or of a parameter in the function's outermost block.

**Constant tables and string constants** do have storage: they are arrays that cannot be changed. A table is given all its values in braces (as above, and they must be constants); a string constant is sized to fit its text, and its `.len` and `.capacity` are constants (`u8 buf[GREETING.len + 1];` works). Writing to one is an error, and so is passing one to a parameter the function writes through (see [3.7](#37-functions)). On Particle they are kept with the program's data; with LLVM, in read-only memory. Declared inside a function, they follow the scope rules of locals but are stored with the globals.

`const f32` and `const f64` constants (LLVM only) hold floating-point values, worked out in double precision.

```c
void f() {
    const u32 N = 4;
    u32 a[N];               // N sizes a local array
    {
        const u32 M = N * 2;
        u32 b[M];
    }
    // M is not in scope here
    {
        const u32 N = 8;    // hides the outer N in this block
    }
}
```

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

The operands of arithmetic, bitwise and comparison operators are numbers. Using one on a string, an array, a value of a user-defined type, a reference or a function value is an error (except `==` and `!=` on two function values).

**Floating point** (LLVM only): `+ - * /`, the comparisons and unary `-` work on `f32` and `f64`. Both operands have the same type: an untyped constant (an integer or floating-point literal, or arithmetic on them) takes the other operand's type, and anything else is converted with `T(x)`. `%`, `& | ^ ~` and the shifts are for integers.

### Conversions

`T(x)`, where `T` is a scalar type (or an alias of one), converts the number `x` to `T`, as in Go:

- To a narrower integer type, it keeps the low bits; `s8`/`s16` sign-extend them and `u8`/`u16` zero-extend them.
- Between `u32` and `s32` (or `u64` and `s64`), the bits are the same and only the signedness changes. To `u64`/`s64`, a narrower value is extended by its own signedness.
- `bool(x)` is 1 when `x` is not zero.
- A float converted to an integer goes toward zero; an integer converted to a float is rounded to the nearest float.
- A constant must fit: `u8(300)` and `s16(u32(0x8000))` are errors.
- Only numbers can be converted: `u32(s)` for a string `s` is an error.

### Comparison

`== != < <= > >=` produce 0 or 1. The comparison is **signed** under the same rule as above, and unsigned otherwise. A constant operand takes the other operand's type (see [3.13](#313-compile-time-evaluation)), so `x < -1` is a signed comparison when `x` is signed, and an error when `x` is unsigned. A comparison of two constants is computed exactly: `-1 < 0` is true.

Only numbers are compared:

- **Strings:** `==` and the other comparisons are errors; use `stringEquals(a, b)` or `stringCompare(a, b)` from `lib/string.act`.
- **Arrays** and **values of user-defined types** are not compared: compare their elements or fields.
- **References:** `a.sameAs(b)` is 1 when both refer to the same value (or both are empty). Both must be references of the same type: record references, heap arrays or heap strings. `==` and `!=` on references are errors, and so is comparing one with `0`: use `r.exists()`.

### Logical

- `!x` produces 1 if `x` is 0, and 0 otherwise.
- A condition (of `if`, `while`, `&&`, `||` and `!`) is an integer or a `bool`. A reference is tested with `r.exists()`, and a float by comparing it.
- `a && b` and `a || b` produce 0 or 1 and **short-circuit**: the right side is evaluated only when it decides the result. `1 && 2` is 1.

### Assignment

`=` stores into a variable, field or array element, and yields the stored value. Chaining (`a = b = 0`) works. The right side is evaluated once. Compound operators load the target, apply the operation and store the result.

A whole array is not assigned: `b = a` for fixed arrays is an error (copy the elements). A string buffer is the exception: giving one a string copies the characters (up to its capacity). Giving a reference variable another reference **moves** it (see [3.10](#310-heap-allocation-and-ownership)); a value of a user-defined type is copied with `a.copyFrom(b)` (see [3.8](#38-user-defined-types)).

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

The heap operations `.create()`, `.createArray()`, `.destroy()`, `.destroyArray()`, `.resize()`, `.exists()`, `.unset()` and `.sameAs()` are described in [3.10](#310-heap-allocation-and-ownership), and `.copyFrom()` in [3.8](#38-user-defined-types). A method call on a string, `s.name(...)`, calls the function `stringName(s, ...)` (such as `stringFind` from `lib/string.act`).

### `sizeof`

- `sizeof(u8)`, `sizeof(s8)`, `sizeof(string)` → 1
- `sizeof(u16)`, `sizeof(s16)` → 2
- `sizeof(u32)`, `sizeof(s32)`, `sizeof(f32)`, `sizeof(void)`, `sizeof(FnType)` → 4
- `sizeof(u64)`, `sizeof(s64)`, `sizeof(f64)` → 8
- `sizeof(TypeName)` → the size of a user-defined type, including alignment padding (see [3.8](#38-user-defined-types))
- `sizeof(variable)` → the variable's size: for a fixed array, the whole array; for a reference, 4
- `sizeof(CONSTANT)` → the size of the constant's type (4 for an untyped constant)
- `sizeof(expression)`, such as `sizeof(a[0])` or `sizeof(p.x)` → the size of the expression's type

A name in `sizeof` that is not a type, variable or constant in scope is an error.

`sizeof` is a compile-time constant.

### Calls

`f(args)` calls a function, an inline function or a function-typed variable. A function's bare name (`f`) evaluates to its address and can be assigned to a variable of a matching function type. Arguments are evaluated left to right.

A function value can also be called where it is stored: `table[i](x)` through an element of an array, `dev.onRead(x)` through a field of function type, and `pick(1)(x)` through a function's result.

A call gives exactly one argument per parameter (a C function with `...` takes more). The call of a function that returns nothing is a statement: using its value is an error.

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
| Task operation | `yield(t);`, `waitUntil(t, cond);`, `pkExit(t);`, only in a task (see [3.11](#311-tasks)) |
| Assertion | `verify(const-expr, "msg");` |

**Conditions** are integers or `bool`s, and are true when non-zero (see [3.5](#35-expressions-and-operators)).

**Range `for`:** `var` is declared by the loop header and must have a type. It starts at `start` and the body runs while `var < end`, compared signed if `var` has a signed type. `end` is evaluated **once**, before the loop starts. After each pass, `var` increases by 1. The body may change `var`.

**Switch:** each `case` label is a constant expression. Control jumps to the matching label, or to `default:` if none matches, or past the switch if there is no `default`. Each case ends with an implicit `break`. A `continue` that is directly inside the switch (not inside a loop within it) jumps to the next case label in source order, or out of the switch from the last case. `break` leaves the switch.

**Continue in loops:** in a `while`, `continue` re-tests the condition. In a `for`, it steps the variable and re-tests.

**Tuple targets** can be `Type name` (declares a new variable), `Type name[]` (declares a heap array or string from a `T[]` result), `name` (an existing variable) or `_` (discard). There can be up to four.

**Missing return:** a function whose result type is not `void` must not run off the end of its body (Go's rule). Its last statement must be one that ends it: a `return`; `trap(0)` (reset); inline assembly, which leaves the result in R1 itself; a block that ends with one; an `if`/`else` whose branches both end with one; a `switch` with a `default` whose every case ends with one (a case may end with `continue` to fall into the next); or a `while` loop whose condition is a non-zero constant and that no `break` leaves. `trap(N)` for any other `N` does not end a function, since its handler can return.

## 3.7 Functions

```
ReturnType name(params) { body }
ReturnType name(params);                       // prototype
asm ReturnType name(params);                   // routine written in assembly
extern ReturnType name(params);                // C function (LLVM only, see 2.10)
extern ReturnType name(params, ...);           // variadic C function
(T1, T2, ...) name(params) { body }            // tuple return, up to 4
T[] name(params) { body }                      // returns a heap array (string[]: a heap string)
ref T[] name(params) { body }                  // returns a heap array of references
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
| `T m[][]`, `T m[][][]` (open array of 2 or 3 dimensions) | data address + one length per dimension | 3, 4 |
| `BinOp f` (function type) | code address | 1 |
| `string s` | address | 1 |

Slots 1–4 travel in R1–R4 and later slots on the stack (see [2.6](#26-calling-convention-and-inline-assembly)), so there is no limit on the number of parameters. A method's `this` uses one slot, and each open array one more than it has dimensions.

**Open arrays of more dimensions:** `T m[][]` takes a fixed array of two dimensions (a local, a global, a field, or another such parameter), of the same element type. `m.len` is the number of rows and `m[i].len` the length of a row; each index is checked against its own length. A row `m[i]` can be passed to a `T row[]` parameter. For `string names[][]`, the last length is the strings' capacity: `names.len` is the number of strings, `names[i].len` the length of one string and `names[i].capacity` its capacity. An open array parameter has at most 3 dimensions; one of an inline function has one.

**Values that must not change:** arrays, strings and records are passed by reference, so a function can change its caller's value through a parameter. The compiler works out which parameters each function writes through (directly, or by passing them on to one that does), and it is an error to pass a constant table, a string constant, a string literal or `main`'s command line to one. It cannot see into `extern` and `asm` functions, which are taken not to write through their parameters; a call through a function value is taken to write through all of them.

**Lambdas:**

```
fn(params) -> ReturnType { body }
fn name(params) -> ReturnType { body }      // a name, seen only inside the body
fn(params) { body }                         // returns nothing
```

A lambda is a function value, written where one is expected: given to a variable, field or array element, passed as an argument, returned, or used in a brace initializer or `T.create(...)`. Its signature must match the function type it is given to. It is compiled as a hidden function of its own, so calling one costs the same as calling any function value.

- It can use its parameters, its own locals, the globals, the functions, and the constants (but not the variables or parameters) of the function it is written in. Using one of that function's variables is an error: pass it as a parameter. Nothing is captured, and nothing is allocated.
- The optional name is seen only inside the lambda, so that it can call itself. Outside it, the name is not declared.
- A lambda written as a statement on its own is an error: it is a value. A global cannot start with a lambda (or any function); give it one in code.
- Lambdas may be written inside lambdas. A lambda cannot be `inline` or a task.
- Messages name a lambda `lambda 'pow'`, or `lambda at main.act:12:9` when it has no name. In the debugger and the assembly it is the function `main.pow` or `main.lambda1`, named after the function it is written in.

**Return values:** a scalar, reference or function value is returned in R1. Tuples return in R1 to R4. In a tuple-returning function, every `return` must give the declared number of values. In a scalar function, `return (a, b)` is an error. A function must not run off the end of its body without returning a value (see **Missing return** in [3.6](#36-statements)).

**Returning heap arrays:** a function declared `T[] name(...)` returns a heap array of `T` (`string[]`: a heap string; `ref T[]`: a heap array of references), and a tuple element can be `T[]` too. Returning one moves it to the caller, which owns it. Only a heap array can be returned this way: an array stored in the function's frame, and an open array parameter (borrowed from the caller), are errors, and so is `return 0` (return an empty `T a[];` instead).

**Inline functions** are expanded at each call site, and may be declared before or after their callers. They have no address. An inline function that calls itself, directly or through other inline functions, is an error. They may declare locals, which live in their own frame for the duration of the expansion. The arguments are evaluated in the caller's scope; the body then has a scope of its own: the globals, its parameters, and its own locals and constants. Using a variable or constant of the function it is expanded into is an error; pass it as a parameter instead.

**Prototypes:** a function must be declared before the program can call it: by its definition (anywhere in the program) or by a prototype. Calling an undeclared name is an error. Every prototype must be matched by a definition in the Action sources, which may come later or in another file. A routine written in assembly is declared with `asm` in front of its prototype instead; it must not also be defined in Action. Its label is `_name`, and it follows the calling convention in [2.6](#26-calling-convention-and-inline-assembly).

**`main`** is special. It sets up the stack and runs, and when it returns the processor enters a halt loop. `main` may be declared `void` or `u32`. It takes no parameters, or the command line as `ref string args[]`:

```c
u32 main(ref string args[]) {
    if (args.len > 1) {
        string name[64] = args[1];   // a copy that can be changed
    }
    return 0;
}
```

`args` is read-only: writing to it, or to one of its strings, is an error. As in C, `args[0]` is the program's name. On Particle there is no command line, so `args.len` is 0. Built with LLVM, `main`'s result is the program's exit status.

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
- **Layout:** fields are placed in declaration order, each at the next offset that is a multiple of its **alignment**: 1 for `u8`/`s8`/`bool`/`string`, 2 for `u16`/`s16`, 4 for `u32`/`s32`/`f32`, references and function values (8 with LLVM, as for `u64`/`s64`/`f64`), and for a nested or embedded type, that type's alignment. A type aligns to its most-aligned field, and its size is padded to a multiple of that, so arrays of it stay aligned. Use `verify(sizeof(Name) == N, "...")` to pin a layout.
- Types may be declared in any order. Types that contain each other by value are an error.
- Embedding a scalar type (`u32;`) is not allowed.

**Reference fields:** `ref OtherType field;` and `Type field[];` each hold one pointer-sized reference. `OtherType` may be the type being declared, which is how linked structures are built. `ref` needs a user-defined type; for an array write `Type field[]`.

- A new value from `create()` has its reference fields empty, since allocations are zeroed.
- Assigning a reference variable to the field moves it there (see [3.10](#310-heap-allocation-and-ownership)). Assigning `T.create()`, `T.createArray(n)` or another reference field also works. Assigning a value stored in place, or `0`, is an error; `obj.field.unset()` empties the field.
- `obj.field.member`, `obj.field[i]`, `.len`, `.capacity`, method calls and passing the field to a function go through the reference. With reference checks on, each first checks it is not empty; element access is also bounds-checked against the heap header.
- `obj.field.destroy()` or `obj.field.destroyArray()` frees the value and leaves the field empty. `obj.field.resize(n)` updates the field. `obj.field.exists()` tests it.
- Destroying `obj` does not free what its fields refer to.

**Embedding:** `OtherType;` inlines `OtherType`'s fields at that position, aligned as a nested field of that type would be. Its fields can then be accessed directly on the outer type. If the outer type declares a field with the same name, the outer field wins. Methods of the embedded type can be called on the outer type, and the receiver is adjusted to point at the embedded part. You can also refer to the embedded part as a whole by its type name: `sprite.Point`.

**Function fields:** a field can have a function type (`Handler onRead;`, or an array of them, `Handler table[4];`). `obj.onRead(x)` calls the function the field holds, and `obj.table[i](x)` one in the array. A type cannot have a field and a method of the same name.

**Methods:** `ReturnType TypeName.method(params)` defines a function with an implicit first parameter `this` of type `TypeName`, passed by reference. Call it as `obj.method(args)`.

**Method references:** `TypeName.method` (on the type name, not on an instance) evaluates to the method's address. Its signature is `fn(TypeName, params...) -> ReturnType`. Writing `instance.method` without calling it is an error.

**Stored in place, or a reference:** a variable of a user-defined type is a **reference** if it is declared `ref T name;` (which starts empty), or if anywhere in its function it is given `T.create()`, another reference, or the result of a function that returns that type. Parameters of user-defined types are always references. Every other such variable is **stored in place**: on the stack for a local, in the data section for a global. Assignment never copies a value, so:

- assigning to a variable stored in place is an error
- assigning a variable stored in place, or a field or array element of a user-defined type, to a reference is an error
- destroying a variable stored in place is an error

**Starting values:** a value stored in place takes a brace initializer, `Point p = {x: 1, y: 2};`, and one on the heap takes the same values by name in `create`: `Point.create(x: 1, y: 2)`. Nested values and arrays take nested braces: `Shape.create(at: {x: 1}, marks: {4, 5})`. A string field takes a string literal, and a reference field a reference (which moves into it). Fields not given are zero (references empty). `create` takes no other arguments.

**Copying:** `dst.copyFrom(src)` copies the bytes of `src` into `dst`. Both are values of the same user-defined type, each stored in place or a reference, and the type must not hold references (in `ref` fields, arrays of references, heap array fields, or a nested type that does), since the copy would be a second owner. It is a statement, and `dst` must not be a constant.

The keyword `struct` is not accepted. Use `type`.

## 3.9 Arrays, strings and slices

**Fixed arrays:** `T a[N]`, or multi-dimensional `T a[N][M]` (row-major). `a[i][j]` addresses element `i*M + j`. `.len` gives `N`, and `.capacity` gives the last dimension. A brace initializer gives the elements their values (see [3.4](#34-declarations)). Arrays are not assigned or compared as a whole.

**Open arrays:** `T a[]` as a parameter. It accepts:

| Argument | Length passed |
|----------|---------------|
| a fixed array | its first dimension |
| a row `m[i]` of an array of more dimensions | the length of a row |
| a heap array | its length, from the heap header |
| another open array | its length |
| a string variable | its current `.len` |
| a slice `x[s..e]` | `e − s` |
| a slice `x[s..]` | `x.len − s` |
| a slice `x[..e]` | `e` |
| a slice `x[..]` | `x.len` |

Slices are valid **only** as open-array arguments. Their bounds may be any expressions. A slice of a string is an array of `u8` characters with no terminator, not a string: pass it to a `u8 s[]` parameter, not a `string` one.

Open array parameters of 2 or 3 dimensions (`T m[][]`) are described in [3.7](#37-functions).

**Strings:**
- `string s[N] = "literal";` creates an N-byte buffer. The literal is copied in at run time, and must be at most N−1 characters so the terminator fits: a longer one is a compile-time error.
- **Assigning a string to a buffer copies it:** `s = "xyz";`, `s = other;` and `string s[N] = other;` copy the characters up to the terminator, at most N−1 of them, then a terminator. A literal that does not fit is a compile-time error; a longer string at run time is cut short. A `string` field of a record (`p.name = "Ada";`) is a buffer too.
- `.len` scans for the null terminator. `.capacity` is N.
- Indexing gives single bytes. Writes are bounds-checked against N−1.
- For a `string s[]` open-array parameter, `.capacity` is the length passed by the caller, and `.len` still scans for the terminator.
- A string literal used in an expression evaluates to the address of a read-only copy in the string table. You can pass it to a `string s` or `string s[]` parameter that the function does not write through (writing through one is found at compile time, see [3.7](#37-functions)). Passed to a `string s[]` parameter, its `.len` works but its `.capacity` is 0.
- Strings are not compared with `==`: use `stringEquals` or `stringCompare` from `lib/string.act`.
- `string g[N] = "text";` at the top level starts with the text; `const string NAME = "text";` is a string constant (see [3.4](#34-declarations)).

**Arrays of strings:** `string names[3][8]` is 3 strings, each a buffer of 8 bytes. `names.len` is 3. `names[i]` is one string: `names[i].len` scans it, `names[i].capacity` is 8, `names[i][j]` is a character, `names[i] = "abc"` copies into it, and it can be passed to a `string s` or `string s[]` parameter. `string names[3][8] = {"ann", "bob"};` gives the strings their values, and `string names[][]` is an open-array parameter that takes the whole array.

**Arrays of references:** `ref T a[N]` (and `ref T a[N][M]`) holds N references to values of a user-defined type `T`, or to strings. It can be a local or a global, and `ref T a[]` is an open-array parameter that takes one.

```c
type Node { u32 val; };

u32 total(ref Node xs[]) {
    u32 t = 0;
    for (u32 i : 0..xs.len) {
        if (xs[i].exists()) { t += xs[i].val; }
    }
    return t;
}

void main() {
    ref Node nodes[4];            // all empty
    nodes[0] = Node.create();
    nodes[0].val = 3;
    Node n = Node.create();
    nodes[1] = n;                 // n is moved into the array
    u32 sum = total(nodes);
    nodes[0].destroy();           // frees it and leaves nodes[0] empty
    nodes[1].destroy();

    ref string words[2];
    words[0] = "one";             // copied into a new heap string
    words[1] = string.create(16); // a heap string variable is moved in
    words[0].destroy();
    words[1].destroy();

    ref Node pool[] = Node.createArray(3);  // a heap array of 3 empty references
    pool.resize(5);               // the new elements are empty
    pool.destroyArray();          // frees only the array (shallow)
}

type Tree {
    u32 val;
    ref Tree kids[2];             // a fixed array of references in the record
    ref Tree more[];              // a reference to a heap array of references
};
```

- The references start empty. An element can be given `T.create()` or another reference, and `nodes[i].unset()` empties it. Giving it a variable moves the variable's reference into the array.
- The flow analysis does not follow elements: using one that is empty (`nodes[i].val`, a method call, passing it, `.len` of a string element) is checked at run time, like a `ref` field. A variable given an element may be empty, so check it with `.exists()` first.
- The elements of a `ref string` array own heap strings. A value that is not a heap string (a literal, a fixed buffer, another element) is copied into a new heap string whose capacity is its length plus the terminator; a heap string variable is moved in. Every element that is set must be destroyed.
- `a.len` is N. `words[i].len` scans the string and `words[i].capacity` reads its heap header. `words[i][j]` is a character of the string and may be written. The strings of `main`'s command-line array are the exception: they are read-only and have no capacity.
- `nodes[i].destroy()` frees the value and leaves the element empty.
- An open-array parameter `ref T xs[]` takes an array of references, and `T xs[]` an array of values; passing one for the other is an error.
- `ref T a[] = T.createArray(n)` makes a heap array of n empty references (locals, globals and fields; `string.createArray(n)` for strings). The declaration decides whether `createArray` makes values or references; giving an array of values to an array of references, or the reverse, is an error. `a.len` is the current length.
- `a.resize(m)` keeps the first elements; growing adds empty references, and shrinking drops the last ones without destroying what they point at, so destroy them first.
- `a.destroyArray()` frees only the array (it is shallow): destroy the elements first.
- A record field can be a fixed array of references (`ref T kids[4]`) or a reference to a heap array of references (`ref T more[]`). The element type must be a user-defined type or `string`.

## 3.10 Heap allocation and ownership

### Operations

| Expression | Effect |
|------------|--------|
| `T.createArray(n)` | Allocates an array of `n` zeroed elements of type `T` (any scalar or user-defined type). Assign it to `T name[]`. |
| `string.create(cap)` | Allocates a string buffer of capacity `cap`, initially empty. |
| `T.create()` | Allocates one `T`, zeroed, and returns a reference to it. |
| `T.create(f: v, ...)` | The same, with fields given values by name (see [3.8](#38-user-defined-types)). |
| `h.resize(n)` | Resizes heap array `h` to `n` elements and updates `h`. |
| `h.destroyArray()` / `h.destroy()` | Frees `h` and leaves the reference empty. |
| `h.exists()` | 1 if `h` has a value, 0 if it is empty. |
| `h.unset()` | Empties the reference (a statement). |
| `a.sameAs(b)` | 1 if `a` and `b` refer to the same value (or are both empty), else 0. |

Declare the variable to match:

```c
type Point { s32 x; s32 y; }

void main() {
    u32 buf[] = u32.createArray(64);
    Point pts[] = Point.createArray(8);
    string s = string.create(128);        // 'string s[] = ...' also works
    Point p = Point.create();
    ref Point q;                          // empty until given a value
    p.destroy();
    s.destroy();
    pts.destroyArray();
    buf.destroyArray();
}
```

There is no null: a reference is never `0`. One declared `ref T name;` (a user-defined type) or `T name[];` (a heap array or string) without a value starts empty. Giving a reference `0`, passing or returning `0` for one, and comparing one with `0` are errors.

Heap arrays and strings carry a 4-byte header that holds the length (arrays) or capacity (strings). `.len`, `.capacity` and bounds checks read this header.

### Ownership rules

These rules are checked at compile time, along every path through each function, for the references held in its variables and parameters:

1. A variable that receives a heap allocation **owns** it. `create()`, `createArray()` and `string.create()` give a valid reference.
2. `b = a`, `T b = a;` and `obj.field = a`, where `a` is a reference variable, **move** the reference to `b` or the field. After that, `a` cannot be used at all, not even tested, until it is given a new value.
3. `x.unset()`, `x.destroy()` and `x.destroyArray()` make `x` empty. A local reference declared without a value is empty. `x.unset()` is an error while `x` is certainly still the owner of a value: destroy it, or move it, first.
4. A reference must be **definitely valid** to be used: reading or writing a field or element, `.len`, `.capacity`, calling a method on it, passing it to a function, destroying or resizing it. On every path to the use, it must have been allocated, received from a function that always returns a valid reference, or tested with `exists()`.
5. Assigning, returning, comparing (`sameAs`) and testing (`exists()`) a reference only require that it has not been moved.
6. Where paths meet (after an `if`, at the top of a loop), a reference that is valid on one path and empty or moved on another **may be** empty or moved, and must be tested before it is used.
7. A function returns a valid reference when every `return` in it gives a definitely valid one, even when it calls itself. Otherwise a call's result may be empty. The same holds for each reference of a tuple result, position by position.
8. Parameters are valid on entry and **borrowed**: they cannot be destroyed, returned, or moved into a variable that owns a reference.
9. References in globals and fields are not followed. A variable given one may be empty. With reference checks on, using an empty reference held in a global or a field traps (see [2.3](#23-bounds-and-reference-checking)). Reading a field into a variable copies the reference; using one copy after the value was destroyed through the other is not caught.

Nothing frees memory automatically.

## 3.11 Tasks

```
task name(State t, other parameters...) { body }

yield(t);
waitUntil(t, condition);
pkExit(t);
```

A task is a function that can pause and resume. `lib/protokernel.act` declares the three operations as prototypes, together with the status constants `PK_WAITING` (0), `PK_YIELDED` (1), `PK_EXITED` (2) and `PK_ENDED` (3), the state type `pt` (`u16 lc;`) and the inline initializer `pkInit(p)`.

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
- `waitUntil(t, cond)` evaluates `cond`. If it is true, execution continues. If it is false, the task returns `PK_WAITING`, and the next call evaluates `cond` again.
- `pkExit(t)` resets the resume point and returns `PK_EXITED`. The next call starts from the top.
- Running off the end, or `return;`, resets the resume point and returns `PK_ENDED`.

**Locals:**
- Locals do not survive a pause. Reading a local after a pause, when it was set before the pause and not set again since, is an error. Keep such values in the state.
- A `for` loop whose body pauses is an error, because its counter is a local. Use a `while` loop with the counter in the state.
- Parameters other than the state are passed on every call, so they can be read after a pause.

## 3.12 Hardware intrinsics and traps

| Call | Generates | Notes |
|------|-----------|-------|
| `trap(N)` | `TRAP N` | `N` is a constant from 0 to 15; anything else is an error. Evaluates to 0. |
| `readFifo(CH)` | `FIFO.R` | Blocking read from channel `CH`. Returns the word read. |
| `writeFifo(CH, value)` | `FIFO.W` | Writes `value` to channel `CH`. |
| `tryReadFifo(CH, x)` | `FIFO.TRYR` | Non-blocking read into the variable, field or element `x`. Returns 1 and stores the word if data was waiting; otherwise returns 0 and leaves `x` unchanged. |
| `peek8(addr)` | `LD8` | Reads the byte at `addr`. Returns it, zero-extended. |
| `peek16(addr)` | `LD16` | Reads the halfword at `addr`. Returns it, zero-extended. |
| `peek32(addr)` | `LD32` | Reads the word at `addr`. Returns it. |
| `poke8(addr, value)` | `ST8` | Writes the low byte of `value` at `addr`. |
| `poke16(addr, value)` | `ST16` | Writes the low halfword of `value` at `addr`. |
| `poke32(addr, value)` | `ST32` | Writes the word `value` at `addr`. |
| `callAddr(addr)` | `JMP R13, R14` | Calls the code at `addr`, which must return with `RRET`. Returns what it leaves in R1. |
| `asm("text")` | verbatim | Each line of `text` becomes one assembly line. |

`CH` must be a constant. The address of the `peek` and `poke` functions and `callAddr` can be any value computed at run time (where an `@` address must be a constant); a word address should be a multiple of 4 and a halfword address a multiple of 2 (a misaligned access raises trap 14). They are for monitors, loaders and drivers; nothing checks what is at the address. A program that declares a function with one of these names calls its own function instead.

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

**In use:** `asm` `bool` `break` `case` `const` `continue` `default` `else` `enum` `extern` `f32` `f64` `false` `fn` `for` `if` `import` `inline` `ref` `return` `s8` `s16` `s32` `s64` `sizeof` `string` `switch` `true` `type` `u8` `u16` `u32` `u64` `verify` `void` `volatile` `while`

**Built-in names** (identifiers with special meaning): `this`, `trap`, `readFifo`, `writeFifo`, `tryReadFifo`, `peek8`, `peek16`, `peek32`, `poke8`, `poke16`, `poke32`, `callAddr`, and the methods `create`, `createArray`, `destroy`, `destroyArray`, `resize`, `exists`, `unset`, `sameAs`, `copyFrom`, `len`, `capacity`. `task` starts a task declaration when it is followed by a name and `(`. `yield`, `waitUntil` and `pkExit` are task operations when `lib/protokernel.act` is imported.

## 3.15 Known limitations and pitfalls

These come from the current compiler's behavior. Code around them until they change.

| Issue | What happens | Workaround |
|-------|-------------|------------|
| Trap 0 cannot be bound | Compile error | Not decided yet. |
