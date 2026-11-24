// =============================================================================
// File: hdl/parcore/lib/parcore_config.dart
// Description: Multi-core 5-stage pipeline and cache controller configurations.
// =============================================================================

import 'package:particle_rohd/cpu_config.dart';

class ParcoreConfig {
  /// Conductor Supervisor Core (Minimal footprint, 2 KB TCM, no FIFOs/DSP)
  static const CpuConfig conductorConfig = CpuConfig(
    coreId: 7,
    tcmSizeBytes: 2 * 1024,
    fifoChannels: 0,
    fifoDepth: 0,
    enableMultiplier: false,
    enableDivider: false,
    enableUlx3sFtdiUart: false,
    trapTableBase: 0x00000100,
  );

  /// Core 0: Instruction Fetch Stage (IF)
  static const CpuConfig core0If = CpuConfig(
    coreId: 0,
    // 16 KB: its vectors and handlers at 0x100-0x4FF, the guest image at
    // 0x500-0x1FFF (as in core 3), and its fetch and decode code from 0x2000
    tcmSizeBytes: 16 * 1024,
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
    enableUlx3sFtdiUart: false,
  );

  /// Core 1: Instruction Decode Stage (ID) & Register Scoreboard
  static const CpuConfig core1Id = CpuConfig(
    coreId: 1,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 3,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
  );

  /// Core 2: Execute Stage (EX)
  static const CpuConfig core2Ex = CpuConfig(
    coreId: 2,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: true,
    enableDivider: true,
  );

  /// Core 3: Memory Access Stage (MEM) + FTDI Console UART (guest I/O)
  static const CpuConfig core3Mem = CpuConfig(
    coreId: 3,
    // 8 KB, like core 0: both hold the guest image at 0x500-0x1FFF
    tcmSizeBytes: 8 * 1024,
    // 0 exToMem in, 1 memToWb, 2 memToIf (store mirror), 3 the FTDI UART
    fifoChannels: 4,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
    enableUlx3sFtdiUart: true,
    ulx3sUartFifoChannel: 3,
  );

  /// Core 4: Writeback Stage (WB)
  static const CpuConfig core4Wb = CpuConfig(
    coreId: 4,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
  );

  /// Core 5: L1 Cache Controller (CC) & SDRAM Burster
  static const CpuConfig core5Cache = CpuConfig(
    coreId: 5,
    tcmSizeBytes: 32 * 1024, // 32 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
  );
}
