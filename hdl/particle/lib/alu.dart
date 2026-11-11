// =============================================================================
// File: hdl/particle/lib/alu.dart
// Architecture: Particle 32-bit RISC Core
// Description: Combinational ALU with 32-bit logic, shifts, math, comparisons,
//              and extended native instructions (NEG, REV32, SEQ, SNE, SLE, SSLE).
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleAlu extends Module {
  Logic get result => output('result');
  Logic get isZero => output('isZero');
  Logic get isNegative => output('isNegative');

  ParticleAlu({
    required Logic operandA,
    required Logic operandB,
    required Logic aluOp,
    super.name = 'particle_alu',
  }) {
    operandA = addInput('operandA', operandA, width: ParticleWidths.word);
    operandB = addInput('operandB', operandB, width: ParticleWidths.word);
    aluOp = addInput('aluOp', aluOp, width: 5);

    addOutput('result', width: ParticleWidths.word);
    addOutput('isZero');
    addOutput('isNegative');

    _build();
  }

  void _build() {
    final operandA = input('operandA');
    final operandB = input('operandB');
    final aluOp = input('aluOp');
    final aluRes = Logic(name: 'alu_res', width: ParticleWidths.word);

    final shiftAmt5 = operandB.slice(4, 0);

    // Unsigned and Signed Less-Than Primitives
    final sltVal = mux(
      operandA.lt(operandB),
      Const(1, width: ParticleWidths.word),
      Const(0, width: ParticleWidths.word),
    );

    final signA = operandA.slice(31, 31);
    final signB = operandB.slice(31, 31);
    final ssltVal = mux(
      signA ^ signB,
      mux(signA, Const(1, width: ParticleWidths.word), Const(0, width: ParticleWidths.word)),
      sltVal,
    );

    // Unsigned and Signed Less-Than-or-Equal Primitives
    final sleVal = mux(
      operandA.lte(operandB),
      Const(1, width: ParticleWidths.word),
      Const(0, width: ParticleWidths.word),
    );

    final ssleVal = mux(
      signA ^ signB,
      mux(signA, Const(1, width: ParticleWidths.word), Const(0, width: ParticleWidths.word)),
      sleVal,
    );

    // Equality Primitives
    final eqVal = mux(
      operandA.eq(operandB),
      Const(1, width: ParticleWidths.word),
      Const(0, width: ParticleWidths.word),
    );

    final neVal = mux(
      operandA.neq(operandB),
      Const(1, width: ParticleWidths.word),
      Const(0, width: ParticleWidths.word),
    );

    // Arithmetic Negate and 32-bit Byte Swap
    final negVal = Const(0, width: ParticleWidths.word) - operandA;
    final rev32Val = [
      operandA.slice(7, 0),
      operandA.slice(15, 8),
      operandA.slice(23, 16),
      operandA.slice(31, 24),
    ].swizzle();

    // Leading Zero Count
    final clzList = <Logic>[];
    for (var i = 0; i < 32; i++) {
      clzList.add(operandA.slice(31 - i, 31 - i));
    }
    final clzVal = Logic(name: 'clz_val', width: ParticleWidths.word);
    final clzCases = <CaseItem>[];
    for (var i = 0; i < 32; i++) {
      clzCases.add(CaseItem(clzList[i], [clzVal < Const(i, width: ParticleWidths.word)]));
    }

    Combinational([
      clzVal < Const(32, width: ParticleWidths.word),
      Case(Const(1), clzCases, defaultItem: [
        clzVal < Const(32, width: ParticleWidths.word),
      ]),
    ]);

    Combinational([
      Case(aluOp, [
        // 0: ADD
        CaseItem(Const(0, width: 5), [aluRes < (operandA + operandB)]),
        // 1: SUB
        CaseItem(Const(1, width: 5), [aluRes < (operandA - operandB)]),
        // 2: AND
        CaseItem(Const(2, width: 5), [aluRes < (operandA & operandB)]),
        // 3: OR
        CaseItem(Const(3, width: 5), [aluRes < (operandA | operandB)]),
        // 4: XOR
        CaseItem(Const(4, width: 5), [aluRes < (operandA ^ operandB)]),
        // 5: SHIFTL
        CaseItem(Const(5, width: 5), [aluRes < (operandA << shiftAmt5)]),
        // 6: SHIFTR
        CaseItem(Const(6, width: 5), [aluRes < (operandA >>> shiftAmt5)]),
        // 7: ASHIFTR
        CaseItem(Const(7, width: 5), [aluRes < (operandA >> shiftAmt5)]),
        // 8: ROTL
        CaseItem(Const(8, width: 5), [
          aluRes < ((operandA << shiftAmt5) | (operandA >>> (Const(32, width: 6) - shiftAmt5.zeroExtend(6)).slice(4, 0))),
        ]),
        // 9: ROTR
        CaseItem(Const(9, width: 5), [
          aluRes < ((operandA >>> shiftAmt5) | (operandA << (Const(32, width: 6) - shiftAmt5.zeroExtend(6)).slice(4, 0))),
        ]),
        // 10: CLZ
        CaseItem(Const(10, width: 5), [aluRes < clzVal]),
        // 11: BEXTR
        CaseItem(Const(11, width: 5), [aluRes < ((operandA >>> shiftAmt5) & Const(1, width: ParticleWidths.word))]),
        // 12: BSET
        CaseItem(Const(12, width: 5), [aluRes < (operandA | (Const(1, width: ParticleWidths.word) << shiftAmt5))]),
        // 13: BCLR
        CaseItem(Const(13, width: 5), [aluRes < (operandA & ~(Const(1, width: ParticleWidths.word) << shiftAmt5))]),
        // 14: BINV
        CaseItem(Const(14, width: 5), [aluRes < (operandA ^ (Const(1, width: ParticleWidths.word) << shiftAmt5))]),
        // 15: BGET
        CaseItem(Const(15, width: 5), [aluRes < ((operandA >>> shiftAmt5) & Const(1, width: ParticleWidths.word))]),
        // 16: SLT
        CaseItem(Const(16, width: 5), [aluRes < sltVal]),
        // 17: SSLT
        CaseItem(Const(17, width: 5), [aluRes < ssltVal]),
        // 18: NOT
        CaseItem(Const(18, width: 5), [aluRes < ~operandA]),
        // 19: NEZ
        CaseItem(Const(19, width: 5), [
          aluRes < mux(operandA.neq(0), Const(1, width: ParticleWidths.word), Const(0, width: ParticleWidths.word)),
        ]),
        // 20: NEG
        CaseItem(Const(20, width: 5), [aluRes < negVal]),
        // 21: REV32
        CaseItem(Const(21, width: 5), [aluRes < rev32Val]),
        // 22: SEQ
        CaseItem(Const(22, width: 5), [aluRes < eqVal]),
        // 23: SNE
        CaseItem(Const(23, width: 5), [aluRes < neVal]),
        // 24: SLE
        CaseItem(Const(24, width: 5), [aluRes < sleVal]),
        // 25: SSLE
        CaseItem(Const(25, width: 5), [aluRes < ssleVal]),
      ], defaultItem: [
        aluRes < Const(0, width: ParticleWidths.word),
      ]),
    ]);

    output('result') <= aluRes;
    output('isZero') <= aluRes.eq(0);
    output('isNegative') <= aluRes.slice(31, 31);
  }
}
