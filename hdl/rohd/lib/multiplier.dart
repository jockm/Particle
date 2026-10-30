// =============================================================================
// File: hdl/rohd/lib/multiplier.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleMultiplier extends Module {
  Logic get operandA => input('operandA');
  Logic get operandB => input('operandB');
  Logic get mulMode =>
      input('mulMode'); // 0: MULL, 1: MULH, 2: SMULH, 3: MULHSU

  Logic get result => output('result');

  ParticleMultiplier({
    required Logic operandA,
    required Logic operandB,
    required Logic mulMode,
    super.name = 'particle_multiplier',
  }) {
    addInput('operandA', operandA, width: ParticleWidths.word);
    addInput('operandB', operandB, width: ParticleWidths.word);
    addInput('mulMode', mulMode, width: 2);

    addOutput('result', width: ParticleWidths.word);

    _build();
  }

  void _build() {
    final prodUU = operandA.zeroExtend(64) * operandB.zeroExtend(64);
    final extA = operandA.signExtend(64);
    final extB = operandB.signExtend(64);
    final prodSS = extA * extB;
    final prodSU = extA * operandB.zeroExtend(64);

    Combinational([
      Case(mulMode, [
        CaseItem(Const(0, width: 2), [result < prodUU.slice(31, 0)]), // MULL
        CaseItem(Const(1, width: 2), [result < prodUU.slice(63, 32)]), // MULH
        CaseItem(Const(2, width: 2), [result < prodSS.slice(63, 32)]), // SMULH
        CaseItem(Const(3, width: 2), [result < prodSU.slice(63, 32)]), // MULHSU
      ], defaultItem: [
        result < Const(0, width: ParticleWidths.word),
      ]),
    ]);
  }
}
