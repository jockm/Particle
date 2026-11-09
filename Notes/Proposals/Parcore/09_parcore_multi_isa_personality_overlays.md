# Parcore Architecture Proposal 09: Dynamic Multi-ISA Personality Overlays and Runtime Reconfiguration

## 1. Executive Summary & Dependency Declaration

This proposal defines the architectural mechanisms, supervisor switching protocols, and microkernel overlay formats for **Dynamic Multi-ISA Personality Overlays and Runtime Reconfiguration** on the Parcore cluster.

### Dependency Declaration

This proposal represents **Tier 9** of the Parcore architecture roadmap and directly **depends on and extends** the specifications established in:

1. **`01_the_parcore_conductor_architecture_proposal.md`**: Provides supervisor reset sequencing, Port B TCM multiplexing, and SPI Flash peripheral mastership.
2. **`02_parcore_cluster_performance_optimization_proposal.md`**: Implements the Pre-Decode Classification RAM, stream windowing primitives (`FIFO.PEEK`, `FIFO.ADV`), and the Shared Architectural Register Fabric (SARF).
3. **`03_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md`**: Establishes heterogeneous functional units (Core 2A ALU, Core 2B DSP/Div, Core 3 AGU) and scoreboarded dynamic issue.
4. **`04_parcore_tiered_execution_model.md`**: Establishes cold-path interpretation and dynamic template compilation.
5. **`05_parcore_code_cache_osr_and_software_mmu_proposal.md`**: Defines the Software MMU, Micro-TLB, and dynamic Code Cache eviction.
6. **`06_parcore_verification_and_golden_trace_proposal.md`**: Exposes the diagnostic commit log bus for lockstep trace verification across multiple target ISAs.
7. **`07_parcore_interrupt_and_timer_subsystem_proposal.md`**: Defines the CLINT timer and cross-core Inter-Processor Interrupt (IPI) signaling.
8. **`08_parcore_l1_l2_cache_coherency_and_sdram_dma_proposal.md`**: Provides the multi-master memory crossbar and hardware SDRAM burst engine.

### Strategic Objective

Because Particle cores are general-purpose, high-efficiency RISC processors executing microkernels out of local TCM rather than fixed hardwired ASICs, **the cluster is not restricted to executing a single ISA**. 

A single Parcore bitstream on the Lattice ECP5 can dynamically transform its compute personality on the fly:
* **Personality A: RV32IM_Zbb** (Modern RISC-V application target running Linux or RTOS).
* **Personality B: x86 (IA-32 / Real & Protected Mode)** (Legacy DOS/Windows software emulation using byte-stream windowing and variable-length decode).
* **Personality C: 6502 / Z80 Retro Computing Fabric** (Cycle-accurate retro machine emulation).
* **Personality D: Streaming Pipelined DSP / FFT Coprocessor** (Repurposing the cores as an audio/signal processing systolic array).

This proposal defines the **Personality Overlay Image (POI)** format and the **Hot-Swap Supervisor Protocol** driven by the Parcore Conductor to transition personalities in sub-millisecond timeframes without FPGA reconfiguration.

---

## 2. Multi-ISA Architectural Substrate

Dynamic personality switching is made possible by the decoupling introduced in Proposals 01, 02, and 05:

```
                            SPI FLASH MEMORY (ULX3S)
        ┌──────────────────────────────────────────────────────────────┐
        │  [Overlay 0: RV32IM]  [Overlay 1: x86-32]  [Overlay 2: DSP]  │
        └──────────────────────────────┬───────────────────────────────┘
                                       │ SPI Burst Stream
                                       ▼
                       ┌───────────────────────────────┐
                       │     The Parcore Conductor     │
                       │   - Supervisor Mode Master    │
                       │   - Reset & Clock Gate Arb    │
                       └───────────────┬───────────────┘
                                       │
           ┌───────────────────────────┼───────────────────────────┐
           ▼                           ▼                           ▼
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│ Core 1 Class. RAM   │     │ Core 0..3 TCMs      │     │ SARF Register Map   │
│ - 256x16 Opcode Map │     │ - Microkernel Code  │     │ - Physical Register │
│ - Slicing Descriptors│    │ - Jump Tables (JTBL)│     │   Bank Offsets      │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘
```

1. **Programmable Classification RAM (Core 1)**: The 256-entry lookup RAM determines instruction lengths, immediate formats, and micro-op dispatch vectors. Changing this table instantly alters how raw byte streams are sliced.
2. **`FIFO.PEEK` and `FIFO.ADV`**: Allows variable-length CISC instruction streams (1 to 15 bytes for x86) to be parsed without pipeline stalls.
3. **SARF Register Mapping**: The 32 physical SARF registers are dynamically partitioned to match the target guest's architectural registers.

---

## 3. Personality Overlay Image (POI) Format

Personality overlays are packaged as dense binary images stored in SPI Flash:

```
+------------------------------------------------------------------+
|                     POI HEADER (64 Bytes)                        |
|  - Magic: 'POVR' (0x504F5652)       - Personality ID (16-bit)    |
|  - Target Cluster Clock (MHz)       - Classification Table Size  |
|  - Core 0..3 Code Offsets & Lengths - Initial Entry PC           |
+------------------------------------------------------------------+
|               CLASSIFICATION RAM TABLE (512 Bytes)               |
|  - 256 entries x 16-bit Opcode Format & Length Descriptors       |
+------------------------------------------------------------------+
|               CORE MICROKERNEL BINARIES (2KB - 4KB each)         |
|  - Core 0: Frontend Fetch & Instruction Stream Filter            |
|  - Core 1: Opcode Decode, Prefix Parser & Scheduler              |
|  - Core 2A: Integer ALU & Condition Flag Engine                  |
|  - Core 2B: Specialized Math / Multiplier / Divider              |
|  - Core 3: Segment / MMU Address Generation & Bus Gateway        |
+------------------------------------------------------------------+
```

