# Architecture Proposal: The Parcore Conductor

**System:** Parcore Heterogeneous Multi-Core Fabric  
**Subsystem:** System Lifecycle & Firmware Boot Supervisor  
**Target Platform:** Lattice ECP5-45F / ECP5-85F (ULX3S)  
**Hardware Description:** Intel ROHD (Dart)  

---

## 1. Executive Summary

In the current Parcore architecture, application stage firmware for Cores 0–5 (IF, ID, EX, MEM, WB, CC) is embedded directly into synthesized Block RAM initialization vectors or loaded statically at testbench construction.

**The Parcore Conductor** is a dedicated, ultra-minimalist supervisor core tasked with system lifecycle orchestration. At power-on, the Conductor holds the application cores in hardware reset, reads stage firmware binaries from an SPI flash memory (or host interface), writes the code directly into each target core's Tightly Coupled Memory (TCM) via Port B multiplexing, and subsequently releases the execution cores in a deterministic, synchronized sequence.

---

## 2. Core Architectural Principles

1. **Deterministic Staging (Zero-Race Boot):** Application cores remain completely quiescent in reset while their instruction and data spaces are staged. No core boots into partially initialized memories or polls empty inter-core FIFOs.
2. **Out-of-Band Staging via Port B MUX:** Bypasses the pipeline FIFO interconnect entirely for code distribution. Firmware is written directly into local TCMs using existing memory write ports.
3. **Ultra-Minimal Footprint:** The Conductor is stripped of all optional execution units (no hardware multiplier, divider, barrel shifter, or streaming FIFO channels), keeping silicon logic overhead minimal.
4. **Post-Boot Utility:** Following system bootstrap, the Conductor transitions into a low-overhead supervisor: monitoring pipeline heartbeats/deadlocks, hosting debug monitors over UART, or handling dynamic overlay reloading.

---

## 3. Hardware Architecture & Interconnect

### 3.1 Top-Level Block Diagram

```
                 +--------------------------------------+
                 |         Parcore Conductor            |
                 |     (Minimal Particle Core)          |
                 +----+-----------------------------+---+
                      | condMem* (Port B Bus)       |
                      | [Addr, WData, BEn, WEn]     | condResetControl [5:0]
                      v                             v
           +--------------------+         +--------------------+
           |  Address Decoder   |         |  Reset Controller  |
           |   & Target Select  |         |                    |
           +---------+----------+         +---------+----------+
                     | targetCore[2:0]              |
                     |                              |
         +-----------+------------------------------+------------+
         |                                                       |
         v (Core 0 Active)                                       v (Core N Active)
   +-----------+                                           +-----------+
   |   MUX 0   |<-- core0.memPortB*                        |   MUX N   |<-- coreN.memPortB*
   +-----+-----+                                           +-----+-----+
         | Port B                                                | Port B
   +-----v-----+                                           +-----v-----+
   |  Core 0   |                                           |  Core N   |
   |  TCM BRAM |                                           |  TCM BRAM |
   +-----------+                                           +-----------+
```

---

### 3.2 TCM Port B Multiplexing Logic

