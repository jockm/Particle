# Parcore Architecture

Parcore is a RISC-V (RV32IM plus parts of Zbb) processor built from Particle cores. Each stage of a RISC-V pipeline is a Particle core running its own firmware, and the stages pass work to each other through hardware FIFOs. A small fifth Particle core, the conductor, can load the stage firmware from SPI flash at power-up.

This document describes the design as it is in `hdl/parcore` and `firmware/parcore`. For the Particle core itself see [hdl_architecture.md](hdl_architecture.md); for the instruction set see [particle_spec.md](particle_spec.md).

## Overview

```
                                                                                              FTDI UART
                                                                                                  │ ch 3
          ┌───────────────┐   ch 1    ┌──────────────┐   ch 1    ┌──────────────┐   ch 1    ┌───────┴──────┐
          │ Core 0  (IF)  │ ────────▶ │ Core 1  (ID) │ ────────▶ │ Core 2  (EX) │ ────────▶ │ Core 3 (MEM) │
          │ fetch         │  ifToId   │ decode, regs │  idToEx   │ ALU, branch  │  exToMem  │ loads/stores │
          └───────▲───────┘           └──────▲───────┘           └──────┬───────┘           └──────┬───────┘
                  │ MBOX vector 1            │ ch 2 (memToWb)           │                          │
                  └──────── branch redirect ─┼──────────────────────────┘                          │
                                             └─────────────────────────────────────────────────────┘
                                                        writeback

          Conductor (core id 7): RST_CTRL, SPI flash controller, writes into every core's TCM
```

| Stage | Module instance | Firmware | TCM | Multiplier / divider |
|---|---|---|---|---|
| Conductor | `parcore_conductor` | `firmware/parcore/conductor/conductor.asm` (from `conductor.act`) | 2 KiB | no / no |
| Core 0, IF | `core0_if` | `firmware/parcore/riscv/core0_if.asm` | 8 KiB | no / no |
| Core 1, ID | `core1_id` | `firmware/parcore/riscv/core1_id.asm` | 4 KiB | no / no |
| Core 2, EX | `core2_ex` | `firmware/parcore/riscv/core2_ex.asm` | 4 KiB | yes / configured, see below |
| Core 3, MEM | `core3_mem` | `firmware/parcore/riscv/core3_mem.asm` | 8 KiB | no / no |

The configurations are in `hdl/parcore/lib/parcore_config.dart` (`ParcoreConfig.conductorConfig`, `core0If`, `core1Id`, `core2Ex`, `core3Mem`). Every stage core has its trap table at `0x100`, so it starts at `0x100` after reset.

`parcore_config.dart` also has `core4Wb` (4 KiB) and `core5Cache` (32 KiB), and `firmware/parcore/riscv` has `core4_wb.asm`, `core5_cache_mem.asm` and `core1_dispatch.asm`. `make firmware` assembles them, but `ParcoreTop` doesn't instantiate cores 4 and 5, so `core4_wb.asm` and `core5_cache_mem.asm` aren't loaded. `core1_dispatch.asm` is used only by a Particle test (`hdl/particle/test/multicore_firmware_test.dart`).

## Source Files

