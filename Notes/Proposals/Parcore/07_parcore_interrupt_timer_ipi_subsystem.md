# Parcore Architecture Proposal 07: Unified Interrupt Architecture, Real-Time Timer & Inter-Processor Interrupt (IPI) Subsystem

**Document ID:** ARCH-PROP-07  
**Status:** Proposed  
**Target Platform:** Lattice ECP5-45F / ECP5-85F (ULX3S)  
**Hardware Description:** Intel ROHD (Dart)  

---

## 1. Executive Summary & Dependency Declaration

### Dependency Declaration
This proposal represents **Tier 07** of the Parcore architecture roadmap and directly **depends on and extends**:
1. **`01_the_parcore_conductor_architecture_proposal.md` (`ARCH-PROP-01`)**: Provides supervisor reset management and Conductor peripheral bus arbitration.
2. **`02_parcore_cluster_performance_optimization_proposal.md` (`ARCH-PROP-02`)**: Implements the Shared Architectural Register Fabric (SARF), MBOX cross-core strobing, and synchronous FIFO flushes.
3. **`03_parcore_verification_golden_trace_co_simulation_suite.md` (`ARCH-PROP-03`)**: Provides the architectural retirement commit bus for lockstep verification of interrupt traps.
4. **`04_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md` (`ARCH-PROP-04`)**: Implements heterogeneous functional units (Core 2A ALU, Core 2B DSP/Div, Core 3 AGU) and scoreboarded dynamic issue.
5. **`05_parcore_autonomous_accelerator_coprocessor_architecture_proposal.md` (`ARCH-PROP-05`)**: Establishes extensible worker core dispatch over the SARF.
6. **`06_parcore_memory_hierarchy_sdram_dma_proposal.md` (`ARCH-PROP-06`)**: Provides the multi-master memory crossbar and hardware SDRAM burst engine for peripheral routing and DMA completion interrupts.

### Strategic Objective

Currently, Parcore utilizes low-latency hardware Mailbox (MBOX) strobes (`mboxStrobeOut` $\to$ `mboxStrobeIn`) exclusively for point-to-point branch redirection (Core 2 $\to$ Core 0) and fault traps. However, guest operating systems (e.g., Linux, FreeRTOS, xv6) and real-time runtimes require standard interrupt primitives:

* **Real-Time Clocks & Preemption**: Standard 64-bit `mtime` and `mtimecmp` timers (RISC-V CLINT / x86 PIT/APIC) to drive OS preemptive multitasking.
* **Platform Peripheral Routing (PLIC)**: Arbitrating external hardware interrupts (FTDI UART RX ready, GPIO pins, SDRAM burst/DMA complete) without corrupting in-flight guest pipeline state.
* **Gated Block-Boundary Servicing**: Ensuring asynchronous interrupts do not break atomic guest instructions, in-flight out-of-order execution, or (once enabled in **Proposals 08–09**) JIT Code Cache basic blocks.
* **Inter-Processor Interrupts (IPI) & TLB Shootdowns**: Providing cross-core signaling to coordinate page-table flushes (`SFENCE.VMA`), Code Cache invalidations, and core wakeups.

---

## 2. System Interrupt Topology

The interrupt subsystem decouples timer generation and platform peripheral routing into hardware peripherals mapped into the Parcore interconnect:

```
                              PLATFORM INTERRUPTS
                  (UART RX Ready, SDRAM DMA Done, GPIO Inputs)
                                       │
                                       ▼
                     ┌───────────────────────────────────┐
                     │   Platform-Level Interrupt        │
                     │   Controller (PLIC) Module        │
                     │   - Priority arbitration & enable │
                     └─────────────────┬─────────────────┘
                                       │
  64-BIT HARDWARE COUNTER              │
  ┌───────────────────────────┐        │
  │   Core Local Interrupt    │        │
  │   (CLINT) Timer Block     ├────────┼────────────────┐
  │   - mtime [63:0] (25 MHz) │        │                │
  │   - mtimecmp [63:0]       │        │                │
  └─────────────┬─────────────┘        │                │
                │                      │                │
                │ Timer Interrupt      │ Ext Interrupt  │ Software IPI
                ▼                      ▼                ▼
  ┌───────────────────────────────────────────────────────────────┐
  │              INTERRUPT GATING & VECTOR DISPATCH               │
  │   - Checks instruction / basic block retirement boundary      │
  │   - Gated during multi-cycle math or speculative execution    │
  └───────────────────────────────┬───────────────────────────────┘
                                  │
                                  ▼
  ┌───────────────────────────────────────────────────────────────┐
  │                  TARGET CORE VECTOR INGESTION                 │
  │  Core 0: Trap Vector 4 (Timer) / Vector 5 (External UART)     │
  │  Core 3: Trap Vector 6 (IPI / TLB Invalidation Shootdown)     │
  └───────────────────────────────────────────────────────────────┘
```

