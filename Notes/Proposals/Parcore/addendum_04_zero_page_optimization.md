# Particle Architecture Specification — Addendum 04: Zero Page Optimization (`0x0000–0x00FF`)

**Document Status:** Proposed Architecture & Firmware Optimization  
**Target Architecture:** Particle 32-bit RISC Core / Parcore Multi-Core Subsystem  
**Affects:** Memory Map Conventions, Standard Library (`lib/common.inc`), Parcore Firmware (`core0`–`core5`), Compiler (`act16c.py`)

---

## 1. Overview & Motivation

By architectural convention, every Particle core's trap table and reset entry point (`TRAP_RESET`) begins at `TRAP_TABLE_BASE = 0x00000100` (byte offset 256). The lower 256 bytes (`0x00000000–0x000000FF`) were intentionally reserved as a **Zero Page** for high-frequency state variables, pointers, and scratch data.

An audit of the Parcore RISC-V pipeline firmware (`core0_if_uart.asm` through `core5_cache_mem.asm`) revealed that **0 bytes of Page Zero are currently utilized**. All firmware modules place their local variables above `0x0100` (e.g., `0x0200`, `0x0400`, `0x0800`, `0x0E00`), leaving 256 bytes of Tightly Coupled Memory (TCM) unused in every core and incurring unnecessary multi-instruction address synthesis overhead on critical loops.

---

## 2. Architectural Mechanics of Page Zero in Particle

Unlike 8-bit processors (such as the 6502) that provide dedicated zero-page memory-indirect opcodes, Particle's load/store instructions (`LD8`, `LD16`, `LD32`, `ST8`, `ST16`, `ST32`) are strictly register-indirect (`(Rl)`). Consequently, the performance advantage of Page Zero in Particle comes from **single-instruction pointer materialization**:

### 2.1 Pointer Materialization Cost Comparison

| Address Range | Instruction Sequence | Size | Execution Cost | Clobbers `R14`? |
| :--- | :--- | :--- | :--- | :--- |
| **`0x0000–0x000F`** (Low Page Zero) | `LD Rr, addr4` | **2 bytes (1 op)** | **2 cycles** | **No** |
| **`0x0000–0x00FF`** (Full Page Zero via `R14`) | `LD R14, addr8` | **2 bytes (1 op)** | **2 cycles** | Yes (`R14` is target) |
| **`0x0000–0x00FF`** (Full Page Zero via `LDZP`) | `LD R14, addr8` + `LD Rr, R14` | **4 bytes (2 ops)** | **4 cycles** | Yes |
| **`0x0100–0xFFFF`** (Legacy `LOAD16` macro) | `LD R14, hi8` + `PUSH8 R14, lo8` + `LD Rr, R14` | **6 bytes (3 ops)** | **6 cycles** | Yes |
| **`0x0100–0xFFFF`** (With Addendum 03 `LDI`) | `LDI Rr, addr16` | **4 bytes (1 op + imm16)** | **3 cycles** | **No** |

### 2.2 Key Takeaways
1. **Direct `R14` Page Zero Access (`2 bytes / 1 op`):** Because `LD R14, Imm8` zero-extends an 8-bit immediate into all 32 bits of `R14` in a single 16-bit instruction, any variable located at `0x0000–0x00FF` can have its pointer loaded into `R14` and dereferenced in **2 instructions total**:
   ```assembly
   LD      R14, SCOREBOARD_MASK    ; 2 bytes (1 op): R14 = 0x00000080
   LD32    R8, (R14)               ; 2 bytes (1 op): R8 = *SCOREBOARD_MASK
   ```
   This is **67% smaller** than the legacy `LOAD16` sequence (6 bytes $\to$ 2 bytes) and **50% smaller** than even the 32-bit `LDI` instruction (4 bytes $\to$ 2 bytes).
2. **Ultra-Fast `0x00–0x0F` Base Pointers (`2 bytes / 1 op`, Any Register):** Addresses in the first 16 bytes (`0x0000–0x000F`) can be loaded directly into *any* register `R1–R15` via `LD Rr, Imm4` without touching `R14`.

---

## 3. Hardware Reset & TCM Initialization Invariant

In `ParcoreTcm` (`hdl/parcore/lib/parcore_tcm.dart`), compiled firmware binaries assembled with `.org 0x00000100` are loaded into TCM starting at `loadOffset = 0x00000100`, while the underlying BRAM array is zero-initialized (`0x00`) at reset.

* **Free Zero-Initialization:** Variables placed in `0x00000000–0x000000FF` are automatically initialized to `0x00000000` by hardware reset before the core fetches its first instruction at `0x00000100`.
* **Caution for Bare-Metal Standalone Mode:** In standalone single-core Particle targets where `0x00000000–0x000000FF` acts as an unmapped null-pointer guard page (trapping dereferences to `0x00000000`), Page Zero variables should start at **`0x00000004`** (leaving `0x00000000` reserved as the `NULL` trap sentinel) or restrict Page Zero usage to Parcore TCM subsystems where `0x00000000` is valid BRAM.

---

## 4. Standard Library (`lib/common.inc`) Additions

Add the following zero-page helper macros to `lib/common.inc`:

```assembly
; --- Macro: LDZP reg, zp_addr ---
; Loads an 8-bit Zero Page address (0x00..0xFF) into any destination register.
; Saves 2 bytes and 1 instruction compared to LOAD16. Clobbers R14.
.macro LDZP reg, zp_addr
    LD      R14, (%zp_addr) & 0xFF
    LD      %reg, R14
.endmacro

; --- Macro: LDZP32 reg, zp_addr ---
; Loads a 32-bit word directly from a Zero Page address into reg.
; Clobbers R14.
.macro LDZP32 reg, zp_addr
    LD      R14, (%zp_addr) & 0xFF
    LD32    %reg, (R14)
.endmacro

; --- Macro: STZP32 zp_addr, reg ---
; Stores a 32-bit word from reg directly into a Zero Page address.
; Clobbers R14.
.macro STZP32 zp_addr, reg
    LD      R14, (%zp_addr) & 0xFF
    ST32    (R14), %reg
.endmacro
```

