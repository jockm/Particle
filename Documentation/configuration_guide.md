# Particle Configuration & Synthesis Guide

This guide covers configuring the Particle core through `CpuConfig`, generating synthesizable SystemVerilog, synthesizing it for the Lattice ECP5 (ULX3S board), and the VS Code tasks that run these steps.

---

## Core Configuration (`CpuConfig`)

The configuration is declared in `hdl/particle/lib/cpu_config.dart` and passed to `ParticleCpuCore` (and to the board top level, `ParticleUlx3sTop`):

| Field | Default | Meaning |
|---|---|---|
| `trapTableBase` | `0x00000100` | Base address of the direct stride trap vector table |
| `trapStrideBytes` | `64` | Bytes per trap vector slot |
| `fifoChannels` | `4` | Number of point-to-point streaming FIFO channels |
| `fifoDepth` | `256` | Depth of each FIFO channel, in 32-bit words |
| `coreId` | `0` | The core's identifier in multi-core topologies |
| `enableMultiplier` | `true` | Include the single-cycle DSP multiplier |
| `enableDivider` | `true` | Include the multi-cycle divider |
| `tcmSizeBytes` | `65536` | On-chip tightly coupled block RAM, in bytes (64 KiB) |
| `mmioBaseAddr` | `0xF0000000` | Base address of the memory-mapped I/O and external memory window |
| `enableUlx3sFtdiUart` | `true` | Include the ULX3S on-board FTDI UART (fixed 3 Mbps) |
| `ulx3sUartFifoChannel` | `0` | FIFO channel of the FTDI UART |
| `systemClockHz` | `25000000` | Clock feeding the UART logic (25 MHz on the ULX3S) |
| `enableAuxGpioUart` | `true` | Include the auxiliary UART on the GPIO / PMOD header pins |
| `auxUartFifoChannel` | `1` | FIFO channel of the auxiliary UART |
| `auxUartDefaultBaud` | `115200` | Starting baud rate of the auxiliary UART (changed at run time through its MMIO divisor register) |

See `hdl_architecture.md` for what the hardware implements today.

---

## Generating SystemVerilog

Each design has a `make` target, run from the repository root. Each fetches the hardware's Dart dependencies first (`make setup`).

| Command | Output | Design |
|---|---|---|
| `make generate-particle` | `hdl/particle/particle_top.sv` | The bare Particle core (`particle_cpu_core`): no memory, peripherals or pins. For simulation and for building into other designs. |
| `make generate-parcore` | `hdl/parcore/parcore_top.sv` | The Parcore RISC-V emulation cluster (see `parcore_architecture.md`). |
| `make generate` | all of the above | |

The generators are Dart programs (`hdl/particle/bin/generate.dart`, `hdl/parcore/bin/generate_parcore.dart`) that build the design with Intel ROHD and write it with `generateSynth()`.

The ULX3S board top level (`particle_ulx3s_top.dart`) has no generator yet: its memory and its UART streams are not connected (see `hdl_architecture.md`).

---

## Synthesis with Yosys and nextpnr (Lattice ECP5 / ULX3S)

Synthesis and place-and-route need the OSS CAD Suite (see *Prerequisites* in `GettingStarted.md`); the `make` targets stop at SystemVerilog. A bitstream needs a board-level design with memory and pins. For a design `<top>.sv` whose top module is `<top>`:

```bash
# Synthesize for ECP5
yosys -p "read_verilog -sv <top>.sv; synth_ecp5 -top <top> -json <top>.json"

# Place and route (85F device in the CABGA381 package, as on the ULX3S 85F;
# use --25k or --45k for the smaller boards). A .lpf file maps the top level's
# ports to the board's pins.
nextpnr-ecp5 --85k --package CABGA381 --json <top>.json --lpf ulx3s.lpf --textcfg <top>.config

# Bitstream
ecppack <top>.config <top>.bit
```

The ULX3S `.lpf` pin file comes with the board's documentation; it is not part of this repository.

---

## VS Code Tasks

`.vscode/tasks.json` provides tasks for the common steps (**Terminal → Run Task…**). They run the `make` targets and the tools in `build/tools`, from the repository root:

| Task | Runs |
|---|---|
| Particle: Build Tools | `make tools` |
| Particle: Build Firmware and Applications | `make build` (the default build task) |
| Particle: Assemble Current File | `pasm` on the open file, into `build/<name>.bin` |
| Particle: Lint Current File | `pasm_lint` on the open file |
| Action: Build and Run Current File in psim | `./pbuild <file> --sim` |
| Action: Build and Run Current File on This Computer (LLVM) | `./llbuild <file> --run` |
| Particle: Generate SystemVerilog (Core) | `make generate-particle` |
| Parcore: Generate SystemVerilog | `make generate-parcore` |
| Particle: Run ROHD Tests | `make test-particle` |
| Parcore: Run ROHD Tests | `make test-parcore` |
| Run Compiler and Language Server Tests | `make compiler-tests` |
| Run All Hardware and Simulator Tests | `make test` (the default test task) |

On Windows the tasks need the shell set up by `pdev.cmd`: start VS Code from that shell (`code .`), so the tasks find Git Bash, `make` and the tools.
