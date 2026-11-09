# Architectural Proposal: Autonomous Accelerator & Functional Extension Subsystem in Parcore

**Document ID:** RFC-PARCORE-2026-EXT01  
**Target Architecture:** Parcore Distributed Spatial Multi-Core / Particle ISA  
**Status:** Draft / Proposed  

---

## 1. Executive Summary

As the Parcore architecture matures beyond base integer emulation (RV32I) into complex computational domains—such as IEEE 754 floating-point arithmetic (Single/Double precision), vector processing, DSP transforms, and cryptographic accelerators—the architectural mechanism used to express, dispatch, and execute these operations must be finalized.

Due to Particle’s compact **16-bit fixed-length instruction format**, instruction opcode space is limited. Adding numerous multi-operand mathematical instructions directly to the base 8-bit opcode space is infeasible. Furthermore, a traditional monolithic coprocessor model (where an auxiliary execution unit stalls the primary pipeline or requires private register files and copy instructions) violates Parcore’s decoupled spatial philosophy.

This proposal specifies a unified hardware and firmware architecture:
1. **Instruction Surface:** A **32-bit Escaped Instruction (`XTRA` / `0xFF`)** that preserves 16-bit density for scalar operations while providing an extensible 16-bit payload for sub-opcodes, rounding modes, and 3-operand register specifiers.
2. **Execution Substrate:** Replacing the traditional synchronous coprocessor sidecar with an **Autonomous Heterogeneous Worker Core (`Core 2B` / `Core 2C`)**.
3. **Decoupled Dataflow & Synchronization:** Work dispatching over point-to-point **Streaming FIFOs** combined with direct operand access and out-of-band writeback via the **Shared Architectural Register Fabric (SARF)** and hardware scoreboarding.

---

## 2. The Architectural Dilemma: Coprocessor vs. Spatial Worker Core

### 2.1 The Limits of the Classic Coprocessor Model
Traditional microprocessor architectures (e.g., MIPS Coprocessor 1/2, RISC-V `F`/`D` sidecars, x87) bind coprocessors tightly to an integer core's datapath:
* **Synchronous Pipeline Freezes:** Multi-cycle instructions (e.g., non-restoring division, square root, transcendentals) assert stall lines directly back to the instruction fetch and decode logic, halting integer throughput.
* **Redundant Register Files:** Coprocessors typically introduce private register files ($f_0$–$f_{31}$), necessitating explicit cross-domain data movement instructions (`MTC1`, `MFC1`, `FMV.W.X`), which increases register file pressure and instruction count.
* **Centralized Dependency Tracking:** In a spatially distributed cluster like Parcore, pipeline stages already live on separate physical cores (Core 0 = IF, Core 1 = ID, Core 2 = EX, Core 3 = MEM). A monolithic coprocessor tied to Core 1 or Core 2 breaks stage boundaries.

### 2.2 The Parcore Solution: Autonomous Worker Engine
In Parcore, an accelerator or FPU is treated as an **autonomous execution worker core** operating on the **Shared Architectural Register Fabric (SARF)**:

```
                            ┌──────────────────────────────────────────────┐
                            │ Shared Architectural Register Fabric (SARF)  │
                            │  - 32-bit / 64-bit multi-ported data fabric  │
                            │  - Synchronous / combinational bypass paths  │
                            └───────▲──────────────▲──────────────▲────────┘
                                    │              │              │
                               SARF │         SARF │         SARF │
                               Port │         Port │         Port │
┌───────────┐      ┌─────────────┐  │ ┌──────────┐ │ ┌──────────┐ │ ┌──────────┐
│  Core 0   ├──FIFO┤   Core 1    ├──┴►│ Core 2A  ├─┴►│ Core 2B  ├─┴►│ Core 2C  │ (Heterogeneous
│  (Fetch)  │      │ (ID/Sched)  ├───►│ (Int ALU)│   │  (FPU)   │   │  (DSP)   │  Worker Cores)
└───────────┘      └─────────────┘    └────┬─────┘   └────┬─────┘   └────┬─────┘
                                           │              │              │
                                           └──────────────┼──────────────┘
                                                          ▼
                                                   To MEM / Retire
```