*(Note: When `%reg` is `R14`, firmware should invoke `LD R14, ZP_ADDR` directly to avoid a redundant `LD R14, R14` move.)*

---

## 5. Parcore Firmware Relocation Plan

### 5.1 Core 0 — Instruction Fetch & UART (`core0_if_uart.asm`)
* **Current Placement:** `REDIRECT_TARGET_ADDR` at `0x0000013C` (wedged into the 4-byte gap immediately preceding `_branch_redirect_handler` at `0x0140`).
* **Zero Page Placement:** Move `REDIRECT_TARGET_ADDR` to **`0x00000004`** (or keep `0x0000013C` only if `parcore_top.dart` MMIO decode explicitly matches `0x0000013C`; if moved to `0x0004`, update `c0ReadRedirectMmio` in `parcore_top.dart`).
* **Impact:** `LD R14, 0x04` loads the MMIO pointer in 1 instruction (2 bytes) instead of 3 instructions (6 bytes).

### 5.2 Core 1 — Instruction Decode & Scoreboard (`core1_id.asm`) — *Highest Impact*
Core 1 executes the hottest inner loop in Parcore and suffers the highest address-loading overhead:
* **Current Placement:**
  * `REG_BASE` = `0x0800` (128 bytes: `x0..x31`)
  * `SCOREBOARD_MASK` = `0x0880` (4 bytes)
* **Zero Page Placement:**
  * `REG_BASE` = **`0x0000`** (`0x0000..0x007F`, 128 bytes)
  * `SCOREBOARD_MASK` = **`0x0080`** (`0x0080..0x0083`, 4 bytes)
  * *Remaining Free Zero Page:* 124 bytes (`0x0084..0x00FF`).
* **Impact:**
  * `SCOREBOARD_MASK` is accessed **5 times** in `core1_id.asm` (reset init, branch flush, hazard check, stall resolution, scoreboard clear, and dispatch reservation). Replacing `LOAD16 R6, SCOREBOARD_MASK` with `LD R14, SCOREBOARD_MASK` saves **4 bytes and 2 instructions per access** (**20 bytes** total code reduction and **6–10 instructions saved** on every RV32 instruction decoded).
  * `REG_BASE` (`0x0000`) eliminates the base-address addition altogether for register file lookups (`SHIFTL R9, R15, 2; LD32 R5, (R9)`), saving another **4 instructions** per register read/write!
  * Hardware reset zero-initialization eliminates the need for the 32-iteration `_init_rf_loop` at boot (saving 14 bytes of startup code).

### 5.3 Core 2 — Execution & CSR Unit (`core2_ex.asm`)
* **Current Placement:** `CSR_BASE` = `0x0E00` (64 bytes: `0x0E00..0x0E3F`).
* **Zero Page Placement:** `CSR_BASE` = **`0x0000`** (`0x0000..0x003F`, 64 bytes).
* **Impact:** Every CSR read/write (`cycle`, `instret`, `mstatus`, `mtvec`, `mscratch`, `mepc`, `mcause`) loads `CSR_BASE + CSR_OFS_*` via `LD R14, (CSR_BASE + CSR_OFS_*)` in **2 bytes (1 op)** instead of 6 bytes (3 ops), saving **~56 bytes** across the CSR dispatch table.

### 5.4 Core 4 — Writeback & Retirement (`core4_wb.asm`)
* **Current Placement:**
  * `INSTRET_LO_ADDR` = `0x0200`
  * `INSTRET_HI_ADDR` = `0x0204`
* **Zero Page Placement:**
  * `INSTRET_LO_ADDR` = **`0x0000`**
  * `INSTRET_HI_ADDR` = **`0x0004`**
* **Impact:** `INSTRET_LO_ADDR` is accessed on **every single retired RISC-V instruction**. Using `LD R14, INSTRET_LO_ADDR` reduces the retirement hot-loop by 4 bytes and 2 instructions per guest instruction retired.

---

## 6. Compiler (`act16c.py`) Global Variable Allocation Strategy

For ACT16 programs compiled via `tools/act16c.py`:
1. **Zero Page Allocation Bucket:** The compiler's global allocator can place the first 252 bytes of scalar globals/pointers (starting at `0x00000004` to preserve `0x00000000` as a hardware-trapped `NULL` pointer) into a `.zpdata` section (`0x0004..0x00FF`).
2. **Codegen Rule:** When emitting global variable address loads in `act16c.py`, if `symbol.address < 0x0100`, emit `LD R14, symbol` (2 bytes) instead of `LDI` (4 bytes) or `LOAD32` (10 bytes).

---

## 7. Summary of Benefits

* **Zero Hardware Changes Required:** Fully compatible with existing `ParticleCpuCore` and `ParcoreTcm` RTL.
* **Reclaims 1,024+ Bytes of TCM BRAM:** Activates the dormant `0x0000–0x00FF` region across Cores 0, 1, 2, and 4.
* **Fastest Possible Pointer Loads:** `LD R14, zp_addr` executes in **2 bytes / 2 cycles**, outperforming both `LOAD16` (6 bytes / 6 cycles) and `LDI` (4 bytes / 3 cycles) for all variables in the first 256 bytes of memory.