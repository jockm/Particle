// =============================================================================
// File: hdl/rohd/test/alu_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

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
      aluOp = Logic(name: 'aluOp', width: 5);
      operandA = Logic(name: 'operandA', width: ParticleWidths.word);
      operandB = Logic(name: 'operandB', width: ParticleWidths.word);

      aluOp.put(0);
      operandA.put(0);
      operandB.put(0);

      alu = ParticleAlu(
        aluOp: aluOp,
        operandA: operandA,
        operandB: operandB,
      );
      await alu.build();
    });

    test('ADD and SUB operations with zero and negative flags', () {
      aluOp.put(0);
      operandA.put(0x10);
      operandB.put(0x25);
      expect(alu.result.value.toInt(), equals(0x35));
      expect(alu.isZero.value.toInt(), equals(0));
      expect(alu.isNegative.value.toInt(), equals(0));

      aluOp.put(1);
      operandA.put(0x50);
      operandB.put(0x50);
      expect(alu.result.value.toInt(), equals(0));
      expect(alu.isZero.value.toInt(), equals(1));
      expect(alu.isNegative.value.toInt(), equals(0));

      aluOp.put(1);
      operandA.put(0x10);
      operandB.put(0x20);
      expect(alu.result.value.toInt(), equals(0xFFFFFFF0));
      expect(alu.isZero.value.toInt(), equals(0));
      expect(alu.isNegative.value.toInt(), equals(1));
    });

    test('Bitwise Logic Operations (AND, OR, XOR)', () {
      operandA.put(0xF0F0F0F0);
      operandB.put(0x0F0FFF00);

      aluOp.put(2);
      expect(alu.result.value.toInt(), equals(0x000F0000));

      aluOp.put(3);
      expect(alu.result.value.toInt(), equals(0xFFFFFFFF));

      aluOp.put(4);
      expect(alu.result.value.toInt(), equals(0xFFF0FF00));
    });

    test('Shifts and Rotates', () {
      operandA.put(0x80000001);
      operandB.put(1);

      aluOp.put(5);
      expect(alu.result.value.toInt(), equals(0x00000002));

      aluOp.put(6);
      expect(alu.result.value.toInt(), equals(0x40000000));

      aluOp.put(7);
      expect(alu.result.value.toInt(), equals(0xC0000000));

      aluOp.put(8);
      expect(alu.result.value.toInt(), equals(0x00000003));

      aluOp.put(9);
      expect(alu.result.value.toInt(), equals(0xC0000000));
    });

    test('Count Leading Zeros (CLZ)', () {
      aluOp.put(10);
      operandB.put(0);

      operandA.put(0x00000000);
      expect(alu.result.value.toInt(), equals(32));

      operandA.put(0x80000000);
      expect(alu.result.value.toInt(), equals(0));

      operandA.put(0x00000001);
      expect(alu.result.value.toInt(), equals(31));

      operandA.put(0x00F00000);
      expect(alu.result.value.toInt(), equals(8));
    });

    test('Relational SLT and SSLT', () {
      aluOp.put(16);
      operandA.put(10);
      operandB.put(20);
      expect(alu.result.value.toInt(), equals(1));

      operandA.put(0xFFFFFFFF);
      operandB.put(1);
      expect(alu.result.value.toInt(), equals(0));

      aluOp.put(17);
      operandA.put(0xFFFFFFFF);
      operandB.put(1);
      expect(alu.result.value.toInt(), equals(1));
    });
  });
}