Under this model:
* Core 1 acts as an instruction classifier and non-blocking task scheduler.
* Core 2B (FPU/Extension) receives work tokens via streaming FIFOs.
* Operands are read directly from the SARF, and completed values are committed directly back to the SARF.
* Hazard mitigation is completely non-blocking: Core 1 marks destination registers as **Busy** in a hardware scoreboard. Standard integer operations continue executing on Core 2A in parallel unless an explicit Read-After-Write (RAW) dependency exists.

---

## 3. Instruction Encoding: 32-Bit Escaped Prefix (`XTRA`)

To prevent consuming base 8-bit opcodes for mathematical extensions, Parcore designates **Opcode `0xFF` (`XTRA`)** as a 2-word (32-bit) instruction escape.

### 3.1 Two-Halfword Bit Layout
When Core 0 (IF) or Core 1 (ID) encounters `0xFF` in bits [15:8] of the first fetched word, the core advances the Program Counter by 4 bytes ($PC \leftarrow PC + 4$) and decodes the subsequent 16-bit word as the second half of the instruction token:

```
Halfword 0 (Fetch Address PC + 0):
 15                         8 7            4 3            0
┌────────────────────────────┬──────────────┬──────────────┐
│        XTRA (0xFF)         │ Extension ID │ Sub-Opcode A │
└────────────────────────────┴──────────────┴──────────────┘

Halfword 1 (Fetch Address PC + 2):
 15             12 11       8 7            4 3            0
┌─────────────────┬──────────┬──────────────┬──────────────┐
│  Sub-Opcode B   │    Rd    │     Rs1      │  Rs2 / Imm4  │
└─────────────────┴──────────┴──────────────┴──────────────┘
```

#### Field Definitions:
* **`XTRA` (Bits [31:24], 8 bits):** Constant prefix `0xFF`. Signals a 32-bit coprocessor/extension instruction.
* **Extension ID (Bits [23:20], 4 bits):** Identifies the target hardware accelerator / worker core:
  * `0x0`: System / Custom Accelerator Control
  * `0x1`: IEEE 754-2019 Single-Precision FPU (float32)
  * `0x2`: IEEE 754-2019 Double-Precision FPU (float64)
  * `0x3`: Vector / SIMD Engine
  * `0x4`: Cryptography Engine (AES, SHA-256)
  * `0x5`–`0xF`: Reserved / User Defined
* **Sub-Opcode [A:B] (Bits [19:16] & [15:12], 8 bits total):** Specifies the distinct operation (e.g., `FADD`, `FSUB`, `FMUL`, `FDIV`, `FSQRT`, `FCVT`, `FCMP`).
* **`Rd` (Bits [11:8], 4 bits):** Destination architectural register index (expands to 5 bits via RBASE or SARF high-bank mapping).
* **`Rs1` (Bits [7:4], 4 bits):** First source operand index.
* **`Rs2 / Imm4` (Bits [3:0], 4 bits):** Second source operand index or auxiliary parameter (rounding mode, sign manipulation).

---

## 4. Hardware Implementation Flexibility for Core 2B

Because Core 2B communicates exclusively over a standard **FIFO interface** (inbound micro-ops) and a standard **SARF port** (operand access & commit), Parcore supports multiple modular implementations for Core 2B without modifying the rest of the CPU cluster.

```
+------------------------------------------------------------------------+
|                             PARCORE TOP                                |
|                                                                        |
|  +--------------------+        Dispatch FIFO                           |
|  | Core 1 (ID/Sched)  |============================+                   |
|  +--------------------+                            |                   |
|                                                    v                   |
|                   ==================================================   |
|                   IMPLEMENTATION OPTIONS FOR CORE 2B                   |
|                   ==================================================   |
|                                                                        |
|   [Option 1: Firmware-Driven Particle Core]                            |
|   - ParticleCpuCore running math microkernel                           |
|   - Executes software IEEE 754 loops in local TCM                      |
|                                                                        |
|   [Option 2: Specialized Particle Core with Hardware FPU/DSP]          |
|   - Particle core sequencer augmented with ROHD FPU blocks             |
|   - Low cycle latency, standard trap/state-machine support             |
|                                                                        |
|   [Option 3: Heterogeneous Third-Party Core (MR4 RISC Core)]           |
|   - 16-bit MR4 CPU attached directly to FIFO + SARF ports              |
|   - Reuses existing MR4 math libraries and DSP code                    |
|                                                                        |
|   [Option 4: Pure Hardware Accelerator Engine (RTL / FSM)]             |
|   - Zero-instruction state machine in ROHD                             |
|   - Directly latches FIFO tokens, controls DSP slices, commits to SARF |
|                                                                        |
|                   ==================================================   |
|                                                    |                   |
|  +--------------------+       SARF Write Port      |                   |
|  | SARF Storage &     |<===========================+                   |
|  | Scoreboard Mask    |                                                |
|  +--------------------+                                                |
+------------------------------------------------------------------------+
```

