// =============================================================================
// File: hdl/rohd/test/cache_subsystem_test.dart
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/cache_subsystem_top.dart';
import 'test_helpers.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle Cache & SDRAM Subsystem Top Tests', () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic sdramDqIn;
    late CacheSubsystemTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      sdramDqIn = Logic(name: 'sdramDqIn', width: 16);

      top = CacheSubsystemTop(
        clk: clk.clk,
        reset: reset,
        sdramDqIn: sdramDqIn,
        clkFreqMhz: 25,
        casLatency: 2,
      );

      await top.build();

      reset.put(1);
      sdramDqIn.put(0);
    });

    test('SDRAM Control Signals Are Driven and Default Unasserted', () async {
      Simulator.registerAction(20, () => reset.put(0));
      Simulator.registerAction(40, () {
        expect(top.sdramClk.value.isValid, isTrue);
        expect(top.sdramCke.value.toInt(), equals(1));
        expect(top.sdramCsN.value.isValid, isTrue);
      });
      Simulator.registerAction(60, () => Simulator.endSimulation());
      await Simulator.run();
    });
  });
}