Each core's `ParcoreTcm` block provides:
* **Port A (16-bit):** Instruction fetch port (dedicated to local core's program counter).
* **Port B (32-bit):** Data load/store port with byte enables.

In `parcore_top.dart`, each core’s Port B inputs are wrapped in a 2:1 multiplexer controlled by the Conductor's reset state for that core:

$$\text{sel}_i = \text{condCoreReset}[i] \ \& \ (\text{condTargetCore} == i)$$

```dart
// Conceptual ROHD Muxing per Core in parcore_top.dart
final isConductorActive = condCoreReset[i] & condTargetCore.eq(Const(i, width: 3));

final muxedAddrB = mux(
  isConductorActive,
  condMemAddr.slice(addrBits - 1, 2),
  core.memPortBAddr.slice(addrBits - 1, 2),
);

final muxedWDataB = mux(
  isConductorActive,
  condMemWData,
  core.memPortBWData,
);

final muxedBEnB = mux(
  isConductorActive,
  condMemBEn,
  core.memPortBBEn,
);

final muxedWEnB = mux(
  isConductorActive,
  condMemWEn,
  core.memPortBWEn & (core.memPortBAddr.slice(31, 28).neq(Const(0xF, width: 4))),
);

final muxedREnB = mux(
  isConductorActive,
  condMemREn, // Optional: read-back verification
  core.memPortBREn,
);
```

---

### 3.3 Conductor Memory Map & Target Windowing

The Conductor addresses individual cores and peripherals through a partitioned memory map:

| Address Range | Size | Target / Function |
| :--- | :--- | :--- |
| `0x0000_0000` – `0x0000_07FF` | 2 KB | **Conductor Local Boot TCM (Code & Stack)** |
| `0x1000_0000` – `0x1000_1FFF` | 8 KB | **Core 0 (IF) TCM Window** |
| `0x1001_0000` – `0x1001_0FFF` | 4 KB | **Core 1 (ID) TCM Window** |
| `0x1002_0000` – `0x1002_0FFF` | 4 KB | **Core 2 (EX) TCM Window** |
| `0x1003_0000` – `0x1003_0FFF` | 4 KB | **Core 3 (MEM) TCM Window** |
| `0x1004_0000` – `0x1004_0FFF` | 4 KB | **Core 4 (WB) TCM Window** |
| `0x1005_0000` – `0x1005_7FFF` | 32 KB | **Core 5 (CC) TCM Window** |
| `0xF000_0000` – `0xF000_0003` | 4 B | **Core Reset Control Register (`RST_CTRL`)** |
| `0xF000_0010` – `0xF000_001C` | 16 B | **SPI Flash Controller MMIO** |

#### Conductor Control Registers:
* **`RST_CTRL` (`0xF000_0000`):**
  * `Bits [5:0]`: Per-core active-high reset/hold lines (`1` = In Reset / MUX to Conductor; `0` = Released / Executing).
  * `Bit 6`: Global Pipeline Interconnect FIFO flush strobe.
  * `Bit 31`: Conductor completed boot indicator.

---

## 4. Resource Budget & Minimization Strategy

To preserve maximum FPGA fabric on the Lattice ECP5 for application pipeline cores and caches, the Conductor is stripped to the minimum configuration required for control flow, byte manipulation, and SPI burst loading.

### 4.1 Feature Stripping Configuration (`CpuConfig`)

```dart
static const CpuConfig conductorConfig = CpuConfig(
  coreId: 7,                  // Designated supervisor ID
  tcmSizeBytes: 2 * 1024,     // 2 KB (Smallest viable block RAM slice)
  fifoChannels: 0,            // Omit FIFO subsystem entirely
  fifoDepth: 0,
  enableMultiplier: false,    // Omit DSP slice allocation
  enableDivider: false,       // Omit multi-cycle hardware divider
  enableUlx3sFtdiUart: false, // UART managed via explicit MMIO if needed
  trapTableBase: 0x00000100,
);
```

### 4.2 Estimated FPGA Resource Footprint (Lattice ECP5)

| Subsystem Component | LUT4 Logic | Flip-Flops (Registers) | EBR (BRAM 18Kb) | DSP Slices |
| :--- | :--- | :--- | :--- | :--- |
| **Particle Core (Minimal)** | ~850 – 950 | ~420 | 0 | 0 |
| **Conductor TCM (2 KB)** | 0 | 0 | 1 (18Kb block) | 0 |
| **Port B 2:1 Multiplexers (6 Cores)** | ~120 – 150 | 0 | 0 | 0 |
| **Address Decoder & Reset FSM** | ~40 – 60 | ~16 | 0 | 0 |
| **SPI Master Engine (MMIO)** | ~180 – 220 | ~110 | 0 | 0 |
| **Total Conductor Overhead** | **~1,200 – 1,400** | **~550** | **1 Block** | **0** |

*Note: On an ECP5-45F (44k LUTs, 108 EBRs), The Parcore Conductor utilizes less than **3% of logic** and **0.9% of on-chip BRAM**.*

---

## 5. Boot Sequence & Lifecycle Timing

1. **Hardware Power-On:**
   * Global `reset` asserts.
   * `condCoreReset[5:0]` defaults to `6'b111111`.
   * Cores 0–5 are held in reset. Port B multiplexers route to the Conductor bus.
2. **Conductor ROM Initialization:**
   * Global `reset` deasserts. The Conductor boots at `0x0000_0100` in its local 2 KB TCM.
3. **SPI Flash Readout & Verification:**
   * The Conductor commands the SPI controller to read the multi-core image header.
   * Parses the firmware payload table (identifying length and target core offsets).
4. **TCM Population:**
   * Streams 32-bit words directly into `0x1000_0000` (Core 0), `0x1001_0000` (Core 1), etc.
   * Hardware write enables assert Port B directly into each target BRAM.
5. **Deterministic Pipeline Release:**
   * Once loading and CRC validation complete, the Conductor writes `0x0000_0000` to `RST_CTRL`.
   * Cores 0–5 simultaneously release from reset and begin fetching from `0x0000_0100` on Port A.
6. **Supervisor Loop:**
   * The Conductor branches to a background watchdog loop or enters a low-frequency sleep/poll state.

---

## 6. Implementation Roadmap

1. **Phase 1: ROHD Control & Reset Wiring (`hdl/parcore/lib/parcore_top.dart`)**
   * Add per-core reset signals to `ParticleCpuCore`.
   * Implement Port B 2:1 multiplexers in `buildTcm()`.
2. **Phase 2: Conductor Core Instantiation**
   * Instantiate the minimal Particle core (`conductorConfig`) in `ParcoreTop`.
   * Wire memory aperture decoding for `0x1000_0000`–`0x1005_FFFF`.
3. **Phase 3: SPI Master Controller Integration**
   * Implement lightweight memory-mapped SPI controller in `hdl/parcore/lib/spi_controller.dart`.
4. **Phase 4: Conductor Firmware (`firmware/parcore/conductor/bootloader.asm`)**
   * Write assembly bootloader to handle SPI read burst, staging loop, and reset release.