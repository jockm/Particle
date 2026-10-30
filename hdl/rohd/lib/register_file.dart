// =============================================================================
// File: hdl/rohd/lib/register_file.dart
// Architecture: Particle 32-bit RISC
// Description: 16x32 Register File with hardwired R0, asynchronous dual read
//              ports, synchronous write port, and single-cycle hardware shadow bank.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class RegisterFile extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  Logic get rAddrA => input('rAddrA');
  Logic get rAddrB => input('rAddrB');

  Logic get wAddr => input('wAddr');
  Logic get wData => input('wData');
  Logic get wEn => input('wEn');

  // Shadow Bank Exchange Strobes
  Logic get xchgEn => input('xchgEn');
  Logic get xchgAllEn => input('xchgAllEn');
  Logic get xchgMostEn => input('xchgMostEn');
  Logic get xchgRegIdx => input('xchgRegIdx');

  // Outputs
  Logic get rDataA => output('rDataA');
  Logic get rDataB => output('rDataB');

  RegisterFile({
    required Logic clk,
    required Logic reset,
    required Logic rAddrA,
    required Logic rAddrB,
    required Logic wAddr,
    required Logic wData,
    required Logic wEn,
    required Logic xchgEn,
    required Logic xchgAllEn,
    required Logic xchgMostEn,
    required Logic xchgRegIdx,
    super.name = 'register_file',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('rAddrA', rAddrA, width: ParticleWidths.regAddr);
    addInput('rAddrB', rAddrB, width: ParticleWidths.regAddr);
    addInput('wAddr', wAddr, width: ParticleWidths.regAddr);
    addInput('wData', wData, width: ParticleWidths.word);
    addInput('wEn', wEn);
    addInput('xchgEn', xchgEn);
    addInput('xchgAllEn', xchgAllEn);
    addInput('xchgMostEn', xchgMostEn);
    addInput('xchgRegIdx', xchgRegIdx, width: ParticleWidths.regAddr);

    addOutput('rDataA', width: ParticleWidths.word);
    addOutput('rDataB', width: ParticleWidths.word);

    _build();
  }

  void _build() {
    final activeRegs = List.generate(
      16,
      (i) => Logic(name: 'r$i', width: ParticleWidths.word),
    );
    final shadowRegs = List.generate(
      16,
      (i) => Logic(name: 'shadow_r$i', width: ParticleWidths.word),
    );

    // Hardwired Zero for R0 and Shadow R0
    activeRegs[0] <= Const(0, width: ParticleWidths.word);
    shadowRegs[0] <= Const(0, width: ParticleWidths.word);

    // Sequential update logic for R1 - R15
    final seqStatements = <Conditional>[];

    for (int i = 1; i < 16; i++) {
      final isR15 = (i == 15);
      final doXchgSingle = xchgEn & xchgRegIdx.eq(i);
      final doXchgAll = xchgAllEn;
      final doXchgMost = xchgMostEn & (isR15 ? Const(0) : Const(1));
      final swapCondition = doXchgSingle | doXchgAll | doXchgMost;

      seqStatements.add(
        If(swapCondition, then: [
          activeRegs[i] < shadowRegs[i],
          shadowRegs[i] < activeRegs[i],
        ], orElse: [
          If(wEn & wAddr.eq(i), then: [
            activeRegs[i] < wData,
          ]),
        ]),
      );
    }

    Sequential(
        clk,
        reset: reset,
        resetValues: {
          for (int i = 1; i < 16; i++)
            activeRegs[i]: Const(0, width: ParticleWidths.word),
          for (int i = 1; i < 16; i++)
            shadowRegs[i]: Const(0, width: ParticleWidths.word),
        },
        seqStatements);

    // Asynchronous Read Multiplexers driven via Combinational Case
    Combinational([
      Case(rAddrA, [
        for (int i = 0; i < 16; i++)
          CaseItem(Const(i, width: ParticleWidths.regAddr),
              [rDataA < activeRegs[i]]),
      ], defaultItem: [
        rDataA < Const(0, width: ParticleWidths.word),
      ]),
      Case(rAddrB, [
        for (int i = 0; i < 16; i++)
          CaseItem(Const(i, width: ParticleWidths.regAddr),
              [rDataB < activeRegs[i]]),
      ], defaultItem: [
        rDataB < Const(0, width: ParticleWidths.word),
      ]),
    ]);
  }
}
