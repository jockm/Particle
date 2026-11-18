# Parcore Architecture Proposal 08: Tiered Execution Model — Interpreted Cold Paths & Hotspot JIT

**Document ID:** ARCH-PROP-08  
**Status:** Proposed  
**Target Platform:** Lattice ECP5-45F / ECP5-85F (ULX3S)  
**Hardware Description:** Intel ROHD (Dart)  

---

## 1. Executive Summary & Dependency Declaration

### Dependency Declaration
This proposal represents **Tier 08** of the Parcore architecture roadmap and directly **depends on and extends**:
1. **`01_the_parcore_conductor_architecture_proposal.md` (`ARCH-PROP-01`)**: Provides deterministic firmware staging and supervisor reset sequencing.
2. **`02_parcore_cluster_performance_optimization_proposal.md` (`ARCH-PROP-02`)**:
   * **SARF Multi-Port Register Fabric**: Provides direct hardware register access ($x0$–$x31$), allowing compiled native Particle instructions to read and write guest state with zero software memory/scratchpad overhead.
   * **Stream Windowing (`FIFO.PEEK`, `FIFO.ADV`) & Classification RAM**: Provides single-cycle opcode classification and bit-slicing required for fast basic block scanning.
   * **Synchronous Hardware FIFO Flushing**: Allows instantaneous purges of in-flight tokens when transitioning between interpreter and JIT execution modes.
3. **`03_parcore_verification_golden_trace_co_simulation_suite.md` (`ARCH-PROP-03`)**: Activates the `commitIsJit` Commit Log signal for cycle-by-cycle lockstep validation of JIT-compiled basic blocks against the golden reference model.
4. **`04_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md` (`ARCH-PROP-04`)**:
   * **Decoupled Functional Cores (2A Int/Branch, 2B DSP Math, 3 AGU/Mem)**: Serves as the target execution fabric for JIT-emitted instruction sequences.
   * **SARF Reservation / Busy Scoreboard**: Hides multi-cycle math or SDRAM cache refill latency during native basic block execution.
5. **`05_parcore_autonomous_accelerator_coprocessor_architecture_proposal.md` (`ARCH-PROP-05`)**: Allows JIT templates to emit escaped `XTRA` (`0xFF`) instructions directly into compiled basic blocks.
6. **`06_parcore_memory_hierarchy_sdram_dma_proposal.md` (`ARCH-PROP-06`)**: Activates Master 2 on the Multi-Master Crossbar for fast Code Cache template refills and binds hardware write-snooping to the Code Cache Directory.
7. **`07_parcore_interrupt_timer_ipi_subsystem.md` (`ARCH-PROP-07`)**: Activates JIT exit-stub interrupt gating so asynchronous CLINT/PLIC interrupts defer cleanly to basic block boundaries.

This proposal defines the architecture and phased implementation strategy for a **Tiered Execution Runtime** on the **Parcore** spatial compute cluster, combining lightweight pipeline interpretation with dynamic Just-In-Time (JIT) compilation for frequently executed code ("hotspots").

Rather than running an expensive AOT compiler over an entire guest binary, or burning block RAM on full dynamic binary translation, Parcore adopts an adaptive **HotSpot/Transmeta-style tiered execution model**:

* **Tier 1 (Cold / Infrequent Code)**: Interpreted across the distributed Parcore pipeline (`Core 0: IF` $\to$ `Core 1: ID` $\to$ `Core 2: EX` $\to$ `Core 3: MEM`) at 0.06–0.25 IPC. Eliminates compile-time overhead for initialization, boot routines, syscalls, and infrequent branches.
* **Tier 2 (Hotspot Detection)**: Hardware/firmware profiler monitors backward branches and loop trip counts.
* **Tier 3 (JIT Translation Cache)**: Loops crossing execution thresholds are dynamically compiled into native Particle RISC sequences inside dedicated Code Cache Block RAMs and executed at **0.50–0.90 native IPC (30–60 MIPS)**.

