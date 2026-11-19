# Particle Configuration & Synthesis Guide

This guide covers configuring the Particle core through `CpuConfig`, generating synthesizable SystemVerilog, synthesizing it for the Lattice ECP5 (ULX3S board), and the VS Code tasks that run these steps.

---

## Core Configuration (`CpuConfig`)

The configuration is declared in `hdl/particle/lib/cpu_config.dart` and passed to `ParticleCpuCore` (and to the board top level, `ParticleUlx3sTop`):

| Field | Default | Meaning |
|---|---|---|
| `trapTableBase` | `0x00000100` | Base address of the direct stride trap vector table |
| `trapStrideBytes` | `16` | Bytes per trap vector slot (8 instructions) |
| `fifoChannels` | `4` | Number of point-to-point streaming FIFO channels |
| `fifoDepth` | `256` | Depth of each FIFO channel, in 32-bit words |
| `coreId` | `0` | The core's identifier in multi-core topologies |
| `enableMultiplier` | `true` | Include the DSP multiplier (2 cycles). When `false`, the multiply opcodes take the illegal-opcode trap (vector 15) |
| `enableDivider` | `true` | Include the divider (34 cycles per divide). When `false`, the divide and remainder opcodes take the illegal-opcode trap (vector 15) |
| `tcmSizeBytes` | `65536` | On-chip tightly coupled block RAM, in bytes (64 KiB) |
| `mmioBaseAddr` | `0xF0000000` | Base address of the memory-mapped I/O and external memory window |
| `enableUlx3sFtdiUart` | `true` | Include the ULX3S on-board FTDI UART (not used by `ParticleUlx3sTop`, which always has it) |
| `ulx3sUartFifoChannel` | `0` | FIFO channel of the FTDI UART (not used: `ParticleUlx3sTop` puts it on channel 0) |
| `systemClockHz` | `25000000` | System clock, for the UART baud divisors. `ParticleUlx3sTop` defaults to 35 MHz, from the PLL |
| `enableAuxGpioUart` | `true` | Include the auxiliary UART on the GPIO header pins (not used by `ParticleUlx3sTop`, which always has it) |
| `auxUartFifoChannel` | `1` | FIFO channel of the auxiliary UART (not used: `ParticleUlx3sTop` puts it on channel 1) |
| `auxUartDefaultBaud` | `115200` | Baud rate of the auxiliary UART. The core has no MMIO bus yet, so it can't be changed at run time |

See `hdl_architecture.md` for what the hardware implements today.

---

## Generating SystemVerilog

Each design has a `make` target, run from the repository root. Each fetches the hardware's Dart dependencies first (`make setup`).

| Command | Output | Design |
|---|---|---|
| `make generate-particle` | `hdl/particle/particle_top.sv` | The bare Particle core (`particle_cpu_core`): no memory, peripherals or pins. For simulation and for building into other designs. |
| `make generate-parcore` | `hdl/parcore/parcore_top.sv` | The Parcore RISC-V emulation cluster (see `parcore_architecture.md`). |
| `make generate-ulx3s` | `build/ulx3s/particle_ulx3s.sv`, `program_bank0.hex`, `program_bank1.hex` | The ULX3S board design (`ulx3s_board`), with a program in its block RAM. See *The ULX3S Board* below. |
| `make generate` | `particle_top.sv` and `parcore_top.sv` | |

The generators are Dart programs (`hdl/particle/bin/generate.dart`, `generate_ulx3s.dart`, and `hdl/parcore/bin/generate_parcore.dart`) that build the design with Intel ROHD and write it with `generateSynth()`.

---

## The ULX3S Board

`make ulx3s-bit` builds a bitstream for the ULX3S 85F: one Particle core at 35 MHz with 64 KiB of block RAM holding a program, the FTDI USB UART and a GPIO UART. It needs the OSS CAD Suite (Yosys, `nextpnr-ecp5`, `ecppack`; see *Prerequisites* in `GettingStarted.md`).

```bash
make ulx3s-bit                                    # apps/asm/ulx3s_echo.asm
make ulx3s-bit ULX3S_PROGRAM=apps/asm/myprog.asm  # another program
make ulx3s-prog                                   # load it into the board (openFPGALoader)
make ulx3s-term                                   # talk to it over the FTDI UART
```

