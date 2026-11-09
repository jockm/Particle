# Parcore Architecture Proposal 05: Dynamic Code Cache Management, On-Stack Replacement (OSR), and Configurable Software-Assisted MMU

## 1. Executive Summary & Dependency Declaration

This proposal defines the architectural specification, hardware primitives, and runtime protocols for **Dynamic Code Cache Management**, **On-Stack Replacement (OSR)**, and a **Configurable Software-Assisted Memory Management Unit (Software MMU)** inspired by the Transmeta Crusoe/Efficeon Code Morphing Software (CMS) architecture.

### Dependency Declaration

This proposal represents **Tier 5** of the Parcore acceleration roadmap and directly **depends on and extends** the specifications established in:

1. **`01_the_parcore_conductor_architecture_proposal.md`**: Provides out-of-band TCM loading, supervisor watchdog monitoring, and flash memory coordination.
2. **`02_parcore_cluster_performance_optimization_proposal.md`**: Establishes the 32-word Shared Architectural Register Fabric (SARF), Pre-Decode Classification RAM, `FIFO.PEEK`/`FIFO.ADV`, and synchronous FIFO flushing.
3. **`03_parcore_multi_ex_dynamic_out_of_order_architecture_proposal.md`**: Implements heterogeneous functional cores (Core 2A ALU, Core 2B DSP/Div, Core 3 AGU/Mem) with SARF scoreboarded dynamic issue.
4. **`04_parcore_tiered_execution_model.md`**: Establishes the interpreter cold-path fallback, hardware branch frequency profiling (BFT), and basic block template compilation.

### Strategic Objective

While Proposal 04 introduced the concept of compiling hotspot loops into native Particle instructions, deploying dynamic execution on an FPGA requires addressing real-world runtime challenges:
* **Bounded Code Cache Capacity**: Handling eviction, ring allocation, and fragmentation in limited FPGA Block RAM (EBR).
* **Mid-Loop Promotion (OSR)**: Promoting a long-running interpreted loop into the native JIT cache while the loop is actively running, without waiting for loop termination.
* **Self-Modifying Code (SMC)**: Invalidating stale JIT blocks when guest programs overwrite previously compiled code space.
* **Transmeta-Style Software MMU**: Providing complete virtual memory support (RISC-V Sv32 / x86 CR3 paging) with minimal hardware: a simple **16/32-entry Micro-TLB in Core 3 (AGU)** paired with a **software page-table walker**, avoiding the complexity of a monolithic hardware table walker.

---

## 2. Configurable Software-Assisted MMU (Transmeta Blueprint)

Traditional soft-core processors implement fixed, silicon-heavy hardware page table walkers that consume substantial FPGA LUTs and fail to adapt across different target ISAs. Parcore adopts Transmeta's approach: **hardware checks the fast path via a Micro-TLB, while software handles page table walks, page faults, and permission checks.**

```
                     VIRTUAL ADDRESS FROM CORE 1 / AGU (VA)
                                       │
                                       ▼
                     ┌───────────────────────────────────┐
                     │   Hardware Micro-TLB in Core 3    │
                     │   (16 or 32 Fully Associative)    │
                     └─────────────────┬─────────────────┘
                                       │
                    ┌──────────────────┴──────────────────┐
                    │                                     │
                 [ HIT ]                               [ MISS ]
                    │                                     │
                    ▼                                     ▼
     Physical Address Translation            Micro-Trap to Handler Core
     - Direct to TCM / SDRAM Cache           - Software Page Table Walk
     - R/W/X & Dirty Bit Check               - Evaluates satp / CR3 in Memory
     - SMC Write-Protect Check               - Refills TLB via MMIO Port B
```

### 2.1. Parameterized HDL Configuration

In `hdl/parcore/lib/parcore_config.dart`, the MMU is fully parameterizable to preserve minimal FPGA resource utilization when running bare-metal workloads:

```dart
enum ParcoreMmuMode {
  none,         // Flat physical addressing; zero LUT overhead (bare-metal)
  softwareMmu,  // 16- or 32-entry Micro-TLB in Core 3 with software table refilling
}
```

### 2.2. Hardware Micro-TLB Specification (Core 3 AGU)

When `ParcoreMmuMode.softwareMmu` is selected:
* **Organization**: 16-entry (or 32-entry) fully associative content-addressable memory (CAM) synthesized from ~180 LUT4s.
* **Entry Fields**:
  * `vpn[19:0]`: Virtual Page Number (bits [31:12] of VA).
  * `ppn[19:0]`: Physical Page Number (bits [31:12] of PA).
  * `asid[8:0]`: Address Space Identifier (matches current active process).
  * `v`: Valid bit.
  * `r, w, x`: Read, Write, Execute permission flags.
  * `u`: User-mode accessible flag.
  * `g`: Global page flag.
  * `smc`: Self-Modifying Code watchpoint flag (Write-Protect Trap).

