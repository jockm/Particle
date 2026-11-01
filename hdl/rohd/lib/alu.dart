// =============================================================================
// File: hdl/rohd/lib/alu.dart
// Architecture: Particle 32-bit RISC Core
// Description: Purely combinational 32-bit ALU with arithmetic, logic, shift,
//              CLZ, BEXTR, bit manipulation, and relational comparison support.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleAlu extends Module {
  Logic get operandA => input('operandA');
  Logic get operandB => input('operandB');
  Logic get aluOp => input('aluOp');

  Logic get result => output('result');
  Logic get zero => output('zero');
  Logic get negative => output('negative');

  // Testbench aliases
  Logic get isZero => output('zero');
  Logic get isNegative => output('negative');

  ParticleAlu({
    required Logic operandA,
    required Logic operandB,
    required Logic aluOp,
    super.name = 'particle_alu',
  }) {
    addInput('operandA', operandA, width: ParticleWidths.word);
    addInput('operandB', operandB, width: ParticleWidths.word);
    addInput('aluOp', aluOp, width: 5);

    addOutput('result', width: ParticleWidths.word);
    addOutput('zero');
    addOutput('negative');

    _build();
  }

  void _build() {
    final res = Logic(name: 'alu_res', width: ParticleWidths.word);
    final shiftAmt5 = operandB.slice(4, 0);
    final subVal = operandA - operandB;

    // Bit manipulation helper
    final bitMask = Const(1, width: ParticleWidths.word) << shiftAmt5;

    // BEXTR helper: Position is operandB[4:0], Length is operandB[9:5]
    final bextrPos = operandB.slice(4, 0);
    final bextrLen = operandB.slice(9, 5);
    final bextrShifted = operandA >>> bextrPos;
    final bextrMask =
        (Const(1, width: 33) << bextrLen.zeroExtend(6)).slice(31, 0) -
            Const(1, width: ParticleWidths.word);
    final bextrResult = bextrShifted & bextrMask;

    // Relational comparisons
    final sltVal = mux(
      operandA.lt(operandB),
      Const(1, width: ParticleWidths.word),
      Const(0, width: ParticleWidths.word),
    );

    final signA = operandA.slice(31, 31);
    final signB = operandB.slice(31, 31);
    final ssltVal = mux(
      signA ^ signB,
      mux(signA.eq(1), Const(1, width: ParticleWidths.word),
          Const(0, width: ParticleWidths.word)),
      sltVal,
    );

    // Count Leading Zeros (Combinational Priority Encoder)
    final clzVal = Logic(name: 'clzVal', width: ParticleWidths.word);

    // Width-matched rotate helpers (32 - shiftAmt5)
    final shiftExt6 = shiftAmt5.zeroExtend(6);
    final rotComplement = (Const(32, width: 6) - shiftExt6).slice(4, 0);

    Combinational([
      Case(
        Const(1, width: 1),
        [
          for (int i = 31; i >= 0; i--)
            CaseItem(operandA.slice(i, i), [
              clzVal < Const(31 - i, width: ParticleWidths.word),
            ]),
        ],
        defaultItem: [
          clzVal < Const(32, width: ParticleWidths.word),
        ],
      ),
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
          res < (operandA.signExtend(64) >>> shiftAmt5).slice(31, 0),
        ]),
        CaseItem(Const(AluOps.rotl, width: 5), [
          res < ((operandA << shiftAmt5) | (operandA >>> rotComplement)),
        ]),
        CaseItem(Const(AluOps.rotr, width: 5), [
          res < ((operandA >>> shiftAmt5) | (operandA << rotComplement)),
        ]),
        CaseItem(Const(AluOps.clz, width: 5), [res < clzVal]),
        CaseItem(Const(AluOps.bextr, width: 5), [res < bextrResult]),
        CaseItem(Const(AluOps.bset, width: 5), [res < (operandA | bitMask)]),
        CaseItem(Const(AluOps.bclr, width: 5), [res < (operandA & ~bitMask)]),
        CaseItem(Const(AluOps.binv, width: 5), [res < (operandA ^ bitMask)]),
        CaseItem(Const(AluOps.bget, width: 5), [
          res <
              ((operandA >>> shiftAmt5) & Const(1, width: ParticleWidths.word)),
        ]),
        CaseItem(Const(AluOps.slt, width: 5), [res < sltVal]),
        CaseItem(Const(AluOps.sslt, width: 5), [res < ssltVal]),
        CaseItem(Const(AluOps.not, width: 5), [res < ~operandA]),
        CaseItem(Const(AluOps.nez, width: 5), [
          res <
              mux(operandA.neq(0), Const(1, width: ParticleWidths.word),
                  Const(0, width: ParticleWidths.word)),
        ]),
      ], defaultItem: [
        res < Const(0, width: ParticleWidths.word),
      ]),
    ]);

    result <= res;
    zero <= res.eq(0);
    negative <= res.slice(31, 31).eq(1);
  }
}
