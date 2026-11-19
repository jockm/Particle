// =============================================================================
// File: hdl/particle/test/mult_div_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/multiplier.dart';
import '../lib/divider.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle Multiplier & Divider Tests', () {
    test('Multiplier computes MULL, MULH, SMULH correctly', () async {
      await Simulator.reset();
      final opA = Logic(name: 'opA', width: ParticleWidths.word);
      final opB = Logic(name: 'opB', width: ParticleWidths.word);
      final mulMode = Logic(name: 'mulMode', width: 2);

      final mul = ParticleMultiplier(
        operandA: opA,
        operandB: opB,
        mulMode: mulMode,
      );
      await mul.build();

      opA.put(100);
      opB.put(25);
      mulMode.put(0); // MULL
      Simulator.tick();
      expect(mul.result.value.toInt(), equals(2500));

      opA.put(0x80000000);
      opB.put(2);
      mulMode.put(1); // MULH
      Simulator.tick();
      expect(mul.result.value.toInt(), equals(1));

      opA.put(0xFFFFFFFF);
      opB.put(5);
      mulMode.put(2); // SMULH
      Simulator.tick();
      expect(mul.result.value.toInt(), equals(0xFFFFFFFF));
    });

    test('Multiplier matches exact products in every mode', () async {
      await Simulator.reset();
      final opA = Logic(name: 'opA', width: ParticleWidths.word);
      final opB = Logic(name: 'opB', width: ParticleWidths.word);
      final mulMode = Logic(name: 'mulMode', width: 2);
      final mul = ParticleMultiplier(
          operandA: opA, operandB: opB, mulMode: mulMode);
      await mul.build();

      final mask = (BigInt.one << 32) - BigInt.one;
      BigInt signed(int v) =>
          v >= 0x80000000 ? BigInt.from(v) - (BigInt.one << 32) : BigInt.from(v);
      int expected(int a, int b, int mode) {
        final ua = BigInt.from(a), ub = BigInt.from(b);
        final p = switch (mode) {
          0 => ua * ub, // MULL: the low word is the same signed or not
          1 => ua * ub, // MULH
          2 => signed(a) * signed(b), // SMULH
          _ => signed(a) * ub, // MULHSU
        };
        return ((mode == 0 ? p : p >> 32) & mask).toInt();
      }

      const edges = [0, 1, 2, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF];
      final rnd = Random(1234);
      final pairs = [
        for (final a in edges)
          for (final b in edges) (a, b),
        for (var i = 0; i < 300; i++)
          (rnd.nextInt(1 << 32), rnd.nextInt(1 << 32)),
      ];
      for (final (a, b) in pairs) {
        for (var mode = 0; mode < 4; mode++) {
          opA.put(a);
          opB.put(b);
          mulMode.put(mode);
          Simulator.tick();
          expect(mul.result.value.toInt(), equals(expected(a, b, mode)),
              reason: 'a=0x${a.toRadixString(16)} b=0x${b.toRadixString(16)} '
                  'mode=$mode');
        }
      }
    });

    test('Divider computes Unsigned Div with multi-cycle completion', () async {
      await Simulator.reset();
      final clk = SimpleClockGenerator(10);
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final isSigned = Logic(name: 'isSigned');
      final dividend = Logic(name: 'dividend', width: ParticleWidths.word);
      final divisor = Logic(name: 'divisor', width: ParticleWidths.word);

      final div = ParticleDivider(
        clk: clk.clk,
        reset: reset,
        start: start,
        isSigned: isSigned,
        dividend: dividend,
        divisor: divisor,
      );
      await div.build();

      reset.put(1);
      start.put(0);
      isSigned.put(0);
      dividend.put(100);
      divisor.put(7);

      bool sawDone = false;
      int capturedQuot = 0;
      int capturedRem = 0;

      clk.clk.posedge.listen((_) {
        if (div.done.value.isValid && div.done.value.toInt() == 1) {
          sawDone = true;
          capturedQuot = div.quotient.value.toInt();
          capturedRem = div.remainder.value.toInt();
        }
      });

      Simulator.registerAction(20, () => reset.put(0));
      Simulator.registerAction(30, () => start.put(1));
      Simulator.registerAction(40, () => start.put(0));

      Simulator.registerAction(450, () {
        expect(sawDone, isTrue);
        expect(capturedQuot, equals(14));
        expect(capturedRem, equals(2));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}
