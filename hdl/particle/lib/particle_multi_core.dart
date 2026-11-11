// ==============================================================================
// Parcore Dual-Core Spatial Emulation Interconnect
// Integrates Core 0, Core 1, SARF (32x32), and Multi-Channel Streaming FIFOs
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'constants.dart';
import 'fifo_subsystem.dart';
import 'shared_reg_fabric.dart';

class ParticleMultiCore extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // Core 0 Memory Ports
  Logic get c0MemPortARData => input('c0_memPortARData');
  Logic get c0MemPortBRData => input('c0_memPortBRData');
  Logic get c0MemPortAAddr => output('c0_memPortAAddr');
  Logic get c0MemPortBAddr => output('c0_memPortBAddr');
  Logic get c0MemPortBWData => output('c0_memPortBWData');
  Logic get c0MemPortBBEn => output('c0_memPortBBEn');
  Logic get c0MemPortBWEn => output('c0_memPortBWEn');
  Logic get c0MemPortBREn => output('c0_memPortBREn');

  // Core 1 Memory Ports
  Logic get c1MemPortARData => input('c1_memPortARData');
  Logic get c1MemPortBRData => input('c1_memPortBRData');
  Logic get c1MemPortAAddr => output('c1_memPortAAddr');
  Logic get c1MemPortBAddr => output('c1_memPortBAddr');
  Logic get c1MemPortBWData => output('c1_memPortBWData');
  Logic get c1MemPortBBEn => output('c1_memPortBBEn');
  Logic get c1MemPortBWEn => output('c1_memPortBWEn');
  Logic get c1MemPortBREn => output('c1_memPortBREn');

  // Diagnostic / SARF Collision Status
  Logic get sarfCollision => output('sarf_collision');

  // Cross-Core Mailbox Interconnect Status
  Logic get c0MboxStrobeIn => output('c0_mboxStrobeIn');
  Logic get c0MboxVectorIn => output('c0_mboxVectorIn');
  Logic get c1MboxStrobeIn => output('c1_mboxStrobeIn');
  Logic get c1MboxVectorIn => output('c1_mboxVectorIn');

  ParticleMultiCore({
    required Logic clk,
    required Logic reset,
    required Logic c0MemPortARData,
    required Logic c0MemPortBRData,
    required Logic c1MemPortARData,
    required Logic c1MemPortBRData,
    CpuConfig configCore0 = const CpuConfig(trapTableBase: 0x00000100),
    CpuConfig configCore1 = const CpuConfig(trapTableBase: 0x00000100),
    super.name = 'particle_multi_core',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);

    addInput('c0_memPortARData', c0MemPortARData, width: ParticleWidths.inst);
    addInput('c0_memPortBRData', c0MemPortBRData, width: ParticleWidths.word);
    addOutput('c0_memPortAAddr', width: ParticleWidths.word);
    addOutput('c0_memPortBAddr', width: ParticleWidths.word);
    addOutput('c0_memPortBWData', width: ParticleWidths.word);
    addOutput('c0_memPortBBEn', width: ParticleWidths.byteEnable);
    addOutput('c0_memPortBWEn');
    addOutput('c0_memPortBREn');

    addInput('c1_memPortARData', c1MemPortARData, width: ParticleWidths.inst);
    addInput('c1_memPortBRData', c1MemPortBRData, width: ParticleWidths.word);
    addOutput('c1_memPortAAddr', width: ParticleWidths.word);
    addOutput('c1_memPortBAddr', width: ParticleWidths.word);
    addOutput('c1_memPortBWData', width: ParticleWidths.word);
    addOutput('c1_memPortBBEn', width: ParticleWidths.byteEnable);
    addOutput('c1_memPortBWEn');
    addOutput('c1_memPortBREn');

    addOutput('sarf_collision');
    addOutput('c0_mboxStrobeIn');
    addOutput('c0_mboxVectorIn', width: 4);
    addOutput('c1_mboxStrobeIn');
    addOutput('c1_mboxVectorIn', width: 4);

    _build(configCore0, configCore1);
  }

  void _build(CpuConfig cfg0, CpuConfig cfg1) {
    // SARF Shared Register Fabric Wires
    final c0Rs1Addr = Logic(name: 'c0Rs1Addr', width: 5);
    final c0Rs2Addr = Logic(name: 'c0Rs2Addr', width: 5);
    final c0RdAddr  = Logic(name: 'c0RdAddr', width: 5);
    final c0RdData  = Logic(name: 'c0RdData', width: 32);
    final c0RdWe    = Logic(name: 'c0RdWe');

    final c1Rs1Addr = Logic(name: 'c1Rs1Addr', width: 5);
    final c1Rs2Addr = Logic(name: 'c1Rs2Addr', width: 5);
    final c1RdAddr  = Logic(name: 'c1RdAddr', width: 5);
    final c1RdData  = Logic(name: 'c1RdData', width: 32);
    final c1RdWe    = Logic(name: 'c1RdWe');

    final sarf = SharedRegFabric(
      clk: clk,
      reset: reset,
      c0Rs1Addr: c0Rs1Addr,
      c0Rs2Addr: c0Rs2Addr,
      c0RdAddr: c0RdAddr,
      c0RdData: c0RdData,
      c0RdWe: c0RdWe,
      c1Rs1Addr: c1Rs1Addr,
      c1Rs2Addr: c1Rs2Addr,
      c1RdAddr: c1RdAddr,
      c1RdData: c1RdData,
      c1RdWe: c1RdWe,
    );
    sarfCollision <= sarf.collisionStrobe;

    // Cross-Core Mailbox Interconnect
    final c0MboxStrobeIn = Logic(name: 'c0MboxStrobeIn');
    final c0MboxVectorIn = Logic(name: 'c0MboxVectorIn', width: 4);
    final c1MboxStrobeIn = Logic(name: 'c1MboxStrobeIn');
    final c1MboxVectorIn = Logic(name: 'c1MboxVectorIn', width: 4);
    // Dual Streaming FIFO Channels for Cross-Core Dataflow
    final c0FifoPushData = Logic(name: 'c0FifoPushData', width: 32);
    final c0FifoPushEn   = Logic(name: 'c0FifoPushEn');
    final c0FifoPopEn    = Logic(name: 'c0FifoPopEn');

    final c1FifoPushData = Logic(name: 'c1FifoPushData', width: 32);
    final c1FifoPushEn   = Logic(name: 'c1FifoPushEn');
    final c1FifoPopEn    = Logic(name: 'c1FifoPopEn');

    // Ch 0 (Core 0 -> Core 1): Instruction dispatch & operand token stream
    final fifo0to1 = ParticleFifoSubsystem(
      clk: clk,
      reset: reset,
      chanSelect: Const(0, width: 2),
      pushData: c0FifoPushData,
      pushEn: c0FifoPushEn,
      popEn: c1FifoPopEn,
      channels: 1,
      name: 'fifo_c0_to_c1',
    );

    // Ch 1 (Core 1 -> Core 0): Branch redirect / result token stream
    final fifo1to0 = ParticleFifoSubsystem(
      clk: clk,
      reset: reset,
      chanSelect: Const(0, width: 2),
      pushData: c1FifoPushData,
      pushEn: c1FifoPushEn,
      popEn: c0FifoPopEn,
      channels: 1,
      name: 'fifo_c1_to_c0',
    );

    // Core 0 Instantiation
    final core0 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c0MemPortARData,
      memPortBRData: c0MemPortBRData,
      mboxStrobeIn: c0MboxStrobeIn,
      mboxVectorIn: c0MboxVectorIn,
      fifoPopData: fifo1to0.popData,
      fifoStatus: fifo1to0.statusWord,
      sarfRs1Data: sarf.c0Rs1Data,
      sarfRs2Data: sarf.c0Rs2Data,
      config: cfg0,
      name: 'core0',
    );

    c0MemPortAAddr  <= core0.memPortAAddr;
    c0MemPortBAddr  <= core0.memPortBAddr;
    c0MemPortBWData <= core0.memPortBWData;
    c0MemPortBBEn   <= core0.memPortBBEn;
    c0MemPortBWEn   <= core0.memPortBWEn;
    c0MemPortBREn   <= core0.memPortBREn;

    c0Rs1Addr       <= core0.sarfRs1Addr;
    c0Rs2Addr       <= core0.sarfRs2Addr;
    c0RdAddr        <= core0.sarfRdAddr;
    c0RdData        <= core0.sarfRdData;
    c0RdWe          <= core0.sarfRdWe;

    c0FifoPushData  <= core0.fifoPushData;
    c0FifoPushEn    <= core0.fifoPushEn;
    c0FifoPopEn     <= core0.fifoPopEn;

    // Core 1 Instantiation
    final core1 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c1MemPortARData,
      memPortBRData: c1MemPortBRData,
      mboxStrobeIn: c1MboxStrobeIn,
      mboxVectorIn: c1MboxVectorIn,
      fifoPopData: fifo0to1.popData,
      fifoStatus: fifo0to1.statusWord,
      sarfRs1Data: sarf.c1Rs1Data,
      sarfRs2Data: sarf.c1Rs2Data,
      config: cfg1,
      name: 'core1',
    );

    c1MemPortAAddr  <= core1.memPortAAddr;
    c1MemPortBAddr  <= core1.memPortBAddr;
    c1MemPortBWData <= core1.memPortBWData;
    c1MemPortBBEn   <= core1.memPortBBEn;
    c1MemPortBWEn   <= core1.memPortBWEn;
    c1MemPortBREn   <= core1.memPortBREn;

    c1Rs1Addr       <= core1.sarfRs1Addr;
    c1Rs2Addr       <= core1.sarfRs2Addr;
    c1RdAddr        <= core1.sarfRdAddr;
    c1RdData        <= core1.sarfRdData;
    c1RdWe          <= core1.sarfRdWe;

    c1FifoPushData  <= core1.fifoPushData;
    c1FifoPushEn    <= core1.fifoPushEn;
    c1FifoPopEn     <= core1.fifoPopEn;

    // Cross-connect MBOX strobes
    c1MboxStrobeIn <= core0.mboxStrobeOut;
    c1MboxVectorIn <= core0.mboxVectorOut;
    c0MboxStrobeIn <= core1.mboxStrobeOut;
    c0MboxVectorIn <= core1.mboxVectorOut;

    output('c0_mboxStrobeIn') <= c0MboxStrobeIn;
    output('c0_mboxVectorIn') <= c0MboxVectorIn;
    output('c1_mboxStrobeIn') <= c1MboxStrobeIn;
    output('c1_mboxVectorIn') <= c1MboxVectorIn;
  }
}
