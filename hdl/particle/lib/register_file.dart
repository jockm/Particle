// =============================================================================
// File: hdl/particle/lib/register_file.dart
// Architecture: Particle 32-bit RISC Core
// Description: 32x32 Register File with Option-2 RBASE windowing, hardwired R0,
//              dual read ports, two write ports, and single-cycle shadow banks.
// =============================================================================
//
// Registers are addressed by their 4-bit virtual index (R0..R15). A non-zero
// index maps to physical register (index + RBASE) mod 32; index 0 is always
// physical register 0, which reads as zero and can't be written.
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

  /// The 32 physical registers and their shadows, for tests and debugging.
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
    addInput('wAddr2', wAddr2 ?? Const(0, width: ParticleWidths.regAddr),
        width: ParticleWidths.regAddr);
    addInput('wData2', wData2 ?? Const(0, width: ParticleWidths.word),
        width: ParticleWidths.word);
    addInput('wEn2', wEn2 ?? Const(0));
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
    physical = activeRegs;
    shadow = shadowRegs;
    final rbase = Logic(name: 'rbase_reg', width: 5);
    output('rbaseOut') <= rbase;

    // Hardwired zero for physical R0
    activeRegs[0] <= Const(0, width: ParticleWidths.word);
    shadowRegs[0] <= Const(0, width: ParticleWidths.word);

    // Virtual to physical: index 0 is physical 0; any other index is
    // (index + rbase) mod 32.
    Logic translate(Logic virtIdx) => mux(
          virtIdx.eq(0),
          Const(0, width: 5),
          (virtIdx.zeroExtend(5) + rbase).slice(4, 0),
        );

    final effRAddrA = Logic(name: 'effRAddrA', width: 5);
    final effRAddrB = Logic(name: 'effRAddrB', width: 5);
    final effWAddr = Logic(name: 'effWAddr', width: 5);
    final effWAddr2 = Logic(name: 'effWAddr2', width: 5);
    final effXchgIdx = Logic(name: 'effXchgIdx', width: 5);
    Combinational([
      effRAddrA < translate(rAddrA),
      effRAddrB < translate(rAddrB),
      effWAddr < translate(wAddr),
      effWAddr2 < translate(wAddr2),
      effXchgIdx < translate(xchgRegIdx),
    ]);

    final seqStatements = <Conditional>[
      If(rbaseEn, then: [
        rbase < rbaseIn,
      ], orElse: [
        rbase < rbase,
      ]),
    ];

    for (int i = 1; i < numPhysicalRegs; i++) {
      final doXchgSingle = xchgEn & effXchgIdx.eq(i);
      final doXchgAll = xchgAllEn;
      // XCHGMOST swaps virtual R1..R14 (not R15, the stack pointer): the
      // physical registers whose virtual index (i - rbase) mod 32 is 1..14
      final virtIdx = (Const(i, width: 5) - rbase).slice(4, 0);
      final doXchgMost = xchgMostEn &
          virtIdx.gte(Const(1, width: 5)) &
          virtIdx.lte(Const(14, width: 5));
      final swapCondition = doXchgSingle | doXchgAll | doXchgMost;

      seqStatements.add(
        If(swapCondition, then: [
          activeRegs[i] < shadowRegs[i],
          shadowRegs[i] < activeRegs[i],
        ], orElse: [
          shadowRegs[i] < shadowRegs[i],
          If(wEn2 & effWAddr2.eq(i), then: [
            activeRegs[i] < wData2,
          ], orElse: [
            If(wEn & effWAddr.eq(i), then: [
              activeRegs[i] < wData,
            ], orElse: [
              activeRegs[i] < activeRegs[i],
            ]),
          ]),
        ]),
      );
    }

    Sequential(clk, reset: reset, resetValues: {
      rbase: Const(0, width: 5),
      for (int i = 1; i < numPhysicalRegs; i++)
        activeRegs[i]: Const(0, width: ParticleWidths.word),
      for (int i = 1; i < numPhysicalRegs; i++)
        shadowRegs[i]: Const(0, width: ParticleWidths.word),
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
