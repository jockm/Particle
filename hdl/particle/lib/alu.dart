// =============================================================================
// File: hdl/particle/lib/alu.dart
// Architecture: Particle 32-bit RISC Core
// Description: Combinational ALU with 32-bit logic, shifts, math, comparisons,
//              and extended native instructions (NEG, REV32, SEQ, SNE, SLE, SSLE).
// =============================================================================
//
// The units are shared so the ALU stays small:
//   * One 33-bit adder does ADD and SUB, and its carry gives every less-than
//     (SLT, SSLT, SLE, SSLE); one equality compare gives SEQ, SNE and the
//     "or equal" of SLE and SSLE.
//   * One right-rotator does every shift and rotate, BEXTR and BGET: a left
//     shift or rotate by s is a right rotate by -s, and masks then clear (or,
//     for ASHIFTR, fill with the sign) the bits shifted in.
//   * One logic unit does AND, OR, XOR and NOT, and BSET, BCLR and BINV with a
//     one-hot bit made from the shift masks.
//   * The one-bit results (comparisons, NEZ, BGET) share one flag.

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
    const w = ParticleWidths.word;
    final a = input('operandA');
    final b = input('operandB');
    final aluOp = input('aluOp');

    Logic isOp(int code) => aluOp.eq(Const(code, width: 5));
    Logic anyOp(List<int> codes) =>
        codes.map(isOp).reduce((x, y) => x | y);
    Logic ones(Logic bit) => bit.replicate(w);

    // ---- Adder: ADD, SUB, and the less-than comparisons ----
    final subtract = anyOp([
      AluOps.sub,
      AluOps.slt,
      AluOps.sslt,
      AluOps.sle,
      AluOps.ssle,
    ]);
    // {0, A, 1} + {0, B ^ sub, sub}: the low bit carries sub in
    final addX = [Const(0), a, Const(1)].swizzle();
    final addY = [Const(0), b ^ ones(subtract), subtract].swizzle();
    final sum = Logic(name: 'alu_sum', width: w + 2);
    sum <= addX + addY;
    final addOut = sum.getRange(1, w + 1);
    // For a subtraction the carry out is 1 when A >= B (unsigned)
    final ltu = ~sum[w + 1];
    final signA = a[w - 1];
    final signB = b[w - 1];
    final lts = mux(signA ^ signB, signA, ltu);
    final eq = a.eq(b);

    // ---- Rotator: shifts, rotates, BEXTR, BGET ----
    final s = b.getRange(0, 5);
    final left = anyOp([AluOps.shiftl, AluOps.rotl]);
    final amount = mux(left, Const(0, width: 5) - s, s);
    var rot = a;
    for (var k = 0; k < 5; k++) {
      final c = 1 << k;
      final rotated = [rot.getRange(0, c), rot.getRange(c, w)].swizzle();
      rot = mux(amount[k], rotated, rot);
    }
    // leftMask bit i = (i >= s): the bits a left shift by s keeps.
    // rightMask is its mirror image: the bits a right shift by s keeps.
    final leftMaskBits = [
      for (var i = 0; i < w; i++) s.lte(Const(i, width: 5)),
    ];
    final leftMask = leftMaskBits.rswizzle();
    final rightMask = leftMaskBits.swizzle();
    // BEXTR's length mask: bit i = (i < len)
    final len = b.getRange(5, 10);
    final lenMask = [
      for (var i = 0; i < w; i++) Const(i, width: 5).lt(len),
    ].rswizzle();
    final shiftMask = mux(
      isOp(AluOps.shiftl),
      leftMask,
      mux(
        anyOp([AluOps.rotl, AluOps.rotr]),
        ones(Const(1)),
        mux(isOp(AluOps.bextr), rightMask & lenMask, rightMask),
      ),
    );
    final signFill = ~rightMask & ones(isOp(AluOps.ashiftr) & signA);
    final shiftOut = (rot & shiftMask) | signFill;

    // ---- Logic unit: AND, OR, XOR, NOT, BSET, BCLR, BINV ----
    // The one-hot bit s: bit i of leftMask without bit i-1
    final oneHot = [
      for (var i = 0; i < w; i++)
        i == 0 ? leftMaskBits[0] : leftMaskBits[i] & ~leftMaskBits[i - 1],
    ].rswizzle();
    final bitOp = anyOp([AluOps.bset, AluOps.bclr, AluOps.binv]);
    final logicB =
        mux(bitOp, oneHot, mux(isOp(AluOps.not), ones(Const(1)), b));
    // Two-bit function: 0 AND, 1 OR (OR, BSET), 2 XOR (XOR, NOT, BINV),
    // 3 AND NOT (BCLR); one LUT per bit
    final fn1 = anyOp([AluOps.xor, AluOps.not, AluOps.binv, AluOps.bclr]);
    final fn0 = anyOp([AluOps.or, AluOps.bset, AluOps.bclr]);
    final logicOut = mux(
      fn1,
      mux(fn0, a & ~logicB, a ^ logicB),
      mux(fn0, a | logicB, a & logicB),
    );

    // ---- One-bit results ----
    final flag = Logic(name: 'alu_flag');
    Combinational([
      Case(aluOp, [
        CaseItem(Const(AluOps.slt, width: 5), [flag < ltu]),
        CaseItem(Const(AluOps.sslt, width: 5), [flag < lts]),
        CaseItem(Const(AluOps.sle, width: 5), [flag < (ltu | eq)]),
        CaseItem(Const(AluOps.ssle, width: 5), [flag < (lts | eq)]),
        CaseItem(Const(AluOps.seq, width: 5), [flag < eq]),
        CaseItem(Const(AluOps.sne, width: 5), [flag < ~eq]),
        CaseItem(Const(AluOps.nez, width: 5), [flag < a.neq(0)]),
        CaseItem(Const(AluOps.bget, width: 5), [flag < rot[0]]),
      ], defaultItem: [
        flag < Const(0),
      ]),
    ]);

    // ---- The rest ----
    final negOut = Const(0, width: w) - a;
    final rev32Out = [
      a.getRange(0, 8),
      a.getRange(8, 16),
      a.getRange(16, 24),
      a.getRange(24, 32),
    ].swizzle();
    final clzOut = _countLeadingZeros(a);

    // ---- Result: one group per unit, ORed together ----
    final groups = <(Logic, Logic)>[
      (anyOp([AluOps.add, AluOps.sub]), addOut),
      (
        anyOp([
          AluOps.and,
          AluOps.or,
          AluOps.xor,
          AluOps.not,
          AluOps.bset,
          AluOps.bclr,
          AluOps.binv,
        ]),
        logicOut
      ),
      (
        anyOp([
          AluOps.shiftl,
          AluOps.shiftr,
          AluOps.ashiftr,
          AluOps.rotl,
          AluOps.rotr,
          AluOps.bextr,
        ]),
        shiftOut
      ),
      (isOp(AluOps.neg), negOut),
      (isOp(AluOps.rev32), rev32Out),
      (isOp(AluOps.clz), clzOut),
      (isOp(AluOps.sext8), a.getRange(0, 8).signExtend(w)),
      (isOp(AluOps.sext16), a.getRange(0, 16).signExtend(w)),
    ];
    final aluRes = Logic(name: 'alu_res', width: w);
    aluRes <=
        groups
            .map((g) => g.$2 & ones(g.$1))
            .reduce((x, y) => x | y) |
        flag.zeroExtend(w);

    output('result') <= aluRes;
    output('isZero') <= aluRes.eq(0);
    output('isNegative') <= aluRes[w - 1];
  }

  /// The number of leading zeros of [x] (32 when x is 0), as a tree: each
  /// level joins two halves, keeping whether each is all zero and the count
  /// of leading zeros within it.
  static Logic _countLeadingZeros(Logic x) {
    // Pairs of bits, most significant first: count is 1 when the high bit is 0
    var groups = <(Logic, Logic)>[
      for (var i = x.width - 1; i > 0; i -= 2)
        (~x[i] & ~x[i - 1], ~x[i]),
    ];
    while (groups.length > 1) {
      groups = [
        for (var i = 0; i < groups.length; i += 2)
          (
            groups[i].$1 & groups[i + 1].$1,
            // High half all zero: its size plus the low half's count
            mux(
              groups[i].$1,
              [Const(1), groups[i + 1].$2].swizzle(),
              [Const(0), groups[i].$2].swizzle(),
            ),
          ),
      ];
    }
    final (allZero, count) = groups.first;
    // count is 5 bits (0..31); all zero gives 32
    return mux(allZero, Const(32, width: ParticleWidths.word),
        count.zeroExtend(ParticleWidths.word));
  }
}
