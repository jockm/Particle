// =============================================================================
// File: hdl/particle/lib/cpu_config.dart
// Architecture: Particle 32-bit RISC
// Description: Parameterized core configuration supporting dual UARTs,
//              optional execution units, and memory boundaries.
// =============================================================================

class CpuConfig {
  /// Base address for direct stride exception table (Default: 0x00000100)
  final int trapTableBase;

  /// Stride size in bytes per trap vector slot (Default: 16 bytes, 8 instructions)
  final int trapStrideBytes;

  /// Number of point-to-point streaming FIFO channels (Default: 4)
  final int fifoChannels;

  /// Maximum depth per FIFO channel in 32-bit words (Default: 256)
  final int fifoDepth;

  /// Hardware Core ID for multi-core topologies (Default: 0)
  final int coreId;

  // ---------------- Missing MR4 Hardware Configuration Options ----------------

  /// Enable the DSP multiplier hardware (2 cycles) (if false, traps to soft emulation)
  final bool enableMultiplier;

  /// Enable multi-cycle non-restoring divider hardware (if false, traps to soft emulation)
  final bool enableDivider;

  /// The pointer modes: loads and stores that pre/post increment or
  /// decrement their pointer register. When false they trap as illegal
  /// (vector 15). Default: true.
  final bool enablePointerModes;

  /// Byte and halfword loads and stores (LD8, ST8, LD16, ST16 in every
  /// mode). When false they trap as illegal (vector 15). Default: true.
  final bool enableSubword;

  /// Taking MBOX traps from other cores. When false an incoming MBOX strobe
  /// is ignored (the core can still send one). Default: true.
  final bool enableMboxReceive;

  /// The shadow register bank (S1-S15). When false XCHG, XCHGALL and
  /// XCHGMOST trap as illegal (vector 15) and the register file has no
  /// second bank. Default: true.
  final bool enableShadowBank;

  /// On-chip tightly-coupled BRAM size in bytes (Default: 64 KB)
  final int tcmSizeBytes;

  /// Base address for shared MMIO / external memory bus window
  final int mmioBaseAddr;

  // ---------------- Dual UART Peripheral Configuration ----------------

  /// Enable onboard ULX3S fixed 3 Mbps FTDI UART
  final bool enableUlx3sFtdiUart;

  /// FIFO channel mapped to the 3 Mbps FTDI UART (Convention: Channel 0)
  final int ulx3sUartFifoChannel;

  /// Base clock frequency in Hz feeding the UART logic (e.g., 25_000_000 on ULX3S)
  final int systemClockHz;

  /// Enable arbitrary-baud auxiliary UART routed to external GPIO / PMOD headers
  final bool enableAuxGpioUart;

  /// FIFO channel mapped to auxiliary GPIO UART (Convention: Channel 1)
  final int auxUartFifoChannel;

  /// Default baud rate for the auxiliary UART (e.g. 115200)
  final int auxUartDefaultBaud;

  const CpuConfig({
    this.trapTableBase = 0x00000100,
    this.trapStrideBytes = 16,
    this.fifoChannels = 4,
    this.fifoDepth = 256,
    this.coreId = 0,
    this.enableMultiplier = true,
    this.enableDivider = true,
    this.enablePointerModes = true,
    this.enableSubword = true,
    this.enableMboxReceive = true,
    this.enableShadowBank = true,
    this.tcmSizeBytes = 65536,
    this.mmioBaseAddr = 0xF0000000,
    this.enableUlx3sFtdiUart = true,
    this.ulx3sUartFifoChannel = 0,
    this.systemClockHz = 25000000,
    this.enableAuxGpioUart = true,
    this.auxUartFifoChannel = 1,
    this.auxUartDefaultBaud = 115200,
  });
}
