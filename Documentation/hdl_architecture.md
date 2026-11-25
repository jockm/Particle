# Particle ROHD Hardware Architecture

The Particle hardware is written in Dart with **Intel ROHD (Rapid Open Hardware Development)**, in `hdl/particle/lib`; there are no hand-written Verilog sources. ROHD generates synthesizable SystemVerilog from it (see `configuration_guide.md`). The Parcore cluster, built from these modules, is in `hdl/parcore` and described in `parcore_architecture.md`.

The instruction set is defined by `particle_spec.md`; this document describes how the hardware implements it, and where it does not yet.

---

## The Core: `ParticleCpuCore` (`cpu_core.dart`)

The core implements all 151 opcodes of `particle_spec.md`, and the differential ISA test checks it against psim (see *Tests*).

### Memory and timing

Memory is **synchronous**, like FPGA block RAM: an address presented in one cycle gives its data in the next.

The core is a pipeline with these stages:

| Stage | What happens |
|---|---|
| F | presents the address of the next halfword on port A |
| D | receives that halfword, decodes it, reads the register file, and decides the unconditional `FBRA`/`BBRA` imm8 branches |
| E | executes, with operands forwarded from the previous two cycles' writes; decides every other branch, jumps, traps and `MBOX` entry |
| W | writes the register for loads, `TAS` and the multiplier, the cycle after E |

Most instructions take one cycle:

| Instruction | Cycles |
|---|---|
| ALU, moves, stores, FIFO operations | 1 |
| Conditional branches not taken | 1 |
| `FBRA`/`BBRA` imm8 (decided in D) | 2 |
| Conditional branches taken, jumps, `TRAP`, and the serialising `XCHG`, `XCHGALL`, `XCHGMOST` (decided in E: the two halfwords behind are dropped) | 3 |
| `LDI`, `LDIS` (the second halfword arrives while the first is in D) | 2 |
| Loads, `TAS`, `MULL`, `MULH`, `SMULH`, `MULHSU` (the register is written in W) | 2 |
| `DIV`, `MOD`, `SDIV`, `SMOD` and their immediate forms | 34 (fewer for a division by zero or `INT_MIN / -1`) |
| `FIFO.R` on an empty channel | stalls until data arrives |

Conditional branches are decided in E rather than D on purpose: testing the register in D puts the register-file read on the path to the fetch address, which cost about 4 MHz on the ULX3S (about 35.5 MHz against 39.5 MHz).

