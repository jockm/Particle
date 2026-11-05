# Parcore Architecture Proposal 08: Unified Memory Hierarchy, Multi-Master L1/L2 Cache Coherency, and SDRAM DMA Fabric

## 1. Executive Summary & Dependency Declaration

This proposal defines the hardware specification, bus arbitration protocols, and memory controller architecture for the **Parcore Unified Memory Hierarchy, Multi-Master Cache Coherency, and SDRAM DMA Subsystem**.

### Dependency Declaration

This proposal represents **Tier 8** of the Parcore acceleration roadmap and directly **depends on and extends** the specifications established in:

1. **`01_the_parcore_conductor_architecture_proposal.md`**: Provides supervisor memory pre-loading, flash memory access, and Conductor bus mastership.
2. **`02_parcore_cluster_performance_optimization_proposal.md`**: Implements the Shared Architectural Register Fabric (SARF), sub-word byte-lane steering, and synchronous FIFO flushes.
3. **`03_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md`**: Implements heterogeneous functional units (Core 2A ALU, Core 2B DSP/Div, Core 3 AGU) with dynamic scoreboarded latency hiding.
4. **`04_parcore_tiered_execution_model.md`**: Defines interpreted cold paths and Hotspot JIT compilation into local TCM.
5. **`05_parcore_code_cache_osr_and_software_mmu_proposal.md`**: Implements the Micro-TLB in Core 3 (AGU), On-Stack Replacement (OSR), and transactional exception rollback.
6. **`06_parcore_verification_and_golden_trace_proposal.md`**: Exposes the architectural retirement commit bus for lockstep memory verification.
7. **`07_parcore_interrupt_and_timer_subsystem_proposal.md`**: Establishes the CLINT timer and cross-core Inter-Processor Interrupt (IPI) invalidation signaling.

### Strategic Objective

In the baseline 5/6-stage cluster architecture, memory accesses are serialized and bottlenecked by software emulation:
* **The MMIO Bottleneck**: Core 3 (MEM) accesses memory by submitting software request packets to Core 5 (Cache Controller) over Port B MMIO (`0xF0000030`–`0xF0000038`).
* **Software Burst Assembly**: Core 5 firmware runs software bit-shifting loops to assemble 16-bit SDRAM words into 32-bit cache lines, consuming dozens of native cycles per cache miss.
* **Master Contention**: Core 0 (Instruction Fetch), Core 3 (Data Memory), the JIT Code Cache (template ingestion), and the Conductor (DMA) compete for memory access without hardware arbitration.
* **Blocking Cache Stalls**: An L1 cache miss completely halts the pipeline for 35–55 clock cycles during main SDRAM line fills.

This proposal eliminates these constraints by introducing:
* A **Split-Transaction Multi-Master Crossbar Interconnect**.
* A **Hardware 16-to-32 Bit SDRAM Burst Assembly FSM** in ROHD.
* A **Non-Blocking (Hit-Under-Miss) Unified L1 Cache**.
* **Hardware Coherency Snooping** between data writes, instruction prefetch buffers, and the JIT Code Cache.

---

## 2. Multi-Master Interconnect Topology

Proposal 08 replaces the point-to-point software MMIO interface with a hardware crossbar connecting all cluster memory masters to a centralized cache and SDRAM controller.

