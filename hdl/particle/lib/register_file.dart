// =============================================================================
// File: hdl/particle/lib/register_file.dart
// Architecture: Particle 32-bit RISC Core
// Description: 16x32 Register File with hardwired R0, dual read ports, two
//              write ports, and a single-cycle shadow bank.
// =============================================================================
//
// Registers R0..R15 are addressed by their 4-bit index. R0 reads as zero and
// can't be written. Each register Rn has a shadow Sn (S0 is also always zero).
//
// Write ports: port 1 (wAddr/wData/wEn) and port 2 (wAddr2/wData2/wEn2).
// When both write the same register in the same cycle, port 2 wins.

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

  Logic get wAddr2 => input('wAddr2');
  Logic get wData2 => input('wData2');
  Logic get wEn2 => input('wEn2');

  // Shadow Bank Exchange Strobes
  Logic get xchgEn => input('xchgEn');
  Logic get xchgAllEn => input('xchgAllEn');
  Logic get xchgMostEn => input('xchgMostEn');
  Logic get xchgRegIdx => input('xchgRegIdx');

  // Outputs
  Logic get rDataA => output('rDataA');
  Logic get rDataB => output('rDataB');

  /// The 16 registers and their shadows, for tests and debugging.
  late final List<Logic> physical;
  late final List<Logic> shadow;

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
    Logic? wAddr2,
    Logic? wData2,
    Logic? wEn2,
    super.name = 'register_file',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('rAddrA', rAddrA, width: ParticleWidths.regAddr);
    addInput('rAddrB', rAddrB, width: ParticleWidths.regAddr);
    addInput('wAddr', wAddr, width: ParticleWidths.regAddr);
    addInput('wData', wData, width: ParticleWidths.word);
    addInput('wEn', wEn);
    addInput('wAddr2', wAddr2 ?? Const(0, width: ParticleWidths.regAddr),
        width: ParticleWidths.regAddr);
    addInput('wData2', wData2 ?? Const(0, width: ParticleWidths.word),
        width: ParticleWidths.word);
    addInput('wEn2', wEn2 ?? Const(0));
    addInput('xchgEn', xchgEn);
    addInput('xchgAllEn', xchgAllEn);
    addInput('xchgMostEn', xchgMostEn);
    addInput('xchgRegIdx', xchgRegIdx, width: ParticleWidths.regAddr);
    addOutput('rDataA', width: ParticleWidths.word);
    addOutput('rDataB', width: ParticleWidths.word);
    _build();
  }

  void _build() {
    const numRegs = 16;
    final activeRegs = List.generate(
      numRegs,
      (i) => Logic(name: 'r$i', width: ParticleWidths.word),
    );
    final shadowRegs = List.generate(
      numRegs,
      (i) => Logic(name: 'shadow_r$i', width: ParticleWidths.word),
    );
    physical = activeRegs;
    shadow = shadowRegs;

    // Hardwired zero for R0 and S0
    activeRegs[0] <= Const(0, width: ParticleWidths.word);
    shadowRegs[0] <= Const(0, width: ParticleWidths.word);

    final seqStatements = <Conditional>[];

    for (int i = 1; i < numRegs; i++) {
      final doXchgSingle = xchgEn & xchgRegIdx.eq(i);
      final doXchgAll = xchgAllEn;
      // XCHGMOST swaps R1..R14, keeping R15 (the stack pointer)
      final doXchgMost = i <= 14 ? xchgMostEn : Const(0);
      final swapCondition = doXchgSingle | doXchgAll | doXchgMost;

      seqStatements.add(
        If(swapCondition, then: [
          activeRegs[i] < shadowRegs[i],
          shadowRegs[i] < activeRegs[i],
        ], orElse: [
          shadowRegs[i] < shadowRegs[i],
          If(wEn2 & wAddr2.eq(i), then: [
            activeRegs[i] < wData2,
          ], orElse: [
            If(wEn & wAddr.eq(i), then: [
              activeRegs[i] < wData,
            ], orElse: [
              activeRegs[i] < activeRegs[i],
            ]),
          ]),
        ]),
      );
    }

    Sequential(clk, reset: reset, resetValues: {
      for (int i = 1; i < numRegs; i++)
        activeRegs[i]: Const(0, width: ParticleWidths.word),
      for (int i = 1; i < numRegs; i++)
        shadowRegs[i]: Const(0, width: ParticleWidths.word),
    }, seqStatements);

    // Asynchronous read multiplexing
    final caseItemsA = <CaseItem>[];
    final caseItemsB = <CaseItem>[];
    for (int i = 0; i < numRegs; i++) {
      caseItemsA.add(CaseItem(Const(i, width: ParticleWidths.regAddr),
          [rDataA < activeRegs[i]]));
      caseItemsB.add(CaseItem(Const(i, width: ParticleWidths.regAddr),
          [rDataB < activeRegs[i]]));
    }

    Combinational([
      Case(rAddrA, caseItemsA, defaultItem: [
        rDataA < Const(0, width: ParticleWidths.word),
      ]),
      Case(rAddrB, caseItemsB, defaultItem: [
        rDataB < Const(0, width: ParticleWidths.word),
      ]),
    ]);
  }
}
