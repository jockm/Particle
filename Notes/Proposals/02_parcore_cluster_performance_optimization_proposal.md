# Parcore Cluster Performance Optimization Proposal

## 1. Executive Summary & Objective

The objective of this proposal is to increase the throughput and instructions-per-cycle (IPC) of the **Parcore distributed multi-core cluster** without moving to radical paradigm shifts (such as JIT/dynamic binary translation). 

Parcore currently executes guest instruction streams (specifically RV32IM/Zbb) as a distributed spatial pipeline across multiple Particle RISC cores (`Core 0: IF`, `Core 1: ID`, `Core 2: EX`, `Core 3: MEM`, and optional `Core 4: WB`). The system's primary throughput limiter is not the physical FPGA clock speed ($F_{\text{max}}$), but the **high native cycle overhead per guest instruction**—most notably the 14–18 native instruction cycles required by Core 1 (ID) for bit-slicing/scoreboard checks, multi-hop pipeline drain penalties during RAW hazards, and the branch redirection flush latency.

This proposal categorizes targeted improvements into:
1. **Pure Firmware Changes** (Immediate microkernel optimizations requiring zero hardware resynthesis).
2. **Pure HDL Changes** (ROHD hardware datapath & interconnect enhancements requiring no microcode changes).
3. **Hardware / Microkernel Co-Design** (Coordinated ISA, interconnect, and microcode additions offering maximum ROI).

---

## 2. Baseline Architecture & Profiling Summary

In the current baseline:
* **Core 1 (Decode/Scoreboard)** spends 14–18 cycles unpacking 32-bit guest opcodes, checking scoreboard masks, and issuing tokens to Core 2. Core 1 is the primary structural bottleneck.
* **RAW Hazards** cause Core 1 to stall for 20–35 native clock cycles while a dependent register value traverses `EX -> MEM -> WB -> ID`.
* **Branch Redirection** incurs a 24–32 native cycle penalty while Core 2 strobes Core 0 via MBOX, latches the target PC, and purges intermediate FIFOs.
* **Sub-Word Memory Accesses** in Core 3 require multi-cycle bit manipulation (shifts, masking, arithmetic sign extension) to satisfy unaligned or non-word byte-lane offsets.

---

## 3. Tier 1: Pure Firmware Optimizations (No HDL Resynthesis)

These optimizations leverage the existing Particle instruction set and interconnect topology.

### 3.1. Jump Table-Driven Decode & Dispatch (`JTBL`)
* **Problem**: Core 1 currently uses linear skip ladders (`FBRA.Z`, `FBRA.NZ`) to identify opcode families and formats, wasting 4–8 cycles per instruction just determining the instruction type.
* **Implementation**:
  * Build a 32-entry or 64-entry jump table in Core 1's local TCM indexed by `inst[6:2]` (the 5-bit major opcode).
  * Use Particle's native `JTBL Rr` (Opcode `0x81`) to jump directly to format handlers (`_decode_r_type`, `_decode_i_type`, `_decode_load`, `_decode_branch`, etc.) in a single cycle.
* **Impact**: Eliminates 6–10 instruction cycles from the Core 1 main loop.

### 3.2. 4-Stage Pipeline Collapse (Drop Core 4 WB Hop)
* **Problem**: In the 5-stage configuration, Core 4 (`core4_wb.asm`) does little more than forward tokens from Core 3 back to Core 1 (`FIFO.R -> FIFO.W`). This adds an unnecessary FIFO transit hop and latency to RAW hazard resolution.
* **Implementation**:
  * Route Core 3 (`core3_mem.asm`) writeback tokens directly back to Core 1's writeback channel (`FIFO.W Rd, 2` and `FIFO.W Data, 2`).
  * Repurpose or disable Core 4, collapsing the cluster into an active 4-core pipeline (`IF -> ID -> EX -> MEM/WB`).
