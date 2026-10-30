// =============================================================================
// File: hdl/rohd/lib/memory_bus.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleMemoryBus extends Module {
  Logic get addr => input('addr');
  Logic get wData => input('wData');
  Logic get size =>
      input('size'); // 0: Byte (8), 1: Halfword (16), 2: Word (32)
  Logic get wEn => input('wEn');
  Logic get rEn => input('rEn');
  Logic get rDataRaw => input('rDataRaw');

  Logic get bEn => output('bEn');
  Logic get wDataAligned => output('wDataAligned');
  Logic get rDataFormatted => output('rDataFormatted');
  Logic get alignFault => output('alignFault');

  ParticleMemoryBus({
    required Logic addr,
    required Logic wData,
    required Logic size,
    required Logic wEn,
    required Logic rEn,
    required Logic rDataRaw,
    super.name = 'memory_bus',
  }) {
    addInput('addr', addr, width: ParticleWidths.word);
    addInput('wData', wData, width: ParticleWidths.word);
    addInput('size', size, width: 2);
    addInput('wEn', wEn);
    addInput('rEn', rEn);
    addInput('rDataRaw', rDataRaw, width: ParticleWidths.word);

    addOutput('bEn', width: 4);
    addOutput('wDataAligned', width: ParticleWidths.word);
    addOutput('rDataFormatted', width: ParticleWidths.word);
    addOutput('alignFault');

    _build();
  }

  void _build() {
    final byteOffset = addr.slice(1, 0);

    // Alignment Fault Detection (Trap 14)
    final misaligned16 = size.eq(1) & byteOffset.slice(0, 0);
    final misaligned32 = size.eq(2) & byteOffset.neq(0);
    final isFault = (rEn | wEn) & (misaligned16 | misaligned32);

    // Byte-Enable Calculation
    final bEnCalc = Logic(name: 'bEnCalc', width: 4);

    // Sub-word read slices
    final byte0 = rDataRaw.slice(7, 0).zeroExtend(ParticleWidths.word);
    final byte1 = rDataRaw.slice(15, 8).zeroExtend(ParticleWidths.word);
    final byte2 = rDataRaw.slice(23, 16).zeroExtend(ParticleWidths.word);
    final byte3 = rDataRaw.slice(31, 24).zeroExtend(ParticleWidths.word);

    final half0 = rDataRaw.slice(15, 0).zeroExtend(ParticleWidths.word);
    final half1 = rDataRaw.slice(31, 16).zeroExtend(ParticleWidths.word);

    Combinational([
      alignFault < isFault,

      // Byte Enable Generation
      Case(size, [
        CaseItem(Const(0, width: 2), [
          Case(byteOffset, [
            CaseItem(Const(0, width: 2), [bEnCalc < Const(0x1, width: 4)]),
            CaseItem(Const(1, width: 2), [bEnCalc < Const(0x2, width: 4)]),
            CaseItem(Const(2, width: 2), [bEnCalc < Const(0x4, width: 4)]),
            CaseItem(Const(3, width: 2), [bEnCalc < Const(0x8, width: 4)]),
          ]),
        ]),
        CaseItem(Const(1, width: 2), [
          bEnCalc <
              mux(byteOffset.slice(1, 1).eq(1), Const(0xC, width: 4),
                  Const(0x3, width: 4)),
        ]),
        CaseItem(Const(2, width: 2), [
          bEnCalc < Const(0xF, width: 4),
        ]),
      ], defaultItem: [
        bEnCalc < Const(0, width: 4),
      ]),

      bEn < mux(wEn & ~isFault, bEnCalc, Const(0, width: 4)),

      // Write Data Steering
      Case(size, [
        CaseItem(Const(0, width: 2), [
          wDataAligned <
              [
                wData.slice(7, 0),
                wData.slice(7, 0),
                wData.slice(7, 0),
                wData.slice(7, 0)
              ].swizzle(),
        ]),
        CaseItem(Const(1, width: 2), [
          wDataAligned < [wData.slice(15, 0), wData.slice(15, 0)].swizzle(),
        ]),
        CaseItem(Const(2, width: 2), [
          wDataAligned < wData,
        ]),
      ], defaultItem: [
        wDataAligned < wData,
      ]),

      // Read Data Steering & Zero-Extension
      Case(size, [
        CaseItem(Const(0, width: 2), [
          Case(byteOffset, [
            CaseItem(Const(0, width: 2), [rDataFormatted < byte0]),
            CaseItem(Const(1, width: 2), [rDataFormatted < byte1]),
            CaseItem(Const(2, width: 2), [rDataFormatted < byte2]),
            CaseItem(Const(3, width: 2), [rDataFormatted < byte3]),
          ]),
        ]),
        CaseItem(Const(1, width: 2), [
          rDataFormatted < mux(byteOffset.slice(1, 1).eq(1), half1, half0),
        ]),
        CaseItem(Const(2, width: 2), [
          rDataFormatted < rDataRaw,
        ]),
      ], defaultItem: [
        rDataFormatted < rDataRaw,
      ]),
    ]);
  }
}
