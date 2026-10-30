// =============================================================================
// File: hdl/rohd/lib/fifo_subsystem.dart
// Architecture: Particle 32-bit RISC
// Description: Multi-channel point-to-point streaming FIFO fabric and MBOX
//              cross-core strobe signaling.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleFifoSubsystem extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  Logic get chanSelect => input('chanSelect');
  Logic get pushData => input('pushData');
  Logic get pushEn => input('pushEn');
  Logic get popEn => input('popEn');

  Logic get popData => output('popData');
  Logic get empty => output('empty');
  Logic get full => output('full');
  Logic get statusWord => output('statusWord');

  ParticleFifoSubsystem({
    required Logic clk,
    required Logic reset,
    required Logic chanSelect,
    required Logic pushData,
    required Logic pushEn,
    required Logic popEn,
    int channels = 4,
    super.name = 'fifo_subsystem',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('chanSelect', chanSelect, width: 2);
    addInput('pushData', pushData, width: ParticleWidths.word);
    addInput('pushEn', pushEn);
    addInput('popEn', popEn);

    addOutput('popData', width: ParticleWidths.word);
    addOutput('empty');
    addOutput('full');
    addOutput('statusWord', width: ParticleWidths.word);

    _build(channels);
  }

  void _build(int channels) {
    final fifoEmpty = List.generate(channels, (i) => Logic(name: 'empty_$i'));
    final fifoFull = List.generate(channels, (i) => Logic(name: 'full_$i'));
    final fifoDepth =
        List.generate(channels, (i) => Logic(name: 'depth_$i', width: 9));
    final fifoHead = List.generate(
        channels, (i) => Logic(name: 'head_$i', width: ParticleWidths.word));

    for (int c = 0; c < channels; c++) {
      final wrPtr = Logic(name: 'wrPtr_$c', width: 8);
      final rdPtr = Logic(name: 'rdPtr_$c', width: 8);
      final count = Logic(name: 'count_$c', width: 9);

      final isCur = chanSelect.eq(c);
      final doPush = pushEn & isCur & ~fifoFull[c];
      final doPop = popEn & isCur & ~fifoEmpty[c];

      // 256-word FIFO storage per channel
      final mem = List.generate(
        256,
        (i) => Logic(name: 'fifo_${c}_ram_$i', width: ParticleWidths.word),
      );

      final memWriteStatements = <Conditional>[];
      for (int m = 0; m < 256; m++) {
        memWriteStatements.add(
          If(wrPtr.eq(m), then: [
            mem[m] < pushData,
          ]),
        );
      }

      Sequential(clk, reset: reset, resetValues: {
        wrPtr: Const(0, width: 8),
        rdPtr: Const(0, width: 8),
        count: Const(0, width: 9),
        for (int m = 0; m < 256; m++)
          mem[m]: Const(0, width: ParticleWidths.word),
      }, [
        If(doPush & ~doPop, then: [
          count < count + Const(1, width: 9),
          wrPtr < wrPtr + Const(1, width: 8),
        ], orElse: [
          If(doPop & ~doPush, then: [
            count < count - Const(1, width: 9),
            rdPtr < rdPtr + Const(1, width: 8),
          ], orElse: [
            If(doPush & doPop, then: [
              wrPtr < wrPtr + Const(1, width: 8),
              rdPtr < rdPtr + Const(1, width: 8),
            ]),
          ]),
        ]),
        If(doPush, then: memWriteStatements),
      ]);

      fifoEmpty[c] <= count.eq(0);
      fifoFull[c] <= count.eq(256);
      fifoDepth[c] <= count;

      // Combinational multiplexer for FIFO head based on rdPtr
      Combinational([
        Case(rdPtr, [
          for (int m = 0; m < 256; m++)
            CaseItem(Const(m, width: 8), [fifoHead[c] < mem[m]]),
        ], defaultItem: [
          fifoHead[c] < Const(0, width: ParticleWidths.word),
        ]),
      ]);
    }

    final curPopData = Logic(name: 'curPopData', width: ParticleWidths.word);
    final curEmpty = Logic(name: 'curEmpty');
    final curFull = Logic(name: 'curFull');
    final curDepth = Logic(name: 'curDepth', width: 9);

    // Channel selection multiplexers
    Combinational([
      Case(chanSelect, [
        for (int c = 0; c < channels; c++)
          CaseItem(Const(c, width: 2), [
            curPopData < fifoHead[c],
            curEmpty < fifoEmpty[c],
            curFull < fifoFull[c],
            curDepth < fifoDepth[c],
          ]),
      ], defaultItem: [
        curPopData < Const(0, width: ParticleWidths.word),
        curEmpty < Const(1),
        curFull < Const(0),
        curDepth < Const(0, width: 9),
      ]),
    ]);

    popData <= curPopData;
    empty <= curEmpty;
    full <= curFull;

    statusWord <=
        [
          Const(0, width: 16),
          curDepth.slice(7, 0),
          Const(0, width: 6),
          full,
          empty,
        ].swizzle();
  }
}
