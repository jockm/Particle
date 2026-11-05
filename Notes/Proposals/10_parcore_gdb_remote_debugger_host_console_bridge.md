# Parcore Architecture Proposal 10: High-Speed Host Debug Engine, GDB Remote Serial Bridge & Non-Intrusive Trace Architecture

## 1. Executive Summary & Dependency Declaration

This proposal defines the hardware debug hooks, host communication protocols, and interactive debugger architecture for the **Parcore High-Speed Host Debug Engine and GDB Remote Serial Protocol (RSP) Bridge**.

### Dependency Declaration

This proposal represents **Tier 10** of the Parcore architecture roadmap and directly **depends on and extends** the specifications established in:

1. **`01_the_parcore_conductor_architecture_proposal.md`**: Provides supervisor control, reset sequencing, and Port B TCM memory multiplexing.
2. **`02_parcore_cluster_performance_optimization_proposal.md`**: Implements the Shared Architectural Register Fabric (SARF), stream windowing, and synchronous FIFO flushes.
3. **`03_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md`**: Establishes heterogeneous functional units and dynamic issue scoreboards.
4. **`04_parcore_tiered_execution_model.md`**: Defines interpreted cold paths and Hotspot JIT compilation into local TCM.
5. **`05_parcore_code_cache_osr_and_software_mmu_proposal.md`**: Introduces the Micro-TLB, transactional exception boundaries, and Code Cache management.
6. **`06_parcore_verification_and_golden_trace_proposal.md`**: Exposes the diagnostic commit log bus and lockstep retirement signals.
7. **`07_parcore_interrupt_and_timer_subsystem_proposal.md`**: Defines the CLINT timer, interrupt gating, and cross-core IPI signaling.
8. **`08_parcore_l1_l2_cache_coherency_and_sdram_dma_proposal.md`**: Provides the multi-master memory crossbar and hardware burst engine.
9. **`09_parcore_multi_isa_personality_overlays_proposal.md`**: Implements dynamic personality switching (RV32, x86, DSP) via the Conductor.

### Strategic Objective

Currently, host interaction is intertwined with application instruction fetch:
* **Resource Sharing Collision**: Core 0 shares its FIFO Channel 0 between guest instruction fetch and the physical FTDI UART transceiver (3 Mbps).
* **Intrusive Diagnostics**: Halting a core or reading internal state requires destructive code patches, software loop injection, or FPGA resynthesis.
* **Lack of Industry-Standard Debugging**: Developers cannot connect standard toolchains (GDB, LLDB, OpenOCD) to set hardware breakpoints, single-step through guest code, or inspect registers across multiple cores.

Proposal 10 decouples debug and console traffic from application instruction flow, creating an **out-of-band Debug Module (DM)** managed collaboratively by the Conductor and dedicated hardware debug controllers.

---

## 2. System Debug Architecture

```
                  HOST WORKSTATION (GDB / LLDB / Console)
                                     │
                                     ▼
                FTDI High-Speed USB Serial Port (3 Mbps)
                                     │
                                     ▼
                   ┌───────────────────────────────────┐
                   │   Parcore Debug Module (DM)       │
                   │   - Packet Framing & Checksum     │
                   │   - GDB RSP Protocol Engine       │
                   │   - UART Virtual Console Mux      │
                   └─────────────────┬─────────────────┘
                                     │
           ┌─────────────────────────┼─────────────────────────┐
           ▼                         ▼                         ▼
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│ Hardware Breakpoint │   │ Conductor Supervisor│   │ SARF / TCM Access   │
│ & Watchpoint Unit   │   │ Control Interface   │   │ Interface           │
│ - 4 Instruction BPs │   │ - Core Halt / Resume│   │ - Direct Register   │
│ - 2 Data Watchpoints│   │ - Single-Step Strobe│   │   Read / Write      │
└─────────────────────┘   └─────────────────────┘   └─────────────────────┘
```

1. **Hardware Debug Module (DM)**: Instantiated as an autonomous unit attached to the external FTDI UART pins. It parses inbound packets without consuming CPU instruction cycles from Core 0.
2. **Channel Multiplexing (Console vs. Debug)**:
   * **Virtual Channel 0 (Debug / RSP)**: Command packets targeting the debug engine (e.g., `$g#67`, `$m1000,4#2a`).
   * **Virtual Channel 1 (Console Stdout/Stdin)**: Raw character streaming between guest OS/application software and host terminal.

---

## 3. Hardware Breakpoint & Watchpoint Engine

The debug unit includes dedicated comparators running in parallel with the pipeline:

### 3.1. Instruction Address Breakpoints (4 Units)
* **Location**: Connected to Core 0 fetch PC (`c0MemPortAAddr`) and JIT Code Cache execution PC.
* **Trigger Condition**: When `fetch_pc == bp_addr[n]` and `bp_enable[n] == 1`:
  1. The Breakpoint Unit asserts a synchronous `debugHalt` strobe to the Conductor.
  2. Cores complete in-flight memory/WB beats and freeze their pipeline clocks.
  3. The DM emits a GDB trap notification packet to the host: `T05trap:02;`.

