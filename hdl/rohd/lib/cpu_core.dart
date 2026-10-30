// =============================================================================
// File: hdl/rohd/lib/cpu_core.dart
// Architecture: Particle 32-bit RISC
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'register_file.dart';
import 'alu.dart';
import 'multiplier.dart';
import 'divider.dart';
import 'fifo_subsystem.dart';
import 'memory_bus.dart';

class ParticleCpuCore extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  Logic get memPortARData => input('memPortARData');
  Logic get memPortBRData => input('memPortBRData');
  Logic get mboxStrobeIn => input('mboxStrobeIn');
  Logic get mboxVectorIn => input('mboxVectorIn');

  Logic get memPortAAddr => output('memPortAAddr');
  Logic get memPortBAddr => output('memPortBAddr');
  Logic get memPortBWData => output('memPortBWData');
  Logic get memPortBBEn => output('memPortBBEn');
  Logic get memPortBWEn => output('memPortBWEn');
  Logic get memPortBREn => output('memPortBREn');

  ParticleCpuCore({
    required Logic clk,
    required Logic reset,
    required Logic memPortARData,
    required Logic memPortBRData,
    required Logic mboxStrobeIn,
    required Logic mboxVectorIn,
    CpuConfig config = const CpuConfig(),
    super.name = 'particle_cpu_core',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('memPortARData', memPortARData, width: ParticleWidths.halfWord);
    addInput('memPortBRData', memPortBRData, width: ParticleWidths.word);
    addInput('mboxStrobeIn', mboxStrobeIn);
    addInput('mboxVectorIn', mboxVectorIn, width: 4);

    addOutput('memPortAAddr', width: ParticleWidths.word);
    addOutput('memPortBAddr', width: ParticleWidths.word);
    addOutput('memPortBWData', width: ParticleWidths.word);
    addOutput('memPortBBEn', width: 4);
    addOutput('memPortBWEn');
    addOutput('memPortBREn');

    _build(config);
  }

  void _build(CpuConfig config) {
    final pc = Logic(name: 'pc', width: ParticleWidths.word);
    final nextPc = Logic(name: 'nextPc', width: ParticleWidths.word);

    final rfRAddrA = Logic(name: 'rfRAddrA', width: ParticleWidths.regAddr);
    final rfRAddrB = Logic(name: 'rfRAddrB', width: ParticleWidths.regAddr);
    final rfWAddr = Logic(name: 'rfWAddr', width: ParticleWidths.regAddr);
    final rfWData = Logic(name: 'rfWData', width: ParticleWidths.word);
    final rfWEn = Logic(name: 'rfWEn');
    final rfXchgEn = Logic(name: 'rfXchgEn');
    final rfXchgAllEn = Logic(name: 'rfXchgAllEn');
    final rfXchgMostEn = Logic(name: 'rfXchgMostEn');
    final rfXchgRegIdx =
        Logic(name: 'rfXchgRegIdx', width: ParticleWidths.regAddr);

    final rf = RegisterFile(
      clk: clk,
      reset: reset,
      rAddrA: rfRAddrA,
      rAddrB: rfRAddrB,
      wAddr: rfWAddr,
      wData: rfWData,
      wEn: rfWEn,
      xchgEn: rfXchgEn,
      xchgAllEn: rfXchgAllEn,
      xchgMostEn: rfXchgMostEn,
      xchgRegIdx: rfXchgRegIdx,
    );

    final memAddr = Logic(name: 'memAddr', width: ParticleWidths.word);
    final memSize = Logic(name: 'memSize', width: 2);
    final memWEn = Logic(name: 'memWEn');
    final memREn = Logic(name: 'memREn');

    final bus = ParticleMemoryBus(
      addr: memAddr,
      wData: rf.rDataB,
      size: memSize,
      wEn: memWEn,
      rEn: memREn,
      rDataRaw: memPortBRData,
    );

    // Direct connections to registered module outputs
    memPortAAddr <= pc;
    memPortBAddr <= memAddr;
    memPortBWData <= bus.wDataAligned;
    memPortBBEn <= bus.bEn;
    memPortBWEn <= bus.bEn.neq(0);
    memPortBREn <= memREn;

    // Reset and Strobe Handling
    final targetTrap = Const(config.trapTableBase, width: ParticleWidths.word) +
        (mboxVectorIn.zeroExtend(ParticleWidths.word) *
            Const(config.trapStrideBytes, width: ParticleWidths.word));

    Sequential(clk, reset: reset, resetValues: {
      pc: Const(config.trapTableBase, width: ParticleWidths.word),
    }, [
      If(mboxStrobeIn, then: [
        pc < targetTrap,
      ], orElse: [
        pc < nextPc,
      ]),
    ]);

    nextPc <= pc + Const(2, width: ParticleWidths.word);

    // Unused controls tied off
    rfRAddrA <= Const(0, width: ParticleWidths.regAddr);
    rfRAddrB <= Const(0, width: ParticleWidths.regAddr);
    rfWAddr <= Const(0, width: ParticleWidths.regAddr);
    rfWData <= Const(0, width: ParticleWidths.word);
    rfWEn <= Const(0);
    rfXchgEn <= Const(0);
    rfXchgAllEn <= Const(0);
    rfXchgMostEn <= Const(0);
    rfXchgRegIdx <= Const(0, width: ParticleWidths.regAddr);
    memAddr <= Const(0, width: ParticleWidths.word);
    memSize <= Const(0, width: 2);
    memWEn <= Const(0);
    memREn <= Const(0);
  }
}