* **Impact**: Cuts RAW dependency resolution latency by 4–8 cycles and frees up a core for auxiliary tasks.

### 3.3. Direct Local TCM Memory Fast-Path in Core 3
* **Problem**: Core 3 unconditionally traverses the external/cache MMIO interface for guest addresses, incurring mailbox and bus synchronization delays.
* **Implementation**:
  * Implement an address range check in `core3_mem.asm`. If the target address resides within local TCM memory, execute local `LD32`/`ST32` instructions directly on Port B rather than submitting request packets to the cache controller.
* **Impact**: Zero-latency memory accesses for scratchpad and microkernel execution.

---

## 4. Tier 2: Pure HDL Hardware Improvements (No Microkernel Changes)

These changes optimize the ROHD datapath and top-level wiring while preserving all existing software contracts.

### 4.1. Synchronous Hardware Pipeline FIFO Flushing
* **Problem**: When a branch is taken, the software pipeline must drain or discard stale instruction tokens step-by-step, resulting in dead cycles.
* **Implementation**:
  * In `parcore_top.dart` and `parcore_interconnect.dart`, route the branch redirect strobe (`c2BranchStrobe` / `c2MboxStrobe`) directly to the synchronous clear/reset inputs of the `ifToId` and `idToEx` FIFOs.
  * When Core 2 signals a taken branch, the FIFO pointers reset synchronously, instantly purging in-flight tokens.
* **Impact**: Eliminates token-draining latency and software flush token (`0xFFFFFFFF`) handling.

### 4.2. Direct Hardware Branch Target Latch
* **Problem**: Branch targets are currently latched into MMIO registers and read back by Core 0 via software trap routines.
* **Implementation**:
  * Connect Core 2's branch target output (`fifoPushData` / `outMemBWData`) directly into a dedicated hardware target register feeding Core 0's program counter logic on `mboxStrobeIn`.
* **Impact**: Cuts branch turnaround time from ~28 cycles to under 6 cycles.

### 4.3. Port B Sub-Word Byte-Lane Steering & Sign Extension
* **Problem**: Core 3 must execute software shifts and arithmetic sign extensions (`SHIFTL + ASHIFTR`) for `LB`, `LBU`, `LH`, `LHU`, `SB`, and `SH`.
* **Implementation**:
  * In `cpu_core.dart` and `parcore_tcm.dart`, enhance the Port B memory controller to align data and byte enables (`bEnB`) according to `addrB[1:0]`.
  * For sub-word reads, provide hardware sign/zero extension directly onto `memPortBRData`.
* **Impact**: Removes 6–8 instructions per memory operation in `core3_mem.asm`.

---

## 5. Tier 3: Hardware / Microkernel Co-Design (Highest ROI)

These enhancements combine targeted hardware primitives with updated microkernel routines to break the Core 1 decode and hazard bottlenecks.

### 5.1. Non-Destructive Stream Windowing (`FIFO.PEEK` & `FIFO.ADV`)
* **HDL Changes**:
  * Add Opcode `FIFO.PEEK Rr, Chan` to inspect the front of the FIFO without popping.
  * Add Opcode `FIFO.ADV Chan, Imm4` to advance the FIFO read pointer by a variable byte/word offset.
* **Firmware Changes**:
  * In `core1_id.asm`, inspect opcode headers and immediate fields directly from the stream without popping into temporary registers and managing staging scratchpads.
* **Impact**: Saves 3–5 instructions per instruction unpack cycle.

### 5.2. Pre-Decode Classification RAM / Opcode Accelerator (`UNPACK`)
* **HDL Changes**:
  * Instantiate a 256-word distributed LUT-RAM or combinational bit-field slicer indexed by opcode.
  * Hardware extracts `rd`, `rs1`, `rs2`, `funct3`, and immediate type in a single cycle.
* **Firmware Changes**:
  * In `core1_id.asm`, a single read to the classification peripheral replaces lines 45–110 of bit-shifting and masking logic.