### 3.2. Data Address Watchpoints (2 Units)
* **Location**: Connected to Master 1 (Core 3 AGU) on the Proposal 08 Memory Crossbar.
* **Trigger Condition**: Fires when `mem_addr == wp_addr[n]` during a load or store (configurable for Read, Write, or Access), capturing the faulting address and data word before pausing the pipeline.

---

## 4. GDB Remote Serial Protocol (RSP) Implementation

The Debug Module implements the standard GDB RSP subset directly in firmware running on the Conductor (or a compact hardware packet parser):

| GDB Command | Protocol Payload | Hardware Action |
| :--- | :--- | :--- |
| **Halt / Break** | `Ctrl-C` (`0x03`) | Assert `debugHalt` across all application cores. |
| **Read Registers** | `$g#67` | Reads SARF registers $x0$–$x31$ + PC + CSRs and returns hex string. |
| **Write Registers** | `$G<hex_bytes>#xx` | Updates target register values in the SARF via Conductor Port B write. |
| **Read Memory** | `$m<addr>,<len>#xx` | Reads `<len>` bytes from target memory via Memory Crossbar Master 3. |
| **Write Memory** | `$M<addr>,<len>:<data>#xx` | Writes `<len>` bytes into TCM or SDRAM via Conductor DMA. |
| **Step Instruction**| `$s#xx` | Releases core clocks for exactly 1 retired guest instruction (via Commit Log Bus). |
| **Continue** | `$c#xx` | De-asserts `debugHalt`; cores resume pipeline execution. |
| **Insert Breakpoint**| `$Z0,<addr>,<kind>#xx` | Programs target address into an available hardware breakpoint comparator. |
| **Remove Breakpoint**| `$z0,<addr>,<kind>#xx` | Clears target hardware breakpoint comparator. |

---

## 5. Non-Intrusive Single-Stepping via Commit Log Bus

Traditional single-stepping by manually setting temporary software breakpoints (`EBREAK`) modifies code and breaks JIT Code Cache blocks.

Proposal 10 leverages **Proposal 06's Architectural Commit Log Bus**:
1. When GDB issues a single-step (`$s`):
   * The Conductor de-asserts `debugHalt`.
   * Application cores step forward.
2. The Hardware Debug Module observes `commitValid` from Proposal 06.
3. The exact cycle that `commitValid` pulses high (indicating exactly one guest instruction has committed its architectural side effects to the SARF or memory):
   * Hardware re-asserts `debugHalt` immediately.
   * Execution freezes before the next guest instruction commits.
4. The DM sends the stop packet (`S05`) back to GDB.
5. This guarantees **cycle-accurate, non-intrusive stepping across both interpreted and JIT-compiled basic blocks**.

---

## 6. Phased Implementation Roadmap

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│     Phase 1      │     │     Phase 2      │     │     Phase 3      │     │     Phase 4      │
│  UART Decoupling ├────►│ Conductor Debug  ├────►│ Hardware BP / WP ├────►│ GDB Server Bridge│
│  & Packet Mux    │     │ Register Engine  │     │ Comparators      │     │ & Python Tooling │
└──────────────────┘     └──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Phase 1: UART Packet Decoupling & Virtual Channels (HDL)
* Refactor `ParticleFtdiUart` to separate console output from debug commands.
* Free Core 0 Channel 0 to focus strictly on instruction flow.
* Verify simultaneous terminal output and host ping-pong packets in simulation.

### Phase 2: Conductor Register & Memory Inspection (Firmware & RTL)
* Implement memory/register read/write MMIO routines in `firmware/conductor/conductor_debug.asm`.
* Verify that the host can pause the cluster, read out all 32 SARF registers, and resume execution without data loss.

### Phase 3: Hardware Breakpoints & Watchpoints (HDL)
* Implement `ParcoreBreakpointUnit` in `hdl/parcore/lib/parcore_debug.dart`.
* Connect comparators to Core 0 PC and Core 3 AGU bus wires.
* Test breakpoint assertion and automatic pipeline freeze in `test/parcore_debug_test.dart`.

### Phase 4: Host Bridge & GDB Integration (Software / Python)
* Build `tools/parcore_gdb_bridge.py`: An open TCP socket server listening for standard `riscv32-unknown-elf-gdb` connections and translating RSP packets to FTDI serial frames.
* Verify setting breakpoints, single-stepping, and inspecting variables in an interactive GDB session on real hardware (ULX3S).

---

## 7. Summary of Capabilities Added

| Feature | Prior State | With Proposal 10 |
| :--- | :--- | :--- |
| **UART Allocation** | Core 0 shares FIFO 0 between fetch & UART | **Dedicated Debug Module; Core 0 fetch isolated** |
| **Debugging Method** | Print statements / waveform dumps | **Interactive GDB / LLDB source-level debugging** |
| **Breakpoints** | Destructive instruction overwrites (`EBREAK`) | **4 Non-intrusive hardware address comparators** |
| **Data Watchpoints** | Not supported | **2 Hardware read/write data watchpoints** |
| **Single-Stepping** | Manual software halts | **Hardware-gated single-step via Commit Log Bus** |
| **Silicon Overhead** | 0 LUTs | **~350–450 LUT4s across comparators and UART mux** |