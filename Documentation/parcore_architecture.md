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
                  └─ branch redirect (ring) ─┼──────────────────────────┘                          │
                                             └─────────────────────────────────────────────────────┘
                                                        writeback

          Conductor (core id 7): RST_CTRL, SPI flash controller, writes into every core's TCM
```

| Stage | Module instance | Firmware | TCM | Multiplier / divider |
|---|---|---|---|---|
| Conductor | `parcore_conductor` | `firmware/parcore/conductor/conductor.asm` | 4 KiB | no / no |
| Core 0, IF | `core0_if` | `firmware/parcore/riscv/core0_if.asm` | 16 KiB | no / no |
| Core 1, ID | `core1_id` | `firmware/parcore/riscv/core1_id.asm` | 4 KiB | no / no |
| Core 2, EX | `core2_ex` | `firmware/parcore/riscv/core2_ex.asm` | 4 KiB | yes / configured, see below |
| Core 3, MEM | `core3_mem` | `firmware/parcore/riscv/core3_mem.asm` | 8 KiB | no / no |

The configurations are in `hdl/parcore/lib/parcore_config.dart` (`ParcoreConfig.conductorConfig`, `core0If`, `core1Id`, `core2Ex`, `core3Mem`). Every stage core has its trap table at `0x100`, so it starts at `0x100` after reset.

Each core leaves out what its firmware doesn't use (`CpuConfig`; a left-out instruction raises vector 15):

| Core | Pointer modes | Byte/halfword | Takes `MBOX` | Shadow bank | 2-word branches | Immediate `BEXTR` | `WAIT`/`HALT` |
|---|---|---|---|---|---|---|---|
| Conductor | yes | no | no | no | no | no | no |
| Core 0 | no | yes | yes | no | yes | yes | yes |
| Core 1 | no | yes | no | no | no | yes | yes |
| Core 2 | no | no | no | no | yes | yes | yes |
| Core 3 | no | yes | no | no | no | yes | yes |

The stage cores' firmware doesn't use `WAIT` or `HALT` yet; they are built in so that `CORE_STATE` means something and ParticleMan-style firmware can be tried on Parcore. Cores 1–3 don't take `MBOX` traps, so on them a `WAIT` never ends. (Kept in, 435.)

The firmware of a core without the 2-word branches is assembled with `-D __NO_LONG_BRANCHES` (the Makefile), so its `JUMP`, `JUMP.cc` and `RCALL` use the forms without them.

With no shadow bank, every firmware file defines `NO_SHADOW_BANK` before including `lib/vectors.inc`, so its unexpected-trap slots use no `XCHG*`. Cores 1 and 2 clear their memory at start-up with plain stores and an `ADD`, not `ST32 (R4++)`.

`parcore_config.dart` also has `core4Wb` (4 KiB) and `core5Cache` (32 KiB), and `firmware/parcore/riscv` has `core4_wb.asm`, `core5_cache_mem.asm` and `core1_dispatch.asm`. `make firmware` assembles them, but `ParcoreTop` doesn't instantiate cores 4 and 5, so `core4_wb.asm` and `core5_cache_mem.asm` aren't loaded. `core1_dispatch.asm` is used only by a Particle test (`hdl/particle/test/multicore_firmware_test.dart`).

## Source Files

| File | Contents |
|---|---|
| `lib/parcore_top.dart` | `ParcoreTop`: the conductor, the four stage cores, their TCMs, the interconnect, the FTDI UART, and the SPI controller |
| `lib/parcore_tcm.dart` | `ParcoreTcm`: a core's TCM, a synchronous `ParticleBlockRamTdp` (16-bit fetch port, 32-bit data port with byte enables), preloaded with a binary at `0x100` |
| `lib/parcore_config.dart` | The `CpuConfig` of each core |
| `lib/spi_controller.dart` | `SpiController`: the conductor's SPI master |
| `lib/spi_flash_rom.dart` | `SpiFlashRom`: the boot image in an on-chip ROM that answers like an SPI flash chip |
| `lib/parcore_image.dart` | Builds the conductor's boot image (format 2, CRC-32) |
| `lib/parcore_ulx3s_top.dart` | `ParcoreUlx3sTop`: `ParcoreTop` with the image ROM and the board's reset, UART, LEDs and buttons |
| `lib/cpu_config.dart` | Parcore's copy of `CpuConfig` |
| `bin/generate_parcore.dart` | Writes `parcore_top.sv` |
| `bin/build_parcore_image.dart`, `bin/generate_parcore_ulx3s.dart` | The boot image and the ULX3S design (`make parcore-image`, `make parcore-bit`) |
| `test/` | ROHD and Verilator tests (see [Tests](#tests)) |
| `test_pipeline.sh` | Runs the RV32 pipeline tests one group at a time |

The demo guest, its link script and build script are in `apps/riscv/`.

## Top-Level Ports

| Port | Direction | Width | Use |
|---|---|---|---|
| `clk`, `reset` | in | 1 | Clock and active-high reset |
| `uart_rx`, `uart_tx` | in / out | 1 | FTDI console UART, connected to core 3: the guest's memory-mapped UART (see [Guest I/O](#guest-io)) |
| `leds` | out | 8 | The board LEDs: the conductor's boot progress and fault codes, then the guest's |
| `buttons` | in | 6 | The board buttons, 1 = pressed: FIRE1, FIRE2, UP, DOWN, LEFT, RIGHT |
| `spi_cs_n`, `spi_sck`, `spi_mosi`, `spi_miso` | out / in | 1 | SPI flash, driven by the conductor |
| `branch_redirect_strobe`, `branch_redirect_vector` | out | 1, 4 | Copies of core 2's MBOX outputs, for debugging |

The constructor takes `clkFreqMhz` (default 25) and optional binaries for each core (`conductorBinary`, `core0Binary` … `core3Binary`). A binary passed here is preloaded into that core's TCM.

## Interconnect

The cores talk over a one-way ring, step 2 of the [network on chip](noc_design.md): a `ParticleRingRouter` per core, in the order conductor → core 0 → core 1 → core 2 → core 3 → conductor, with each link a register, so a packet moves one router a cycle. Each stage core has a network interface (`ParticleRingInterface`) on its FIFO port. It holds the receive buffers of the links that come to the core (each 256 32-bit words in one block RAM), a credit count for each link it sends on, an injection queue of 8 packets, and a channel table saying what each of the core's channels 0–3 reads, writes and reports. A word read is a credit owed to its sender, sent back in a `CREDIT` packet (16 at a time, or sooner when there is nothing else to send). The conductor's network interface sends `MBOX` packets (its `MBOX Rr, Rl` can go to any core, to wake one from a `WAIT` say, though in Parcore only core 0 takes `MBOX` traps; `MBOX Rr, Imm4` has no default target and is dropped), and `CONFIG` packets, which change a core's table (see [Conductor](#conductor)), only when `ParcoreConfig.writableNocTables` is on; it is off by default (418), so the tables are Parcore's wiring as constants; a core's network interface resets with the core. Each interface builds only the `MBOX` side its core uses: core 0's receives, core 2's sends (to its default target, core 0), and cores 1 and 3 have neither (an `MBOX` sent to them is answered and discarded). The five links, with their length on the ring:

| Link (receive buffer) | Writer (channel) | Reader (channel) | Contents |
|---|---|---|---|
| `ifToId` (1 hop) | core 0 (ch 1) | core 1 (ch 0) | 5 words per instruction: control word, w1, w2, B, W3 (see [Packets](#packets)) |
| `idToEx` (1 hop) | core 1 (ch 1) | core 2 (any) | 4 words: control word, operand A, operand B, word 3 (see [Packets](#packets)) |
| `exToMem` (1 hop) | core 2 (ch 1) | core 3 (any) | results and memory requests; a cancel has control-word bit 2 set |
| `memToWb` (3 hops) | core 3 (ch 1) | core 1 (ch 2) | 2 words: destination register (plus `0x20` for a cancel), value |
| `memToIf` (2 hops) | core 3 (ch 2) | core 0 (ch 2) | Guest stores into core 0's guest area, and FENCE.I markers, one word each (see [FENCE.I](#fencei)) |

The channel tables are in `ParcoreTop`. Core 2 reads `idToEx` on every channel, and core 3 reads `exToMem` on every channel but 3 (the UART, the network interface's local device).

A `FIFO.W` without a credit is dropped, as a `FIFO.W` to a full FIFO was (one that only finds the injection queue full waits instead), so the writers that can get ahead check for room first with `FIFO.STAT`, whose count is 256 minus the credits: core 0 pushes a packet only while `ifToId` holds fewer than 128 words, and core 1 decodes an instruction only while `idToEx` does (it keeps retiring writebacks while it waits). `FIFO.STAT` on core 0's channels 1 and 2 reads `ifToId`'s and `memToIf`'s status, on core 1's channels 0, 1 and 2 reads `ifToId`, `idToEx` and `memToWb`, and on core 3's channel 2 reads `memToIf` (any other channel reads `exToMem`). Core 3 mirrors a store only while `memToIf` holds fewer than 128 words.

Core 3's channel 3 is the FTDI UART, not a FIFO: `FIFO.W`/`FIFO.TRYW` on channel 3 send the low byte, `FIFO.TRYR`/`FIFO.R` receive a byte, and `FIFO.STAT` gives bit 0 set when nothing has been received and bit 1 set while the transmitter is busy, so `FIFO.TRYW` only sends when it can. The UART divisor is the clock divided by the baud rate (`ParcoreTop(clkFreqMhz:, ftdiBaud:)`, 25 MHz and 1 Mbps by default, giving 25 cycles per bit; `ParcoreTop.ftdiDivisor`).

### Flush

On a redirect or a FENCE.I (core 2's `MBOX`), core 0's handler stores 1 to its network interface's `FLUSH` register (`0xFFFF_FF00`), which sends a `FLUSH` packet on `ifToId` behind everything core 0 sent on the wrong path; when it reaches core 1, its `ifToId` buffer is emptied (and the discarded words are credited back). Core 1 may have read the first words of a packet before that. So after the `FLUSH`, core 0 sends a marker packet: five words of all ones. If core 1 was part-way through a packet, it reads markers as the rest of it, sees that its last word (W3, which is never all ones) is a marker, and drops it; nothing was counted for it yet. Each marker word left over reads as a control word of class 15 (`CLASS_MARKER`), which core 1 skips. A real control word is never all ones: operation numbers stop at 55. `memToIf` isn't flushed: a mirrored store is never on a wrong path. `idToEx`, `exToMem` and `memToWb` are only cleared by `reset`: core 1 has already counted the destination of every packet in `idToEx` as in flight, so core 2 drops the stale ones itself (see [Branches](#branches)).

## Stage Firmware

Each stage runs a loop that reads its input FIFO, does its part of the RISC-V instruction, and writes the result to the next FIFO.

**Core 0 (IF)** fetches, decodes and predicts. Its TCM is 16 KiB: the return-address stack in its zero page, the vectors and its redirect handlers below `0x500`, the guest image at `0x500`–`0x1FFF` (as in core 3), and its fetch and decode loop from `0x2000`. It keeps the guest PC in R10, starting at `0x500`, and the control word's flags (valid, and the epoch in bit 1) in R9. Each pass it applies one store core 3 mirrored on channel 2, if there is one (see [FENCE.I](#fencei)); then, while `ifToId` holds fewer than 16 words (four packets), it loads the instruction at the PC, decodes it with one `JTBL` on bits 6:0, and pushes a 5-word packet on channel 1: the finished control word (operation number, core 1's class, memory operation, Rd, flags) and four words whose meaning depends on the class (see [Packets](#packets)). It predicts as it goes (see [Branches](#branches)). An instruction it can't decode goes on as an illegal-instruction item (`OP_ILLEGAL`, with the instruction as operand B): an unknown opcode or SYSTEM encoding, or an invalid encoding within a known opcode. That means a load with funct3 3, 6 or 7; a store with funct3 3 or more; a branch with funct3 2 or 3; `JALR` with funct3 other than 0; a shift-immediate or register-register instruction whose funct7 (or, for `ZEXT.H`, rs2) isn't one RV32I, RV32M or Zbb defines for its funct3; MISC-MEM with funct3 2–7; SYSTEM with funct3 4. Those last two are reserved now, and claimed by extensions (Zicbom/Zicboz cache-block operations, the hypervisor's `HLV`/`HSV`) that would be implemented later. `FENCE`, `WFI` and a `JAL` without a link send nothing. A zero word is not decoded: core 0 waits at that PC, reading it again on every pass. That is how a guest program ends: by running into memory that was never written. (RISC-V defines 0x00000000 as an illegal instruction; Parcore keeps the zero word as the end of a program instead.) Its trap vector 1 (`0x110`) branches to the redirect handler, which loads the new PC from its network interface's `NI_MBOX_VALUE` register (`0xFFFF_FF04`), flips the epoch, sends a marker packet (see [Flush](#flush)), and goes back to the loop; vector 2 (`0x120`) is FENCE.I.

**Core 1 (ID)** keeps the 32 RISC-V registers in its zero page (`x0`–`x31` at `0x00`–`0x7F`; `x0`'s word is never written, so it reads as zero) and a count of writes in flight for each register (bytes at `0xF00`–`0xF1F`). It first retires every writeback waiting on channel 2: it writes the value to the register and takes one from its count (a cancel, destination plus `0x20`, only takes one from the count: its value lands at `0x80` + 4 × Rd, which nothing uses; writebacks for `x0` are ignored). Then, if `idToEx` has room, it takes a packet from channel 0 and dispatches on its class (control-word bits 23:20) with one `JTBL`. Each class's handler reads the rest of the packet, waits while the source registers it names have writes in flight (retiring writebacks meanwhile), reads them, adds one to the destination's count, and sends core 2 a 4-word packet on channel 1. Core 1 receives no `MBOX`.

**Core 2 (EX)** does the ALU work, RV32M multiply, divide and remainder, the Zbb instructions, CSRs (`cycle`, `time`, `instret`, `mstatus`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval`), traps and branches. It dispatches with one `JTBL` on the operation number in control-word bits 31:24; the numbers are in `firmware/parcore/riscv/parcore_ops.inc`, which cores 0, 1 and 2 include. It keeps its epoch in a register. `ECALL`, `EBREAK` and an illegal-instruction item set `mepc` and `mcause` (11, 3 and 2; an illegal instruction also sets `mtval` to the instruction) and redirect to `mtvec`. Divide and remainder use Particle's `SDIV`, `DIV`, `SMOD` and `MOD`, whose results for a divisor of zero and for INT_MIN / −1 are RISC-V's. For a branch or a return that went against core 0's guess, and for any other `JALR`, it executes `MBOX R14, 1` and flips its epoch (see [Branches](#branches)); a `JAL` or `JALR` with a destination register forwards its link value to core 3. FENCE.I is the same redirect, to the next instruction, with vector 2, followed by a FENCE.I item for core 3 (memory operation 11).

