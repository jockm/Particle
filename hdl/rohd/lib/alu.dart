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
    final res = Logic(name: 'res_internal', width: ParticleWidths.word);

    // Subtraction and comparison
    final subVal = operandA - operandB;
    final sltVal = mux(
      operandA.lt(operandB),
      Const(1, width: ParticleWidths.word),
      Const(0, width: ParticleWidths.word),
    );

    // Signed comparison (SSLT):
    // If sign bits differ, operand with sign bit 1 (negative) is smaller.
    // If sign bits match, unsigned comparison holds.
    final signA = operandA.slice(31, 31);
    final signB = operandB.slice(31, 31);
    final ssltVal = mux(
      signA ^ signB,
      mux(signA, Const(1, width: ParticleWidths.word),
          Const(0, width: ParticleWidths.word)),
      sltVal,
    );

    // Bit manipulation helpers
    final bitIdx = operandB.slice(4, 0);
    final bitMask = Const(1, width: ParticleWidths.word) << bitIdx;

    // Shift & Rotate amounts (both sides must match 6 bits for width-checked subtraction)
    final shiftAmt5 = operandB.slice(4, 0);
    final shiftAmt6 = shiftAmt5.zeroExtend(6);
    final rotComplement = (Const(32, width: 6) - shiftAmt6).slice(4, 0);

    // Count Leading Zeros priority tree
    final clzVal = Logic(name: 'clz_val', width: ParticleWidths.word);
    final clzList = <Conditional>[];
    for (int i = 31; i >= 0; i--) {
      clzList.add(
        If(operandA.slice(i, i).eq(Const(1)), then: [
          clzVal < Const(31 - i, width: ParticleWidths.word),
        ]),
      );
    }

    Combinational([
      clzVal < Const(32, width: ParticleWidths.word),
      ...clzList.reversed,
      Case(aluOp, [
        CaseItem(Const(AluOps.add, width: 5), [res < operandA + operandB]),
        CaseItem(Const(AluOps.sub, width: 5), [res < subVal]),
        CaseItem(Const(AluOps.and, width: 5), [res < (operandA & operandB)]),
        CaseItem(Const(AluOps.or, width: 5), [res < (operandA | operandB)]),
        CaseItem(Const(AluOps.xor, width: 5), [res < (operandA ^ operandB)]),
        CaseItem(
            Const(AluOps.shiftl, width: 5), [res < (operandA << shiftAmt5)]),
        CaseItem(
            Const(AluOps.shiftr, width: 5), [res < (operandA >>> shiftAmt5)]),
        CaseItem(Const(AluOps.ashiftr, width: 5), [
          res <
              (operandA >>> shiftAmt5) |
                  mux(
                    signA,
                    ~(Const(0xFFFFFFFF, width: ParticleWidths.word) >>>
                        shiftAmt5),
                    Const(0, width: ParticleWidths.word),
                  ),
        ]),
        CaseItem(Const(AluOps.rotl, width: 5), [
          res < ((operandA << shiftAmt5) | (operandA >>> rotComplement)),
        ]),
        CaseItem(Const(AluOps.rotr, width: 5), [
          res < ((operandA >>> shiftAmt5) | (operandA << rotComplement)),
        ]),
        CaseItem(Const(AluOps.clz, width: 5), [res < clzVal]),
        CaseItem(Const(AluOps.bset, width: 5), [res < (operandA | bitMask)]),
        CaseItem(Const(AluOps.bclr, width: 5), [res < (operandA & ~bitMask)]),
        CaseItem(Const(AluOps.binv, width: 5), [res < (operandA ^ bitMask)]),
        CaseItem(Const(AluOps.bget, width: 5), [
          res < ((operandA >>> bitIdx) & Const(1, width: ParticleWidths.word))
        ]),
        CaseItem(Const(AluOps.slt, width: 5), [res < sltVal]),
        CaseItem(Const(AluOps.sslt, width: 5), [res < ssltVal]),
        // NOT Rr (0x72): Bitwise inversion
        CaseItem(Const(AluOps.not, width: 5), [res < ~operandA]),
        // NEZ Rr (0x73): Set on Not Equal Zero
        CaseItem(Const(AluOps.nez, width: 5), [
          res <
              mux(
                operandA.neq(Const(0, width: ParticleWidths.word)),
                Const(1, width: ParticleWidths.word),
                Const(0, width: ParticleWidths.word),
              ),
        ]),
      ], defaultItem: [
        res < Const(0, width: ParticleWidths.word),
      ]),
      result < res,
      isZero < res.eq(Const(0, width: ParticleWidths.word)),
      isNegative < res.slice(31, 31),
    ]);
  }
}
