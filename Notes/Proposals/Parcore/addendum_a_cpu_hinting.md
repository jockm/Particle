# Addendum A: CPU Hinting (`HINT` / `0xFE`)

**Document ID:** `ARCH-ADD-A`  
**Status:** Proposed  
**Target Architecture:** Particle ISA v1.x & Parcore Distributed Cluster (`dataWidth`-parameterized)  
**Dependencies:**
* `02_parcore_cluster_performance_optimization_proposal.md` (`ARCH-PROP-02` — SARF & Stream Windowing)
* `04_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md` (`ARCH-PROP-04` — Multi-EX Dispatch & Scoreboarding)
* `05_parcore_autonomous_accelerator_coprocessor_architecture_proposal.md` (`ARCH-PROP-05` — `0xFF` `XTRA` Escape Convention)
* `06_parcore_memory_crossbar_and_cache_coherency_proposal.md` (`ARCH-PROP-06` — Split-Transaction Crossbar & L1 Cache)
* `08_parcore_tiered_hotspot_jit_proposal.md` (`ARCH-PROP-08` — Hardware Branch Frequency Table & Code Cache)

---

## 1. Executive Summary

As the **Particle** ISA and **Parcore** distributed cluster evolve to support heterogeneous execution cores (Multi-EX), out-of-band Shared Architectural Register Fabric (SARF) scoreboarding, non-blocking L1 caches, and tiered JIT compilation, software compilers (`pasm.py` and the runtime JIT emitter) possess high-level structural knowledge about instruction streams that hardware cannot easily infer from a compact 16-bit instruction word alone.

This addendum specifies **`HINT` (`0xFE`)**, a single-word 16-bit architectural hint instruction modeled after `0xFF` (`XTRA`). Unlike `XTRA`, which alters architectural state and requires an extended 32-bit escape payload, `HINT` is **architecturally transparent**:
* On a standalone or minimal `ParticleCpuCore` implementation, `0xFE` retires as a side-effect-free `NOP`.
* On a full **Parcore** cluster, the instruction fetcher, dispatch stage, memory crossbar, and cache controllers inspect the 8-bit hint payload (`imm8`) to steer execution, prefetch SDRAM cache lines, suppress cache pollution, or eliminate spinlock bus contention.

---

## 2. Instruction Encoding & Semantics

`HINT` occupies opcode **`0xFE`**, immediately adjacent to the `0xFF` (`XTRA`) escape opcode in `ParticleOpcodes` (`hdl/rohd/lib/constants.dart`).

### 2.1. Binary Format (16-Bit Fixed Width)

```text
 15                 8 7                  0
+--------------------+--------------------+
|   Opcode (0xFE)    |   Hint Code (imm8) |
+--------------------+--------------------+
```

| Field | Bits | Width | Description |
| :--- | :--- | :--- | :--- |
| **`opcode`** | `[15:8]` | 8 bits | Fixed `0xFE` (`ParticleOpcodes.hint`). |
| **`imm8`** | `[7:0]` | 8 bits | Hint identifier specifying the advisory microarchitectural behavior. |

### 2.2. Architectural Guarantees

1. **Zero Architectural State Mutation:** `HINT` never modifies general-purpose registers ($R0$–$R15$), SARF registers ($x0$–$x31$), condition flags, memory, or trap vectors.
2. **Forward & Backward Compatibility:** Unrecognized or unsupported `imm8` hint codes **must** be silently ignored and executed as a `NOP` (`pc <= pc + 2`, `rfWEn <= 0`). Software may emit `HINT` instructions unconditionally across different Parcore FPGA configurations without runtime feature gating.
3. **Scope of Effect:** Unless explicitly noted otherwise (such as block-level hints), a `HINT` applies to the **immediately following instruction** (`pc + 2`).

---

## 3. Cycle Cost Analysis & Fetch-Stage Folding

Because `ParticleCpuCore` is a non-pipelined, 2-state FSM (`stateFetch` $\to$ `stateExec`), retiring a standalone 16-bit `HINT` instruction natively costs **2 clock cycles** (`1` fetch + `1` execute).

### 3.1. Why Traditional Branch Prediction Hints Are Excluded
On a single `ParticleCpuCore`, conditional branches (`FBRA`, `BBRA`) resolve directly inside `stateExec` with zero speculative fetch pipeline to flush. Paying a guaranteed **2-cycle prefix overhead** to save at most **1–2 cycles** on a branch yields a net cycle loss on the common path. Consequently, static branch prediction hints (`BRANCH_LIKELY` / `BRANCH_UNLIKELY`) are **not** included in the primary hint set.

