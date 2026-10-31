// =============================================================================
// File: hdl/parcore/lib/parcore_config.dart
// Description: Multi-core 5-stage pipeline and cache controller configurations.
// =============================================================================

import 'package:particle_rohd/cpu_config.dart';

class ParcoreConfig {
  /// Core 0: Instruction Fetch Stage (IF) + FTDI Console UART
  /// Needs a modest buffer for UART character staging and fetch window
  static const CpuConfig core0If = CpuConfig(
    coreId: 0,
    tcmSizeBytes: 8 * 1024, // 8 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
    enableUlx3sFtdiUart: true,
    ulx3sUartFifoChannel: 0,
  );

  /// Core 1: Instruction Decode Stage (ID) & Register Scoreboard
  /// Tight register lookup loop; minimal local scratchpad needed
  static const CpuConfig core1Id = CpuConfig(
    coreId: 1,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 3,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
  );

  /// Core 2: Execute Stage (EX)
  /// Dedicated execution engine; retains multiplier/divider
  static const CpuConfig core2Ex = CpuConfig(
    coreId: 2,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: true,
    enableDivider: true,
  );

  /// Core 3: Memory Access Stage (MEM)
  /// Handles alignment and routing tokens
  static const CpuConfig core3Mem = CpuConfig(
    coreId: 3,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
  );

  /// Core 4: Writeback Stage (WB)
  /// Commit and retire queue
  static const CpuConfig core4Wb = CpuConfig(
    coreId: 4,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
  );

  /// Core 5: L1 Cache Controller (CC) & SDRAM Burster
  /// Needs significant RAM for cache tag directories and line refill buffers
  static const CpuConfig core5Cache = CpuConfig(
    coreId: 5,
    tcmSizeBytes: 32 * 1024, // 32 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
  );
}