---

## 3. Core Local Interruptor (CLINT) Hardware Specification

The CLINT module provides real-time timekeeping and periodic preemption ticks.

### 3.1. Register Map (MMIO Window: `0xF0000100`–`0xF000011F`)

The CLINT is mapped into Port B MMIO space across all cores (read-only for application cores, write-accessible to the Conductor and Core 0):

| Offset | Register Name | Width | Access | Description |
| :--- | :--- | :---: | :---: | :--- |
| `0xF0000100` | `MTIME_LO` | 32 | RO | Free-running timer counter (lower 32 bits, increments at clk / 1) |
| `0xF0000104` | `MTIME_HI` | 32 | RO | Free-running timer counter (upper 32 bits) |
| `0xF0000108` | `MTIMECMP_LO` | 32 | RW | Timer comparator threshold (lower 32 bits) |
| `0xF000010C` | `MTIMECMP_HI` | 32 | RW | Timer comparator threshold (upper 32 bits) |
| `0xF0000110` | `CLINT_IPI_STROBE` | 32 | WO | Bits [7:4] = Target Core, Bits [3:0] = Trap Vector |

### 3.2. Hardware Implementation in ROHD (`parcore_clint.dart`)

* A free-running 64-bit synchronous counter increments every clock cycle (e.g., 25 MHz timebase).
* A comparator evaluates `mtime >= mtimecmp`.
* When true, `timerInterruptPending` asserts high until software writes a new value to `MTIMECMP`.
* Connects to **Proposal 06's** crossbar preemption priority line so urgent timer interrupts can preempt ongoing bus arbitration cleanly.

---

## 4. Gated Interrupt Servicing & Precise Exceptions

Asynchronous interrupts (timer ticks, UART incoming bytes) arrive at arbitrary clock cycles. In an out-of-order, multi-core, or JIT-accelerated cluster, taking an interrupt mid-instruction or mid-basic block causes catastrophic state corruption.

### 4.1. Transmeta-Style Block-Boundary Gating

To maintain architectural determinism without requiring complex micro-architectural checkpointing:

1. **Pending Latch**: When an interrupt asserts (timer or peripheral), hardware asserts an internal `irqPending` latch.
2. **Execution Gating**:
   * **Interpreter Mode *(active at Tier 07)***: The interrupt is serviced immediately at the next guest instruction boundary (when `commitValid` fires from **Proposal 03** and the current instruction reaches writeback).
   * **JIT Code Cache Mode *(staged hook; activates at Proposals 08–09)***:
     * Hardware defers taking the trap while inside a compiled basic block.
     * The executing basic block continues to its terminal instruction / branch exit stub.
     * The exit stub commits all working registers to the SARF and updates the guest `PC`.
     * Upon reaching the exit boundary, Core 0 senses `irqPending` and vectors to the guest interrupt handler.
3. **Speculative Abort Guarantee**:
   * If an interrupt is accompanied by an urgent abort (e.g., hardware watchdog timeout from the Conductor), speculative writes to the SARF are gated off, the pipeline FIFOs are synchronously flushed, and the cluster resets to the last valid committed guest PC.

---

## 5. Platform-Level Interrupt Controller (PLIC) & Peripheral Multiplexing

The PLIC arbitrates multiple asynchronous interrupt sources into a single external interrupt line directed to Core 0 (IF) and Core 1 (ID).

### 5.1. Interrupt Sources & Prioritization

| IRQ ID | Source | Condition | Default Target Core |
| :---: | :--- | :--- | :---: |
| **0** | Reserved / None | — | — |
| **1** | FTDI UART RX Ready | FIFO Channel 0 has $\ge 1$ byte | Core 0 |
| **2** | SDRAM Burst / DMA Complete | **Proposal 06** Hardware SDRAM Burst FSM fill / flush complete | Core 3 |
| **3** | Timer Comparator | `mtime >= mtimecmp` | Core 0 |
| **4** | Cross-Core IPI | Inter-core vector strobe | Core 1 / Core 3 |
| **5** | Watchdog Alert | Conductor timeout monitor | Conductor |

