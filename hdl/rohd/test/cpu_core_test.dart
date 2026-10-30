// =============================================================================
// File: hdl/rohd/test/cpu_core_test.dart
// Architecture: Particle 32-bit RISC
// Description: Integrated testbench verifying instruction fetch, execution,
//              memory access, and Direct Stride vector dispatch.
// =============================================================================

import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/cpu_config.dart';
import '../lib/cpu_core.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  group('Particle CPU Core Integration Tests', () {
    late SimpleClockGenerator clkGen;
    late Logic reset;
    late Logic memARData;
    late Logic memBRData;
    late Logic mboxStrobe;
    late Logic mboxVector;
    late ParticleCpuCore core;

    Future<void> stepClocks(int cycles) async {
      for (int i = 0; i < cycles; i++) {
        await clkGen.clk.nextPosedge;
      }
    }

    setUp(() async {
      clkGen = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      memARData = Logic(name: 'memARData', width: ParticleWidths.halfWord);
      memBRData = Logic(name: 'memBRData', width: ParticleWidths.word);
      mboxStrobe = Logic(name: 'mboxStrobe');
      mboxVector = Logic(name: 'mboxVector', width: 4);

      core = ParticleCpuCore(
        clk: clkGen.clk,
        reset: reset,
        memPortARData: memARData,
        memPortBRData: memBRData,
        mboxStrobeIn: mboxStrobe,
        mboxVectorIn: mboxVector,
        config: const CpuConfig(trapTableBase: 0x0100, trapStrideBytes: 64),
      );
      await core.build();

      unawaited(Simulator.run());

      // Assert reset for 2 full cycles
      reset.put(1);
      mboxStrobe.put(0);
      mboxVector.put(0);
      memARData.put(0);
      memBRData.put(0);
      await stepClocks(2);
      reset.put(0);
    });

    test('Core Reset Vector Fetch at 0x0100', () async {
      // In reset, PC holds reset vector 0x0100.
      // Allow simulator delta cycle to settle combinational port out
      expect(core.memPortAAddr.value.toInt(), equals(0x00000100));
    });

    test('Inbound MBOX Strobe Interruption to Vector 1 (0x0140)', () async {
      // Assert cross-core MBOX strobe targeting vector 1
      mboxVector.put(1);
      mboxStrobe.put(1);
      await stepClocks(1);
      mboxStrobe.put(0);

      // Core immediately sets PC to trapTarget (0x0100 + 1 * 64 = 0x0140)
      expect(core.memPortAAddr.value.toInt(), equals(0x00000140));
    });
  });
}