| Target | Does |
|---|---|
| `make generate-ulx3s` | Builds `ULX3S_PROGRAM` with `pbuild --format hex` into `build/ulx3s/program.hex`, then runs `hdl/particle/bin/generate_ulx3s.dart`. That splits the image into the two block RAM banks (`program_bank0.hex`, `program_bank1.hex`, placed at `0x100`) and writes `particle_ulx3s.sv`, whose top level is `ulx3s_board`. |
| `make ulx3s-bit` | `generate-ulx3s`, then Yosys (`synth_ecp5`), nextpnr (`--85k --package CABGA381`, pins from `hdl/particle/boards/ulx3s/ulx3s_v20.lpf`) and `ecppack`, in `build/ulx3s`. Prints nextpnr's maximum frequency; the logs are `yosys.log` and `nextpnr.log`. The bitstream is `build/ulx3s/particle_ulx3s.bit`. |
| `make ulx3s-prog` | Loads the bitstream into the board's FPGA with `openFPGALoader -b ulx3s` (until the next power cycle). |
| `make ulx3s-flash` | Writes the bitstream to the board's configuration flash (`openFPGALoader -b ulx3s -f`), so it loads at every power-up. |
| `make ulx3s-term` | Opens the FTDI UART with `hdl/particle/boards/ulx3s/ulx3s_term.py`, a small terminal using only the Python standard library: the first `/dev/cu.usbserial-*` (macOS) or `/dev/ttyUSB*` (Linux) port, at 1 Mbps (`ULX3S_PORT`, `ULX3S_BAUD`). Ctrl-] leaves. |

Variables: `ULX3S_PROGRAM` (default `apps/asm/ulx3s_echo.asm`), `ULX3S_CLOCK_HZ` (default `35000000`, below the core's measured Fmax of about 40 MHz; `make ulx3s-timing` reports it for your build. The generator stops if the PLL can't make the clock exactly from 25 MHz: 35 and 37.5 MHz work, 36 and 38 don't), and `YOSYS`, `NEXTPNR_ECP5`, `ECPPACK`, `OPENFPGALOADER` for the tool commands.

The program is part of the bitstream, so changing it means running `make ulx3s-bit` again. The hardware implements every instruction in the spec (see `hdl_architecture.md`), so an Action program built with `pbuild` should run too; so far only `ulx3s_echo.asm` has been run on the ULX3S design (in simulation).

| Board | Pins | Use |
|---|---|---|
| FTDI USB UART | `ftdi_txd`, `ftdi_rxd` | FIFO channel 0, 1 Mbps 8-N-1 |
| GPIO UART | `gp[0]` (B11) transmit, `gp[1]` (A10) receive | FIFO channel 1, 115200 8-N-1 |
| Power button | `btn[0]` | Reset (also held until the PLL locks) |
| LEDs | `led[7:0]` | Low byte of the fetch address |

`apps/asm/ulx3s_echo.asm` prints `Particle ULX3S` on both UARTs and then sends back each byte it receives. Open the board's serial port at 1000000 baud in a terminal program: for example `screen /dev/cu.usbserial-<id> 1000000` on a Mac, or PuTTY on the board's COM port on Windows.

The pin file is the ULX3S project's `ulx3s_v20.lpf` (with its `LICENSE.md`), unchanged; it lists every pin on the board, and nextpnr warns about the ones the design doesn't use.

### Other designs

For another design `<top>.sv` whose top module is `<top>`:

```bash
yosys -p "read_verilog -sv <top>.sv; synth_ecp5 -top <top> -json <top>.json"
nextpnr-ecp5 --85k --package CABGA381 --json <top>.json \
    --lpf hdl/particle/boards/ulx3s/ulx3s_v20.lpf --textcfg <top>.config
ecppack <top>.config <top>.bit
```

Use `--25k` or `--45k` for the smaller boards. The top level's port names must match the pin file's (`clk_25mhz`, `led`, `btn`, `gp`, …).

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
| ULX3S: Build Bitstream | `make ulx3s-bit` |
| ULX3S: Load Bitstream into the Board | `make ulx3s-prog` |
| ULX3S: Open the FTDI UART | `make ulx3s-term` |
| Particle: Run ROHD Tests | `make test-particle` |
| Parcore: Run ROHD Tests | `make test-parcore` |
| Run Compiler and Language Server Tests | `make compiler-tests` |
| Run All Hardware and Simulator Tests | `make test` (the default test task) |

On Windows the tasks need the shell set up by `pdev.cmd`: start VS Code from that shell (`code .`), so the tasks find Git Bash, `make` and the tools.