### 4.1 Option 1: Standard Particle Core Running Microcode
* **Architecture:** A standard `ParticleCpuCore` with an isolated 4 KB TCM.
* **Execution:** Core 2B executes an assembly loop (`core2b_fpu.asm`). It pops tokens, extracts operands from its SARF read port, runs multi-word software math algorithms, and writes the computed result to the SARF.
* **Trade-off:** High cycle count per operation, but zero additional FPGA DSP/hard-math logic. Excellent for simulation bring-up and complex functions (trigonometry, division).

### 4.2 Option 2: Specialized Particle Core (Integrated Hardware FPU)
* **Architecture:** A `ParticleCpuCore` configured via `ParcoreConfig` with custom execution units replacing or augmenting `ParticleAlu`.
* **Execution:** The core's execution stage invokes dedicated ROHD IEEE 754 adder and multiplier pipelines.
* **Trade-off:** Retains standard instruction-driven control flow while accelerating math down to 1–4 cycles.

### 4.3 Option 3: Heterogeneous Third-Party Core (MR4 Integration)
* **Architecture:** An MR4 RISC core instantiated in place of Core 2B.
* **Execution:** MR4's native FIFO streaming semantics match Particle's FIFO subsystem. MR4 executes math routines natively, writing results to the SARF via its Port B bus.
* **Trade-off:** Reuses mature codebases and routines already validated on MR4.

### 4.4 Option 4: Pure Hardware State Machine / Direct Execution Pipeline
* **Architecture:** Core 2B contains **no instruction sequencer, no PC, and no TCM Block RAM**. It is a pure hardware FSM written in ROHD.
* **Execution:** 
  1. A token arriving in `id_to_ext_fifo` immediately triggers the FSM.
  2. The FSM latches the token, pulls $R_{s1}$ and $R_{s2}$ from SARF ports within 1 cycle, and feeds hardware DSP slices.
  3. Upon calculation completion, it asserts `sarfRdWe`, drives `sarfRdAddr` and `sarfRdData`, and drops the SARF scoreboard busy flag.
* **Trade-off:** Lowest possible cycle latency, highest energy efficiency, and minimal logic footprint.

---

## 5. Token Protocol & FIFO Dispatch Specification

When Core 1 decodes an `0xFF` escaped instruction, it packs and pushes a single 32-bit dispatch token over the dedicated extension FIFO (`id_to_c2b_fifo`):

### 5.1 Token Data Format
```
 31         28 27       24 23       16 15       10 9       5 4       0
┌─────────────┬───────────┬───────────┬───────────┬─────────┬─────────┐
│ Ext ID (4b) │ Flags/Rnd │ Sub-Op(8b)│  Reserved │ Rs2(5b) │ Rs1(5b) │
└─────────────┴───────────┴───────────┴───────────┴─────────┴─────────┘
```
*(Accompanying metadata word transmits Destination Register $R_d$ [4:0] and operation tag).*

### 5.2 Handshake Sequence
1. **Core 1 (Dispatch):**
   * Inspects the SARF scoreboard.
   * If registers $R_{s1}$ or $R_{s2}$ are marked **Busy**, Core 1 holds dispatch until the producing functional unit clears the flag.
   * Marks $R_d$ as **Busy** in the SARF scoreboard mask.
   * Pushes the token to Core 2B via `fifoPushEn`.
   * Continues to decode the next instruction immediately (non-blocking issue).