**Core 3 (MEM)** reads a control word whose bits [19:16] give the memory operation (1–5 loads LB, LH, LW, LBU, LHU; 8–10 stores SB, SH, SW; 11 FENCE.I; 0 an ALU result), performs the access with sign or zero extension, and sends `[rd, value]` back to core 1 on channel 1. Most packets are ALU results on their way to core 1: a packet with no memory operation and no cancel bit takes a fast path, about 14 cycles, and goes straight back out. Core 3 dispatches the rest with a `JTBL` on the memory operation. It also sends stores into core 0's guest area, and FENCE.I markers, to core 0 on channel 2. Accesses to `0x1000_0000`–`0x1FFF_FFFF` are guest I/O (see [Guest I/O](#guest-io)) and never touch its TCM.

### Branches

Core 0 predicts as it decodes, with no history:

* `JAL`: it follows it, and is never wrong. It sends a `JAL` only if it has a link register; core 2 then sends PC + 4 to it.
* Conditional branches: backward (a negative offset, usually a loop) guessed taken, forward guessed not taken. Core 0 fetches down the guessed path, sets control-word bit 3 if it guessed taken, and sends as W3 the address to go to if the guess is wrong (PC + 4, or the target). Core 2 evaluates the branch and redirects to that address only when it went the other way.
* Returns (`JALR` with rd `x0` and rs1 `x1` or `x5`, as RISC-V's calling convention marks them): predicted with a return-address stack. Every call (`JAL` or `JALR` with rd `x1` or `x5`) pushes PC + 4 on a 16-entry ring in core 0's zero page (`0x00`–`0x3F`, the top's index at `0x40`; a deeper call chain overwrites the oldest entries). A return pops its guess: core 0 fetches it, sets bit 3 and sends the guess as W3, and core 2 redirects only if the real target differs.
* Other `JALR`s (calls through a register, jump tables): not predicted. Core 0 fetches on from PC + 4, and core 2 redirects to the target.

On a wrong guess, a `JALR`, `MRET` or a trap, core 2 executes `MBOX R14, 1` with the new PC in R14, and flips its epoch (bit 1 of its R1). Core 2's network interface has core 0 as its default `MBOX` target, so the `MBOX` goes round the ring as a packet (see [MBOX design](mbox_design.md)); core 2's next `MBOX` waits until core 0's interface has answered `ACK`. Core 0 takes trap vector 1 with `MBOX` masked, and keeps the value in its `NI_MBOX_VALUE` register; its handler loads the new PC from there, flips its own epoch, so everything it sends from then on carries the new epoch, and flushes `ifToId` (see [Flush](#flush)). Both handlers end with `EI` before going back to the loop: they never return with `RETI`, so another redirect waits in core 0's queue until the handler is done. Whatever core 1 took from the wrong path before the `FLUSH` reached it carries the old epoch, and core 2 drops it.

Instructions core 1 sent on after the branch, before the redirect, carry the old epoch. Core 2 drops every packet whose epoch isn't its own; for one with a destination register it sends a cancel to core 3 (control-word bit 2), which passes it on to core 1 as a writeback of destination plus `0x20`. Core 1 then takes one from that register's in-flight count without writing it. Every destination core 1 counts gets exactly one writeback or cancel, in order, so the counts are always right, and a wrong-path instruction waiting for a wrong-path result is released when the cancel arrives.

### Packets

`firmware/parcore/riscv/parcore_ops.inc` defines both packets. The control word is the same in both: bits 31:24 the operation number, 23:20 core 1's class, 19:16 the memory operation (loads and stores), 15:8 Rd, bit 3 "guessed taken" (branches), bit 1 the epoch, bit 0 valid (bit 2, cancel, is used only from core 2 to core 3). Cores 2 and 3 ignore bits 23:20.

| Class | Core 0 → core 1: w1, w2, B, W3 | Core 1 → core 2: A, B, word 3 | Used for |
|---|---|---|---|
| 0 `CLASS_RS1_IMM` | rs1, rd, the immediate, PC | x(rs1), the immediate, PC | OP-IMM, loads, `JALR`, CSRs, `ECALL`/`EBREAK`/`MRET` (Rd 0) |
| 1 `CLASS_RS1_RS2` | rs1, rd, rs2, PC | x(rs1), x(rs2), PC | OP |
| 2 `CLASS_STORE` | rs1, rs2, the offset, PC | x(rs1), the offset, x(rs2) | stores |
| 3 `CLASS_BRANCH` | rs1, rs2, (unused), the address if the guess is wrong | x(rs1), x(rs2), that address | branches |
| 4 `CLASS_IMM` | (unused), rd, B, PC | 0, B, PC | `LUI`, `AUIPC`, `JAL`, `FENCE.I`, illegal (B the instruction) |
| 5 `CLASS_ZIMM` | the 5-bit immediate, rd, the CSR, PC | the immediate, the CSR, PC | CSR immediate forms |

Core 1 counts rd's write in flight for classes 0, 1, 4 and 5 (rd 0: none).

### Guest I/O

Core 3 does every guest load and store, so the guest's I/O is there. Addresses from `0x1000_0000` to `0x1FFF_FFFF` are I/O and never touch core 3's TCM:

| Address | Store | Load |
|---|---|---|
| `0x1000_0000` | Sends the low byte on the FTDI UART, waiting while the transmitter is busy | The received byte, or `0xFFFFFFFF` if none has arrived |
| `0x1000_0004` | Ignored | Status: bit 0 set when a byte has been received, bit 1 set when there's room to send |
| `0x1000_0008` | Sets the LEDs (bits 7:0), once the conductor has handed them over | The value last stored |
| `0x1000_000C` | Ignored | The buttons, 1 = pressed: bit 0 FIRE1, 1 FIRE2, 2 UP, 3 DOWN, 4 LEFT, 5 RIGHT |
| Anything else in the range | Ignored | `0` |

The LEDs and buttons are core 3's own I/O, at `0xF000_0000` and `0xF000_0004` in its address space. I/O loads aren't sign-extended. A store to `0x1000_0000` waits, so a guest can print without checking the status first; a guest that must not wait checks bit 1. The UART runs at the clock divided by `ParcoreTop.ftdiDivisor` (1 Mbps by default).

### FENCE.I

The guest has one memory, as RISC-V expects, and core 0 and core 3 each hold a copy of it: core 0 fetches instructions from its TCM, and core 3 does the loads and stores in its own. The guest address is the TCM address in both. A guest image (`.text`, then `.data`) is loaded at `0x500` into both cores, and must end by `0x2000` (core 3's TCM is 8 KiB; core 0's continues past it with its decode code); the official tests are linked that way (`test/riscv_tests/link.ld`).

To keep the two copies the same, core 3 also sends every store into the guest area, `0x500` up to `0x2000`, to core 0 on `memToIf`, and core 0 writes it into its TCM. Code can be written anywhere in that area, `.data` included; the official `fence_i` test writes and runs code in `.data`.

An entry is one word, so an `MBOX` can't arrive halfway through one: bits [31:16] the data, [14:13] the kind (1 byte, 2 halfword, 3 FENCE.I marker), [12:0] the address. A word store is sent as two halfword entries. Core 0 keeps the entry it is applying in R11 until it has written it, and both of its handlers write that entry again before anything else; writing an entry twice gives the same result.

Core 0 applies mirrored stores as they arrive, one per pass of its loop, so a store can reach fetch before a FENCE.I, which RISC-V allows. A FENCE.I makes sure every earlier store has reached it:

1. Core 2 redirects to the instruction after the FENCE.I with `MBOX` vector 2 (flipping its epoch and flushing `ifToId`, as for a branch), then sends core 3 a FENCE.I item.
2. Core 3 handles items in order, so it sends the marker after every earlier store's entries.
3. Core 0's vector 2 handler sets the new PC and flips its epoch, then writes entries into its TCM until it reads the marker, and only then goes back to fetching. Nothing new reaches core 2 while it waits, so no other `MBOX` arrives.

## Conductor

The conductor is a minimal Particle core (no multiplier, divider or FIFOs, 4 KiB TCM, 436). Its address space:

| Address | Use |
|---|---|
| `0x0000_0000`–`0x0000_0FFF` | Its own TCM |
| `0x1000_0000 + (core << 16)` | A window into stage core `core`'s TCM (writes go to that TCM's port B while the core is held in reset) |
| `0xF000_0000` | `RST_CTRL` |
| `0xF000_0010` | `SPI_CTRL`: bit 0 CS_N, bit 1 START, bit 2 BUSY (read only) |
| `0xF000_0014` | `SPI_DATA`: bits 7:0, transmit and receive |
| `0xF000_0018` | `SPI_DIV`: bits 15:0, SPI clock divider |
| `0xF000_0020` | `STATUS`: bits 7:0 the board LEDs while the conductor has them; bit 8 gives them to the guest (core 3's I/O, see [Guest I/O](#guest-io)) |
| `0xF000_0024` | `BUTTONS` (read only): 1 = pressed; bit 0 FIRE1, 1 FIRE2, 2 UP, 3 DOWN, 4 LEFT, 5 RIGHT |
| `0xF000_0028` | `CORE_STATE` (read only): 2 bits per stage core, core *n* at bits 2*n*+1:2*n*: 0 running, 1 asleep in a `WAIT`, 2 halted (`HALT`), 3 held in reset (`RST_CTRL`) |
| `0xF000_002C` | `CYCLES` (read only): clock cycles since reset (wraps after 2³² cycles, about 172 s at 25 MHz) |
| `0xF000_0030 + 4n` | `CORE_PC` (read only): the PC of the instruction in stage core *n*'s E stage |
| `0xFFFF_FF0C` | `NI_CONFIG` (write only, with `ParcoreConfig.writableNocTables` on): a store sends a `CONFIG` packet setting one entry of a core's table, or of every core's (see [MBOX design](mbox_design.md), part 6). Parcore's firmware doesn't use it, and the switch is off by default (418) |

The SPI controller uses SPI mode 0. Writing `SPI_DATA` (or `SPI_CTRL` with START) while idle starts an 8-bit transfer, most significant bit first. SCK changes once every `SPI_DIV + 1` cycles. MISO is sampled on each rising SCK edge and shifted in on the next falling edge, which is also when the next MOSI bit appears, so MOSI never changes while SCK is high.

`RST_CTRL` bits:

| Bits | Use |
|---|---|
| 5:0 | Per-core reset/hold (1 = held in reset, and its TCM port B is connected to the conductor). Only bits 3:0 have cores. |
| 31 | Boot complete |

Reads of `RST_CTRL`, the SPI registers, `STATUS`, `BUTTONS` and the conductor's TCM all answer like memory: the value is captured at the clock edge after the address, and arrives in the next cycle.

At reset `RST_CTRL` is `0x3F` (every core held) when a conductor binary is given, and `0` otherwise, so without a conductor the stage cores start immediately from their preloaded TCMs. Likewise `STATUS` starts at `0` (LEDs off, the conductor's) with a conductor, and at `0x100` (the guest's) without one.

The conductor's firmware is `firmware/parcore/conductor/conductor.asm`, written by hand: its job is small and sits right on the SPI timing, and it had to fit in 2 KiB (4 KiB since 436, for the watchdog and the `pmon` console) without a multiplier.

### Boot Image

At reset the conductor holds every stage core, reads a firmware image over SPI from flash address `0x0040_0000` (4 MiB in, past any ECP5-85F bitstream; the ULX3S 3.1.7 has 16 MiB), copies its sections into the cores' TCMs through the windows, checks its CRC-32, and releases the cores together, writing `0x80000000` to `RST_CTRL`. It reads the image front to back in one pass. Format 2, all words little-endian:

| Offset | Contents |
|---|---|
| 0 | Magic `0x50415243` (`"PARC"`) |
| 4 | Number of sections, 1 to 8 |
| 8 | CRC-32 of the whole image (header, section table and payloads) with these four bytes taken as zero: the standard CRC-32 (zlib's, Python's `binascii.crc32`), over the image's bytes in order |
| 12 | Format version: 2 |
| 16 + 12·n | Section n: the cores (bit i set writes the payload into core i's TCM, bits 0–5), the offset in those TCMs, the payload length in bytes (both multiples of 4) |

The payloads follow the section table, in section order. `lib/parcore_image.dart` builds images (`buildParcoreImage`), and `bin/build_parcore_image.dart` (`make parcore-image`) builds the usual one: each stage core's firmware at `0x100` (core 0's in two sections, below `0x500` and from `0x2000`, so the zeros the assembler leaves across the guest area aren't in the image: `parcoreFirmwareSections`), and the guest program at `0x500` as one section for cores 0 and 3. That makes six sections, so LEDs 0–6 light while booting.

**LEDs:** while booting, LED 0 is lit and one more lights per section loaded. Once the cores are released, `STATUS` bit 8 gives the LEDs to the guest. If a check fails, every core stays held, and the conductor blinks a fault code on LEDs 0–3 with LED 7 flashing:

| Code | Fault |
|---|---|
| 1 | Not `"PARC"` |
| 2 | Not format version 2 (a version 1 image has 0 there) |
| 3 | 0 or more than 8 sections |
| 4 | A section with no cores, cores beyond 5, or an offset or length that isn't a multiple of 4 |
| 5 | The CRC-32 doesn't match |

**FIRE1:** once the cores are running, pressing FIRE1 makes the conductor reload the image and restart them, without a full reset.

On the ULX3S the image comes from `SpiFlashRom` (`lib/spi_flash_rom.dart`), an on-chip ROM built into the bitstream that answers the standard SPI flash read command (`0x03` and a 24-bit address) like the flash chip, so the conductor's code is the same as it will be for the real flash. It needs `SPI_DIV` of at least 1, and reads outside the image return `0xFF`, like erased flash.

### The ULX3S design

`ParcoreUlx3sTop` (`lib/parcore_ulx3s_top.dart`) is `ParcoreTop` with the conductor's code in its TCM, the stage cores' TCMs empty, the boot image in a `SpiFlashRom`, and a two-flip-flop reset synchroniser. The board wrapper (the particle package's `ulx3sBoardVerilog`) adds the PLL and pins: the power button resets, the FTDI UART is the guest's console, `btn[6:1]` are the buttons and `led[7:0]` the LEDs. `bin/generate_parcore_ulx3s.dart` writes the design and the memories' contents.

The demo guest, `apps/riscv/hello.S`, prints a banner, echoes what you type, shows the buttons on LEDs 0–5 with a heartbeat on LED 7, and names each button as it's pressed. It debounces the buttons in software: a change counts once they have read the same for 64 passes of its main loop, about 10 ms. `apps/riscv/build_riscv_guest.sh` builds a guest with a RISC-V GCC or LLVM toolchain (see `apps/riscv/riscv_toolchain.sh`), linked by `apps/riscv/link.ld` at `0x500` like the official tests.

## Building and Generating

| Target | What it does |
|---|---|
| `make firmware` | Assembles everything under `firmware/parcore` into `build/parcore/...` (for example `build/parcore/riscv/core0_if.bin`) |
| `make guest-tests` | Builds the RV32 guest programs (`build/guest_rv32_*.bin`) from the generators in `apps/asm/gen` |
| `make generate-parcore` | Writes `hdl/parcore/parcore_top.sv` |
| `make test-parcore` | Builds the firmware and guest programs, then runs the Parcore tests |
| `make test-parcore-isa` | Builds the official RISC-V tests (`third_party/riscv-tests`, a submodule) and runs them on Parcore |
| `make parcore-guest` | Builds the guest program `PARCORE_GUEST` (default `apps/riscv/hello.S`) into `build/riscv/` (needs a RISC-V GCC or LLVM toolchain) |
| `make parcore-image` | Builds the boot image, `build/parcore_ulx3s/parcore_image.bin`: the stage firmware and the guest |
| `make parcore-bit` | Generates the ULX3S design with that image (`PARCORE_CLOCK_HZ`, default 25 MHz) and synthesizes, places and routes it: `build/parcore_ulx3s/parcore_ulx3s.bit` |
| `make parcore-size` | The size of each kind of core and of every module (LUT4s, flip-flops, block RAMs and so on), without place and route: `build/parcore_ulx3s/size_report.txt` |
| `make parcore-timing` | The last `parcore-bit`'s Fmax and critical path |
| `make parcore-profile` | Runs `PARCORE_PROFILE_GUEST` (default `apps/riscv/bench.S`) on Parcore in Verilator and prints the cycles per RISC-V instruction, overall and per phase, and where each stage core's cycles go (see [Profiling](#profiling)) |
| `make parcore-prog`, `make parcore-flash` | Load the bitstream into the ULX3S, or write it to its flash |

On the board, `make ulx3s-term` opens the guest's console.

## Profiling

`make parcore-profile` (`bin/profile_parcore.dart`) runs a guest on `ParcoreTop` in Verilator, with the stage firmware from `build/parcore/riscv` and the guest at `0x500`, from reset until the guest stores `0xA5` to the LEDs. Counters added to each stage core record the cycles each instruction address spends in E. It reports:

* The cycles per RISC-V instruction: the run's cycles over the instructions the RV32 reference model (`test/rv32_reference.dart`) executes for the same guest. A phase starts each time the guest stores a value from 1 to 15 to the LEDs, and each phase gets its own line.
* For each core, the share of cycles running, waiting in a `FIFO.R`, and in bubbles (E empty after a taken branch, jump or redirect), and the routines taking the most cycles, by the labels in the firmware's `.lst`. A core polling a FIFO's status counts as running.
* Whether the guest's `a0` matches the reference model's.

The benchmark guest, `apps/riscv/bench.S`, has five phases: ALU work, memory copies, an insertion sort, recursive calls, and multiply and divide.

## Tests

| File | What it checks |
|---|---|
| `parcore_top_test.dart` | `ParcoreTop` elaborates and generates SystemVerilog; the UART line idles while in reset; a guest echo program sends a byte received on `uart_rx` back on `uart_tx`; a guest's four back-to-back stores to the UART come out in order at a baud rate slow enough that core 3 must wait for the transmitter (the guest programs are in `guest_echo.dart`) |
| `parcore_pipeline_trace_test.dart` | The guest UART echo, as its own test |
| `conductor_boot_test.dart` | The conductor and SPI controller elaborate; the conductor copies firmware from a simulated SPI flash into the core TCMs and releases reset, and core 0 and core 1's TCMs hold their sections (about 10,000 cycles) |
| `parcore_rv32_pipeline_test.dart` | Guest RV32 programs run on the four-stage pipeline, and core 1's registers at the end must match the RV32 reference model: register writes, signed division, multiply high, sub-word loads and stores, branches and jumps, CSRs. An illegal-instruction program checks that `SRET` and `0xFFFFFFFF` trap with the right `mcause`, `mtval` and `mepc` and that `WFI` does nothing; another runs 17 invalid encodings within known opcodes, each beside valid ones, and checks that exactly those trap. A FENCE.I program writes code with `SW` and `SB`, runs it, replaces an instruction and runs it again; the reference model keeps code and data apart, so that test checks the registers itself |
| `rv32_reference.dart` | Not a test: the RV32 reference interpreter the pipeline tests compare against (RV32I, RV32M, the Zbb instructions core 1 decodes, and the CSRs core 2 keeps) |
| `parcore_riscv_isa_test.dart` | The official rv32ui, rv32um and rv32uzbb tests, including `rv32ui/fence_i` |
| `spi_flash_rom_test.dart` | `SpiFlashRom` through the conductor's SPI controller, at `SPI_DIV` 1 and 3: reads at the start and middle, past the image and the ROM (`0xFF`), below it, and an unknown command |
| `conductor_boot_test.dart` | The conductor loads a format 2 image from a `SpiFlashRom` (one section into two cores), checks its CRC-32 and releases the cores; each of the five faults leaves the cores held with its code on the LEDs; the CRC-32 matches the standard check value |
| `parcore_ulx3s_boot_test.dart` | The whole ULX3S design in Verilator, from reset: the conductor loads the stage firmware and a guest from the image ROM, and the guest prints on the FTDI UART |

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
