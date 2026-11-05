# Parcore Multi-EX & Dynamic Out-of-Order Architecture Proposal

## 1. Executive Summary & Dependency Declaration

This proposal outlines the architectural specification and phased implementation roadmap for extending the **Parcore** cluster with **Heterogeneous Multiple Execution Units (Multi-EX)** and **Scoreboarded Dynamic Out-of-Order (OoO) Dispatch**.

### Dependency Declaration
This document directly **depends on and extends** the foundational optimizations established in:
> `docs/parcore_performance_proposal.md` (*Parcore Cluster Performance Optimization Proposal*)

Specifically, this architecture assumes the following prerequisites from the previous proposal are either concurrently deployed or established as baseline interfaces:
1. **Tier 3.5: Out-of-Band Shared Architectural Register Fabric (SARF):** The 32-entry $\times$ 32-bit multi-port distributed LUT-RAM with hardwired $x0$, collision arbitration, and zero-cycle write-to-read forwarding.
2. **Tier 3.2: Pre-Decode Classification RAM (`UNPACK`):** Front-end accelerated bit-slicing and opcode classification.
3. **Tier 3.1: Stream Windowing Primitives (`FIFO.PEEK` & `FIFO.ADV`):** Non-destructive instruction header inspection.
4. **Tier 2.1 & 2.2: Synchronous FIFO Flushing and Hardware Branch Target Latching:** Fast control redirection directly from execution units back to Core 0 (IF).

By building on top of the SARF and Classification Front-End, this design transforms Parcore from a single-issue, in-order emulated pipeline into an **agile spatial compute fabric** capable of hiding multi-cycle math latency (DSP multiplication, 34-cycle division) and memory access stalls.

---

## 2. Architectural Motivation: The In-Order Latency Wall

In the baseline in-order 4/5-stage Parcore pipeline:
* A single execution core (`Core 2: EX`) processes all ALU, branch, shift, DSP multiplication, and multi-cycle division operations.
* When a 34-cycle unsigned division (`DIVU x10, x11, x12`) enters Core 2, the inbound FIFO (`idToEx`) fills up immediately.
* Core 1 stalls on `FIFO.W` backpressure, completely freezing the dispatch of subsequent independent single-cycle operations (such as `ADDI x1, x1, 1`).
* Similarly, memory loads requiring cache line refills or external SDRAM access via Core 3 (MEM) stall all upstream execution.

### Architectural Solution
1. **Decouple Functional Units across Multiple Cores:** Dedicate independent Particle cores to separate execution domains (Integer ALU/Branch vs. Multi-cycle Math/DSP vs. Address Generation/Memory).
2. **Dynamic Scoreboarded Dispatch:** Utilize the SARF's centralized register busy scoreboard to dispatch ready instructions out-of-order to whichever execution unit is free, retiring results directly into the SARF as functional units finish.

---

## 3. System Topology & Functional Unit Allocation

The enhanced cluster reorganizes the execution stage into specialized cores communicating with Core 1 (Dispatch) and Core 0 (IF) over point-to-point queues and the out-of-band SARF.

```
                         ┌─────────────────────────────────────────────────────────┐
                         │       Shared Architectural Register Fabric (SARF)       │
                         │   - Multi-Read Ports: Rs1/Rs2 per EX Core               │
                         │   - Multi-Write Ports with Arbitration & Bypass         │
                         │   - Hardware Register Busy / Reservation Scoreboard     │
                         └───────▲──────────▲──────────▲───────────────▲───────────┘
                                 │          │          │               │
                                 │ Read     │ Read/Wr  │ Read/Wr       │ Read/Wr
                                 │          │          │               │
┌──────────────┐      ┌──────────┴───┐      │          │               │
│   Core 0     ├──FIFO┤    Core 1    ├──────┼──────────┼───────────────┤
│ (IF & UART)  │      │  (Dispatch / │      │          │               │
└──────▲───────┘      │  Scheduler)  │      │          │               │
       │              └──────┬───────┘      │          │               │
       │                     │              │          │               │
       │       ┌─────────────┼──────────────┘          │               │
       │       │             │                         │               │
       │       │ FIFO (ALU)  │ FIFO (Math)             │ FIFO (AGU/Mem)│
       │       ▼             ▼                         ▼               │
       │ ┌───────────┐ ┌───────────┐             ┌───────────┐         │
       │ │  Core 2A  │ │  Core 2B  │             │  Core 3   │         │
       │ │  (Int/Br) │ │ (DSP/Div) │             │  (AGU/Mem)│         │
       │ └─────┬─────┘ └─────┬─────┘             └─────┬─────┘         │
       │       │             │                         │               │
       └───────┴─────────────┴─────────────────────────┴───────────────┘
                      Branch Redirect / Trap Feedback Network
```