> **Width Parameterization Mandate (Particle-64 Readiness):** The `target_pc` tag in the 16-entry Hardware Branch Frequency Table (BFT) and the `Guest_PC` tag in the Code Cache Directory are parameterized to `dataWidth` (default `32`, scaling to `64` in **Proposal 12: `12_particle_64_bit_architecture_extension_proposal.md`**).

---

## 2. Architectural Motivation: Overcoming the Interpreter Tax

While **Proposal 02** and **Proposal 04** optimize the distributed interpreter, interpreting guest instructions instruction-by-instruction carries an unavoidable **Interpreter Tax**:
* Fetching, slicing bitfields, decoding opcodes, and dispatching multi-token FIFO packets consumes 4–10 native Particle instructions per guest instruction.
* In inner loops (e.g., matrix multiplies, checksums, string searches), this tax is paid repeatedly on every single iteration.

By compiling a detected loop into native Particle assembly:
$$\text{Guest RV32 Loop: } 5 \text{ instructions} \times 1,000 \text{ iterations} = 5,000 \text{ guest ops}$$
* **Interpreted Path**: $\approx 5,000 \times 14 \text{ native cycles} = 70,000 \text{ cycles}$.
* **JIT-Compiled Path**: $\approx 7 \text{ native instructions} \times 2 \text{ cycles/inst} \times 1,000 \text{ iterations} + 80 \text{ cycles compile overhead} \approx 14,080 \text{ cycles}$ (**$5\times$ speedup**).

---

## 3. System Topology & Core Allocation

To support tiered execution without disrupting existing pipeline roles, cluster responsibilities are configured as follows:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        PARCORE TIERED ARCHITECTURE                     │
│                                                                        │
│   INSPECTION & PROFILING                TRANSLATION & COMPILATION      │
│   ┌───────────────────────────┐         ┌───────────────────────────┐  │
│   │ Core 0: IF & Profiler     │         │ Core 1: ID / JIT Engine   │  │
│   │ - Program Counter Gen     │         │ - Cold Path Dispatch      │  │
│   │ - Loop Trip Counters      │         │ - Dynamic Binary Compiler │  │
│   │ - Code Cache Directory    │         │ - Particle Code Emitter   │  │
│   └─────────────┬─────────────┘         └─────────────┬─────────────┘  │
│                 │                                     │                │
│                 ▼                                     ▼                │
│   ┌─────────────────────────────────────────────────────────────────┐  │
│   │               Dynamic Code Cache (TCM Block RAM)                │  │
│   │  Stores translated native Particle micro-op sequences           │  │
│   └─────────────────────────────┬───────────────────────────────────┘  │
│                                 │ Native Fetch                         │
│                                 ▼                                      │
│   EXECUTION & STATE MANAGEMENT                                         │
│   ┌─────────────────────────────────────────────────────────────────┐  │
│   │ Backend Cores: Core 2A (ALU), Core 2B (Math), Core 3 (Mem/AGU)  │  │
│   └─────────────────────────────┬───────────────────────────────────┘  │
│                                 │                                      │
│                                 ▼                                      │
│   ┌─────────────────────────────────────────────────────────────────┐  │
│   │           Shared Architectural Register Fabric (SARF)           │  │
│   │  Direct physical mapping of guest registers (x0..x31)           │  │
│   └─────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

1. **Core 0 (Profiler & Fetch Engine)**:
   * In Cold Mode, fetches guest words from SDRAM/cache via **Proposal 06's** crossbar and feeds Core 1 over FIFO Channel 1.
   * Tracks target addresses of backward branches.
   * Intercepts PC fetches that hit the **Code Cache Directory**: if a compiled block exists, redirects fetch directly into the Code Cache.
