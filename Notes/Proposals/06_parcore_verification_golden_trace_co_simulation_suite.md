# Parcore Architecture Proposal 06: Verification & Golden Trace Co-Simulation Suite

## 1. Executive Summary & Dependency Declaration

This proposal defines the architectural specification, observability hardware hooks, and testbench co-simulation infrastructure for the **Parcore Verification & Golden Trace Suite**.

### Dependency Declaration

This proposal represents **Tier 6** of the Parcore acceleration and robustness roadmap and directly **depends on and extends** the specifications established in:

1. **`01_the_parcore_conductor_architecture_proposal.md`**: Provides supervisor control, deterministic reset sequencing, and memory pre-loading.
2. **`02_parcore_cluster_performance_optimization_proposal.md`**: Implements the Shared Architectural Register Fabric (SARF), fast stream decode, and synchronous FIFO flushes.
3. **`03_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md`**: Introduces parallel execution cores (Core 2A, Core 2B, Core 3) and scoreboarded dynamic issue.
4. **`04_parcore_tiered_execution_model.md`**: Establishes interpreted cold paths and Hotspot JIT compilation into local TCM.
5. **`05_parcore_code_cache_osr_and_software_mmu_proposal.md`**: Introduces the Micro-TLB, On-Stack Replacement (OSR), and transactional exception rollback.

### Strategic Objective

As Parcore evolves from a single-issue sequential interpreter into a distributed, out-of-order, JIT-accelerated multi-core compute cluster, conventional verification methods (such as inspecting final TCM memory dumps or manually analyzing large VCD waveforms) become inadequate. Complex race conditions, speculative rollbacks, FIFO backpressure bubbles, and OSR transitions require **automated, cycle-by-cycle lockstep verification**.

The goal of this proposal is to establish:
* An **Architectural Instruction Retirement Bus (Commit Log)** exposed as non-synthesizable/debug signals in ROHD.
* A **Lockstep Golden Trace Co-Simulator** running alongside ROHD simulations that validates guest execution against a reference emulator (e.g., Spike / QEMU / Python reference model).
* A **Deterministic Inter-Core Replay Engine** that records FIFO handshake timings, asynchronous interrupts, and MBOX strobes for cycle-accurate debugging.
* Automated integration into the continuous integration (`dart test`) test suite.

---

## 2. The Architectural Instruction Retirement Bus (Commit Log)

To monitor guest instruction retirement across the distributed cluster without perturbing hardware timing or introducing probe effects, Parcore defines a dedicated, out-of-band **Commit Log Interface**.

```
                           PARCORE CLUSTER
┌──────────────────────────────────────────────────────────────────┐
│  Core 0 (IF)   Core 1 (ID)   Core 2A/2B (EX)   Core 3 (MEM/WB)   │
└─────────────────────────────────┬────────────────────────────────┘
                                  │
                                  ▼
               ┌─────────────────────────────────────┐
               │    Architectural Commit Monitor     │
               │  - Gated to official retired ops    │
               │  - Discards speculative/flushed ops │
               └──────────────────┬──────────────────┘
                                  │
                                  ▼
                      COMMIT LOG DIAGNOSTIC BUS
                      [ 128-bit Structured Token ]
        ┌──────────────┬───────────┬─────────────┬──────────────┐
        │ Guest PC     │ Inst Word │ Rd Index    │ Write Data   │
        │ [63:32]      │ [31:0]    │ [7:0]       │ [31:0]       │
        └──────────────┴───────────┴─────────────┴──────────────┘
                                  │
                                  ▼
               ┌─────────────────────────────────────┐
               │       Lockstep Co-Simulator         │
               │   (Spike / Reference Model Bridge)  │
               └─────────────────────────────────────┘
```

### 2.1. Signal Interface Definition

In `hdl/parcore/lib/parcore_top.dart`, the diagnostic commit interface is exposed at the top-level module boundary (enabled conditionally during simulation or via build flags):

```dart
// Diagnostic Architectural Retirement Signals
Logic get commitValid => output('commit_valid');
Logic get commitGuestPc => output('commit_guest_pc');       // 32-bit
Logic get commitInstWord => output('commit_inst_word');     // 32-bit
Logic get commitRdAddr => output('commit_rd_addr');         // 6-bit (x0..x31 or f0..f31)
Logic get commitRdData => output('commit_rd_data');         // 32-bit
Logic get commitMmuFault => output('commit_mmu_fault');     // 1-bit
Logic get commitIsJit => output('commit_is_jit');           // 1-bit (Interpreter vs JIT block)
```