* **Impact**: Reduces Core 1 decode time from 16 cycles down to 3–4 cycles, effectively tripling cluster IPC.

### 5.3. Register Windowing (`RBASE` - Option 2 Architecture)
* **HDL Changes**:
  * Add `rbase` register logic in `register_file.dart`. Registers $R1$–$R15$ are offset by `rbase` ($R_n + RBASE$), while $R0$ remains hardwired to zero.
  * Add instructions `RBASE Imm4` and `RBASE Rr`.
* **Firmware Changes**:
  * Map guest RV32 registers $x1$–$x15$ to $RBASE=0$ and $x16$–$x31$ to $RBASE=16$. Eliminates manual base address calculation (`LOAD16 + SHIFTL + ADD + LD32`) in Core 1.
* **Impact**: Reduces register file access overhead by 70%.

### 5.4. Express Forwarding Ring (Core 2 $\to$ Core 1 Bypass)
* **HDL Changes**:
  * Add a dedicated point-to-point FIFO channel directly from Core 2 (EX) back to Core 1 (ID).
* **Firmware Changes**:
  * Core 2 pushes completed ALU results to the bypass queue immediately upon execution.
  * Core 1 checks this bypass queue on RAW hazard detection rather than stalling for the MEM/WB round trip.
* **Impact**: Drops RAW hazard latency from ~24–30 cycles down to 4–6 cycles.

### 5.5. Out-of-Band Shared Architectural Register Fabric (SARF)
* **HDL Changes**:
  * Implement a 32-entry $\times$ 32-bit multi-port distributed LUT-RAM accessible across cores via dedicated SARF ports (`sarfRs1Data`, `sarfRs2Data`, `sarfRdAddr`, `sarfRdData`, `sarfRdWe`).
  * Include internal write-to-read forwarding.
* **Firmware Changes**:
  * Remove software register file emulation and scoreboard tracking from Core 1's local TCM. Cores read operands and commit writebacks directly into the SARF.
* **Impact**: Completely eliminates software scoreboard polling and reduces dependency bubbles to 0–1 cycles.

---

## 6. Implementation Phasing & Work Breakdown

| Phase | Tasks Included | Primary Scope | Expected Throughput Improvement |
| :--- | :--- | :--- | :--- |
| **Phase 1: Quick Wins** | • Jump Table Dispatch (`JTBL`)<br>• Collapse to 4-Stage Pipeline<br>• Synchronous FIFO Flush on Branch | Firmware (`core1_id.asm`, `core3_mem.asm`), HDL (`parcore_interconnect.dart`) | **+40% – 60% MIPS** |
| **Phase 2: Core 1 Unpack Acceleration** | • Hardware Byte Steering (`LB`/`SB`)<br>• `FIFO.PEEK` & `FIFO.ADV`<br>• Pre-Decode Classification RAM | HDL (`cpu_core.dart`, `parcore_tcm.dart`), Firmware (`core1_id.asm`) | **+100% – 150% MIPS** (2x–2.5x) |
| **Phase 3: Register File & Hazard Elimination** | • Register Windowing (`RBASE`)<br>• Express Forwarding Ring OR SARF | HDL (`register_file.dart`, `parcore_top.dart`), Firmware (all stages) | **+200% – 300% MIPS** (3x–4x) |

---

## 7. Verification & Test Plan

1. **Unit Verification (`hdl/parcore/test/`)**:
   * Regression testing against existing suites: `parcore_rv32_pipeline_test.dart` and `parcore_top_test.dart`.
   * New testbench for synchronous FIFO clear during active data streaming.
2. **Benchmark Verification**:
   * Execute synthetic instruction loops (Fibonacci, Memory Copy, Bit-reversal) comparing cycle counts pre- and post-optimization.
   * Cycle-accurate monitoring of queue fill levels to verify that Core 1 is no longer starving downstream execution stages.