# Road to GHz

The project's goal is a fast, flexible multi-core design that could run at several GHz if built on a 22/28 nm class process. This document records what stands between the current design and that goal, and what we might do about it, so we can come back to it.

**Priority:** none of this comes before getting the end-to-end Parcore design running on the ULX3S. This is a list to return to afterwards, not a plan in progress.

**Parcore isn't fixed.** The current Parcore design (each RISC-V pipeline stage as a Particle core running firmware) came from an earlier discussion and isn't a commitment. If a different design serves the goal better in the long term, we can change it.

---

## Where we are (November 2026)

| | |
|---|---|
| Particle core | 4-stage pipeline (F, D, E, W) with forwarding; see `hdl_architecture.md` |
| Measured on the ECP5-85F | about 40 MHz Fmax (39.1–40.3 MHz across placements); the ULX3S runs it at 35 MHz |
| Before the pipeline | 16.9 MHz, single cycle |
| What limits it now | several paths at about 40 MHz each: D's decode and register read into the fetch address, E's ALU, forwarding and redirect, and the multiplier's output into write-back. Fixing any one alone doesn't help. |
| Parcore | four stage cores (IF, ID, EX, MEM) and a conductor, connected by FIFOs; every RISC-V instruction is many Particle instructions in each stage |

## What FPGA numbers tell us

The ECP5 is a slow, low-cost FPGA, and most of a critical path there is routing between LUTs. FPGA MHz don't translate reliably into ASIC GHz. What does carry over is how many gate delays fit in a pipeline stage. A common yardstick is the FO4 delay (one inverter driving four others):

* 1 GHz at 28 nm allows roughly 60–70 FO4 per cycle.
* 3 GHz allows roughly 20–25 FO4, including flip-flop overhead.

For scale, approximately: in-order cores with about 8 stages reach about 1.3–1.6 GHz at 28 nm; cores at 2.5 GHz or more there use 12–15 or more stages, branch prediction and carefully built SRAMs.

Our E stage (register read with forwarding, a full 32-bit ALU or shifter, the branch decision and the next fetch address, in one cycle) is probably 1 GHz-class work at 28 nm, not 3 GHz.

---

## What's stopping us

### 1. The Particle core does too much per stage

* **Fetch to decode:** the block RAM output goes straight into decode; there's no instruction register between them.
* **Decode:** D decodes, reads the register file and resolves the unconditional branches into the fetch address in one cycle.
* **Execute:** E holds the whole ALU, the forwarding muxes and the redirect logic.
* **Branches:** there's no prediction. A taken branch costs 1–2 cycles now, and would cost 4–8 in a deeper pipeline.
* **ISA features that are hard to pipeline:**
  * `RBASE` and the shadow-bank exchanges (`XCHG`, `XCHGALL`, `XCHGMOST`) remap registers on the read path and force a refetch.
  * R14 is the implicit destination of every imm8 operation, which creates dependencies the program didn't ask for.
  * `MBOX` is taken at any instruction boundary.

  None of these is fatal, but each costs a pipeline stall or a mux on the critical path.

### 2. Parcore's throughput is set by software, not the clock

Each RISC-V instruction becomes many Particle instructions in each stage: core 2's dispatch is a chain of compare-and-branch, and FIFO traffic, epoch checks and scoreboarding come on top. The official ISA tests suggest tens of Particle cycles per RISC-V instruction. Even at 3 GHz that would be roughly 60–150 RISC-V MIPS, slower than a plain single-issue RISC-V core at a few hundred MHz. A faster clock makes the cost cheaper but doesn't change the ratio; the per-instruction software cost is what has to come down.

### 3. The memory and system design only works on an FPGA

* **Memory:** each core runs from a small private TCM with single-cycle synchronous access. There are no caches, no shared memory hierarchy and no DRAM path.
* **FENCE.I:** works by mirroring stores between two TCMs (core 3 to core 0), which doesn't scale beyond that pair.
* **Global signals:** the flush, the MBOX strobes and the conductor's reset lines are single-cycle signals that fan out across the chip.
* **Many cores:** need a real interconnect (a mesh or a ring) with flow control, coherence or explicit message passing, and a memory controller.
* **ASIC SRAM:** at multi-GHz, an SRAM access takes about a full cycle or more, so a one-cycle TCM becomes pipelined SRAM with 2–3 cycle loads.

### 4. Nothing measures the design in ASIC terms

Everything is tuned against an ECP5. Some structures would cost very differently in an ASIC: register files built from LUTs or flip-flops, memories initialised with `$readmemh`, read-first block RAM behaviour, and the reset style.

---

## What we might do

### Step 1: measure for an ASIC

The open-source OpenROAD flow can synthesise, place and route the Particle core against real cell libraries: Nangate45, SkyWater 130 nm, or ASAP7 (a predictive 7 nm kit). That gives an ASIC Fmax and the critical path in gate delays, which is the number that matters for this goal. It's cheap to set up next to the existing Yosys flow. It should come first, because every change below should be judged by it.

### Step 2: deepen the Particle pipeline, in measured steps

* An instruction register after fetch.
* A separate register-read stage.
* Execute split from the forwarding and redirect logic.
* A memory stage, with 2-cycle loads.
* Write-back.
* Branch prediction alongside: backward-taken/forward-not-taken first, then a small branch target buffer. A CPU hint instruction may also help here.
* Decide what to do about `RBASE` and the exchanges: keep them as slow serialising instructions, or rename registers instead of remapping them.
* Use the block RAMs' output registers on the FPGA. This adds a cycle to fetch and loads, so it needs measuring.

### Step 3: cut Parcore's per-instruction cost (or change Parcore)

Roughly in order of effort:

* A jump-table dispatch instruction in Particle, and bitfield extract/insert, to replace core 2's compare chains and core 1's shift-and-mask decoding.
* FIFO-to-register paths that skip the explicit `FIFO.R`.
* More than one core per slow stage, such as two EX cores taking alternate instructions (proposal 04 points this way).
* Hardware decode for the common RISC-V formats, with firmware handling the rest. This is the biggest step and trades away some flexibility.
* Or a different Parcore design altogether, if one serves the goal better.

### Step 4: design the multi-core system for scale

* Caches in front of the TCMs, or instead of them.
* A real interconnect with flow control.
* Message passing as the main model; Particle's FIFOs and `MBOX` already lean that way.
* One place where coherence is defined; FENCE.I becomes a cache operation.
* SARF and the conductor fit here.

### Step 5: keep the hardware description portable

* Synchronous resets.
* Memories behind wrappers that can become SRAM macros.
* No FPGA-only primitives in the core.
* Eventually, clock gating and test (DFT) hooks.

---

## Tracking

| # | Item | Status |
|---|---|---|
| 1 | End-to-end Parcore running on the ULX3S | In progress: comes before everything below |
| 2 | ASIC measurement with OpenROAD (Nangate45, SKY130 or ASAP7) | Not started |
| 3 | Deeper Particle pipeline and branch prediction | Not started |
| 4 | `RBASE` and exchange instructions: keep serialising, or rename | Not decided |
| 5 | Parcore per-instruction cost, or a different Parcore design | Not started |
| 6 | Caches, interconnect and memory controller for many cores | Not started |
| 7 | Portable hardware description (resets, SRAM wrappers, no FPGA primitives) | Not started |
| 8 | ROHD 0.7 migration (after the conductor work) | Planned |

Done so far on this road: the 4-stage Particle pipeline (17 to 40 MHz on the ECP5), the single-product multiplier, and conditional branches moved to E.