### Core Allocation & Responsibilities

| Core | Architectural Role | Hardware Configuration (`CpuConfig`) | Inbound Queues | Direct SARF Ports |
| :--- | :--- | :--- | :--- | :--- |
| **Core 0** | **Instruction Fetch & UART** | `enableMultiplier: false`<br>`enableDivider: false`<br>`ulx3sUartFifoChannel: 0` | MBOX Strobe (Redirect)<br>UART RX | None |
| **Core 1** | **Dynamic Dispatch & Scheduler** | `enableMultiplier: false`<br>`enableDivider: false`<br>Classification Table Attached | `ifToId` FIFO (Core 0)<br>Retirement Events | Read Busy Bitmask<br>Set Busy Bit ($R_d$) |
| **Core 2A** | **Integer ALU & Branch Unit** | `enableMultiplier: false`<br>`enableDivider: false` | `idToExA` FIFO (from Core 1) | Port A Read ($Rs1, Rs2$)<br>Port A Write ($R_d$ Commit) |
| **Core 2B** | **DSP Math & Multi-Cycle Unit** | `enableMultiplier: true`<br>`enableDivider: true` | `idToExB` FIFO (from Core 1) | Port B Read ($Rs1, Rs2$)<br>Port B Write ($R_d$ Commit) |
| **Core 3** | **AGU & Memory Gateway** | `enableMultiplier: false`<br>`enableDivider: false`<br>Direct Port B TCM / Cache MMIO | `idToMem` FIFO (from Core 1) | Port C Read ($Rs1, Rs2$)<br>Port C Write ($R_d$ Commit) |

---

## 4. Hardware Enhancements (ROHD HDL)

### 4.1. SARF Scoreboard & Busy Bit Hardware Extension
The `SharedRegFabric` module (`hdl/rohd/lib/shared_reg_fabric.dart`) is augmented with a 32-bit hardware register reservation mask:

* **Busy Bit Register (`regBusy[31:0]`):**
  * Bit 0 is permanently tied to `0` ($x0$).
  * Bits 1–31 indicate an in-flight destination register reservation.
* **Dispatch Interface (Core 1):**
  * `sarfScoreboardMask [31:0]` output driven combinationally to Core 1.
  * `sarfReserveRdAddr [4:0]` and `sarfReserveEn` input strobes: Sets bit `Rd` in `regBusy` on instruction issue.
* **Retirement Interface (Core 2A, Core 2B, Core 3):**
  * Whenever an EX or MEM unit asserts writeback (`sarfWrEn` for its port), the hardware clears `regBusy[sarfWrAddr]`.
  * If a concurrent dispatch and retirement target the same register index, the writeback takes precedence or priority rules maintain correct state.

### 4.2. Top-Level Multi-EX Interconnect (`parcore_interconnect.dart`)
Replace single `idToEx` FIFO with three independent point-to-point queues:
1. `idToExA` (Width: 32, Depth: 8–16): Channels single-cycle integer ALU ops and branches to Core 2A.
2. `idToExB` (Width: 32, Depth: 8–16): Channels RV32M multiply, divide, and remainder operations to Core 2B.
3. `idToMem` (Width: 32, Depth: 8–16): Channels loads, stores, and fence operations to Core 3.