### 2.2. Retirement Qualification Rules

An instruction token is asserted on the Commit Bus **if and only if** it has irrevocably committed its architectural side effects:
1. **In-Order Retirement Point**: For interpreted instructions, the token fires when Core 3 (MEM/WB) writes to the SARF or releases the scoreboard bit.
2. **JIT Execution Retirement**: For compiled basic blocks executing in the Code Cache, tokens are emitted as each native instruction commits to the SARF.
3. **Speculative Discard**: Instructions invalidated by a pipeline flush (`c2BranchStrobe`) or rolled back due to an MMU page fault **must not** assert `commitValid`.
4. **Zero-Register Writes**: Instructions writing to $x0$ ($R_d = 0$) still emit a commit token with `commitRdAddr = 0` and `commitRdData = 0` to verify program counter progression.

---

## 3. Lockstep Golden Reference Co-Simulation

Rather than comparing register states only at the end of a test run, the testbench runs a golden software reference emulator in lockstep with the ROHD hardware simulator.

### 3.1. Co-Simulation Architecture

```
                 GUEST TEST BINARY (RV32IM / RISC-V Tests)
                                   │
                  ┌────────────────┴────────────────┐
                  │                                 │
                  ▼                                 ▼
       ROHD Hardware Simulation        Golden Reference Model
       (Parcore Top-Level Module)      (Spike / In-Memory ISA Model)
                  │                                 │
                  ▼                                 ▼
          Emitted Commit Token             Expected Commit Token
          [PC, Inst, Rd, Data]             [PC, Inst, Rd, Data]
                  │                                 │
                  └────────────────┬────────────────┘
                                   │
                                   ▼
                     CYCLE-BY-CYCLE COMPARATOR
                     - Verifies PC match
                     - Verifies destination register
                     - Verifies committed value
                     - Throws actionable divergence error
```

### 3.2. Divergence Diagnostic Reporting

When a mismatch occurs, the testbench immediately halts simulation and outputs a comprehensive divergence snapshot:

```text
================================================================================
PARCORE CO-SIMULATION DIVERGENCE DETECTED AT CYCLE 14,820
================================================================================
Instruction Retirement # 1,429

FIELD             HARDWARE (PARCORE)            GOLDEN REFERENCE (SPIKE)
--------------------------------------------------------------------------------
Guest PC          0x0000084C                    0x0000084C
Instruction       0x00A585B3 (ADD x11, x11, x10)0x00A585B3 (ADD x11, x11, x10)
Destination Rd    x11 (11)                      x11 (11)
Committed Data    0x00000034                    0x00000038   <--- MISMATCH!
Execution Mode    JIT Code Cache (Block 4)      Interpreter

PIPELINE STATUS AT DIVERGENCE:
  Core 0 (IF)   : PC=0x00000854, State=FETCH
  Core 1 (ID)   : Inst=0x00000000, Scoreboard=0x00000800
  Core 2A (ALU) : Idle
  Core 2B (DSP) : Multi-cycle DIV in flight (Cycle 18/34)
  Core 3 (MEM)  : Addr=0x00010040, Hit=1

SARF SNAPSHOT (Top 8 Diverging Registers):
  x10: HW=0x00000004  REF=0x00000004
  x11: HW=0x00000034  REF=0x00000038  (Mismatch)
  x12: HW=0x00000010  REF=0x00000010
================================================================================
```

---

## 4. Deterministic Inter-Core Replay & Trace Logging

In a distributed multi-core system communicating over asynchronous FIFOs, bugs often manifest as intermittent race conditions dependent on memory access latency or FIFO fullness.

### 4.1. Event Logging Subsystem

During test runs, the simulation harness can optionally capture an **Execution Event Log (EEL)** recording all non-deterministic external events:
* **UART Inbound Packets**: Timestamps and byte values received on FIFO Channel 0.
* **External Interrupts**: Assertion cycle and interrupt vector.
* **SDRAM Cache Miss Delays**: Simulated memory controller latency cycles.
* **MBOX Cross-Core Strobes**: Inter-core vector notifications.

### 4.2. Cycle-Accurate Replay Harness

The replay harness reads the event log and reproduces the exact timing conditions:
```dart
final replayEngine = ParcoreReplayHarness(
  top: top,
  logPath: 'test/traces/failing_run_trace.eel',
);

// Runs testbench with identical external stimulus and latency jitter
await replayEngine.runToCycle(14820);
```
This enables zero-latency reproduction of transient multi-core deadlocks and hazard stalls without modifying application binaries.

---

