# Particle Pure ROHD Hardware Architecture

The Particle processor datapath is implemented 100% in Dart using the **Intel ROHD (Rapid Open Hardware Development)** framework. The codebase maintains clean architectural separation with zero legacy Verilog source files.

---

## Core Datapath Modules

### 1. `RegisterFile` (`hdl/particle/lib/register_file.dart`)
* **Dimensions**: 16 native 32-bit registers paired with a dedicated 16x32 shadow bank.
* **Ports**: Dual asynchronous read ports (`rAddrA`, `rAddrB`) and a single synchronous write port (`wAddr`, `wData`, `wEn`).
* **Hardwired R0**: Register 0 is tied directly to constant 0 on both active and shadow banks; writes to $R0$ are safely ignored.
* **Shadow Bank Synchronization**:
  * `xchgEn`: Swaps active and shadow register at `xchgRegIdx`.
  * `xchgAllEn`: Swaps all registers $R1$ through $R15$ in a single cycle.
  * `xchgMostEn`: Swaps application registers $R1$ through $R14$ while preserving the active stack pointer ($R15$) for instantaneous trap context switches.

### 2. `ParticleAlu` (`hdl/particle/lib/alu.dart`)
* Full 32-bit datapath supporting arithmetic addition, subtraction, bitwise logic (`AND`, `OR`, `XOR`), and barrel shifting (`ShiftL`, `ShiftR`, `AShiftR`, `RotL`, `RotR`).
* Provides single-cycle sign-extension (`SEXT8`, `SEXT16`), population count, and leading zero count (`CLZ`).
* Emits condition flags: `isZero`, `isNegative`, `overflow`, and `carry`.

### 3. `ParticleMultiplier` (`hdl/particle/lib/multiplier.dart`)
* Single-cycle 32x32 hardware multiplier mapping directly to FPGA DSP blocks (e.g. ECP5 `MULT18X18D`).
* Operates across 4 architectural modes:
  * `MULL`: Lower 32 bits of unsigned product.
  * `MULH`: Upper 32 bits of unsigned product ($32 	imes 32 	o 64$).
  * `SMULH`: Upper 32 bits of signed product.
  * `MULHSU`: Upper 32 bits of signed $	imes$ unsigned product.

### 4. `ParticleDivider` (`hdl/particle/lib/divider.dart`)
* Multi-cycle non-restoring divider computing 32-bit quotient and remainder over 34 clock cycles.
* Supports both signed (`SDiv`, `SMod`) and unsigned (`Div`, `Mod`) operations with zero-division protection.

### 5. `ParticleFifoSubsystem` (`hdl/particle/lib/fifo_subsystem.dart`)
* Parameterized multi-channel streaming FIFO array (default: 4 channels, 256 depth).
* Synchronous head inspection, atomic push/pop strobes, and full/empty status bitfield generation (`FIFO.STAT`).

### 6. `ParticleMemoryBus` (`hdl/particle/lib/memory_bus.dart`)
* Connects the execution pipeline to on-chip True Dual-Port Block RAM.
* Drives 4-bit byte enables (`bEn`) for sub-word writes (8, 16, 32 bits).
* Hardware alignment verification: traps misaligned halfword (`addr[0] != 0`) and word (`addr[1:0] != 0`) memory operations to Vector 14 before committing changes.
