// =============================================================================
// File: hdl/particle/lib/multiplier.dart
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
    // One 32 x 32 unsigned product. The signed high words follow from it:
    // as a signed number, an operand with its top bit set is worth 2^32 less
    // than as an unsigned one, so its partner is taken off the high word.
    //   SMULH:  hi(a * b) - (a < 0 ? b : 0) - (b < 0 ? a : 0)
    //   MULHSU: hi(a * b) - (a < 0 ? b : 0)           (b unsigned)
    // The low word is the same in every mode.
    final product = operandA.zeroExtend(64) * operandB.zeroExtend(64);
    final low = product.slice(31, 0);
    final high = product.slice(63, 32);
    final aNeg = operandA.slice(31, 31);
    final bNeg = operandB.slice(31, 31);
    final zero = Const(0, width: ParticleWidths.word);
    final corrA = mux(aNeg, operandB, zero); // for SMULH and MULHSU
    final corrB = mux(bNeg, operandA, zero); // for SMULH only
    final signedCorr = mux(mulMode.eq(Const(2, width: 2)), corrA + corrB, corrA);

    Combinational([
      Case(mulMode, [
        CaseItem(Const(0, width: 2), [result < low]), // MULL
        CaseItem(Const(1, width: 2), [result < high]), // MULH
        CaseItem(Const(2, width: 2), [result < high - signedCorr]), // SMULH
        CaseItem(Const(3, width: 2), [result < high - signedCorr]), // MULHSU
      ], defaultItem: [
        result < zero,
      ]),
    ]);
  }
}
