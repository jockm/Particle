// =============================================================================
// File: hdl/rohd/lib/register_file.dart
// Architecture: Particle 32-bit RISC Core
// Description: 32x32 Register File with Option-2 RBASE windowing, hardwired R0,
//              dual read ports, write port, and single-cycle shadow banks.
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

  // RBASE Windowing Control
  Logic get rbaseEn => input('rbaseEn');
  Logic get rbaseIn => input('rbaseIn');
  Logic get rbaseOut => output('rbaseOut');

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
    Logic? rbaseEn,
    Logic? rbaseIn,
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

    addInput('rbaseEn', rbaseEn ?? Const(0));
    addInput('rbaseIn', rbaseIn ?? Const(0, width: 5), width: 5);
    addOutput('rbaseOut', width: 5);

    addOutput('rDataA', width: ParticleWidths.word);
    addOutput('rDataB', width: ParticleWidths.word);

    _build();
  }

  void _build() {
    const numPhysicalRegs = 32;

    final activeRegs = List.generate(
      numPhysicalRegs,
      (i) => Logic(name: 'r$i', width: ParticleWidths.word),
    );
    final shadowRegs = List.generate(
      numPhysicalRegs,
      (i) => Logic(name: 'shadow_r$i', width: ParticleWidths.word),
    );

    final rbase = Logic(name: 'rbase_reg', width: 5);
    output('rbaseOut') <= rbase;

    // Hardwired zero for physical R0
    activeRegs[0] <= Const(0, width: ParticleWidths.word);
    shadowRegs[0] <= Const(0, width: ParticleWidths.word);

    // Option 2 Effective Physical Address Translation:
    // If incoming 4-bit register index == 0, address is strictly physical 0.
    // If index != 0, address is index + rbase (modulo 32).
    Logic translate(Logic virtIdx) => mux(
          virtIdx.eq(0),
          Const(0, width: 5),
          (virtIdx.zeroExtend(5) + rbase).slice(4, 0),
        );

    final effRAddrA = Logic(name: 'effRAddrA', width: 5);
    final effRAddrB = Logic(name: 'effRAddrB', width: 5);
    final effWAddr = Logic(name: 'effWAddr', width: 5);
    final effXchgIdx = Logic(name: 'effXchgIdx', width: 5);

    Combinational([
      effRAddrA < translate(rAddrA),
      effRAddrB < translate(rAddrB),
      effWAddr < translate(wAddr),
      effXchgIdx < translate(xchgRegIdx),
    ]);

    // Sequential updates with explicit state retention
    final seqStatements = <Conditional>[
      If(rbaseEn, then: [
        rbase < rbaseIn,
      ], orElse: [
        rbase < rbase,
      ]),
    ];

    for (int i = 1; i < numPhysicalRegs; i++) {
      final isR15 = (i == 15);
      final doXchgSingle = xchgEn & effXchgIdx.eq(i);
      final doXchgAll = xchgAllEn;
      final doXchgMost = xchgMostEn & (isR15 ? Const(0) : Const(1));
      final swapCondition = doXchgSingle | doXchgAll | doXchgMost;

      seqStatements.add(
        If(swapCondition, then: [
          activeRegs[i] < shadowRegs[i],
          shadowRegs[i] < activeRegs[i],
        ], orElse: [
          shadowRegs[i] < shadowRegs[i],
          If(wEn & effWAddr.eq(i), then: [
            activeRegs[i] < wData,
          ], orElse: [
            activeRegs[i] < activeRegs[i],
          ]),
        ]),
      );
    }

    Sequential(clk, reset: reset, resetValues: {
      rbase: Const(0, width: 5),
      for (int i = 1; i < numPhysicalRegs; i++) activeRegs[i]: Const(0, width: ParticleWidths.word),
      for (int i = 1; i < numPhysicalRegs; i++) shadowRegs[i]: Const(0, width: ParticleWidths.word),
    }, seqStatements);

    // Asynchronous Read Multiplexing based on translated physical addresses
    final caseItemsA = <CaseItem>[];
    final caseItemsB = <CaseItem>[];
    for (int i = 0; i < numPhysicalRegs; i++) {
      caseItemsA.add(CaseItem(Const(i, width: 5), [rDataA < activeRegs[i]]));
      caseItemsB.add(CaseItem(Const(i, width: 5), [rDataB < activeRegs[i]]));
    }

    Combinational([
      Case(effRAddrA, caseItemsA, defaultItem: [
        rDataA < Const(0, width: ParticleWidths.word),
      ]),
      Case(effRAddrB, caseItemsB, defaultItem: [
        rDataB < Const(0, width: ParticleWidths.word),
      ]),
    ]);
  }
}