### 4.3. Multi-Port Writeback Arbiter
The SARF integrates a 3-way write arbiter (Core 2A, Core 2B, Core 3) with prioritized write-to-read forwarding:
* Priority ordering for write conflicts: **Core 3 (Mem)** > **Core 2B (Math)** > **Core 2A (ALU)** (configurable).
* Any active write port immediately forwards its data combinationally to any read port currently requesting that register address.

---

## 5. Firmware & Microkernel Specification

### 5.1. Core 1 Dynamic Scheduler Microkernel (`core1_dispatch.asm`)
Core 1 ceases to execute arithmetic and instead operates as an instruction scheduler:

1. **Stream Peek & Pre-Decode:**
   * Reads opcode, $Rs1$, $Rs2$, and $R_d$ from the front-end classification RAM using `FIFO.PEEK`.
2. **Hazard Check (Scoreboard Interlock):**
   * Inspects `sarfScoreboardMask`.
   * Checks if `(scoreboardMask & (1 << Rs1)) != 0` or `(scoreboardMask & (1 << Rs2)) != 0`.
   * If operands are busy: Core 1 holds the queue without popping, waiting for retirement.
   * If operands are clear:
     * Dispatches micro-op token to the appropriate queue (`FIFO.W -> idToExA`, `idToExB`, or `idToMem`).
     * Asserts `sarfReserveEn` for $R_d$ (if $R_d \ne x0$).
     * Advances stream pointer via `FIFO.ADV`.

### 5.2. Core 2A Microkernel: Integer ALU & Branch Evaluation (`core2a_alu.asm`)
* Pops from `idToExA`.
* Directly reads $Rs1$ and $Rs2$ from SARF Port A.
* Evaluates ALU operations or branch conditions.
* On Branch Taken:
  * Emits hardware `c2MboxStrobe` directly to Core 0 (IF) with target PC.
  * Hardware resets `idToExA`, `idToExB`, and `idToMem` FIFOs.
  * Core 1's hardware scoreboard mask is reset to `0x00000000`.
* On Completion: Writes $R_d$ to SARF Port A, which automatically releases the scoreboard reservation bit in hardware.

### 5.3. Core 2B Microkernel: DSP Multiplication & Division (`core2b_math.asm`)
* Pops from `idToExB`.
* Directly reads $Rs1$ and $Rs2$ from SARF Port B.
* Dispatches `MULL`, `MULH`, `SMULH`, `DIV`, `DIVU`, `MOD`, `MODU` utilizing Particle's hardware DSP and multi-cycle divider.
* On Completion: Writes $R_d$ to SARF Port B and releases scoreboard reservation bit.
* **Key Non-Blocking Feature:** While Core 2B is computing a 34-cycle division, Core 1 and Core 2A continue processing independent integer instructions concurrently.

### 5.4. Core 3 Microkernel: Memory Access Engine (`core3_mem.asm`)
* Pops memory operations from `idToMem`.
* Reads Base address $Rs1$ and Store Data $Rs2$ from SARF Port C.
* Executes load/store transactions against TCM / Cache MMIO.
* On Load Completion: Writes read data to SARF Port C ($R_d$), releasing the scoreboard lock.

---

## 6. Staged Implementation Roadmap

To maintain verification discipline and avoid breaking regression suites, implementation is partitioned into **four discrete stages**:

```
┌────────────────────────────────────────────────────────────────────────┐
│ Stage 1: Dual-EX Interconnect & Scoreboard Hardware Foundation        │
│   - Add 32-bit hardware reservation mask to SharedRegFabric (ROHD).    │
│   - Split idToEx into idToExA and idToExB in parcore_interconnect.     │
│   - Unit test scoreboard bit set/clear & forwarding in isolation.      │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Stage 2: Integer / Math Stage Separation (Core 2A & Core 2B)          │
│   - Create core2a_alu.asm and core2b_math.asm microkernels.           │
│   - Update core1_dispatch.asm to route RV32M to 2B and ALU to 2A.      │
│   - Verify concurrent execution: DIV in 2B overlapping with ADDs in 2A.│
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Stage 3: Out-of-Order Memory Decoupling (Core 3 AGU / Direct SARF)     │
│   - Connect Core 3 directly to SARF Port C.                            │
│   - Route memory ops directly from Core 1 to Core 3 via idToMem.       │
│   - Validate load-use hazard interlocks and independent ALU overlap.   │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Stage 4: Dynamic Reordering & Precise Exception Recovery              │
│   - Integrate synchronous branch/trap FIFO flush across all queues.   │
│   - Scoreboard rollback logic on branch mispredictions / Trap 14.     │
│   - Full RV32IM_Zbb compliance suite regression.                       │
└────────────────────────────────────────────────────────────────────────┘
```

