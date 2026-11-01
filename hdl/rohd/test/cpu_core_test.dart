// =============================================================================
// File: hdl/rohd/test/cpu_core_test.dart
// Architecture: Particle 32-bit RISC
// Description: Integrated testbench verifying instruction fetch, reset vector,
//              and Direct Stride vector dispatch.
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
    late Logic clk;
    late Logic reset;
    late Logic memARData;
    late Logic memBRData;
    late Logic mboxStrobe;
    late Logic mboxVector;
    late ParticleCpuCore core;

    setUp(() async {
      clk = Logic(name: 'clk');
      reset = Logic(name: 'reset');
      memARData = Logic(name: 'memARData', width: ParticleWidths.halfWord);
      memBRData = Logic(name: 'memBRData', width: ParticleWidths.word);
      mboxStrobe = Logic(name: 'mboxStrobe');
      mboxVector = Logic(name: 'mboxVector', width: ParticleWidths.trapVector);

      core = ParticleCpuCore(
        clk: clk,
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
      // Clock 1 cycle in reset
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      expect(core.memPortAAddr.value.toInt(), equals(0x00000100));
    });

    test('Inbound MBOX Strobe Interruption to Vector 1 (0x0140)', () async {
      // Cycle 1: Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Cycle 2: Deassert reset, assert MBOX strobe for Vector 1
      Simulator.registerAction(12, () {
        reset.put(0);
        mboxVector.put(1);
        mboxStrobe.put(1);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      // Vector 1 target: TRAP_TABLE_BASE (0x0100) + (1 * 64) = 0x0140 (320)
      expect(core.memPortAAddr.value.toInt(), equals(0x00000140));
    });
  });
}
