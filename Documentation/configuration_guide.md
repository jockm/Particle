# Particle Configuration & Synthesis Guide

This guide details how to parameterize the Particle core via `CpuConfig` and generate synthesizable SystemVerilog for target FPGA architectures.

---

## Parameterized Core Configuration (`CpuConfig`)

The core execution configuration is declared in `hdl/rohd/lib/cpu_config.dart`:

```dart
class CpuConfig {
  final int trapTableBase;      // Base address of Direct Stride Vector Table (Default: 0x00000100)
  final int trapStrideBytes;    // Stride size in bytes per slot (Default: 64 bytes)
  final int fifoChannels;       // Number of point-to-point streaming FIFO channels (Default: 4)
  final int fifoDepth;          // Capacity per FIFO channel in 32-bit words (Default: 256)
  final int coreId;             // Unique identifier for multi-core mesh routing (Default: 0)

  const CpuConfig({
    this.trapTableBase = 0x00000100,
    this.trapStrideBytes = 64,
    this.fifoChannels = 4,
    this.fifoDepth = 256,
    this.coreId = 0,
  });
}
```

---

## Synthesis Generation Flow (`bin/generate.dart`)

Particle generates clean, single-file SystemVerilog via Intel ROHD's `generateSynth()` API.

### 1. Generating SystemVerilog
From the `hdl/rohd/` directory:
```bash
dart run bin/generate.dart
```
This produces `particle_top.sv` in the working directory.

### 2. Synthesis with Yosys and nextpnr (Target: Lattice ECP5 / ULX3S)
A sample synthesis script for Yosys:
```tcl
# Read synthesizable SystemVerilog
read_verilog -sv particle_top.sv

# Synthesize for ECP5
synth_ecp5 -top particle_cpu_core -json particle_synth.json

# Place & Route with nextpnr
# nextpnr-ecp5 --85k --package CABGA381 --json particle_synth.json --textcfg particle.config
```

---

## VS Code Workflow
The repository includes `.vscode/tasks.json` with ready-to-run automation:
* `Particle: Run ROHD Tests`: Runs `dart test` inside `hdl/rohd`.
* `Particle: Generate SystemVerilog`: Runs `bin/generate.dart`.
* `Particle: Assemble Current File`: Invokes `pasm.py` on the active file.
* `Particle: Compile ACT16 Current File`: Invokes `act16c.py` on the active file.