2. **Core 2B (Accelerator / FPU):**
   * Monitors `fifoPopEmpty`. When non-empty, asserts `fifoPopEn`.
   * Latches the token, asserts `sarfRs1Addr` and `sarfRs2Addr`, and receives source operands combinationally.
   * Computes the result (1 to $N$ cycles).
   * Drives the writeback port:
     * `sarfRdAddr <= token.rd;`
     * `sarfRdData <= computedResult;`
     * `sarfRdWe <= 1'b1;`
   * Signals the SARF scoreboard to release the **Busy** bit on register $R_d$.

---

## 6. Scoreboard & Hazard Management in SARF

To maintain sequential program consistency while executing out-of-order across Core 2A (Integer ALU) and Core 2B (Accelerator), the SARF hardware incorporates a **32-bit Scoreboard Mask**:

```dart
// Conceptual Hardware Scoreboard Logic within SharedRegFabric
final scoreboardBusy = Logic(name: 'scoreboard_busy', width: 32);

Sequential(clk, reset: reset, resetValues: {
  scoreboardBusy: Const(0, width: 32),
}, [
  // Issue Stage: Mark Rd as busy when dispatched by Core 1
  If(core1DispatchExtEn & (core1RdAddr.neq(Const(0, width: 5))), then: [
    scoreboardBusy < (scoreboardBusy | (Const(1, width: 32) << core1RdAddr)),
  ]),
  // Writeback Stage: Clear Rd when Core 2B commits
  If(core2bCommitEn & (core2bRdAddr.neq(Const(0, width: 5))), then: [
    scoreboardBusy < (scoreboardBusy & ~(Const(1, width: 32) << core2bRdAddr)),
  ]),
]);
```

* If an incoming integer instruction on Core 1 requires an operand where `scoreboardBusy[Rs] == 1`, Core 1 pauses issuing to Core 2A.
* Unrelated instructions (operating on non-busy registers) execute with zero stall cycles, achieving true latency hiding for multi-cycle accelerator operations.

---

## 7. Comparative Assessment Matrix

| Metric | MMIO Register Interface | Closely-Coupled Core Coprocessor | Parcore Autonomous Worker Core (Proposed) |
| :--- | :--- | :--- | :--- |
| **Instruction Footprint** | Zero base ISA changes (Uses standard `LD`/`ST`) | Consumes precious 8-bit opcodes in 16-bit space | Uses a single 8-bit escape (`0xFF`), providing clean 16-bit extension space |
| **Call Latency** | 4–8 cycles (Address generation, stores, loads) | 1 cycle issue | 1 cycle issue via streaming FIFO |
| **Pipeline Interlock** | Software polling or interrupt handling | Freezes Core execution stage (Pipeline stall) | Decoupled non-blocking dispatch; SARF scoreboard stalls only on true RAW dependencies |
| **Register Pressure** | Requires burning integer registers for addresses | Dedicated private register file (requires move instructions) | Direct read/write access to unified 32-bit architectural registers |
| **Modularity & Reuse** | Tied to memory crossbar / bus fabric | Hardwired into ALU datapath logic | Worker core can be swapped (Particle, MR4, or pure RTL FSM) without pipeline redesign |

---

## 8. Implementation Roadmap

1. **Phase 1: Toolchain & Instruction Definition**
   * Assign `0xFF` as `XTRA` in `hdl/rohd/lib/constants.dart`.
   * Update assembler (`tools/pasm.py`) to recognize 2-word syntax:
     ```assembly
     XTRA.F32  FADD, R4, R2, R1     ; Escaped float add: R4 = R2 + R1
     XTRA.F32  FMUL, R6, R4, R3     ; Escaped float mul: R6 = R4 * R3
     ```
2. **Phase 2: SARF Scoreboard Extension**
   * Add the 32-bit `busyMask` tracking register to `hdl/rohd/lib/shared_reg_fabric.dart`.
   * Route scoreboard status lines to Core 1 hazard detection logic.
3. **Phase 3: Top-Level Integration (`ParcoreTop`)**
   * Instantiate Core 2B in `parcore_top.dart`.
   * Connect `id_to_c2b` FIFO channel in `ParcoreInterconnect`.
   * Wire Core 2B read/write ports into SARF Port 2.
4. **Phase 4: Prototyping Accelerator Blocks**
   * Implement Option 1 (Particle firmware math microkernel) to validate dispatch and synchronization.
   * Synthesize Option 4 (direct ROHD hardware FSM) for high-performance IEEE 754 single-precision benchmarks.