2. **Core 1 (Dual-Role: Interpreter Dispatcher & JIT Compiler)**:
   * **Mode A (Interpreter)**: Runs standard table-driven dispatch via Classification RAM to backend cores.
   * **Mode B (Compile Strobe)**: When Core 0 triggers a Hotspot Trap, Core 1 parses the guest basic block, maps guest registers directly to native SARF operands, and writes native Particle machine code directly into the Code Cache.
3. **Core 2A, 2B, 3 (Execution Engines)**:
   * Execute both interpreted micro-ops and JIT-compiled basic blocks natively against the SARF.

---

## 4. Hotspot Profiling & Detection Hardware

To avoid software profiling overhead, Parcore adds a minimal hardware **Branch Frequency Table (BFT)** to Core 0's datapath:

### 4.1. Hardware Branch Frequency Table (BFT)
* **Structure**: A 16-entry direct-mapped circular table in `parcore_top.dart` / `cpu_core.dart`.
* **Index**: `target_pc[5:2]`.
* **Entry Fields**:
  * `target_pc [dataWidth-1:0]`: Guest branch destination address.
  * `trip_count [7:0]`: 8-bit saturating counter.
  * `compiled_flag [0]`: Set to 1 if already translated in Code Cache.
* **Operation**:
  * Whenever Core 2 evaluates a taken backward branch (`target_pc < current_pc`), the BFT increments `trip_count` for that target.
  * When `trip_count == HOTSPOT_THRESHOLD` (e.g., 32 or 64 iterations) and `compiled_flag == 0`:
    * Hardware fires an internal vector trap (`MBOX Vector 2: Hotspot Detected`) directly to Core 1.
    * Sets `compiled_flag = 1`.

---

## 5. Binary Translation: Guest RISC-V to Native Particle Code

Because the SARF exposes guest registers $x0$–$x31$ directly to execution cores, translating basic blocks is a direct, template-based 1:1 or 1:2 mapping.

### 5.1. Translation Examples

#### Example 1: Integer ALU Operation
* **Guest Instruction**: `ADD x5, x1, x2` (Add $x1$ and $x2$, store in $x5$)
* **Particle Native Template** (assuming SARF register bank mapped to $R1$–$R31$):
  ```assembly
  ; Particle 16-bit instructions emitted into Code Cache:
  MOV    R5, R1        ; R5 = x1 (1 cycle)
  ADD    R5, R2        ; R5 = x1 + x2 (1 cycle)
  ```
  *(Execution: 2 native instructions = 4 cycles vs. 18 interpreter cycles).*

#### Example 2: Immediate Math
* **Guest Instruction**: `ADDI x10, x10, 1`
* **Particle Native Template**:
  ```assembly
  ADD    R10, 1        ; Single-cycle native Particle immediate add
  ```
  *(Execution: 1 native instruction = 2 cycles vs. 14 interpreter cycles).*

#### Example 3: Loop Branch (Back-Edge)
* **Guest Instruction**: `BNE x5, x0, loop_start`
* **Particle Native Template**:
  ```assembly
  ; Direct native conditional branch inside Code Cache:
  BBRA.NZ R5, _cached_loop_start
  ```

### 5.2. Exit Stubs & De-optimization (Fallback)
Every compiled basic block ends with an **Exit Stub**:
* If a branch exits the loop (cold exit) or **Proposal 07's** `irqPending` flag is asserted at the block boundary, the stub:
  1. Writes the current guest PC back to Core 0's PC register.
  2. Clears the Code Cache active bit.
  3. Resumes normal 4-stage pipeline interpretation (or interrupt vectoring) at the exit PC.

---

## 6. Code Cache Memory Architecture

* **Storage**: A dedicated 4 KB to 8 KB True Dual-Port Block RAM (`parcore_code_cache.dart`).
  * **Port A**: Connected to Core 1 (Write interface for emitting compiled instructions) and Master 2 of **Proposal 06's** crossbar.
  * **Port B**: Connected to Core 0 / backend execution fetch (High-speed fetch port).