---

## 6. Inter-Processor Interrupts (IPI) & TLB Shootdowns

The IPI transport layer (`CLINT_IPI_STROBE` $\to$ MBOX Vector 6) is established at Tier 07 so that cross-core signaling is immediately available for OS synchronization and ready for virtual memory / JIT coherence when **Proposals 08–09** land.

### 6.1. The `SFENCE.VMA` TLB Shootdown Sequence *(Micro-TLB & Code Cache flush handlers bind at Proposals 08–09)*

When guest software issues an address-space fence (`SFENCE.VMA rs1, rs2`):

1. **Core 1 (Decode)** executes `SFENCE.VMA`:
   * Writes the target ASID/address to Port B MMIO.
   * Strobes Core 3's MBOX with **Vector 6: TLB Shootdown**.
2. **Core 3 (AGU/MEM)**:
   * Traps to Vector 6 handler in local TCM (`0x00000190`).
   * Invalidates matching entries in the Hardware Micro-TLB (**Proposal 09**).
   * Strobes acknowledgment back to Core 1 via MBOX.
3. **Core 1 Code Cache Purge**:
   * Core 1 invalidates JIT basic blocks mapped to the affected address space (**Proposals 08–09**).
   * Pipeline resumes normal execution.

---

## 7. Phased Implementation Roadmap

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│     Phase 1      │     │     Phase 2      │     │     Phase 3      │     │     Phase 4      │
│   CLINT 64-bit   ├────►│ Interrupt Gating ├────►│ PLIC Peripheral  ├────►│ IPI & Cross-Core │
│   mtime Module   │     │ & Boundary Commit│     │ Routing (UART)   │     │ Shootdown Tests  │
└──────────────────┘     └──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Phase 1: Hardware CLINT Module (HDL)
* Create `hdl/parcore/lib/parcore_clint.dart`.
* Implement the 64-bit `mtime` counter and `mtimecmp` comparator.
* Expose Port B read/write decoding in `ParcoreTop` and connect preemption priority to **Proposal 06's** crossbar.
* Verify cycle-accurate counter progression in `test/parcore_clint_test.dart`.

### Phase 2: Block-Boundary Interrupt Gating (HDL & Firmware)
* Implement `irqPending` holding registers in `cpu_core.dart` and `ParcoreTop`.
* Wire gating logic to ensure interrupts only vector when `inExec` finishes (and expose the JIT exit-stub boundary hook for **Proposals 08–09**).
* Verify that in-flight multi-cycle divisions (Core 2B) or cache fills (Core 3) finish cleanly before interrupt handlers execute.

### Phase 3: PLIC & UART RX Interrupt Integration (HDL & Microkernel)
* Connect `ftdiUart.rxValid` directly to PLIC IRQ 1 and **Proposal 06's** SDRAM Burst FSM done signal to PLIC IRQ 2.
* Update `core0_if_uart.asm` to eliminate busy-polling (`FIFO.TRYR`) in the main fetch loop, transitioning to interrupt-driven character ingestion.

### Phase 4: Cross-Core IPI & Concurrency Verification (Co-Design & Test)
* Implement the cross-core IPI transport and stub `SFENCE.VMA` shootdown handlers (wiring full Micro-TLB and Code Cache invalidation in **Proposals 08–09**).
* Add compliance test cases in `test/parcore_interrupt_test.dart` asserting that timer ticks, external UART bytes, and IPIs retire deterministically through **Proposal 03's** Commit Log Bus.

---

## 8. Summary of Capabilities Added

| Feature | Prior State (Proposals 01–06) | With Proposal 07 |
| :--- | :--- | :--- |
| **Real-Time Clock** | None (Software instruction counters) | **Hardware 64-bit `mtime` / `mtimecmp` (CLINT)** |
| **Preemption Support** | None (Run-to-completion only) | **Deterministic timer interrupts for OS scheduling** |
| **UART Processing** | Polling loop (`FIFO.TRYR`) in Core 0 | **Interrupt-driven zero-overhead ingestion** |
| **Interrupt Precision** | Prone to in-flight bubble corruption | **Strict instruction & block-boundary commit gating** |
| **Cross-Core Sync** | Point-to-point MBOX branch strobe only | **Standardized IPI & `SFENCE.VMA` shootdowns** |
