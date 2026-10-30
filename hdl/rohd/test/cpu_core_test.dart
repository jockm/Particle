// =============================================================================
// File: hdl/rohd/test/cpu_core_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/cpu_config.dart';
import '../lib/cpu_core.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle CPU Core Integration Tests', () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic memARData;
    late Logic memBRData;
    late Logic mboxStrobe;
    late Logic mboxVector;
    late ParticleCpuCore core;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      memARData = Logic(name: 'memARData', width: ParticleWidths.halfWord);
      memBRData = Logic(name: 'memBRData', width: ParticleWidths.word);
      mboxStrobe = Logic(name: 'mboxStrobe');
      mboxVector = Logic(name: 'mboxVector', width: 4);

      reset.put(1);
      mboxStrobe.put(0);
      mboxVector.put(0);
      memARData.put(0);
      memBRData.put(0);

      core = ParticleCpuCore(
        clk: clk.clk,
        reset: reset,
        memPortARData: memARData,
        memPortBRData: memBRData,
        mboxStrobeIn: mboxStrobe,
        mboxVectorIn: mboxVector,
        config: const CpuConfig(trapTableBase: 0x0100, trapStrideBytes: 64),
      );
      await core.build();
    });

    test('Core Reset Vector Fetch at 0x0100', () async {
      // During reset (timestamp 10), core holds PC at TRAP_TABLE_BASE
      Simulator.registerAction(10, () {
        expect(core.memPortAAddr.value.toInt(), equals(0x00000100));
        reset.put(0);
      });
      Simulator.registerAction(30, () => Simulator.endSimulation());
      await Simulator.run();
    });

    test('Inbound MBOX Strobe Interruption to Vector 1 (0x0140)', () async {
      Simulator.registerAction(10, () => reset.put(0));
      Simulator.registerAction(20, () {
        mboxVector.put(1);
        mboxStrobe.put(1);
      });
      Simulator.registerAction(30, () {
        // Core should register trap and vector to 0x0140 (0x0100 + 1 * 64)
        expect(core.memPortAAddr.value.toInt(), equals(0x00000140));
        mboxStrobe.put(0);
      });
      Simulator.registerAction(50, () => Simulator.endSimulation());
      await Simulator.run();
    });
  });
}