### 3.2. High-ROI Target Selection
A 2-cycle `HINT` prefix yields a substantial net speedup when the stall or latency penalty it prevents is **$10\times$ to $25\times$ greater** than its fetch cost—specifically:
* Avoiding a **34-cycle** iterative division head-of-line block in Multi-EX (`Proposal 04`).
* Avoiding a **20–35 cycle** SARF RAW scoreboard stall (`Proposal 02`/`04`).
* Hiding a **35–55 cycle** external SDRAM cache-line refill (`Proposal 06`).
* Eliminating a **32–64 iteration** cold-interpreter warmup loop before JIT compilation (`Proposal 08`).

### 3.3. Zero-Cycle Fetch-Stage Folding (Optional Hardware Optimization)
In Parcore configurations where Core 0 (IF) or the Code Cache fetcher reads 32-bit aligned words from TCM/BRAM:
* If bits `[15:0]` contain `0xFE <imm8>`, the fetch unit may **combinatorially fold** the hint into the metadata sideband of the instruction in bits `[31:16]` and advance `PC` by `+4` in a single cycle.
* When folded, `ParticleCpuCore` never executes `0xFE` as a separate instruction, reducing the execution overhead of `HINT` to **0 cycles**.

---

## 4. Parcore Hint Catalog (`imm8` Allocations)

Hint codes are partitioned into functional domains aligned with the Parcore subsystem architecture:

| Code | Mnemonic | Target Subsystem | Scope | Summary of Advisory Action |
| :--- | :--- | :--- | :--- | :--- |
| **`0x00`** | `HINT.HEAVY` | Core 1 (ID) / Multi-EX | Next Op / Block | Steer upcoming arithmetic to secondary worker (`Core 2B`) to prevent head-of-line blocking on `Core 2A`. |
| **`0x01`** | `HINT.INDEP` | Core 1 / SARF Scoreboard | Next 4 Ops | Assert that the upcoming instruction window has no RAW hazards against in-flight SARF writes. |
| **`0x02`** | `HINT.STREAM` | Core 3 / Crossbar (`Prop 06`) | Next Load/Store | Trigger a predictive burst prefetch of the next sequential cache line (`addr + 32`). |
| **`0x03`** | `HINT.BYPASS` | Core 3 / L1 Data Cache (`Prop 06`) | Next Load/Store | Mark memory access as non-temporal (streaming/DMA); bypass L1 cache line allocation on miss. |
| **`0x04`** | `HINT.PAUSE` | Arbiters / Port B / FIFO | Current Cycle | Yield memory/FIFO arbitration slots briefly inside spinlocks (`TAS`) or polling loops (`FIFO.STAT`). |
| **`0x05`** | `HINT.HOT` | Core 0 BFT / JIT (`Prop 08`) | Loop Entry | Bypass the `HOTSPOT_THRESHOLD` trip counter in the Branch Frequency Table and trigger immediate JIT compilation. |
| `0x06`–`0xFF` | *Reserved* | — | — | Reserved for future extensions; hardware decodes as `NOP`. |

---

### 4.1. Detailed Hint Specifications

#### `0x00` — `HINT.HEAVY` (Multi-EX Worker Steering)
* **Target:** Core 1 (Instruction Decode / Dispatcher) & Multi-EX Router (`Proposal 04`).
* **Behavior:** Preceding a multi-cycle operation (e.g., `DIV`, `MOD`, or an `XTRA` coprocessor sequence), instructs Core 1's issue logic to route the operation immediately to **Core 2B** (Math/DSP worker) rather than queuing it behind single-cycle ALU instructions on **Core 2A**.
* **Fallback:** Ignored on single-EX clusters; executes normally.

#### `0x01` — `HINT.INDEP` (Scoreboard Hazard Bypass)
* **Target:** Core 1 / SARF Reservation Scoreboard (`Proposal 02` & `04`).
* **Behavior:** Signals that the compiler or JIT emitter has statically verified that the next 4 instructions have **zero Read-After-Write (RAW) dependencies** on currently in-flight `regBusy[31:0]` entries. Core 1 may issue tokens at peak rate without inserting scoreboard verification wait states.
* **Safety Rule:** Software must **never** emit `HINT.INDEP` if any source operand in the subsequent 4 instructions depends on an unretired destination register.

#### `0x02` — `HINT.STREAM` (Sequential Cache-Line Prefetch)
* **Target:** Core 3 (MEM) & Split-Transaction Memory Crossbar (`Proposal 06`).
* **Behavior:** Preceding a strided or post-increment load (`LD32 (Rl++)`), advises the L1 cache controller to issue a low-priority background burst refill for the subsequent cache line (`(addr & ~0x1F) + 32`) if it is not already resident in the tag directory.
* **Benefit:** Overlaps the 35–55 cycle SDRAM burst transfer with loop computation.