### 2.3. Fast Micro-Trap & Software Table Walker

* **TLB Hit (Single-Cycle)**: Core 3 concatenates `ppn[19:0]` with `va[11:0]` to produce the physical address and proceeds with the Port B memory or SDRAM cache transaction.
* **TLB Miss / Permission Fault**:
  1. Core 3 halts the memory request and triggers an internal hardware trap:
     * `Trap 12: TRAP_PAGE_FAULT` (permission violation or unmapped address).
     * `Trap 13: TRAP_TLB_MISS` (valid page exists, but entry absent from Micro-TLB).
  2. The software table-walker microkernel (executing on Core 3 or the Conductor):
     * Reads the guest root page table register (`satp` for RISC-V, `CR3` for x86).
     * Walks the 2-level page directory in memory using standard `LD32` instructions.
     * Selects an eviction victim in the Micro-TLB (Round-Robin or Pseudo-LRU).
     * Programs the new entry via Port B MMIO (`0xF0000050`–`0xF0000058`).
  3. Re-executes the pending memory access.

---

## 3. Self-Modifying Code (SMC) via TLB Write Protection

Dynamic compilation creates coherence hazards when guest software writes to memory locations that contain active JIT-compiled basic blocks.

### 3.1. Zero-Overhead SMC Detection via the MMU

Rather than having Core 3 compare every memory store against a list of active basic blocks:
1. When Core 1 compiles a basic block from guest page $P$, it marks page $P$'s entry in the Micro-TLB with `smc = 1` and clears the `w` (write) permission bit.
2. If the guest application subsequently issues a store (`SB`, `SH`, `SW`) to that page:
   * The Micro-TLB immediately fires a write-protection fault to Core 3.
   * Core 3 vectors to the **SMC Invalidation Handler**.
   * The handler inspects the store target address, locates the overlapping compiled block in the Code Cache Directory, and marks that block as **Invalid**.
   * Core 3 temporarily grants write access, commits the store, and restores the watchpoint.
3. Subsequent fetches to that guest address fall back cleanly to the interpreter or trigger a recompile.

---

## 4. On-Stack Replacement (OSR): Mid-Loop Promotion

In long-running loops (e.g., matrix calculations, decompression, encryption), a loop may execute thousands of iterations during a single invocation. Waiting for the loop to terminate before switching to compiled code forfeits the majority of the performance gain.

```
ITERATION:   1 .. 31                32 (THRESHOLD MET)           33 .. N
MODE:       [ Interpreter ]   ──►   [ OSR Transition ]    ──►   [ Native Code Cache ]
            Core 0 -> Core 1        Core 1 snapshots            Direct native loop
            Core 2 -> Core 3        PC & SARF state,            at 0.5 native IPC
                                    emits JIT block,
                                    redirects Core 0
```

### 4.1. The OSR Mechanism

1. **Threshold Trigger**: On iteration 32, Core 0's Hardware Branch Frequency Table (BFT) increments past the hotspot threshold on a backward branch.
2. **Pipeline Quiescence**:
   * Core 0 halts new fetches and fires an OSR synchronization signal to Core 1.
   * In-flight instructions drain through Core 2 and Core 3 into the SARF.
3. **State Verification**:
   * All 32 architectural registers ($x0$–$x31$) reside in the SARF.
   * The guest loop header PC is confirmed.
4. **On-The-Fly Compilation**:
   * Core 1 parses the basic block from the current PC using `FIFO.PEEK` and Classification RAM.
   * Core 1 generates native Particle instructions into the Code Cache.
5. **Execution Transfer**:
   * Core 0 sets its fetch target to the entry point of the newly compiled block in the Code Cache BRAM.
   * Execution resumes natively on the very next iteration with zero register reloading.

---

## 5. Dynamic Code Cache Management & Basic Block Chaining

### 5.1. Code Cache Memory Organization

* **Dual-Port BRAM Partition**: 8 KB total dedicated Code Cache (`parcore_code_cache.dart`).
  * **Port A**: Core 1 Write Interface (emitting 16-bit native instructions).
  * **Port B**: Execution Fetch Interface (high-speed single-cycle fetch for backend cores).
* **Allocation Policy**: **Circular Ring Buffer (Generational Wipe)**:
  * Blocks are allocated sequentially with a bump pointer.
  * When the ring pointer approaches the end of the 8 KB buffer, Core 1 executes a coarse generation wipe: the Code Cache Directory is cleared, and allocation resets to base.
  * This eliminates complex heap fragmentation, free-list management, and garbage-collection pauses.

### 5.2. Basic Block Chaining (Direct Trampolines)

In naive dynamic binary translation, every basic block exits by returning control to a software dispatcher to resolve the next guest PC, adding 8–12 cycles of overhead per block.