```
       Master 0               Master 1               Master 2             Master 3
   ┌──────────────┐       ┌──────────────┐       ┌──────────────┐     ┌──────────────┐
   │ Core 0 (IF)  │       │ Core 3 (AGU) │       │  Core 1/JIT  │     │  Conductor   │
   │  Inst Fetch  │       │  Data Mem    │       │  Code Cache  │     │ DMA / Boot   │
   └──────┬───────┘       └──────┬───────┘       └──────┬───────┘     └──────┬───────┘
          │                      │                      │                    │
          └───────────────┬──────┴──────────────────────┴────────────────────┘
                          ▼
            ┌───────────────────────────┐
            │ Multi-Master Crossbar     │
            │ - Fair Round-Robin Arb    │
            │ - Split Request / Grant   │
            │ - Address Range Decoder   │
            └─────────────┬─────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
┌───────────────────────────┐   ┌───────────────────────────┐
│ Local TCM Fast-Path       │   │ Non-Blocking L1 Subsystem │
│ - 0-cycle wait state      │   │ - 4-Way Set Associative   │
│ - Direct SRAM partition   │   │ - MSHR (Hit-Under-Miss)   │
└───────────────────────────┘   └─────────────┬─────────────┘
                                              ▼
                                ┌───────────────────────────┐
                                │ Hardware SDRAM Burst FSM  │
                                │ - Lattice ECP5 SDR PHY    │
                                │ - 16-bit to 32-bit Pack   │
                                └───────────────────────────┘
```

---

## 3. Bus Protocol & Crossbar Arbitration

### 3.1. Split-Transaction Request/Response Channel
The crossbar defines decoupled request and response phases to prevent slow SDRAM operations from blocking high-speed TCM transactions.

#### Request Channel (Master $\to$ Crossbar)
* `req_valid`: Strobe indicating a pending transaction.
* `req_master_id [1:0]`: Master identifier (00=Core 0, 01=Core 3, 10=JIT, 11=Conductor).
* `req_addr [31:0]`: Physical byte address.
* `req_wdata [31:0]`: Store data word.
* `req_ben [3:0]`: Byte-enable mask.
* `req_we`: Write enable (1=Write, 0=Read).

#### Response Channel (Crossbar $\to$ Master)
* `resp_valid`: Strobe indicating valid data/completion.
* `resp_master_id [1:0]`: Destination master.
* `resp_rdata [31:0]`: Read data word.
* `resp_fault`: Bus access fault indicator (Trap 12/14).

### 3.2. Arbitration Policy
* **Fair Round-Robin**: Grants requests cyclically among active masters.
* **Preemption Priority**: When the Conductor asserts an urgent DMA abort or the CLINT triggers an unmasked timer interrupt, Master 3 (Conductor) is granted immediate priority after the current bus beat completes.

---

## 4. Hardware 16-to-32 Bit SDRAM Burst Engine

The ULX3S FPGA features a 16-bit wide external SDR SDRAM interface. Previously, Core 5 assembled cache lines through repeated 16-bit loads and software shifts.

### 4.1. Hardware Burst Packing FSM
The burst engine (`parcore_sdram_burst_fsm.dart`) directly interfaces with the 16-bit SDRAM PHY:
1. **Burst Activation**: Miss detection triggers a 32-byte (8-word) line refill from SDRAM.
2. **Burst Read**: SDRAM issues a sequential 16-beat burst of 16-bit halfwords at clock frequency (50–75 MHz).
3. **Hardware Assembly**:
   * Beat $2n$: Latches lower 16 bits `dq_in[15:0]`.
   * Beat $2n+1$: Concatenates `dq_in[15:0]` as upper bits `[31:16]` and commits the complete 32-bit word directly to the L1 cache line buffer.
4. **Latency Reduction**: Refilling a 32-byte cache line drops from **~85 software cycles down to 18 hardware cycles** (CAS latency + 16 burst beats).

---

## 5. Non-Blocking L1 Cache (Hit-Under-Miss Architecture)

In traditional in-order designs, a cache miss stalls the entire core until the line returns from external memory. 

### 5.1. Miss Status Holding Register (MSHR)
Proposal 08 implements a single-entry (or two-entry) MSHR:
* When Core 3 requests a word that misses in L1:
  1. The MSHR captures the target `addr`, `master_id`, and `destination_rd`.
  2. The SDRAM burst engine begins background line retrieval.
  3. Instead of stalling Core 3, the MSHR marks the target guest register as **Busy** in the SARF scoreboard (Proposal 03).
  4. Core 3 continues executing subsequent independent memory requests.
