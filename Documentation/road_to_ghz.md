# Road to GHz

The project's goal is a fast, flexible multi-core design that could run at several GHz if built on a 22/28 nm class process. This document records what stands between the current design and that goal, and what we might do about it, so we can come back to it.

**Priority:** none of this comes before getting the end-to-end Parcore design running on the ULX3S. This is a list to return to afterwards, not a plan in progress.

**Parcore isn't fixed.** The current Parcore design (each RISC-V pipeline stage as a Particle core running firmware) came from an earlier discussion and isn't a commitment. If a different design serves the goal better in the long term, we can change it.

## The larger goal

The ULX3S limits how many Particles a design can have, but the aim is a system of dozens, perhaps hundreds, of Particles, configured at boot for one job or another:

* Several Parcores side by side: a multi-core RISC-V system, or a RISC-V Parcore next to one emulating another architecture (a Pentium, say).
* "Spare" Particles as I/O controllers, or for dedicated computation.
* Inside a Parcore, techniques such as out-of-order and superscalar execution or an internal JIT; but the point is larger systems that are fast and flexible.
* **Small, lean Particles**, so that many fit: a lot of them on an FPGA, dozens to hundreds on an ASIC or a tiled design, with room left for a JIT and the other things we want to try. Speed must not be bought with size that stops this. With the register file in LUT RAM (364), one Particle core is about 6,800 LUTs on the ECP5 (8% of the 85F), and Parcore's five cores about 29,500 (35%), so the 85F holds about twelve cores: still too few. Each core's size, and what it can leave out, needs tracking alongside the cycle counts (item 19).
* **Each core's firmware stays in its own local memory**, for speed: the stage cores' hot loops must never wait on a shared memory. Large or shared data (a guest's memory) can live further away, behind caches (item 18).
* **A Parcore RISC-V somewhere near native RISC-V performance.** This is the hard target. Today a RISC-V instruction costs about 75 Particle cycles (down from 285 in November 2026), so closing that gap (dispatch, decode, hardware assists, perhaps translation) matters more than the clock. It will take time, refinement and experiment.

**ParticleMan.** Besides Parcore, Particle is to be the base of ParticleMan: both the name of a build of many Particle cores and of the OS it runs, like MicroRISC4's Mr4OS (clusters of 2–256 MR4 cores: core 0 runs the kernel and I/O, the others run applications, one of them with console input and output and others with output if wanted, each with a small resident program that loads programs and dispatches OS messages over the network), but more advanced. For the hardware that means small, lean cores (item 19), a network on chip with `MBOX` and broadcast for OS messages (item 15), and a small local memory per core for its resident program (item 18).

This shapes the items below: the network on chip and the `MBOX` redesign are what let many Particles be arranged at boot, and the firmware and ISA work is aimed at the per-instruction cost.

The conductor will have more jobs: a watchdog over the other cores, and a serial console on a second UART for loading new firmware and the like. Writing it in Action was tried (`conductor.act`) and wasn't practical yet: it needed more than 2 KiB and a multiplier. To revisit: Action with multi-line `asm` blocks, not just single `asm("...")` statements, and the conductor written in Action.

---

## Where we are (November 2026)

| | |
|---|---|
| Particle core | 4-stage pipeline (F, D, E, W) with forwarding; see `hdl_architecture.md` |
| Measured on the ECP5-85F | about 40 MHz Fmax (39.1–40.3 MHz across placements); the ULX3S runs it at 35 MHz |
| Before the pipeline | 16.9 MHz, single cycle |
| What limits it now | several paths at about 40 MHz each: D's decode and register read into the fetch address, E's ALU, forwarding and redirect, and the multiplier's output into write-back. Fixing any one alone doesn't help. |
| Parcore | four stage cores (IF, ID, EX, MEM) and a conductor, connected by FIFOs; every RISC-V instruction is many Particle instructions in each stage |
| Parcore on the ECP5-85F | 45% of the LUTs and about 34 MHz Fmax (run at 25 MHz on the ULX3S), with the FIFOs in block RAM; 65% and about 29 MHz before `RBASE` was removed |
| Biggest block in each core | the register file: 16 registers and 16 shadows in flip-flops since `RBASE` was removed, which took the single core from 12,427 to 9,137 LUTs and 2,763 to 1,734 flip-flops |

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
  * The shadow-bank exchanges (`XCHG`, `XCHGALL`, `XCHGMOST`) force a refetch. (`RBASE`, which also remapped every register read, has been removed.)
  * R14 is the implicit destination of every imm8 operation, which creates dependencies the program didn't ask for.
  * `MBOX` is taken at any instruction boundary.

  None of these is fatal, but each costs a pipeline stall or a mux on the critical path.

### 2. Parcore's throughput is set by software, not the clock

Each RISC-V instruction becomes many Particle instructions in each stage: core 2's dispatch is a chain of compare-and-branch, and FIFO traffic, epoch checks and scoreboarding come on top. Measured on the demo guest (`apps/riscv/hello.S`, in simulation): its main loop, 18 RISC-V instructions with two branches, takes about 3,800 Particle cycles a pass, and printing a character (7 instructions, including a call and a return) about 2,190: roughly 200–300 Particle cycles per RISC-V instruction. Even at 3 GHz that would be roughly 10–15 RISC-V MIPS, slower than a plain single-issue RISC-V core at a few hundred MHz. A faster clock makes the cost cheaper but doesn't change the ratio; the per-instruction software cost is what has to come down.

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
* Make the register file smaller still: it is in flip-flops, 16 registers and 16 shadows. LUT RAM, or fewer shadows, would help both area and the read path.
* Branch prediction alongside: backward-taken/forward-not-taken first, then a small branch target buffer. A CPU hint instruction may also help here.
* Remove `RBASE` (done): nothing uses it, and a 15-register window can't show three arbitrary guest registers at once, so it doesn't help emulate 32-register architectures. Guest registers live in memory (core 1's zero page), as emulators usually keep them. If more fast storage is ever needed, Thumb-style high registers reachable only through moves would avoid remapping every read.
* Use the block RAMs' output registers on the FPGA. This adds a cycle to fetch and loads, so it needs measuring.

### Step 3: cut Parcore's per-instruction cost (or change Parcore)

Roughly in order of effort:

* **Use the instructions Particle already has.** The stage firmware uses none of `JTBL` (jump-table dispatch), `BEXTR` (bit-field extract) or `DIV`/`MOD`. Core 2 picks each operation with chains of compare-and-branch (144 long jumps) and divides in software (`_udiv_calc`, about 32 loop iterations); core 1 extracts RISC-V fields with shift-and-mask sequences. Rewriting them with `JTBL`, `BEXTR` and `DIV` needs no ISA change and is probably the biggest gain available. Agreed (337): the first step after end-to-end Parcore, measured stage by stage.
* The new Particle instructions in [Particle ISA additions](#particle-isa-additions), especially the 2-word branches and the immediate `BEXTR`.
* FIFO-to-register paths that skip the explicit `FIFO.R`.
* More than one core per slow stage, such as two EX cores taking alternate instructions (proposal 04 points this way).
* Hardware decode for the common RISC-V formats, with firmware handling the rest. This is the biggest step and trades away some flexibility.
* Or a different Parcore design altogether, if one serves the goal better.

**Measure first.** Before choosing, instrument the Verilator runs to count, for each stage core, the cycles spent working versus waiting on a FIFO, and how long dependent instructions wait. That shows which stage limits Parcore and whether the dependency round trip matters.

**SARF (proposal 02).** A hardware register file holding the guest's `x0`–`x31`, shared by the stage cores through dedicated ports, with a busy bit per register. It would replace core 1's software register file, in-flight counts and writeback handling.

* It could help with core 1's per-instruction bookkeeping, and with the dependency round trip: today a result goes core 2 → core 3 → `memToWb` → core 1 before a dependent instruction can use it, ALU results included.
* It doesn't help the conductor: the guest registers are already in core 1's TCM (`0x00`–`0x7F`), which the conductor can reach through its window.
* It's shared state between cores, against the CSP/transputer model Particles are meant for (cores coordinate over channels, with no shared memory), and it ties cores 1, 2 and 3 together. A register file shared by cores spread across a die is also hard to time at GHz.
* Cheaper options in the same spirit: send ALU results from core 2 straight to core 1 on a FIFO of their own instead of through core 3; add Particle instructions that make core 1's bookkeeping cheaper.

### Particle ISA additions

Agreed (337, 338): one step after the firmware rewrite. Each touches the spec, the core, psim, pasm and its linter, and the Action compiler.

* **2-word branches**, with a signed 16-bit displacement in the second word, covering the whole TCM in either direction: `BRA disp16`, `BRA.Z/NZ/N/P Rr, disp16` (any register, not just R14), and `CALL Rl, disp16` (PC-relative, with link). Today a far jump is `LOAD16 R14, label` + `JMP R14, R0`: 3 halfwords and about 5 cycles, and a conditional one adds an inverted short branch around it. The stage firmware has 234 of them. The displacement arrives while the first halfword is in D, as for `LDI`, and E decides: about 3 cycles when taken. Free opcodes: `0xBC`–`0xBF`, `0xCC`–`0xCF`.
* **Compare-two-registers-and-branch**, `BEQ`/`BNE Rr, Rl, disp16`.
* **Immediate `BEXTR`**: a 2-word form with the position and length in the second word, from a source register that isn't overwritten, so a RISC-V field is one instruction.
* **`JTBL` strides**: the Rl field (ignored today, and written as 0 by pasm) gives the entry size: 0 two bytes (as now, a short branch), 1 four bytes (a 2-word branch to anywhere), 2 eight bytes and 3 sixteen bytes (a handler inline, like the trap table's slots). Only a shift of the index in the pipeline.
* **`WAIT` and `HALT`, and low power.** `WAIT` sleeps until an `MBOX` arrives from any core, keeping the core's state. `HALT` sleeps until reset: the conductor restarts the core through `RST_CTRL`, and may reload its TCM first, so a halted core could later be powered down completely. Asleep, the core's clock enable (and its block RAMs') is off on the FPGA, and its clock is gated on an ASIC, with only the `MBOX` and reset logic awake. A blocking `FIFO.R` can sleep the same way while it waits. The conductor gets a status bit per core (running, waiting, halted) and a way to send an `MBOX` to any core. In the pipeline both are a stall that only `MBOX` or reset ends.

  *Done (426–429): as above, with `WAIT` ending on a pending `MBOX` even when masked (like RISC-V's `WFI`), `CORE_STATE` at `0xF000_0028` (2 bits per core: running, waiting, halted, in reset) and the conductor's `MBOX`. Still to do: the clock enables and gating (with item 7), and a status for a core asleep in `FIFO.R`.*
* **The `MBOX` redesign**, all five parts:
  1. **R14:** trap entry writes the return PC into R14, destroying the interrupted code's R14 (a known issue in the spec; `lib/particle_runtime.asm`'s handler returns to interrupted code). An `MBOX` trap switches to the shadow bank in hardware, with the return PC in S14, and a new `RETI` swaps back and returns.
  2. **Masking:** `DI`/`EI`; an `MBOX` that arrives while masked waits until the core unmasks.
  3. **No lost messages:** today a newer `MBOX` replaces one not yet taken. A small queue of pending `MBOX`es, or a busy result the sender can check, as with `FIFO.TRYW`.
  4. **Any target:** `MBOX Rr, Rl`, with the target core in a register, instead of wiring fixed by configuration.
  5. **Scale:** carried through the interconnect as messages, a few cycles' latency, instead of a single-cycle strobe across the chip.

  Together: an `MBOX` is a message on a per-core interrupt channel, queued, maskable and addressed to any core. Its arrival traps, and the handler reads the value with `FIFO.R`, which also removes the memory write at trap entry (`MBOX_VALUE`).

  *Designed in [mbox_design.md](mbox_design.md) (398–409), which replaced parts of this: `EPC` and `RETI` instead of the shadow bank, and the value read from network-interface registers rather than with `FIFO.R`. psim implements all of it; the HDL implements it in steps 3a (the core, the queue, `ACK`/`NACK`, the registers, Parcore's redirect over the ring) and 3b (writable tables, `CONFIG`, broadcast). The masking instructions are `EI`/`DI` (409), covering every asynchronous trap.*
* **A per-core timer** (410), for multitasking in ParticleMan and for embedded programs: a free-running counter and a compare register in each core (or its network interface), raising an asynchronous trap on its own vector when the counter reaches the compare value. It is masked by `DI` like `MBOX`, returns with `RETI` through `EPC`, and is left out by a `CpuConfig` option. To be designed: where its registers live (beside the `NI_` registers at `0xFFFF_FF10` up is one choice), its vector, one-shot or periodic, and what happens when it and an `MBOX` are due together.
* Later, a static "likely taken" bit on the 2-word conditional branches could let D redirect early for loops.

Avoid, for the core's speed: instructions that write two registers, read three, or do a memory access and ALU work together.

### Step 4: design the multi-core system for scale

* Caches in front of the TCMs, or instead of them.
* **Memory (358, for later):** each core keeps its firmware in a small local memory, and the guest's memory moves to SDRAM.
  * Guest memory in SDRAM, behind an instruction cache in core 0 and a data cache in core 3, with one SDRAM controller shared through the network. FENCE.I becomes a cache invalidation, and the store mirror between cores 0 and 3 goes away. The particle package already has a cache subsystem and an SDRAM controller (`cache_subsystem_test.dart`, `sdram_controller_test.dart`), and MicroRISC4 has I/D caches with an SDRAM controller to compare with.
  * Firmware stays local, loaded at boot by the conductor (from flash, or from a reserved block of SDRAM): the stage cores' hot loops must not wait on a shared controller. A cache that is filled at boot and then locked is the same thing.
  * A Harvard split of each core's local memory (instruction memory on the fetch port, data memory on the data port, at different addresses) makes each memory smaller and single-ported. That matters most in an ASIC; the OpenROAD numbers (item 2) should decide it. It suits Parcore: core 0's guest image is already data to core 0, read with loads.
* **A network on chip (339)** instead of dedicated FIFOs, so any core can message any other. Dedicated FIFOs need on the order of N² for all-to-all, with wires that lengthen as the chip grows.
  * A router per core, linked to its neighbours: a ring first, a 2D mesh with more cores. Every hop is registered, so no wire crosses the chip.
  * Packets: a header (destination core, destination channel, type: data or `MBOX`) and the data word.
  * A network interface per core holds the receive buffers for its input channels (block RAM), so `FIFO.R`, `FIFO.STAT` and `FIFO.TRYR` still work locally.
  * Each core has a channel table, set up by the conductor, mapping its local channel numbers to (destination core, destination channel). Firmware still writes "my channel 2", so Parcore's stage firmware needn't change.
  * `MBOX` is a priority packet type on the same network: the `MBOX` redesign above.
  * Costs: 1–2 cycles per hop; credit-based flow control, so nothing is dropped ("full" becomes "no credit", and checks like "fewer than 128 words" change meaning); deadlock avoidance (fixed routing order, `MBOX` packets kept apart from data); routers of a few hundred LUTs each.
  * In order with fixed routes, which Parcore depends on.
  * Steps: (1) the channel table and network interface over today's direct links, with nothing behaving differently; (2) a ring of routers; (3) `MBOX` as packets; (4) a mesh when the core count calls for it. psim already routes channels from a JSON configuration, so it can model the latency first.
  * The design note: [noc_design.md](noc_design.md) (packet format, flow control, flush, the channel table, what `FIFO.STAT` reports), for agreement before any code.
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
| 4 | Remove `RBASE`: 16 registers plus 16 shadows, keeping `XCHG`/`XCHGALL`/`XCHGMOST`; `0xD3`/`0xD4` become illegal. Touches the spec, the core, psim, pasm and its linter, and the tests. Thumb-style high-register moves (`MOVHI`/`MOVLO`) only if a need is shown | Done: the single core went from 12,427 to 9,137 LUTs, Parcore from 53,758 to 37,678 LUTs and from 28.8 to 33.8 MHz. `0xD3`/`0xD4` are reserved for the coming ISA additions (346) |
| 5 | Parcore per-instruction cost, or a different Parcore design | Not started |
| 6 | Caches, interconnect and memory controller for many cores | Not started |
| 7 | Portable hardware description (resets, SRAM wrappers, no FPGA primitives) | Not started |
| 8 | ROHD 0.7 migration (after the conductor work) | Planned |
| 9 | Measure each Parcore stage's busy and waiting cycles, and dependency waits | Done: `make parcore-profile`. Baseline on `apps/riscv/bench.S`: 285 cycles per RISC-V instruction; core 1 (ID) is the bottleneck, running 77% of the time with 23% bubbles, while core 2 waits 64% and core 3 82% |
| 10 | SARF, or a cheaper alternative (such as an EX-to-ID result FIFO), decided from 9's numbers | Not needed for now (361): a fast path in core 3 for ALU results (firmware only) took `bench.S` from 83.5 to 75.5 cycles per RISC-V instruction, and core 1's waits for results from 16.6% of its time to 1.1%, so a direct core 2 → core 1 channel would now gain little. To look at again if the result latency grows |
| 11 | Smaller register file (shadow banks) | Part of 19 (364): the register file in LUT RAM |
| 12 | Stage firmware rewritten with `JTBL`, `BEXTR` and `DIV` | In progress (337), one package per core; the core 1 to core 2 packet may change (350). Core 1 done: `bench.S` went from 285 to 163 cycles per RISC-V instruction. Core 2 done (operation numbers in control-word bits 31:24, one `JTBL`, hardware divide): 121 cycles. Core 2 now runs 20% of the time and core 1 about 80% with 17% bubbles: core 1 is the limit again. Core 1 second pass (353a: hot paths fall through, a 128-entry `JTBL`, a shorter retire): 111.5 cycles. Decoding moved to core 0, with static branch prediction there (353 b + c; core 0's TCM 16 KiB, 358): 87.8 cycles, 3.2 times faster than the 285 at the start. Core 1 now waits about 15% of its time for results, so the result latency through cores 2 and 3 is the next limit (item 10); A return-address stack in core 0 (359b) predicts returns: the calls phase went from 98 to 84 cycles, and the whole benchmark to 83.5. Core 3's fast path for ALU results (361): 75.5. Core 1 is the limit again, running about 80% with 19% bubbles |
| 13 | Particle ISA additions: 2-word branches, compare-and-branch, immediate `BEXTR`, `JTBL` strides, `WAIT`/`HALT` | Agreed (337): after 12. Designed (420–433), in three packages. Package 1 done: `BRA`, `BRA.Z`/`NZ`/`N`/`P`, `RJUMP label, Rl`, `BEQ`, `BNE` and `LEA` (`CpuConfig.enableLongBranches`, pasm and psim `--no-long-branches`), with `JUMP`, `JUMP.cc` and `RCALL` using them; 3 cycles taken, 2 not, against 5 for `LDI R14` + `JMP`. Parcore: 75.7 cycles per RISC-V instruction (77.2 before; 76.0 from `JUMP` alone, then core 2's SYSTEM/CSR path rewritten with `BEQ`/`BNE` and core 0's calls with `RJUMP`); cores 0 and 2 have them (about 160 LUT4s each), cores 1 and 3 and the conductor don't. Package 2 done: `BEXTR`/`SBEXTR Rr, Rl, pos, len` (`0x8D`, `CpuConfig.enableImmBextr`, psim `--no-imm-bextr`) and `JTBL Rr, 4`/`8`/`16`; the stage firmware's field and immediate extraction rewritten with them: 70.6 cycles per RISC-V instruction (75.7 before), about 140 LUT4s per core, 39.6 MHz. Package 3 done: `WAIT` (`0xEA`) and `HALT` (`0xEB`) (`CpuConfig.enableWaitHalt`, psim `--no-wait-halt`), the conductor's `CORE_STATE` register (`0xF000_0028`) and its `MBOX` to any core; sleeping is a stall for now (clock enables and gating with item 7). Item 13 is done |
| 14 | `MBOX` redesign: R14 and `RETI`, masking, no lost messages, any target, through the interconnect | Done: designed in [mbox_design.md](mbox_design.md) (398–412, 418); in psim, and in the HDL as steps 3a and 3b. `MBOX.ON`/`MBOX.OFF` renamed `EI`/`DI` (409). Redirect over the ring: 77.2 cycles per RISC-V instruction (77.0 before) |
| 15 | Network on chip replacing the dedicated FIFOs | Agreed (339): design agreed (374–380), [noc_design.md](noc_design.md); step 1 done (385–389): a network interface per Parcore stage core over direct links, nothing behaving differently; step 2 done (392–397): the one-way ring in psim and the HDL, Parcore at 77.0 cycles per instruction on it; step 3 done (`MBOX`, `CONFIG` and broadcast as packets, with 14) |
| 16 | Conductor: watchdog over the cores; console on a second UART for loading firmware | Designed (436–445): a 4 KiB conductor TCM, a cycle counter (`CYCLES`), a stall detector, and a console (`pmon`: a text monitor and a framed binary loader on a second UART, row 0 of the ULX3S header) with a host tool of the same name. Two packages. Package 1 done: the 4 KiB TCM, `CYCLES`, `CORE_PC`, `ACTIVITY` and the watchdog (446), with core 0 asleep in a `WAIT` at the end of a program (447; not `HALT`, which would take no redirect `MBOX`). Next: package 2, `pmon` |
| 17 | Action: multi-line `asm` blocks; then the conductor in Action | Not started |
| 18 | Memory: guest memory in SDRAM with caches in cores 0 and 3; firmware in small local (perhaps Harvard) memories (358) | Not started; core 0's TCM grew to 16 KiB for now |
| 19 | Lean cores: a size budget per core, reported with every build; options to leave out what a core doesn't use (the shadow bank, the multiplier and divider, FIFO channels); the register file in LUT RAM instead of flip-flops | In progress (362a). Measured: a core is about 7,300 LUT4s and 1,300 flip-flops without the multiplier and divider: register file 2,605 LUT4s and 960 flip-flops (36%), ALU 1,776 (24%), the rest of the core 2,884 (40%); the five cores are 93% of Parcore's LUT4s. Agreed order: `make parcore-size` and `make ulx3s-size`, with device totals printed by every bitstream build (363, done); the register file in LUT RAM, with a bank bit per register for the shadows and R14 in flip-flops (364, done: the register file went from 2,605 LUT4s and 960 flip-flops to 381 LUT4s, 83 flip-flops and 32 LUT RAM cells; a stage core from 7,265 to 4,797 LUT4s, and Parcore from 39,544 to 27,665 (nextpnr: 38,560 to 29,480 LUT4s, 7,871 to 3,506 flip-flops, 32.5 to 36.4 MHz; the single core 9,137 to 6,815 LUT4s, about 40 to 42.4 MHz); no cycle cost, except 16 cycles to clear the registers after reset); one shared rotator and comparator in the ALU (365, done: the ALU went from 1,776 to 1,207 LUT4s in the core, a stage core from 4,797 to 4,228, Parcore 28,157 logic cells at 37.2 to 38.1 MHz over two seeds; no ISA or cycle change); sharing in the rest of the core: one adder for E's PC-relative branch targets (it had eight, feeding a 26-way mux), one for D's `FBRA`/`BBRA` target, one for the pointer modes' `± size` (366a, done: in Parcore a stage core's own logic went from 2,640 to 1,847 LUT4s and from 248 to 105 carry cells, a stage core from 4,228 to 3,435 LUT4s, Parcore from 28,157 to 21,941 logic cells and to 39.97 MHz; no ISA or cycle change); leave-out options (366b, done): `enablePointerModes`, `enableSubword`, `enableMboxReceive` and `enableShadowBank` in `CpuConfig` and psim, set per Parcore core to what its firmware uses; the stage cores went from 3,435 to about 2,920–3,120 LUT4s (the register file without its shadow bank from 381 to 153), core 2 from 4,180 to 3,410. Then the ALU's rotator as five `(* keep_hierarchy *)` stage modules (384): the ALU from 1,207 to 1,024 LUT4s, a stage core to about 2,740. Held as an option (369): Yosys's `-nowidelut`, which stops it building wide multiplexers from `PFUMX`/`L6MUX21`; on Parcore it gave 13% fewer logic cells for about 2 MHz less Fmax on average. 364 and 365 together should bring a core to about 4,500 LUT4s, about 17 cores on the 85F |
| 20 | CRC instructions in the ISA (a CRC-16 or CRC-32 step per byte or word), for loaders, network packets and storage | To discuss, later |
| 21 | `CPUINFO`: an instruction reporting the core's identity and features (to discuss: the user has ideas for it), about the same time as 20 | To discuss, later |

Done so far on this road: the 4-stage Particle pipeline (17 to 40 MHz on the ECP5), the single-product multiplier, conditional branches moved to E, the FIFOs moved into block RAM, Parcore running end to end on the ULX3S, and `RBASE` removed.