#### `0x03` — `HINT.BYPASS` (Non-Temporal / Cache-Bypass Access)
* **Target:** Core 3 (MEM) & Unified L1 Data Cache (`Proposal 06`).
* **Behavior:** Preceding `LD32` or `ST32`, indicates that the accessed data exhibits low temporal locality (e.g., framebuffer blits, `memset`/`memcpy` buffers, or Conductor DMA staging). On a cache miss, the crossbar performs a direct word/burst transaction without evicting existing hot L1 lines.

#### `0x04` — `HINT.PAUSE` (Spinlock & Polling Backoff)
* **Target:** Memory Crossbar Arbiter, Port B Mux, & FIFO Subsystem.
* **Behavior:** Placed inside `TAS` atomic spinlock loops or `FIFO.STAT` busy-wait loops. Causes the core's FSM to insert a configurable backoff delay (e.g., 4–8 idle cycles) before re-issuing Port B or FIFO status reads, freeing memory and interconnect bandwidth for the worker core holding the lock or producing FIFO data.

#### `0x05` — `HINT.HOT` (Immediate JIT Hotspot Promotion)
* **Target:** Core 0 Branch Frequency Table (BFT) & Tiered JIT (`Proposal 08`).
* **Behavior:** Emitted at the entry header of a known hot loop or latency-critical routine. When Core 0 encounters `HINT.HOT`, it immediately sets the BFT entry's `trip_count` to `HOTSPOT_THRESHOLD` and fires `MBOX Vector 2` (`Hotspot Detected`) to Core 1, eliminating the 32–64 iteration cold-interpreter warmup penalty.

---

## 5. Toolchain & HDL Implementation Plan

### 5.1. Assembler Support (`tools/pasm.py`)
Add first-class support for `HINT` in `pasm.py` using both numeric and mnemonic forms:

```assembly
; Numeric immediate form
HINT    0x02                ; Encodes as 0xFE02

; Mnemonic / Pseudo-op forms
HINT.HEAVY                  ; Encodes as 0xFE00
HINT.INDEP                  ; Encodes as 0xFE01
HINT.STREAM                 ; Encodes as 0xFE02
HINT.BYPASS                 ; Encodes as 0xFE03
HINT.PAUSE                  ; Encodes as 0xFE04
HINT.HOT                    ; Encodes as 0xFE05
```

### 5.2. ROHD Hardware Changes

1. **`hdl/rohd/lib/constants.dart`:**
   * Add `static const int hint = 0xFE;` to `ParticleOpcodes`.
   * Define `ParticleHints` constants (`heavy = 0x00`, `indep = 0x01`, `stream = 0x02`, `bypass = 0x03`, `pause = 0x04`, `hot = 0x05`).
2. **`hdl/rohd/lib/cpu_core.dart`:**
   * Add `CaseItem(Const(ParticleOpcodes.hint, width: 8), [...])` to the main execution `Case` statement:
     * Default behavior: `pc < pc + 2` (1-cycle `NOP` in `stateExec`).
     * Optional backoff counter when `imm8 == ParticleHints.pause`.
   * Expose optional sideband outputs `hintValid` (1-bit) and `hintCode` (8-bit, wired to `inst.slice(7, 0)`) when `opcode == 0xFE` so wrapper modules in `parcore_top.dart` can snoop hints cleanly without modifying core datapath logic.
3. **`hdl/parcore/lib/parcore_top.dart` & `parcore_interconnect.dart`:**
   * Connect `core0.hintValid` / `core0.hintCode` to the BFT hotspot trigger (`0x05`).
   * Connect `core1.hintValid` / `core1.hintCode` to the Multi-EX router (`0x00`) and SARF scoreboard bypass (`0x01`).
   * Connect `core3.hintValid` / `core3.hintCode` to the crossbar prefetch/non-temporal request flags (`0x02`, `0x03`).

---

## 6. Verification Plan

1. **ISA & Single-Core Regression (`hdl/rohd/test/`):**
   * Verify `0xFE00`–`0xFEFF` execute as exact `NOP`s on standalone `ParticleCpuCore` with zero register or flag side effects.
   * Verify `pasm.py` assembles both `HINT <imm8>` and `HINT.<MNEMONIC>` syntax into the expected `0xFE<imm8>` halfwords.
2. **Parcore Cluster Co-Simulation (`hdl/parcore/test/`):**
   * Confirm lockstep golden-trace parity (`Proposal 03` Commit Log Bus) on RV32IM benchmarks compiled with and without `HINT` annotations.
   * Measure cycle-count deltas for:
     * `HINT.STREAM` + `HINT.BYPASS` on sequential SDRAM array copies.
     * `HINT.HEAVY` on mixed `DIVU` + integer ALU workloads.
     * `HINT.HOT` on tight inner loops under Tiered JIT execution.