* **Hit-Under-Miss**: If subsequent loads or stores hit in other L1 cache lines or local TCM, they complete in **1 cycle**.
* **Retirement**: Once the SDRAM burst completes, the MSHR updates the cache line, writes the requested word directly to the SARF, and clears the register's scoreboard busy bit.

---

## 6. Hardware Cache Coherency & Invalidation Snooping

Coherency hazards occur when guest stores overwrite code that is already cached in Core 0's instruction prefetch buffer or compiled in the JIT Code Cache.

### 6.1. Store-Invalidation Snooping
The crossbar integrates write-snooping logic:
* Whenever Master 1 (Core 3 AGU) or Master 3 (Conductor DMA) performs a write:
  1. The target address is broadcast across the internal snooping bus.
  2. **Core 0 Prefetch Invalidation**: If the address matches Core 0's active instruction line, the prefetch buffer is marked invalid, forcing a fresh fetch on the next cycle.
  3. **JIT Code Cache Invalidation**: If the address falls within a page marked as compiled in the Code Cache Directory (Proposal 05), the corresponding basic block tag is cleared in 1 cycle.
* This guarantees complete **Self-Modifying Code (SMC)** safety without software cache-flush loops.

---

## 7. Phased Implementation Roadmap

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│     Phase 1      │     │     Phase 2      │     │     Phase 3      │     │     Phase 4      │
│  Crossbar Arbiter├────►│ SDRAM 16-to-32   ├────►│ Non-Blocking     ├────►│ Coherency        │
│  & Bus Channels  │     │ Burst FSM        │     │ MSHR Engine      │     │ Snooping & Test  │
└──────────────────┘     └──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Phase 1: Split-Transaction Crossbar Module (HDL)
* Create `hdl/parcore/lib/parcore_memory_crossbar.dart`.
* Implement round-robin arbitration among Master 0 (Core 0), Master 1 (Core 3), and Master 3 (Conductor).
* Connect Port B memory interfaces to the crossbar and verify concurrent read/write arbitration in testbenches.

### Phase 2: Hardware 16-to-32 Bit SDRAM Burst Engine (HDL)
* Implement `parcore_sdram_burst_fsm.dart` in `hdl/parcore/lib/`.
* Connect the FSM to the ULX3S 16-bit SDRAM controller interface.
* Verify 32-byte line fills assembling 16-bit halfwords into 32-bit words without software intervention.

### Phase 3: Non-Blocking Cache & MSHR Integration (HDL & SARF Co-Design)
* Add the Miss Status Holding Register (MSHR) to the cache controller.
* Connect MSHR pending flags to the SARF scoreboard to allow hit-under-miss memory execution.
* Verify that independent memory hits resolve while background SDRAM refills are in flight.

### Phase 4: Coherency Snooping & Full Regression Suite (HDL & Compliance)
* Connect store-snoop broadcast wires to Core 0 prefetch logic and the JIT Code Cache Directory.
* Execute self-modifying code benchmarks and mixed load/store stress tests via Proposal 06's Golden Trace Co-Simulator.

---

## 8. Summary of Capabilities Added

| Feature | Baseline Architecture | With Proposal 08 |
| :--- | :--- | :--- |
| **Data Memory Access** | Software MMIO packets to Core 5 | **Direct hardware crossbar interconnect** |
| **SDRAM Line Refill** | ~85 native software loop cycles | **18 hardware burst clock cycles** |
| **Cache Miss Handling** | Entire pipeline stalls | **Non-blocking hit-under-miss via MSHR** |
| **Concurrent Access** | Serialized; masters block each other | **Split-transaction round-robin arbitration** |
| **SMC Coherency** | Manual software trap/flush | **1-cycle hardware write-snoop invalidation** |
| **Hardware Overhead** | 0 extra (Core 5 running microcode) | **~850–1,100 LUT4s across crossbar and burst FSM** |