## 5. Comprehensive Compliance Test Suites

The verification suite integrates three layers of standard test suites:

### 5.1. Layer 1: RISC-V Architectural Compliance (`riscv-tests`)
Executes the official RISC-V compliance suite:
* **`rv32ui-p-*`**: User-mode integer instructions (ADDI, ADD, SUB, AND, OR, XOR, SLT, Branches, Loads, Stores, Jumps).
* **`rv32um-p-*`**: Multiplier and divider extension (MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU).
* **`rv32uc-p-*`**: Compressed 16-bit instruction decoding (via Pre-Decode RAM).
* **`rv32uzbb-p-*`**: Basic bit-manipulation operations (CLZ, CTZ, CPOP, ROL, ROR).

### 5.2. Layer 2: Stress & Hazard Micro-benchmarks
Targeted test cases designed to force worst-case pipeline conditions:
* **RAW Hazard Hammer**: Tight sequences of back-to-back dependent arithmetic instructions testing SARF write-to-read forwarding.
* **Branch Thrash**: Alternating taken/untaken branches designed to trigger continuous hardware FIFO flushes and target latch redirects.
* **Divide Collision**: Issuing single-cycle ALU instructions immediately behind long-latency unsigned division to stress out-of-order dynamic issue.
* **Memory Stride & Unaligned Spanning**: Accessing sub-word and misaligned addresses across word boundaries to trigger Core 3 alignment routines and Trap 14 handling.

### 5.3. Layer 3: OSR & JIT Invalidation Verification
* **Hotspot Transition Test**: Loops configured with trip counts spanning 1 to 100,000 iterations to verify seamless promotion from interpreted mode to JIT code cache mode via On-Stack Replacement.
* **Self-Modifying Code (SMC) Attack**: A guest program writes new instructions into its own loop header, asserting that the Micro-TLB write-protect trap invalidates the compiled JIT block and prevents executing stale instructions.

---

## 6. Implementation Phasing & Integration Roadmap

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│     Phase 1      │     │     Phase 2      │     │     Phase 3      │     │     Phase 4      │
│  Commit Monitor  ├────►│ Software Golden  ├────►│ riscv-tests      ├────►│ Replay Engine &  │
│  Diagnostic Bus  │     │ Reference Model  │     │ Regression Suite │     │ CI Automation    │
└──────────────────┘     └──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Phase 1: Diagnostic Commit Log Interface (HDL & Simulation)
* Implement the architectural retirement monitor in `hdl/parcore/lib/parcore_top.dart`.
* Expose `commitValid`, `commitGuestPc`, `commitInstWord`, `commitRdAddr`, and `commitRdData`.
* Verify that speculative flushes and stalled instructions do not emit spurious commit tokens.

### Phase 2: Golden Reference Bridge (Dart / Test Framework)
* Create `test/helpers/riscv_reference_model.dart` (or hook into native Spike C-API via Dart FFI).
* Implement the lockstep comparison engine in `hdl/parcore/test/helpers/cosim_runner.dart`.
* Verify basic arithmetic instruction traces against the golden model.

### Phase 3: Architectural Test Suite Integration (Tooling & Binaries)
* Build automated harness to compile, link, and execute the official `riscv-tests` repository.
* Map pass/fail macro exits (`tohost` / `gp == 1`) to automated Dart test assertions.
* Establish automated test coverage reports for all RV32IM_Zbb instructions.

### Phase 4: Deterministic Replay & Continuous Integration (CI)
* Implement the event recording logger and replay harness.
* Integrate full regression runs into `dart test` under CI environments.
* Set regression gating: zero divergence allowed across all standard compliance tests.

---

## 7. Summary & Deliverables

| Verification Component | Purpose | Target Artifact |
| :--- | :--- | :--- |
| **Commit Diagnostic Bus** | Hardware retirement observability | `hdl/parcore/lib/parcore_top.dart` |
| **Lockstep Co-Simulator** | Cycle-accurate state comparison | `hdl/parcore/test/helpers/cosim_runner.dart` |
| **Golden Reference Model** | Authoritative RISC-V behavior | `hdl/parcore/test/helpers/riscv_golden_model.dart` |
| **Compliance Test Harness** | Official test suite automation | `hdl/parcore/test/compliance/riscv_tests.dart` |
| **Deterministic Replay** | Multi-core race condition reproduction | `hdl/parcore/test/helpers/replay_harness.dart` |

This verification foundation ensures that subsequent architectural changes—such as adding functional units, modifying cache refill bursts, or tuning JIT templates—can be undertaken with complete regression safety.