E computes every PC-relative target with one adder, on halfwords: `pc/2 + offset`, plus one for `JTBL`, or `pc/2 + ~offset + 1` for the backward forms (`JMP`'s target is the register itself). D's `FBRA`/`BBRA` target and the pointer modes' `± size` have one adder each as well. Each form used to have its own adder, all feeding a 26-way multiplexer; sharing them took a stage core's own logic from about 2,640 to about 1,850 LUT4s in Parcore.

### Ports

* **Memory port A** (`memPortAAddr`, `memPortARData`, 16 bits): instruction fetch. `memPortAAddr` is a byte address; the data for it is expected in the next cycle.
* **Memory port B** (`memPortBAddr`, `memPortBWData`, `memPortBRData`, byte enables, read and write enables, 32 bits): loads, stores and `TAS`. A store's write happens at the clock edge; a load's data is expected in the next cycle (read-first for `TAS`). Any data source on port B, including memory-mapped registers and multiplexers between memories, must answer the same way (see `ParcoreTop`'s conductor readback).
* **FIFO port** (`fifoChanSelect`, `fifoPushData`, `fifoPushEn`, `fifoPopEn`, `fifoPopData`, `fifoStatus`): to a FIFO subsystem or a design's own interconnect. The channel is the low 2 bits of register `Rl`; `fifoStatus` bit 0 is empty and bit 1 full.
* **MBOX** (`mboxStrobeOut`/`mboxVectorOut`/`mboxDataOut` and `mboxStrobeIn`/`mboxVectorIn`/`mboxDataIn`): `MBOX Rr, Imm4` raises vector `Imm4` on another core and sends `Rr`; an incoming strobe makes this core take the vector, and in that trap-entry cycle it writes the value through port B to the word below its trap table (`trapTableBase − 4`, `0xFC` by default).
* **SARF** (`sarfRs1Addr`, `sarfRs2Addr`, `sarfRdAddr`, data and write enable): the shared architectural register fabric planned for Parcore (proposals 02–04). The core drives the addresses from its `Rr`/`Rl` fields; its write enable is not yet driven.

### Registers

The register file has two write ports. Port 1 takes an instruction's result and loaded data; port 2 takes pointer updates (the `(Rr++)`, `(++Rr)`, `(Rr--)` and `(--Rr)` modes), `FIFO.TRYR`'s status in R14, and R14 on trap entry. When an instruction writes the same register twice, the result matches psim: a load through its own pointer (`LD32 R5, (R5++)`) keeps the loaded value, `FIFO.TRYR R14, Rl` keeps the status, and a store through its own pointer (`ST32 (--R15), R15`) stores the updated pointer.

The registers live in LUT RAM rather than flip-flops (about 380 LUT4s, 83 flip-flops and 32 `TRELLIS_DPR16X4` cells, against 2,605 LUT4s and 960 flip-flops before):

* R14 and S14 are flip-flops, with a write port of their own: every second write in a cycle, except a pointer update, goes to R14.
* The other registers and their shadows are in two 16×32 LUT RAMs (`ParticleLutRam`, `lut_ram.dart`), bank 0 and bank 1, with one write port each. A bank bit per register says which bank holds its active value; `XCHG`, `XCHGALL` and `XCHGMOST` flip bank bits (and swap R14 with S14), so they stay single-cycle. A read reads both banks and picks one with the bank bit.
* At most one write a cycle may go to the LUT RAMs. A pointer update, the only port-2 write outside R14, never comes in the same cycle as a port-1 write: a load writes its pointer in E and its data in W, when E is empty, and a store writes only its pointer. In simulation the register file stops the run if two such writes ever meet.
* LUT RAM can't be reset, so after reset the register file writes zeros to both banks for 16 cycles (`clearing`), and holds the rest of the core in reset meanwhile.

### Traps and interrupts

The trap table base and stride come from `CpuConfig` (`trapTableBase`, default `0x100`; `trapStrideBytes`, 16). On every trap, R14 gets a return address:

| Cause | Vector | R14 |
|---|---|---|
| `TRAP Rr`, `TRAP Imm4` | `Rr[3:0]` / `Imm4` | the next instruction |
| Misaligned halfword or word access (nothing is changed) | 14 | the faulting instruction |
| Branch or jump to an odd address (a `JMP`/`RJUMP` still links) | 14 | the odd target |
| Opcode not in the spec, or a multiply/divide opcode when that unit is disabled | 15 | the illegal instruction |
| Incoming `MBOX` | its vector | the instruction it interrupted |

An incoming `MBOX` strobe (and its value) is held until the core is between instructions, or stalled on a `FIFO.R` or a divide; a newer strobe replaces an older one that hasn't been taken. It is taken before the next instruction runs; a stalled `FIFO.R` or divide is abandoned and runs again when the handler returns (`JMP R14, R0`). It never interrupts a load or `LDI` part-way.

### Configuration

`CpuConfig.enableMultiplier` and `enableDivider` decide whether the multiplier and divider are built. Without them, their opcodes raise vector 15. In the same way `enablePointerModes`, `enableSubword` and `enableShadowBank` leave out the pointer modes, the byte and halfword accesses and the shadow bank (their opcodes raise vector 15, and their logic is tied off so synthesis removes it), and `enableMboxReceive` leaves out taking `MBOX` traps. The opcode lists are `ParticleOpcodes.pointerModeOps`, `subwordOps` and `shadowOps`; `test/isa/13_left_out.asm` checks them against psim with `; config: no-pointer-modes no-subword no-shadow-bank`.

### Differences from psim

psim and the hardware are allowed to differ in a few places, which the differential test avoids:

* `TRAP 0` and `TRAP 15` end a psim run; on hardware they go to their vectors.
* `FIFO.STAT`'s entry count: psim reports up to 256 (bit 16); the hardware's count field is 8 bits.

---

## Datapath Modules

| Module | File | Used by | Description |
|---|---|---|---|
| `RegisterFile` | `register_file.dart` | the core | 16 32-bit registers (`R0`–`R15`) plus one shadow register for each. Two asynchronous read ports and two synchronous write ports (port 2 wins when both write one register). `R0` and its shadow are always zero. `xchgEn` swaps one register with its shadow, `xchgAllEn` swaps `R1`–`R15` (`XCHGALL`), and `xchgMostEn` swaps `R1`–`R14`, keeping the stack pointer (`XCHGMOST`, used by `FAST_ENTER_TRAP`/`FAST_EXIT_TRAP`). R14 and S14 are flip-flops; the other registers and their shadows are in two `ParticleLutRam` banks, with a bank bit per register (see *Registers*). `clearing` is high for 16 cycles after reset while it clears them. `regValue(i)` and `shadowValue(i)` give tests the register values. |
| `ParticleNetworkInterface` | `network_interface.dart` | Parcore's stage cores | A core's network interface, on its FIFO port (see `noc_design.md`): a receive buffer per input link (a one-channel `ParticleFifoSubsystem`, with a flush), a credit count per output link (256 at reset; a `FIFO.W` without a credit is dropped), a channel table (`NiChannel`: for each channel 0–3, the input it reads, the output it writes or the local device, and where `FIFO.STAT` reads its status, `NiStatus`), and a local-device port. In step 1 the links are direct wires and credits come back in the same cycle, so the status a sender sees is what a shared FIFO would report. `network_interface_test.dart` checks credits, status, a full link, flush and a device channel. |
| `ParticleLutRam` | `lut_ram.dart` | `RegisterFile` | A small RAM (default 16 words) with one synchronous write port and two asynchronous read ports, and no reset; it starts at zero. Generated as a plain memory array, which Yosys maps to ECP5 LUT RAM (`TRELLIS_DPR16X4`, one copy per read port); simulated with ROHD registers. |
| `ParticleAlu` | `alu.dart` | the core | Single-cycle 32-bit ALU: `ADD`, `SUB`, `AND`, `OR`, `XOR`, the shifts and rotates, `CLZ`, `BEXTR`, `BSET`/`BCLR`/`BINV`/`BGET`, `SLT`/`SSLT`, `NOT`, `NEZ`, `NEG`, `REV32`, `SEQ`/`SNE`/`SLE`/`SSLE`, `SEXT8`/`SEXT16`. Outputs the result and `isZero`/`isNegative`. The units are shared to keep it small (about 1,020 LUT4s in Parcore, against 1,776 when each operation had its own): one adder for `ADD`, `SUB` and every less-than; one equality compare; one right-rotator, with masks, for every shift and rotate, `BEXTR` and `BGET` (a left shift by s is a right rotate by -s; its five stages are `ParticleRotateStage` modules generated with `(* keep_hierarchy *)`, because Yosys's ECP5 mapping otherwise merges them into a 32-way multiplexer per bit, about 500 LUT4s instead of 160); one logic unit for `AND`, `OR`, `XOR`, `NOT` and the bit operations, with a one-hot bit made from the shift masks; and one flag for the one-bit results. `alu_test.dart` checks every operation against a reference model, on edge values with every shift amount and `BEXTR` field, and on random operands. |
| `ParticleMultiplier` | `multiplier.dart` | the core | 32×32 multiplier for the FPGA's DSP blocks, fed from registers the core loads in E (the result is written in W): one unsigned product, with the signed high words corrected from it, `MULL` (low 32 bits), `MULH` (high 32 bits, unsigned), `SMULH` (high, signed), `MULHSU` (high, signed × unsigned). |
| `ParticleDivider` | `divider.dart` | the core (when `enableDivider`) | Multi-cycle divider (one bit per cycle, 32 steps): signed and unsigned quotient and remainder, with a one-cycle `done` pulse, division-by-zero and `INT_MIN / -1` handling, and an `abort` input (an MBOX interrupting a divide). |
| `ParticleMemoryBus` | `memory_bus.dart` | its tests | Byte enables, write-data alignment, sub-word read formatting and alignment fault detection for 8-, 16- and 32-bit accesses. The core does the same work internally. |
| `ParticleBlockRamTdp` | `block_ram_tdp.dart` | `ParticleUlx3sTop`, Parcore's `ParcoreTcm`, the test harness | True dual-port block RAM for the FPGA's embedded RAM: port A reads 16-bit instructions (halfword address), port B reads and writes 32-bit data with byte enables (word address); default 16,384 words, 64 KiB. Two 16-bit banks (halfwords at byte addresses 4n and 4n+2), each with one port A read and one port B read/write port, as ECP5 block RAM provides. Both ports are synchronous: the address before a rising edge gives its data after it, as the core expects (read-first when port B reads and writes one word). Simulation loads it from a byte list; the generated SystemVerilog loads each bank with `$readmemh` (`ParticleBlockRamTdp.bankFiles` writes the files) or from the byte list as initial values. |
| `ParticleFifoSubsystem` | `fifo_subsystem.dart` | `ParticleMultiCore`, Parcore | Multi-channel streaming FIFOs (default 4 channels of 256 words): push, pop, `empty`/`full`, and the `FIFO.STAT` status word. Each channel's words are in block RAM (`ParticleBlockRamSdp`, one ECP5 block). The head word is visible in the same cycle, as `FIFO.R` expects: the RAM is read every cycle at the address the head will have after that cycle's pop, and a word read at the same edge it was written comes from a bypass register. |
| `ParticleBlockRamSdp` | `block_ram_sdp.dart` | `ParticleFifoSubsystem` | Simple dual-port block RAM: one write port and one synchronous read port, any width and a power-of-two depth. Generated as a plain memory array, which Yosys maps to ECP5 block RAM. |
| `SharedRegFabric` | `shared_reg_fabric.dart` | `ParticleMultiCore` | The SARF: a 32 × 32-bit register block with read and write ports for two cores. |

---

## Multi-Core and Board Designs

| Design | File | Description |
|---|---|---|
| `ParticleMultiCore` | `particle_multi_core.dart` | Two cores with a FIFO in each direction, the SARF, and MBOX strobes between them. |
| `CacheSubsystemTop` | `cache_subsystem_top.dart` | Two cores: core 0 runs the application, core 1 runs a cache and SDRAM worker. MBOX strobes between them, and an MMIO bridge to the SDRAM controller. |
| `SdramController` | `sdram_controller.dart` | The ULX3S's 16-bit SDRAM: PHY and command state machine. |
| `ParticleUlx3sTop` | `particle_ulx3s_top.dart` | The ULX3S board design: one core, 64 KiB of `ParticleBlockRamTdp` loaded with a program, the FTDI UART on FIFO channel 0 (1 Mbps) and the GPIO UART on channel 1 (`auxUartDefaultBaud`, 115200), synchronized reset and receive pins, and the LEDs showing the low byte of the fetch address. `FIFO.STAT` gives bit 0 = nothing received, bit 1 = transmitter busy; channels 2 and 3 report both. Each UART holds one received byte and sends one at a time, so a `FIFO.W` while the transmitter is busy is dropped. |
| `ulx3sBoardVerilog` | `ulx3s_board.dart` | The SystemVerilog top level `ulx3s_board` around `ParticleUlx3sTop`: the ECP5 PLL (25 MHz to the system clock, 35 MHz by default) and the board's pin names. `btn[0]` resets, `ftdi_txd`/`ftdi_rxd` are the FTDI UART, `gp[0]` transmits and `gp[1]` receives for the GPIO UART, and `wifi_gpio0` is held high. Written as text, because ROHD 0.5 has no vendor primitives or bidirectional ports. |
| `ParticleUartTransceiver` | `uart.dart` | 8-N-1 transmitter and receiver with a configurable baud divisor; holds a received byte until `rxReady`, sampling in the middle of each bit. Used by `ParticleUlx3sTop` and Parcore. |
| `ParticleFtdiUart`, `ParticleGpioUart` | `ftdi_uart.dart`, `gpio_uart.dart` | Board UART peripherals built on `ParticleUartTransceiver`: the FTDI UART with its divisor fixed by the clock and baud rate (1 Mbps by default), and a GPIO UART whose divisor can be written at run time (`mmioDivisor`, default 217: about 115200 baud at 25 MHz). Not used by the current tops, which instantiate the transceiver directly. |

`constants.dart` holds the opcodes, ALU operation codes and widths; `particle_rohd.dart` exports the package.

---

## Tests

`make test-particle` runs the ROHD tests in `hdl/particle/test`, which drive the modules and designs above with clocked simulation. `make test-parcore` runs Parcore's (see `parcore_architecture.md`). Both need `make tools` (the Particle tests assemble programs with pasm and run psim).

**Differential ISA test** (`isa_diff_test.dart`, also `make test-particle-isa`). Each program in `test/isa/` is assembled and run twice: in psim, and on the core in `CoreHarness` (`core_harness.dart`: 64 KiB of synchronous block RAM and a four-channel FIFO subsystem whose channels loop back to the core, as psim's do). At the end both must have the same PC, all 16 registers and 16 shadow registers, and the same bytes in each memory area the program lists. The directed programs cover every instruction group, with corner cases: shift counts 0 and 31, division by zero and `INT_MIN / -1`, every addressing mode including the pointer as data register, every branch form (the register-target and R14 forms as `.half`), `JMP`/`RJUMP` links, traps and their R14 values, misaligned loads, stores and `TAS` in every pointer mode (which change nothing), the shadow bank, the reserved opcodes `0xD3` and `0xD4` (vector 15), and the FIFO try-instructions. Seeded random programs (`isa_random.dart`) add mixes of ALU, multiply, divide, R14-immediate, load/store, `TAS`, FIFO and `XCHG` instructions; `ISA_RANDOM_SEEDS=1,2,3` chooses the seeds (default 1 to 8).

A program for the test starts at `0x100`, ends in a jump to itself, and may set `; check-memory: <addr> <bytes>` and `; max-cycles: <n>` in comments. It must avoid what psim and the hardware may do differently (see *Differences from psim*).

**Core tests** (`cpu_core_test.dart`): what psim can't check: reset, cycle counts, `MBOX` interrupts (between instructions, during a `FIFO.R` stall and during a divide), vector 15, a misaligned load changing nothing, and a core built without its divider.