* **Chaining Protocol**:
  1. When Block A compiles, its terminal conditional branch points to a stub that returns to the dispatcher.
  2. If the branch target (Block B) is subsequently compiled into the Code Cache, the runtime patches Block A's terminal branch offset in BRAM:
     ```assembly
     ; Before Chaining:
     BBRA.NZ  R5, _dispatch_stub   ; Bounces through dispatcher (10 cycles)
     
     ; After Chaining:
     BBRA.NZ  R5, _block_b_entry   ; Direct single-cycle jump to Block B!
     ```
  3. Once chained, hot loops oscillate between compiled basic blocks at full silicon speed without touching the interpreter or dispatch engine.

---

## 6. Speculative Abort & Precise Exceptions (Transmeta Gated Commit)

When executing out-of-order across Core 2A/2B or within a JIT-compiled basic block:
* If an unexpected page fault, misaligned memory access, or external UART interrupt occurs mid-block, the architectural state must reflect a clean instruction boundary.

### 6.1. Transactional Commit Points

1. **Block-Boundary State Commit**:
   * Native instructions within a JIT block operate directly against working registers.
   * Guest architectural PC is only officially committed at basic block termination or loop back-edges.
2. **Interrupt Deferral**:
   * Asynchronous external interrupts (UART RX, Timers) set a pending latch but do not interrupt an executing basic block mid-stream.
   * The block completes its current iteration, commits results to the SARF, and yields cleanly at the exit stub.
3. **Synchronous Exception Rollback**:
   * If a page fault or load-access fault occurs in Core 3 during a block:
     * Core 3 triggers an immediate synchronous pipeline clear.
     * Speculative write enables to the SARF are gated off.
     * The cluster rolls back the guest PC to the start of the failing guest instruction and drops into the interpreter, allowing the exact trap vector to be reported accurately.

---

## 7. Phased Implementation Roadmap

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│     Phase 1      │     │     Phase 2      │     │     Phase 3      │     │     Phase 4      │
│  Software MMU &  ├────►│ Code Cache Ring  ├────►│ On-Stack Replace ├────►│ Block Chaining  │
│  Micro-TLB Core3 │     │ & SMC Watchpoint │     │ (OSR Promotion)  │     │ & Spec. Rollback │
└──────────────────┘     └──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Phase 1: Software MMU & Micro-TLB in Core 3 (HDL & Firmware)
* Implement the 16-entry CAM Micro-TLB in `hdl/parcore/lib/parcore_mmu.dart`.
* Add `ParcoreMmuMode` parameter to `parcore_config.dart`.
* Implement software page-table walk routines in `firmware/parcore/riscv/mmu_walker.asm`.
* Verify address translation, TLB miss traps, and page-fault handling in testbenches.

### Phase 2: Code Cache Ring Buffer & SMC Watchpoints (HDL & Firmware)
* Instantiate the 8 KB dual-port Code Cache BRAM in `parcore_top.dart`.
* Connect Micro-TLB `smc` write-protect bits to trigger SMC invalidation traps in Core 3.
* Verify that modifying a guest code page evicts the associated JIT entry from the directory.

### Phase 3: On-Stack Replacement (OSR) Integration (Firmware & Co-Design)
* Connect Core 0's BFT loop counter to trigger OSR promotion vectors.
* Implement the mid-loop SARF synchronization sequence in `core1_id.asm`.
* Test live promotion of a 10,000-iteration guest compute loop from interpreted to native execution.

### Phase 4: Basic Block Chaining & Precise Exception Rollback (Firmware & RTL)
* Implement dynamic branch patching for adjacent compiled basic blocks.
* Add transactional commit gating to the SARF write ports on memory access faults.
* Run complex multi-block benchmark suites demonstrating uninterrupted chained execution.

---

## 8. Summary of Architectural Capabilities

| Architectural Feature | Baseline Cluster (Current) | Tiered JIT (Proposal 04) | With Proposal 05 (Full System) |
| :--- | :--- | :--- | :--- |
| **Virtual Memory Support** | None (Flat physical only) | None (Flat physical only) | **Full Sv32 / x86 CR3 via Software MMU** |
| **MMU Silicon Cost** | 0 LUTs | 0 LUTs | **~180–220 LUT4s (16-entry Micro-TLB)** |
| **Code Cache Management** | None | Static/Fixed BRAM | **Dynamic Ring Buffer with Auto-Eviction** |
| **Loop Promotion** | Must wait for loop exit | Must wait for loop exit | **Live Mid-Loop Promotion via OSR** |
| **SMC Coherence** | Unhandled | Manual software flush | **Zero-overhead hardware TLB write traps** |
| **Block-to-Block Overhead** | N/A | 8–12 cycle dispatcher hop | **1-cycle direct jump (Block Chaining)** |
| **Peak Emulated Throughput** | ~5 MIPS | ~35 MIPS | **45–60 MIPS** |