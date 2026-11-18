# Particle ROHD Hardware Architecture

The Particle hardware is written in Dart with **Intel ROHD (Rapid Open Hardware Development)**, in `hdl/particle/lib`; there are no hand-written Verilog sources. ROHD generates synthesizable SystemVerilog from it (see `configuration_guide.md`). The Parcore cluster, built from these modules, is in `hdl/parcore` and described in `parcore_architecture.md`.

The instruction set is defined by `particle_spec.md`; this document describes how the hardware implements it, and where it does not yet.

---

## The Core: `ParticleCpuCore` (`cpu_core.dart`)

The core is a small state machine with four states:

| State | Does |
|---|---|
| Fetch | Reads the instruction at the PC through memory port A. |
| Exec | Decodes and executes it: ALU, multiplier, memory port B, FIFO, branches and traps. |
| Wait | Holds while a FIFO read has no data. |
| FetchImm | For the 32-bit `LDI`/`LDIS`, reads the second word (the 16-bit immediate) at PC + 2. |

Its ports connect it to the rest of a design:

* **Memory port A** (`memPortAAddr`, `memPortARData`, 16 bits): instruction fetch.
* **Memory port B** (`memPortBAddr`, `memPortBWData`, `memPortBRData`, byte enables, read and write enables, 32 bits): loads, stores and `TAS`. Misaligned halfword and word accesses, and an odd branch target, raise vector 14 before any state changes.
* **FIFO port** (`fifoChanSelect`, `fifoPushData`, `fifoPushEn`, `fifoPopEn`, `fifoPopData`, `fifoStatus`): to a FIFO subsystem or a design's own interconnect. The channel is the low 2 bits of register `Rl`.
* **MBOX** (`mboxStrobeOut`/`mboxVectorOut` and `mboxStrobeIn`/`mboxVectorIn`): `MBOX` raises a vector on another core; an incoming strobe makes this core take the vector.
* **SARF** (`sarfRs1Addr`, `sarfRs2Addr`, `sarfRdAddr`, data and write enable): the shared architectural register fabric used by Parcore. The core drives the addresses from its `Rr`/`Rl` fields; its write enable is not yet driven.

The trap table base and stride come from `CpuConfig` (`trapTableBase`, default `0x100`; `trapStrideBytes`, 64).

### What the core implements

The core decodes **108 of the 151 opcodes** in `particle_spec.md`. These are **not yet implemented** in hardware (psim implements them all):

| Group | Opcodes not decoded |
|---|---|
| Memory addressing modes | Pre-increment, pre-decrement and post-decrement forms of every load and store (`(++Rr)`, `(--Rr)`, `(Rr--)`); plain `(Rr)` and post-increment `(Rr++)` work |
| Division | `DIV`, `MOD`, `SDIV`, `SMOD`, and their immediate forms (the divider module exists but is not instantiated in the core) |
| Signed arithmetic | `SADD`, `SSUB` (register forms) |
| Other ALU | `NEG`, `SEXT8`, `SEXT16`, `SEQ`, `SNE`, `SLE`, `SSLE` (the ALU has `NEG`, `SEQ`, `SNE`, `SLE` and `SSLE` operations, but the decoder does not route these opcodes to them) |
| Traps | `TRAP Rr`, `TRAP Imm4` |
| Branches | The register-target conditional branches `FBRA.Z/N/P Rr, Rl` and `BBRA.Z/N/P Rr, Rl` |

An opcode the core does not decode does nothing. Two more differ from the spec: `CLZ` counts the leading zeros of `Rr` rather than `Rl`, and `BEXTR` follows the spec's bit-field form.

---

## Datapath Modules

| Module | File | Used by | Description |
|---|---|---|---|
| `RegisterFile` | `register_file.dart` | the core | 32 physical 32-bit registers, seen through the 16-register `RBASE` window (`R0`–`R15`), plus a 16-register shadow bank. Two asynchronous read ports and one synchronous write port. `R0` is always zero. `xchgEn` swaps one register with its shadow, `xchgAllEn` swaps `R1`–`R15` (`XCHGALL`), and `xchgMostEn` swaps `R1`–`R14`, keeping the stack pointer (`XCHGMOST`, used by `FAST_ENTER_TRAP`/`FAST_EXIT_TRAP`). |
| `ParticleAlu` | `alu.dart` | the core | Single-cycle 32-bit ALU: `ADD`, `SUB`, `AND`, `OR`, `XOR`, the shifts and rotates, `CLZ`, `BEXTR`, `BSET`/`BCLR`/`BINV`/`BGET`, `SLT`/`SSLT`, `NOT`, `NEZ`, `NEG`, `REV32`, `SEQ`/`SNE`/`SLE`/`SSLE`. Outputs the result and `isZero`/`isNegative`. |
| `ParticleMultiplier` | `multiplier.dart` | the core | Single-cycle 32×32 multiplier for the FPGA's DSP blocks: `MULL` (low 32 bits), `MULH` (high 32 bits, unsigned), `SMULH` (high, signed), `MULHSU` (high, signed × unsigned). |
| `ParticleDivider` | `divider.dart` | not yet wired in | Multi-cycle divider (one bit per cycle, 32 steps): signed and unsigned quotient and remainder, with a `done` handshake and division-by-zero handling. |
| `ParticleMemoryBus` | `memory_bus.dart` | its tests | Byte enables, write-data alignment, sub-word read formatting and alignment fault detection for 8-, 16- and 32-bit accesses. The core does the same work internally. |
| `ParticleBlockRamTdp` | `block_ram_tdp.dart` | not yet wired in | True dual-port block RAM for the FPGA's embedded RAM: port A reads 16-bit instructions, port B reads and writes 32-bit data with byte enables (default 16,384 words, 64 KiB). |
| `ParticleFifoSubsystem` | `fifo_subsystem.dart` | `ParticleMultiCore`, Parcore | Multi-channel streaming FIFOs (default 4 channels of 256 words): push, pop, `empty`/`full`, and the `FIFO.STAT` status word. |
| `SharedRegFabric` | `shared_reg_fabric.dart` | `ParticleMultiCore` | The SARF: a 32 × 32-bit register block with read and write ports for two cores. |

---

## Multi-Core and Board Designs

| Design | File | Description |
|---|---|---|
| `ParticleMultiCore` | `particle_multi_core.dart` | Two cores with a FIFO in each direction, the SARF, and MBOX strobes between them. |
| `CacheSubsystemTop` | `cache_subsystem_top.dart` | Two cores: core 0 runs the application, core 1 runs a cache and SDRAM worker. MBOX strobes between them, and an MMIO bridge to the SDRAM controller. |
| `SdramController` | `sdram_controller.dart` | The ULX3S's 16-bit SDRAM: PHY and command state machine. |
| `ParticleUlx3sTop` | `particle_ulx3s_top.dart` | The ULX3S board top level: one core, the 3 Mbps FTDI UART (`ftdi_uart.dart`), the configurable GPIO UART (`gpio_uart.dart`), the reset button and the LEDs (showing the low byte of the fetch address). Not yet functional: its memory is tied to zero and the UARTs' data streams are not connected to the core's FIFO channels. |
| UART engine | `uart_engine.dart`, `uart.dart` | 8-N-1 transmitter and receiver with a configurable baud divisor and a streaming handshake. |

`constants.dart` holds the opcodes, ALU operation codes and widths; `particle_rohd.dart` exports the package.

---

## Tests

`make test-particle` runs the ROHD tests in `hdl/particle/test`, which drive the modules and designs above with clocked simulation. `make test-parcore` runs Parcore's (see `parcore_architecture.md`).