### Stage 1: Dual-EX Interconnect & Scoreboard Hardware Foundation
* **Objective:** Prepare the hardware datapath without altering existing microkernel functionality.
* **Deliverables:**
  * Update `hdl/rohd/lib/shared_reg_fabric.dart`: Implement `regBusy[31:0]`, `reserveRd`, and auto-clear on writeback.
  * Update `hdl/parcore/lib/parcore_interconnect.dart`: Add `idToExA` and `idToExB` FIFO channels.
  * Unit tests: `test/sarf_scoreboard_test.dart` validating multi-port collisions, reservations, and bypass paths.

### Stage 2: Integer / Math Stage Separation (Core 2A & Core 2B)
* **Objective:** Enable parallel execution of single-cycle ALU and multi-cycle math instructions.
* **Deliverables:**
  * Implement `firmware/parcore/riscv/core2a_alu.asm` and `core2b_math.asm`.
  * Update `firmware/parcore/riscv/core1_dispatch.asm` to check `regBusy` and dispatch to Channel 1 (ALU) or Channel 2 (Math).
  * Test: Verify that a loop containing interleaved `DIV` and `ADD` operations executes without stalling the integer instructions.

### Stage 3: Out-of-Order Memory Decoupling (Core 3 AGU / Direct SARF)
* **Objective:** Allow execution cores to complete without routing non-memory tokens through Core 3.
* **Deliverables:**
  * Rewire Core 3 in `parcore_top.dart` to read and write directly to SARF Port C.
  * Decouple memory loads/stores so Core 1 dispatches them straight to Core 3.
  * Verify memory writeback clears the scoreboard and unblocks dependent downstream ALU ops.

### Stage 4: Dynamic Reordering & Precise Exception Recovery
* **Objective:** Guarantee clean pipeline recovery during taken branches, jumps, and memory misalignments (Trap 14).
* **Deliverables:**
  * Route Core 2A branch strobe to synchronously flush all three dispatch queues (`idToExA`, `idToExB`, `idToMem`) and reset the SARF busy bitmask.
  * Execute the full `parcore_rv32_pipeline_test.dart` and architectural compliance benchmarks.

---

## 7. Resource & Performance Projections (Lattice ECP5-85F)

| Metric | Baseline 5-Stage Cluster | Proposed Multi-EX OoO Cluster | Delta / Impact |
| :--- | :--- | :--- | :--- |
| **Active Core Count** | 5 Cores (`IF, ID, EX, MEM, WB`) | 5–6 Cores (`IF, ID, 2A, 2B, 3, [CC]`) | Neutral (Repurposed Core 4) |
| **Logic Utilization (LUT4)** | ~14,000–16,000 LUT4s | ~16,500–19,000 LUT4s | +10–15% (SARF ports & arbiter) |
| **DSP Slices Allocated** | 4 DSPs (Allocated to Core 2) | 4 DSPs (Dedicated to Core 2B) | **Zero DSP change** |
| **BRAM / EBR Blocks** | 12–14 EBRs | 12–14 EBRs | Neutral |
| **Single-Cycle ALU Latency**| 14–18 native cycles per inst | 3–5 native cycles per inst | **~3.5× Faster** |
| **Math Interlock Stall** | Complete pipeline freeze | Zero stall for independent ops | **Complete latency hiding** |
| **Effective Cluster IPC** | $\approx 0.06 – 0.08$ (4–6 MIPS) | **$\approx 0.22 – 0.35$ (18–28 MIPS)** | **~3.5× to 4.5× Throughput** |