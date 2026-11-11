// =============================================================================
// File: hdl/particle/test/fifo_mbox_test.dart
// Architecture: Particle 32-bit RISC
// Description: Unit testbench for multi-channel streaming FIFO fabric.
// =============================================================================

import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/fifo_subsystem.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  group('Particle FIFO Subsystem Tests', () {
    late SimpleClockGenerator clkGen;
    late Logic reset;
    late Logic chanSelect;
    late Logic pushData;
    late Logic pushEn;
    late Logic popEn;
    late ParticleFifoSubsystem fifo;

    Future<void> stepClocks(int cycles) async {
      for (int i = 0; i < cycles; i++) {
        await clkGen.clk.nextPosedge;
      }
    }

    setUp(() async {
      clkGen = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      chanSelect = Logic(name: 'chanSelect', width: 2);
      pushData = Logic(name: 'pushData', width: ParticleWidths.word);
      pushEn = Logic(name: 'pushEn');
      popEn = Logic(name: 'popEn');

      fifo = ParticleFifoSubsystem(
        clk: clkGen.clk,
        reset: reset,
        chanSelect: chanSelect,
        pushData: pushData,
        pushEn: pushEn,
        popEn: popEn,
        channels: 4,
      );
      await fifo.build();

      unawaited(Simulator.run());

      reset.put(1);
      chanSelect.put(0);
      pushData.put(0);
      pushEn.put(0);
      popEn.put(0);

      await stepClocks(2);
      reset.put(0);
    });

    test('Initial state: FIFO empty flag asserted, full flag cleared',
        () async {
      expect(fifo.empty.value.toInt(), equals(1));
      expect(fifo.full.value.toInt(), equals(0));
      expect(fifo.statusWord.value.toInt() & 0x01, equals(1));
    });

    test('Push and Pop single word FIFO Channel 0', () async {
      // Push 0x12345678 into Channel 0
      chanSelect.put(0);
      pushData.put(0x12345678);
      pushEn.put(1);
      await stepClocks(1);
      pushEn.put(0);

      // Verify not empty
      expect(fifo.empty.value.toInt(), equals(0));
      expect(fifo.popData.value.toInt(), equals(0x12345678));

      // Pop item
      popEn.put(1);
      await stepClocks(1);
      popEn.put(0);

      // Verify empty again
      expect(fifo.empty.value.toInt(), equals(1));
    });

    test('Multi-word ordering and channel isolation', () async {
      // Push to Channel 1
      chanSelect.put(1);
      pushData.put(0xAAAAAAAA);
      pushEn.put(1);
      await stepClocks(1);

      pushData.put(0xBBBBBBBB);
      await stepClocks(1);
      pushEn.put(0);

      // Verify Channel 0 remains empty
      chanSelect.put(0);
      expect(fifo.empty.value.toInt(), equals(1));

      // Verify Channel 1 contents
      chanSelect.put(1);
      expect(fifo.empty.value.toInt(), equals(0));
      expect(fifo.popData.value.toInt(), equals(0xAAAAAAAA));

      popEn.put(1);
      await stepClocks(1);
      popEn.put(0);

      expect(fifo.popData.value.toInt(), equals(0xBBBBBBBB));
    });
  });
}
