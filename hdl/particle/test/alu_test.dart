// =============================================================================
// File: hdl/particle/test/alu_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/alu.dart';
import '../lib/constants.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle ALU Tests', () {
    late Logic aluOp;
    late Logic operandA;
    late Logic operandB;
    late ParticleAlu alu;

    setUp(() async {
      await Simulator.reset();
      aluOp = Logic(name: 'aluOp', width: 5);
      operandA = Logic(name: 'operandA', width: ParticleWidths.word);
      operandB = Logic(name: 'operandB', width: ParticleWidths.word);

      alu = ParticleAlu(
        aluOp: aluOp,
        operandA: operandA,
        operandB: operandB,
      );
      await alu.build();
    });

    test('ADD and SUB operations with zero and negative flags', () {
      aluOp.put(0); // ADD
      operandA.put(0x10);
      operandB.put(0x25);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0x35));
      expect(alu.isZero.value.toInt(), equals(0));
      expect(alu.isNegative.value.toInt(), equals(0));

      aluOp.put(1); // SUB
      operandA.put(0x50);
      operandB.put(0x50);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0));
      expect(alu.isZero.value.toInt(), equals(1));
      expect(alu.isNegative.value.toInt(), equals(0));

      aluOp.put(1); // SUB
      operandA.put(0x10);
      operandB.put(0x20);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0xFFFFFFF0));
      expect(alu.isZero.value.toInt(), equals(0));
      expect(alu.isNegative.value.toInt(), equals(1));
    });

    test('Bitwise Logic Operations (AND, OR, XOR)', () {
      operandA.put(0xF0F0F0F0);
      operandB.put(0x0F0FFF00);

      aluOp.put(2); // AND
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0x0000F000));

      aluOp.put(3); // OR
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0xFFFFFFF0));

      aluOp.put(4); // XOR
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0xFFFF0FF0));
    });

    test('Shifts and Rotates', () {
      operandA.put(0x80000001);
      operandB.put(1);

      aluOp.put(5); // SHL
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0x00000002));

      aluOp.put(6); // SHR
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0x40000000));

      aluOp.put(7); // ASR
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0xC0000000));

      aluOp.put(8); // ROTL
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0x00000003));

      aluOp.put(9); // ROTR
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0xC0000000));
    });

    test('Count Leading Zeros (CLZ)', () {
      aluOp.put(10);
      operandB.put(0);

      operandA.put(0x00000000);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(32));

      operandA.put(0x80000000);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0));

      operandA.put(0x00000001);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(31));

      operandA.put(0x00F00000);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(8));
    });

    test('Relational SLT and SSLT', () {
      aluOp.put(16); // SLT
      operandA.put(10);
      operandB.put(20);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(1));

      operandA.put(0xFFFFFFFF);
      operandB.put(1);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0));

      aluOp.put(17); // SSLT
      operandA.put(0xFFFFFFFF);
      operandB.put(1);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(1));
    });

    test('Every operation against a reference model (random and edge values)',
        () {
      final rnd = Random(365);
      int r32() => (rnd.nextInt(1 << 16) << 16) | rnd.nextInt(1 << 16);
      const edges = [
        0, 1, 2, 31, 32, 0x7FFFFFFF, 0x80000000, 0x80000001, //
        0xFFFFFFFE, 0xFFFFFFFF, 0x0000FFFF, 0x00010000, 0x12345678,
      ];
      for (var op = 0; op < 32; op++) {
        final cases = <(int, int)>[
          for (final x in edges) for (final y in edges) (x, y),
          // Every shift amount, and every BEXTR position and length
          for (final x in edges) for (var y = 0; y < 1024; y++) (x, y),
          for (var i = 0; i < 2000; i++) (r32(), r32()),
        ];
        for (final (x, y) in cases) {
          aluOp.put(op);
          operandA.put(x);
          operandB.put(y);
          expect(alu.result.value.toInt(), equals(_aluModel(op, x, y)),
              reason: 'op $op, A 0x${x.toRadixString(16)}, '
                  'B 0x${y.toRadixString(16)}');
        }
      }
    });
  });
  group('Particle ALU Tests', () {
    test('NOT and NEZ operations', () async {
      final aluOp = Logic(name: 'aluOp', width: 5);
      final operandA = Logic(name: 'operandA', width: 32);
      final operandB = Logic(name: 'operandB', width: 32);

      final alu = ParticleAlu(
        aluOp: aluOp,
        operandA: operandA,
        operandB: operandB,
      );

      await alu.build();

      // Test 1: Bitwise NOT
      aluOp.put(AluOps.not);
      operandA.put(0x00000000);
      operandB.put(0);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0xFFFFFFFF));

      operandA.put(0xAAAAAAAA);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0x55555555));

      // Test 2: NEZ (Set on Not Equal Zero)
      aluOp.put(AluOps.nez);
      operandA.put(0);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(0));

      operandA.put(1234);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(1));

      operandA.put(0x80000000);
      Simulator.tick();
      expect(alu.result.value.toInt(), equals(1));
    });
  
    test('Extended ISA: NEG, REV32, SEQ, SNE, SLE, SSLE', () async {
      final opA = Logic(name: 'opA', width: 32);
      final opB = Logic(name: 'opB', width: 32);
      final aluOp = Logic(name: 'aluOp', width: 5);
      final alu = ParticleAlu(operandA: opA, operandB: opB, aluOp: aluOp);
      await alu.build();

      // NEG: 0 - 10 = -10 (0xFFFFFFF6)
      opA.put(10);
      opB.put(0);
      aluOp.put(20);
      expect(alu.result.value.toInt(), equals(0xFFFFFFF6));

      // REV32: byte swap 0x12345678 -> 0x78563412
      opA.put(0x12345678);
      aluOp.put(21);
      expect(alu.result.value.toInt(), equals(0x78563412));

      // SEQ: 42 == 42 -> 1, 42 == 99 -> 0
      opA.put(42);
      opB.put(42);
      aluOp.put(22);
      expect(alu.result.value.toInt(), equals(1));
      opB.put(99);
      expect(alu.result.value.toInt(), equals(0));

      // SNE: 42 != 99 -> 1, 42 != 42 -> 0
      aluOp.put(23);
      expect(alu.result.value.toInt(), equals(1));
      opB.put(42);
      expect(alu.result.value.toInt(), equals(0));

      // SLE (unsigned): 15 <= 15 -> 1, 20 <= 15 -> 0
      aluOp.put(24);
      opA.put(15);
      opB.put(15);
      expect(alu.result.value.toInt(), equals(1));
      opA.put(20);
      expect(alu.result.value.toInt(), equals(0));

      // SSLE (signed): -5 <= 5 -> 1
      aluOp.put(25);
      opA.put(0xFFFFFFFB); // -5
      opB.put(5);
      expect(alu.result.value.toInt(), equals(1));
    });
});
}

