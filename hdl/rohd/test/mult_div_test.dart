// =============================================================================
// File: hdl/rohd/test/mult_div_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

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
      final opA = Logic(name: 'opA', width: ParticleWidths.word);
      final opB = Logic(name: 'opB', width: ParticleWidths.word);
      final mulMode = Logic(name: 'mulMode', width: 2);

      opA.put(0);
      opB.put(0);
      mulMode.put(0);

      final mul = ParticleMultiplier(
        operandA: opA,
        operandB: opB,
        mulMode: mulMode,
      );
      await mul.build();

      opA.put(100);
      opB.put(25);
      mulMode.put(0);
      expect(mul.result.value.toInt(), equals(2500));

      opA.put(0x80000000);
      opB.put(2);
      mulMode.put(1);
      expect(mul.result.value.toInt(), equals(1));

      opA.put(0xFFFFFFFF);
      opB.put(5);
      mulMode.put(2);
      expect(mul.result.value.toInt(), equals(0xFFFFFFFF));
    });

    test('Divider computes Unsigned Div with multi-cycle completion', () async {
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

      Simulator.registerAction(20, () => reset.put(0));
      Simulator.registerAction(30, () => start.put(1));
      Simulator.registerAction(40, () => start.put(0));

      Simulator.registerAction(400, () {
        expect(div.done.value.toInt(), equals(1));
        expect(div.quotient.value.toInt(), equals(14));
        expect(div.remainder.value.toInt(), equals(2));
      });
      Simulator.registerAction(420, () => Simulator.endSimulation());

      await Simulator.run();
    });
  });
}
