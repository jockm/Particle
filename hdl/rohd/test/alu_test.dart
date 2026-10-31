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
  });
}