| File | Contents |
|---|---|
| `lib/parcore_top.dart` | `ParcoreTop`: the conductor, the four stage cores, their TCMs, the interconnect, the FTDI UART, and the SPI controller |
| `lib/parcore_interconnect.dart` | `ParcoreInterconnect`: the four stage-to-stage FIFOs, the store-mirror FIFO for FENCE.I, and the flush logic |
| `lib/parcore_tcm.dart` | `ParcoreTcm`: a core's TCM, a synchronous `ParticleBlockRamTdp` (16-bit fetch port, 32-bit data port with byte enables), preloaded with a binary at `0x100` |
| `lib/parcore_config.dart` | The `CpuConfig` of each core |
| `lib/spi_controller.dart` | `SpiController`: the conductor's SPI master |
| `lib/cpu_config.dart` | Parcore's copy of `CpuConfig` |
| `bin/generate_parcore.dart` | Writes `parcore_top.sv` |
| `test/` | ROHD and Verilator tests (see [Tests](#tests)) |
| `test_pipeline.sh` | Runs the RV32 pipeline tests one group at a time |

## Top-Level Ports

| Port | Direction | Width | Use |
|---|---|---|---|
| `clk`, `reset` | in | 1 | Clock and active-high reset |
| `uart_rx`, `uart_tx` | in / out | 1 | FTDI console UART, connected to core 3: the guest's memory-mapped UART (see [Guest I/O](#guest-io)) |
| `spi_cs_n`, `spi_sck`, `spi_mosi`, `spi_miso` | out / in | 1 | SPI flash, driven by the conductor |
| `branch_redirect_strobe`, `branch_redirect_vector` | out | 1, 4 | Copies of core 2's MBOX outputs, for debugging |

The constructor takes `clkFreqMhz` (default 25) and optional binaries for each core (`conductorBinary`, `core0Binary` … `core3Binary`). A binary passed here is preloaded into that core's TCM.

## Interconnect

`ParcoreInterconnect` holds five `ParticleFifoSubsystem` instances, each with one channel of 256 32-bit words in one block RAM:

| FIFO | Writer (channel) | Reader (channel) | Contents |
|---|---|---|---|
| `ifToId` | core 0 (ch 1) | core 1 (ch 0) | 2 words per instruction: PC (bit 0 is the epoch), instruction |
| `idToEx` | core 1 (ch 1) | core 2 (any) | 4 words: control word (bit 0 valid, bit 1 epoch), operand A, operand B, PC |
| `exToMem` | core 2 (ch 1) | core 3 (any) | results and memory requests; a cancel has control-word bit 2 set |
| `memToWb` | core 3 (ch 1) | core 1 (ch 2) | 2 words: destination register (plus `0x20` for a cancel), value |
| `memToIf` | core 3 (ch 2) | core 0 (ch 2) | Guest stores into core 0's guest area, and FENCE.I markers, one word each (see [FENCE.I](#fencei)) |

Because each FIFO has one channel, the FIFO's own channel number is always 0 (`chanSelect: Const(0)`); `ParcoreTop` decodes each core's `fifoChanSelect` to decide which FIFO a push or pop goes to. Core 2 and core 3 have a single input FIFO, so their pops aren't decoded by channel.

A `FIFO.W` to a full FIFO is dropped, so the writers that can get ahead check for room first with `FIFO.STAT`: core 0 pushes a packet only while `ifToId` holds fewer than 128 words, and core 1 decodes an instruction only while `idToEx` does (it keeps retiring writebacks while it waits). `FIFO.STAT` on core 0's channels 1 and 2 reads `ifToId`'s and `memToIf`'s status, on core 1's channels 0, 1 and 2 reads `ifToId`, `idToEx` and `memToWb`, and on core 3's channel 2 reads `memToIf` (any other channel reads `exToMem`). Core 3 mirrors a store only while `memToIf` holds fewer than 128 words.

Core 3's channel 3 is the FTDI UART, not a FIFO: `FIFO.W`/`FIFO.TRYW` on channel 3 send the low byte, `FIFO.TRYR`/`FIFO.R` receive a byte, and `FIFO.STAT` gives bit 0 set when nothing has been received and bit 1 set while the transmitter is busy, so `FIFO.TRYW` only sends when it can. The UART divisor is the clock divided by the baud rate (`ParcoreTop(clkFreqMhz:, ftdiBaud:)`, 25 MHz and 1 Mbps by default, giving 25 cycles per bit; `ParcoreTop.ftdiDivisor`).

### Flush

`pipelineFlush` empties `ifToId`, the instructions core 0 fetched that core 1 hasn't decoded. It is driven by core 2's MBOX strobe (a taken branch or jump, or a FENCE.I) or by the conductor's RST_CTRL bit 6. `memToIf` isn't flushed: a mirrored store is never on a wrong path. `idToEx`, `exToMem` and `memToWb` are only cleared by `reset`: core 1 has already counted the destination of every packet in `idToEx` as in flight, so core 2 drops the stale ones itself (see [Branches](#branches)).

## Stage Firmware

Each stage runs a loop that reads its input FIFO, does its part of the RISC-V instruction, and writes the result to the next FIFO.

**Core 0 (IF)** keeps the guest PC in R10, starting at `0x500` (the guest program is placed in core 0's TCM at `0x500`), and the epoch in R9. Each pass it checks that `ifToId` has room, loads the instruction word at the PC, and pushes `[PC | epoch, instruction]` on channel 1. A zero word is not pushed: core 0 waits at that PC, reading it again on every pass. That is how a guest program ends: by running into memory that was never written. (RISC-V defines 0x00000000 as an illegal instruction; Parcore keeps the zero word as the end of a program instead, and traps on other instructions it can't decode, see core 1.) Its trap vector 1 (`0x110`) branches to the branch-redirect handler, which loads the new PC from `MBOX_VALUE` (`0xFC`), flips the epoch, and goes back to the loop. Each pass also applies one store core 3 mirrored on channel 2, if there is one, before fetching; vector 2 (`0x120`) is FENCE.I (see [FENCE.I](#fencei)).

**Core 1 (ID)** keeps the 32 RISC-V registers in its zero page (`x0`–`x31` at `0x00`–`0x7F`), a count of writes in flight for each register (bytes at `0x90`–`0xAF`), and a mask at `0x80` with a bit set for each register whose count isn't zero. It first retires any writeback on channel 2: it writes the value to the register and takes one from its count (a cancel, destination plus `0x20`, only takes one from the count). Then, if `idToEx` has room, it decodes the next instruction from channel 0, waits while its source registers are in flight (retiring writebacks meanwhile), adds one to its destination's count, and sends a 4-word packet to core 2 on channel 1 with the instruction's epoch (PC bit 0) in control-word bit 1. Every RV32 instruction word has bits [1:0] = `11` and a PC has bit 1 = 0, so if the word core 1 pops as an instruction is a PC (the flush emptied `ifToId` between a packet's two words), it starts again with that PC. An instruction with an opcode or SYSTEM encoding core 1 doesn't recognise goes to core 2 as an illegal-instruction item (uop `0x46`, with the instruction as operand B). `WFI` does nothing. Invalid encodings within an opcode core 1 does recognise (for example a branch with funct3 2) aren't checked yet. Core 1 receives no `MBOX`.

**Core 2 (EX)** does the ALU work, RV32M multiply, divide and remainder, the Zbb instructions, CSRs (`cycle`, `time`, `instret`, `mstatus`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval`), traps and branches. `ECALL`, `EBREAK` and an illegal-instruction item set `mepc` and `mcause` (11, 3 and 2; an illegal instruction also sets `mtval` to the instruction) and redirect to `mtvec`. Division is done in software (`_udiv_calc`); the firmware was written before the Particle core had `DIV`, which it now has. For a taken branch or jump it executes `MBOX R14, 1` and flips its epoch (see [Branches](#branches)) and, if the instruction has a destination register (JAL/JALR), forwards the link value to core 3. FENCE.I is the same redirect, to the next instruction, with vector 2, followed by a FENCE.I item for core 3 (memory operation 11).

**Core 3 (MEM)** reads a control word whose bits [19:16] give the memory operation (1–5 loads LB, LH, LW, LBU, LHU; 8–10 stores SB, SH, SW; 11 FENCE.I; 0 an ALU result), performs the access with sign or zero extension, and sends `[rd, value]` back to core 1 on channel 1. It also sends stores into core 0's guest area, and FENCE.I markers, to core 0 on channel 2. Accesses to `0x1000_0000`–`0x1FFF_FFFF` are guest I/O (see [Guest I/O](#guest-io)) and never touch its TCM.

### Branches

On a taken branch, a jump, `MRET` or a trap, core 2 executes `MBOX R14, 1` with the target PC in R14, and flips its epoch (`0x48` in its zero page). In `ParcoreTop` core 2's MBOX strobe goes to core 0's MBOX input and to `pipelineFlush`. Core 0 stores the target at `MBOX_VALUE` (`0xFC`) as it takes trap vector 1, the cycle after the strobe; its handler loads the new PC from there and flips its own epoch, so everything it sends from then on carries the new epoch. The flush empties `ifToId` in the same cycle as the strobe, including a push in that cycle, so core 0 never leaves half a packet behind.

Instructions core 1 decoded after the branch, before the redirect, carry the old epoch. Core 2 drops every packet whose epoch isn't its own; for one with a destination register it sends a cancel to core 3 (control-word bit 2), which passes it on to core 1 as a writeback of destination plus `0x20`. Core 1 then takes one from that register's in-flight count without writing it. Every destination core 1 counts gets exactly one writeback or cancel, in order, so the counts are always right, and a wrong-path instruction waiting for a wrong-path result is released when the cancel arrives.

### Guest I/O

Core 3 does every guest load and store, so the guest's I/O is there. Addresses from `0x1000_0000` to `0x1FFF_FFFF` are I/O and never touch core 3's TCM:

| Address | Store | Load |
|---|---|---|
| `0x1000_0000` | Sends the low byte on the FTDI UART, waiting while the transmitter is busy | The received byte, or `0xFFFFFFFF` if none has arrived |
| `0x1000_0004` | Ignored | Status: bit 0 set when a byte has been received, bit 1 set when there's room to send |
| Anything else in the range | Ignored | `0` |

I/O loads aren't sign-extended. A store to `0x1000_0000` waits, so a guest can print without checking the status first; a guest that must not wait checks bit 1. The UART runs at the clock divided by `ParcoreTop.ftdiDivisor` (1 Mbps by default).

### FENCE.I

The guest has one memory, as RISC-V expects, and core 0 and core 3 each hold a copy of it: core 0 fetches instructions from its TCM, and core 3 does the loads and stores in its own. The guest address is the TCM address in both. A guest image (`.text`, then `.data`) is loaded at `0x500` into both cores, which have 8 KiB TCMs, so it must end by `0x2000`; the official tests are linked that way (`test/riscv_tests/link.ld`).

To keep the two copies the same, core 3 also sends every store into the guest area, `0x500` up to `0x2000`, to core 0 on `memToIf`, and core 0 writes it into its TCM. Code can be written anywhere in that area, `.data` included; the official `fence_i` test writes and runs code in `.data`.

An entry is one word, so an `MBOX` can't arrive halfway through one: bits [31:16] the data, [14:13] the kind (1 byte, 2 halfword, 3 FENCE.I marker), [12:0] the address. A word store is sent as two halfword entries. Core 0 keeps the entry it is applying in R11 until it has written it, and both of its handlers write that entry again before anything else; writing an entry twice gives the same result.

Core 0 applies mirrored stores as they arrive, one per pass of its loop, so a store can reach fetch before a FENCE.I, which RISC-V allows. A FENCE.I makes sure every earlier store has reached it:

1. Core 2 redirects to the instruction after the FENCE.I with `MBOX` vector 2 (flipping its epoch and flushing `ifToId`, as for a branch), then sends core 3 a FENCE.I item.
2. Core 3 handles items in order, so it sends the marker after every earlier store's entries.
3. Core 0's vector 2 handler sets the new PC and flips its epoch, then writes entries into its TCM until it reads the marker, and only then goes back to fetching. Nothing new reaches core 2 while it waits, so no other `MBOX` arrives.

## Conductor

The conductor is a minimal Particle core (no multiplier, divider or FIFOs, 2 KiB TCM). Its address space:

| Address | Use |
|---|---|
| `0x0000_0000`–`0x0000_07FF` | Its own TCM |
| `0x1000_0000 + (core << 16)` | A window into stage core `core`'s TCM (writes go to that TCM's port B while the core is held in reset) |
| `0xF000_0000` | `RST_CTRL` |
| `0xF000_0010` | `SPI_CTRL`: bit 0 CS_N, bit 1 START, bit 2 BUSY (read only) |
| `0xF000_0014` | `SPI_DATA`: bits 7:0, transmit and receive |
| `0xF000_0018` | `SPI_DIV`: bits 15:0, SPI clock divider |

The SPI controller uses SPI mode 0. Writing `SPI_DATA` (or `SPI_CTRL` with START) while idle starts an 8-bit transfer, most significant bit first. SCK changes once every `SPI_DIV + 1` cycles. MISO is sampled on each rising SCK edge and shifted in on the next falling edge, which is also when the next MOSI bit appears, so MOSI never changes while SCK is high.

`RST_CTRL` bits:

| Bits | Use |
|---|---|
| 5:0 | Per-core reset/hold (1 = held in reset, and its TCM port B is connected to the conductor). Only bits 3:0 have cores. |
| 6 | Flush `ifToId` and `idToEx` |
| 31 | Boot complete |

Reads of `RST_CTRL`, the SPI registers and the conductor's TCM all answer like memory: the value is captured at the clock edge after the address, and arrives in the next cycle.

At reset `RST_CTRL` is `0x3F` (every core held) when a conductor binary is given, and `0` otherwise, so without a conductor the stage cores start immediately from their preloaded TCMs.

### Flash Image

`conductor.act` reads a firmware image from SPI flash at `0x0010_0000`:

| Offset | Contents |
|---|---|
| 0 | Magic `0x50415243` (`"PARC"`) |
| 4 | Number of sections (at most 6) |
| 8 | Payload checksum |
| 12 | Reserved |
| 16 + 12·n | Section n: target core, destination offset in that core's TCM (usually `0x100`), payload size in bytes (a multiple of 4) |

The payloads follow the section table. The conductor holds every core in reset and pulses the flush bit, copies each payload into its core's TCM through the window, then writes `0x80000000` to `RST_CTRL`, releasing the cores and setting boot complete.

There is no make target that builds this flash image yet.

## Building and Generating

| Target | What it does |
|---|---|
| `make firmware` | Assembles everything under `firmware/parcore` into `build/parcore/...` (for example `build/parcore/riscv/core0_if.bin`) |
| `make guest-tests` | Builds the RV32 guest programs (`build/guest_rv32_*.bin`) from the generators in `apps/asm/gen` |
| `make generate-parcore` | Writes `hdl/parcore/parcore_top.sv` |
| `make test-parcore` | Builds the firmware and guest programs, then runs the Parcore tests |
| `make test-parcore-isa` | Builds the official RISC-V tests (`third_party/riscv-tests`, a submodule) and runs them on Parcore |

## Tests

| File | What it checks |
|---|---|
| `parcore_top_test.dart` | `ParcoreTop` elaborates and generates SystemVerilog; the UART line idles while in reset; a guest echo program sends a byte received on `uart_rx` back on `uart_tx`; a guest's four back-to-back stores to the UART come out in order at a baud rate slow enough that core 3 must wait for the transmitter (the guest programs are in `guest_echo.dart`) |
| `parcore_pipeline_trace_test.dart` | The guest UART echo, as its own test |
| `conductor_boot_test.dart` | The conductor and SPI controller elaborate; the conductor copies firmware from a simulated SPI flash into the core TCMs and releases reset, and core 0 and core 1's TCMs hold their sections (about 10,000 cycles) |
| `parcore_rv32_pipeline_test.dart` | Guest RV32 programs run on the four-stage pipeline, and core 1's registers at the end must match the RV32 reference model: register writes, signed division, multiply high, sub-word loads and stores, branches and jumps, CSRs. An illegal-instruction program checks that `SRET` and `0xFFFFFFFF` trap with the right `mcause`, `mtval` and `mepc` and that `WFI` does nothing. A FENCE.I program writes code with `SW` and `SB`, runs it, replaces an instruction and runs it again; the reference model keeps code and data apart, so that test checks the registers itself |
| `rv32_reference.dart` | Not a test: the RV32 reference interpreter the pipeline tests compare against (RV32I, RV32M, the Zbb instructions core 1 decodes, and the CSRs core 2 keeps) |
| `parcore_riscv_isa_test.dart` | The official rv32ui, rv32um and rv32uzbb tests, including `rv32ui/fence_i` |

### Simulators

The pipeline and ISA tests run in either simulator, chosen by `PARCORE_FAST_SIM`:

| `PARCORE_FAST_SIM` | Simulator | Needs |
|---|---|---|
| `1` (the default for `make test-parcore` and `make test-parcore-isa`) | Verilator, on the generated SystemVerilog | Verilator: `$VERILATOR`, or `verilator` on the PATH (the OSS CAD Suite has it) |
| `0` | The ROHD simulator, in Dart | Nothing else; slower (minutes per guest program) |

```bash
make test-parcore                       # Verilator
make test-parcore PARCORE_FAST_SIM=0    # ROHD simulator
make test-parcore VERILATOR=/path/to/verilator
```

Each guest program runs for exactly its test's cycle count, with no early exit, so a slow instruction can't end a run before its result is written. The Verilator model is built in `/tmp/parcore_pipeline_verilator` (`/tmp/parcore_verilator` for the ISA test) and rebuilt whenever the generated SystemVerilog or the test's C++ harness changes. The Verilator runs simulate the generated SystemVerilog as it is: `ParcoreTop(tcmInitDir:)` makes each TCM load its two bank files with `$readmemh`, and each run writes those files, so one model serves every program.

`test_pipeline.sh` runs each pipeline test on its own, runs them all even when one fails, and lists the failures at the end.

### Skipped tests

None at present. A test that can't pass yet goes in `_knownGaps` in `parcore_riscv_isa_test.dart` with its reason, and is listed in the test output as skipped.
