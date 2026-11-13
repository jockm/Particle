# Particle Processor & Toolchain Fabric

**Particle** is a 32-bit load/store RISC processor architecture utilizing compact 16-bit instructions, inspired by the Hitachi SH-2, ARM Thumb, and lessons learned from the MiniRISC4 computing fabric. It is targeted for synthesis on modern FPGAs (specifically Lattice ECP5 on the ULX3S platform and modern SoC FPGAs) and implemented cleanly in **Intel ROHD (Rapid Open Hardware Development in Dart)** with zero legacy Verilog source codebases.

---

## Key Architectural Dimensions

* **Native 32-Bit Datapath**: Registers ($R0$–$R15$), arithmetic units, address space, and internal buses operate at 32-bit width.
* **Compact 16-Bit Instruction Format**: Instructions are strictly 16 bits wide, fetched sequentially over a dedicated synchronous bus without slot packing.
* **Register File & Hardware Shadow Bank**: 16 registers ($R0$ hardwired to 0, $R1$–$R15$ general purpose) paired with a dedicated hardware shadow bank enabling single-cycle, zero-memory-spill context switches via `XCHG`, `XCHGALL`, and `XCHGMOST`.
* **Direct Stride Exception Vectoring**: Base address `0x00000100` with fixed 64-byte (32-instruction) strides per vector slot, jumping directly into vector logic without indirect pointer tables.
* **Unified Dual-Port Memory System**: Byte-addressed memory mapped to on-chip True Dual-Port Block RAM (Port A: synchronous instruction fetch; Port B: data read/write, MMIO, and atomic access).
* **Multi-Core & Hardware Streaming**: Built-in point-to-point streaming FIFO channels (`FIFO.R`, `FIFO.W`, `FIFO.STAT`, `FIFO.TRYR`, `FIFO.TRYW`) and cross-core hardware strobe signaling (`MBOX`).

---

## Directory Structure

```text
particle/
├── README.md                          # Project root overview and quickstart
├── Documentation/
│   ├── particle_spec.md               # Master architectural specification
│   ├── pasm_assembler.md              # Macro assembler documentation
│   ├── psim_simulator.md              # Simulator & p4db debugger reference
│   ├── act16_compiler.md              # Action systems language specification
│   ├── hdl_architecture.md            # Pure ROHD datapath, memory & execution model
│   ├── configuration_guide.md         # CpuConfig parameters and synthesis flow
│   └── memory_map_and_conventions.md  # Vector layout, ABI, and calling conventions
├── hdl/
│   └── rohd/                          # Hardware description workspace
│       ├── pubspec.yaml               # Dart package configuration (rohd, test)
│       ├── Makefile                   # Test execution & synthesis generation targets
│       ├── bin/generate.dart          # Synthesizable SystemVerilog generator
│       ├── lib/                       # ROHD module implementations
│       └── test/                      # Unit & integration hardware testbenches
├── lib/
│   ├── common.inc                     # Architectural macros, vector defines & tiered loads
│   └── particle_runtime.asm           # Direct stride vector table & cold-boot entry
├── tools/
│   ├── pasm.py                        # Two-pass macro assembler
│   ├── psim.py                        # Instruction-accurate simulator & p4db
│   └── act16c.py                      # Action systems compiler
└── apps/
    ├── asm/                           # Assembly validation suites
    └── Action/                         # Action application sources
```

---

## Toolchain & Build Quickstart

For complete setup instructions, VS Code installation, and test commands, see
[Getting Started](GettingStarted.md).

### Prerequisites
* **Dart SDK** `>= 3.0.0 < 4.0.0` with `rohd: ^0.5.0`
* **Python** `>= 3.8`

### 1. Compile Action Programs
```bash
python3 tools/act16c.py apps/act/streaming_demo.act -o apps/asm/streaming_demo.asm
```

### 2. Assemble to Binary or Hex
```bash
python3 tools/pasm.py apps/asm/comprehensive_test.asm -I lib -o build/test.bin --format bin
```

### 3. Simulate & Debug
```bash
# Run simulator
python3 tools/psim.py build/test.bin

# Run interactive debugger (p4db)
python3 tools/psim.py build/test.bin -d
```

### 4. Build Action Programs for Your Computer (LLVM)

Action also compiles through LLVM to native programs for 64-bit macOS and
Linux, which is handy for testing algorithms and libraries off the hardware.
It needs clang (LLVM 15 or later).

```bash
make llvm-tools                        # builds build/tools/action_llvm
./llbuild myprogram.act --run          # compile, link with clang, and run
make llvm-tests                        # run the Action test programs natively
```

`llbuild` accepts several `.act` files, C sources and libraries (`-l`), and
optimization levels (`-O0` to `-O3`); the programs carry debug information for
`lldb`/`gdb`. The language is the same, with additions only the LLVM compiler
has so far (`u64`/`s64`, `f32`/`f64`, and `extern` C functions such as
`printf`); Particle hardware features (inline assembly, FIFOs, trap handlers)
are not available. See section 2.10 of the Action language guide.

### 5. Run ROHD Hardware Tests & Generate SystemVerilog
```bash
cd hdl/particle
dart pub get
dart test
dart run bin/generate.dart   # Emits synthesizable particle_top.sv
```