* **Code Cache Directory (LUT-RAM)**:
  * 32-entry fully associative or set-associative cache mapping `Guest_PC [dataWidth-1:0] -> Cache_TCM_Address`.
  * Connected to **Proposal 06's** crossbar write-snoop bus for 1-cycle invalidation on self-modifying code stores.
  * If Core 0's fetch address matches a valid directory tag, Core 0 suspends FIFO streaming to Core 1 and signals the execution engine to branch directly into the Code Cache TCM.

---

## 7. Phased Implementation Roadmap

To maintain verification discipline and avoid breaking the existing 4-stage cluster, this tiered architecture is deployed across four discrete phases:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Phase 1     │     │     Phase 2     │     │     Phase 3     │     │     Phase 4     │
│   Code Cache    ├────►│ Static Block    ├────►│ Hardware BFT    ├────►│ Full HotSpot /  │
│   Dual-Port BRAM│     │ Execution Test  │     │ Profiler Hook   │     │ Dynamic JIT Loop│
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Phase 1: Code Cache Storage & Dual-Port TCM Integration (HDL)
* Instantiate `ParcoreCodeCache` in `parcore_top.dart`.
* Wire Port A to Core 1's memory bus (write-only code generation), bind Master 2 + store-snoop invalidation on **Proposal 06's** crossbar, and wire Port B to execution fetch multiplexers.
* Verify memory write and execution isolation in ROHD unit tests.

### Phase 2: Static Template Translation Verification (Firmware)
* Hand-compile a known guest benchmark loop (`guest_rv32_test.bin`) into native Particle instructions and pre-seed the Code Cache.
* Implement the switchover mechanism: Core 0 detects the start PC, jumps to the Code Cache, executes against the SARF, and verifies correct register results upon exit via **Proposal 03's** Commit Log Bus (`commitIsJit = 1`).
* Measure raw execution IPC on the compiled loop (target: $>0.50$ native IPC).

### Phase 3: Hardware Branch Frequency Profiler (BFT) (HDL & Co-Design)
* Add the 16-entry `BranchFrequencyTable` in `parcore_top.dart`.
* Connect branch resolution signals from Core 2 to increment target counters.
* Implement `MBOX Vector 2` interrupt generation when counter crosses threshold.
* Verify profiler triggering using Dart testbench simulations.

### Phase 4: Dynamic JIT Compiler Microkernel (Firmware)
* Implement the JIT code generation engine in Core 1's firmware (`core1_jit.asm`).
* Connect the Classification RAM and `FIFO.PEEK` front-end to scan basic blocks upon receiving Vector 2.
* Emit native templates into the Code Cache and register the block in the directory.
* Run end-to-end tests: guest code starts in interpreter mode, detects hot loops, compiles dynamically, and seamlessly accelerates inner loops without host intervention.

---

## 8. Expected Performance & Utilization Summary

| Execution Mode | Cycles / Guest Inst | Effective RV32 IPC | Effective MIPS (@ 75 MHz) | Resource Footprint |
| :--- | :---: | :---: | :---: | :--- |
| **Baseline Interpreter** (Current) | 16–22 cycles | $\approx 0.05 – 0.06$ | $\approx 4 – 5$ MIPS | 0 extra LUTs / BRAMs |
| **Optimized Interpreter** (Proposals 02 & 04) | 5–8 cycles | $\approx 0.15 – 0.22$ | $\approx 12 – 18$ MIPS | +SARF, +Scoreboard (~450 LUTs) |
| **Tiered Hotspot JIT** (This Proposal) | **1.5–2.5 cycles** (in hot loops) | **$\approx 0.45 – 0.70$** | **$\approx 35 – 55$ MIPS** | +Code Cache BRAM (1–2 EBR blocks) |

### Summary Benefit
By reserving JIT compilation exclusively for hot loops, Parcore achieves **near-native FPGA execution speeds (35–55 MIPS)** while keeping code cache memory requirements under **8 KB** and preserving full compatibility with arbitrary guest code on the cold interpreter path.