---

## 4. Architectural Personality Profiles

### 4.1. Profile A: RISC-V (RV32IM_Zbb)
* **Instruction Format**: Fixed 32-bit (and compressed 16-bit via Pre-Decode).
* **SARF Layout**: Direct mapping of registers $x0$ through $x31$.
* **Core Roles**: Standard 4/5-stage distributed execution pipeline.

### 4.2. Profile B: x86 Real & Protected Mode (IA-32 Subset)
* **Instruction Format**: Variable-length (1–15 bytes) with prefix bytes (`0x66`, `0x67`, `0xF0`, segment overrides).
* **Front-End Operation**: Core 1 uses `FIFO.PEEK` to examine prefix bytes and `FIFO.ADV` to step past consumed prefixes in 1 cycle.
* **SARF Register Layout**:
  * Words 0–7: GPRs (`EAX`, `ECX`, `EDX`, `EBX`, `ESP`, `EBP`, `ESI`, `EDI`).
  * Words 8–13: Segment Selectors & Base Registers (`CS`, `DS`, `SS`, `ES`, `FS`, `GS`).
  * Word 14: `EFLAGS` (Condition codes: CF, PF, AF, ZF, SF, OF).
  * Word 15: `EIP` (Instruction Pointer).
* **Core 2A Role**: Computes arithmetic results and evaluates packed x86 flag updates combinationally.

### 4.3. Profile C: Streaming DSP & Systolic Coprocessor
* **Instruction Format**: Macro-command stream from host or DMA.
* **Pipeline Transformation**:
  * Pipelining collapses into an autonomous dataflow pipeline.
  * Core 0: Input sample stream buffer (Audio I2S / ADC).
  * Core 1: Windowing and coefficient generator.
  * Core 2A / 2B: MAC (Multiply-Accumulate) FIR/IIR filter engine.
  * Core 3: DMA circular output buffer to DAC / SDRAM.

---

## 5. Hot-Swap Supervisor Protocol

Switching personalities is orchestrated entirely by the Conductor over Port B TCM multiplexing:

```
[ GUEST REQUEST / TRAP ]
           │
           ▼
1. Core 1 asserts MMIO trap to Conductor (`0xF0000024`) requesting Overlay Switch.
2. Conductor asserts synchronous active-high hardware reset to Cores 0, 1, 2A, 2B, 3.
3. Conductor asserts Port B write-multiplexer override (`portB_mux_sel <= 1`).
4. Conductor reads POI image from SPI Flash:
   a. Streams 512 bytes into Core 1 Classification RAM.
   b. Writes new microkernel code into Core 0, 1, 2, 3 local TCMs.
   c. Clears SARF registers and resets scoreboard masks to zero.
   d. Clears Code Cache Directory in BRAM (Proposal 05).
5. Conductor sets target starting PC in Core 0.
6. Conductor de-asserts Port B multiplexer and releases core resets simultaneously.
7. Cluster resumes execution immediately under the new ISA personality.
```

* **Total Switchover Latency**: Less than **1.2 milliseconds** at a 25 MHz SPI clock rate.

---

## 6. Phased Implementation Roadmap

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│     Phase 1      │     │     Phase 2      │     │     Phase 3      │     │     Phase 4      │
│  POI Image Spec  ├────►│ Conductor Swap   ├────►│ x86 Variable-    ├────►│ Dynamic Switch   │
│  & Tooling       │     │ Routine (HDL)    │     │ Length Decoder   │     │ Regression Tests │
└──────────────────┘     └──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Phase 1: Tooling & Overlay Packaging (Software / Python)
* Create `tools/mkoverlay.py` to package compiled microkernels and classification tables into `.poi` binary files.
* Build the x86 real-mode opcode classification table.

### Phase 2: Conductor Overlay Loader (Firmware & RTL)
* Implement the SPI flash burst reader in `firmware/conductor/conductor_main.asm`.
* Add the hot-swap MMIO command trigger (`0xF0000024`) in `parcore_top.dart`.
* Verify that the Conductor can halt the pipeline, rewrite TCMs, and restart the cluster cleanly.

### Phase 3: x86 Variable-Length Microkernel Suite (Firmware)
* Author `firmware/parcore/x86/core1_x86_id.asm` implementing prefix scanning via `FIFO.PEEK` and `FIFO.ADV`.
* Author `firmware/parcore/x86/core2_x86_ex.asm` implementing x86 arithmetic and `EFLAGS` evaluation.

### Phase 4: Verification & Multi-ISA Co-Simulation (Test)
* Add test cases in `test/parcore_multi_isa_test.dart` executing an RV32 compute loop, triggering an overlay swap to x86, executing an x86 real-mode routine, and asserting correct SARF output via Proposal 06's Commit Log Bus.

---

## 7. Summary of Architectural Impact

| Dimension | Fixed Silicon Soft-Cores | Parcore with Proposal 09 |
| :--- | :--- | :--- |
| **ISA Flexibility** | Hardwired to a single ISA (e.g., RV32 only) | **Multi-personality (RV32, x86, Retro, DSP)** |
| **Reconfiguration Cost** | Full FPGA bitstream reload (several seconds) | **Software microkernel overlay swap (< 1.5 ms)** |
| **FPGA Logic Overhead** | Multiple separate core instantiations | **Zero additional execution logic (re-uses cores)** |
| **Code Density** | Fixed instruction format | **Optimized per target domain** |