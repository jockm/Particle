// =============================================================================
// File: hdl/parcore/lib/parcore_config.dart
// Description: Multi-core 5-stage pipeline and cache controller configurations.
// =============================================================================

import 'package:particle_rohd/cpu_config.dart';

class ParcoreConfig {
  /// Whether the network interfaces' tables (routes, senders, the default
  /// MBOX target) can be changed by CONFIG packets, and the conductor's
  /// interface has the NI_CONFIG register to send them (418). Parcore's
  /// firmware never sends CONFIG, so it is off: the tables are constants,
  /// about 220 LUT4s and 150 flip-flops fewer. ParticleMan and other builds can turn it on.
  static const bool writableNocTables = false;

  /// Conductor Supervisor Core (minimal: 8 KB TCM, no FIFOs/DSP). 8 KB
  /// (453; 4 KB from 436) leaves room for the watchdog, the pmon console
  /// with flash writing, and what comes later (a gdb stub).
  static const CpuConfig conductorConfig = CpuConfig(
    coreId: 7,
    tcmSizeBytes: 8 * 1024,
    fifoChannels: 0,
    fifoDepth: 0,
    enableMultiplier: false,
    enableDivider: false,
    enableUlx3sFtdiUart: false,
    trapTableBase: 0x00000100,
    // Leave out what its firmware doesn't use (366b): it traps as illegal
    enablePointerModes: true,
    enableSubword: false,
    enableMboxReceive: false,
    enableShadowBank: false,
    // Its firmware is assembled with -D __NO_LONG_BRANCHES (the Makefile)
    enableLongBranches: false,
    enableImmBextr: false,
    // It wakes cores (an MBOX); it never sleeps itself
    enableWaitHalt: false,
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
    // Leave out what its firmware doesn't use (366b): it traps as illegal
    enablePointerModes: false,
    enableSubword: true,
    enableMboxReceive: true,
    enableShadowBank: false,
  );

  /// Core 1: Instruction Decode Stage (ID) & Register Scoreboard
  static const CpuConfig core1Id = CpuConfig(
    coreId: 1,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 3,
    fifoDepth: 256,
    enableMultiplier: false,
    enableDivider: false,
    // Leave out what its firmware doesn't use (366b): it traps as illegal
    enablePointerModes: false,
    enableSubword: true,
    enableMboxReceive: false,
    enableShadowBank: false,
    // Its firmware uses none of the 2-word instructions: it is assembled
    // with -D __NO_LONG_BRANCHES (the Makefile)
    enableLongBranches: false,
  );

  /// Core 2: Execute Stage (EX)
  static const CpuConfig core2Ex = CpuConfig(
    coreId: 2,
    tcmSizeBytes: 4 * 1024, // 4 KB local TCM
    fifoChannels: 2,
    fifoDepth: 256,
    enableMultiplier: true,
    enableDivider: true,
    // Leave out what its firmware doesn't use (366b): it traps as illegal
    enablePointerModes: false,
    enableSubword: false,
    enableMboxReceive: false,
    enableShadowBank: false,
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
    // Leave out what its firmware doesn't use (366b): it traps as illegal
    enablePointerModes: false,
    enableSubword: true,
    enableMboxReceive: false,
    enableShadowBank: false,
    // Its firmware uses none of the 2-word instructions: it is assembled
    // with -D __NO_LONG_BRANCHES (the Makefile)
    enableLongBranches: false,
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