/// What the ALU should return for [op] on [a] and [b] (32-bit unsigned).
int _aluModel(int op, int a, int b) {
  const m = 0xFFFFFFFF;
  int s32(int x) => x >= 0x80000000 ? x - 0x100000000 : x;
  int b2i(bool v) => v ? 1 : 0;
  final s = b & 31;
  final len = (b >> 5) & 31;
  switch (op) {
    case AluOps.add:
      return (a + b) & m;
    case AluOps.sub:
      return (a - b) & m;
    case AluOps.and:
      return a & b;
    case AluOps.or:
      return a | b;
    case AluOps.xor:
      return a ^ b;
    case AluOps.shiftl:
      return (a << s) & m;
    case AluOps.shiftr:
      return a >> s;
    case AluOps.ashiftr:
      return (s32(a) >> s) & m;
    case AluOps.rotl:
      return ((a << s) | (a >> ((32 - s) & 31))) & m;
    case AluOps.rotr:
      return ((a >> s) | (a << ((32 - s) & 31))) & m;
    case AluOps.clz:
      for (var i = 0; i < 32; i++) {
        if ((a >> (31 - i)) & 1 == 1) return i;
      }
      return 32;
    case AluOps.bextr:
      return (a >> s) & ((1 << len) - 1);
    case AluOps.sbextr:
      // BEXTR, sign-extended from bit len - 1 (a field of length 0 is 0)
      final f = (a >> s) & ((1 << len) - 1);
      if (len == 0 || ((f >> (len - 1)) & 1) == 0) return f;
      return (f | ~((1 << len) - 1)) & 0xFFFFFFFF;
    case AluOps.bset:
      return a | (1 << s);
    case AluOps.bclr:
      return a & ~(1 << s) & m;
    case AluOps.binv:
      return a ^ (1 << s);
    case AluOps.bget:
      return (a >> s) & 1;
    case AluOps.slt:
      return b2i(a < b);
    case AluOps.sslt:
      return b2i(s32(a) < s32(b));
    case AluOps.not:
      return ~a & m;
    case AluOps.nez:
      return b2i(a != 0);
    case AluOps.neg:
      return (-a) & m;
    case AluOps.rev32:
      return ((a & 0xFF) << 24) |
          ((a & 0xFF00) << 8) |
          ((a >> 8) & 0xFF00) |
          ((a >> 24) & 0xFF);
    case AluOps.seq:
      return b2i(a == b);
    case AluOps.sne:
      return b2i(a != b);
    case AluOps.sle:
      return b2i(a <= b);
    case AluOps.ssle:
      return b2i(s32(a) <= s32(b));
    case AluOps.sext8:
      return (a & 0x80) != 0 ? (a & 0xFF) | 0xFFFFFF00 : a & 0xFF;
    case AluOps.sext16:
      return (a & 0x8000) != 0 ? (a & 0xFFFF) | 0xFFFF0000 : a & 0xFFFF;
    default:
      return 0;
  }
}
