// =============================================================================
// File: hdl/rohd/lib/alu.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleAlu extends Module {
  Logic get aluOp => input('aluOp');
  Logic get operandA => input('operandA');
  Logic get operandB => input('operandB');

  Logic get result => output('result');
  Logic get isZero => output('isZero');
  Logic get isNegative => output('isNegative');

  ParticleAlu({
    required Logic aluOp,
    required Logic operandA,
    required Logic operandB,
    super.name = 'particle_alu',
  }) {
    addInput('aluOp', aluOp, width: 5);
    addInput('operandA', operandA, width: ParticleWidths.word);
    addInput('operandB', operandB, width: ParticleWidths.word);

    addOutput('result', width: ParticleWidths.word);
    addOutput('isZero');
    addOutput('isNegative');

    _build();
  }

  void _build() {
    final shiftAmt = operandB.slice(4, 0);

    // Count Leading Zeros (CLZ) Priority Tree
    final clzVal = Logic(name: 'clzVal', width: ParticleWidths.word);
    final clzCases = <Conditional>[];
    for (int i = 31; i >= 0; i--) {
      clzCases.add(
        If(operandA.slice(i, i).eq(1), then: [
          clzVal < Const(31 - i, width: ParticleWidths.word),
        ]),
      );
    }

    // Bitfield Extract (BEXTR)
    final bextrPos = operandB.slice(4, 0);
    final bextrLen = operandB.slice(9, 5);
    final bextrShifted = operandA >>> bextrPos;
    final bextrMask = (Const(1, width: 33) << bextrLen).slice(31, 0) -
        Const(1, width: ParticleWidths.word);
    final bextrResult = bextrShifted & bextrMask;

    // Barrel Rotators
    final rotL = (operandA << shiftAmt) |
        (operandA >>> (Const(32, width: 5) - shiftAmt));
    final rotR = (operandA >>> shiftAmt) |
        (operandA << (Const(32, width: 5) - shiftAmt));

    // Bitwise Set, Clear, Invert, Get
    final bitMask = Const(1, width: ParticleWidths.word) << shiftAmt;
    final bset = operandA | bitMask;
    final bclr = operandA & ~bitMask;
    final binv = operandA ^ bitMask;
    final bget =
        (operandA >>> shiftAmt).slice(0, 0).zeroExtend(ParticleWidths.word);

    // Relational Comparisons: SLT (unsigned) and SSLT (signed)
    final sltResult = operandA.lt(operandB).zeroExtend(ParticleWidths.word);

    // Signed comparison: if signs differ, negative operand is smaller; if signs same, unsigned lt holds
    final signA = operandA.slice(31, 31);
    final signB = operandB.slice(31, 31);
    final ssltResult = mux(
      signA ^ signB,
      signA.zeroExtend(ParticleWidths.word),
      sltResult,
    );

    // Arithmetic Shift Right (ASR): sign-extend then shift
    final asrResult = (operandA.signExtend(64) >>> shiftAmt).slice(31, 0);

    Combinational([
      clzVal < Const(32, width: ParticleWidths.word),
      ...clzCases.reversed,
      Case(aluOp, [
        CaseItem(Const(0, width: 5), [result < operandA + operandB]),
        CaseItem(Const(1, width: 5), [result < operandA - operandB]),
        CaseItem(Const(2, width: 5), [result < operandA & operandB]),
        CaseItem(Const(3, width: 5), [result < operandA | operandB]),
        CaseItem(Const(4, width: 5), [result < operandA ^ operandB]),
        CaseItem(Const(5, width: 5), [result < operandA << shiftAmt]),
        CaseItem(Const(6, width: 5), [result < operandA >>> shiftAmt]),
        CaseItem(Const(7, width: 5), [result < asrResult]),
        CaseItem(Const(8, width: 5), [result < rotL]),
        CaseItem(Const(9, width: 5), [result < rotR]),
        CaseItem(Const(10, width: 5), [result < clzVal]),
        CaseItem(Const(11, width: 5), [result < bextrResult]),
        CaseItem(Const(12, width: 5), [result < bset]),
        CaseItem(Const(13, width: 5), [result < bclr]),
        CaseItem(Const(14, width: 5), [result < binv]),
        CaseItem(Const(15, width: 5), [result < bget]),
        CaseItem(Const(16, width: 5), [result < sltResult]),
        CaseItem(Const(17, width: 5), [result < ssltResult]),
      ], defaultItem: [
        result < Const(0, width: ParticleWidths.word),
      ]),
      isZero < result.eq(0),
      isNegative < result.slice(31, 31),
    ]);
  }
}
