// =============================================================================
// File: hdl/particle/test/fifo_mbox_test.dart
// Architecture: Particle 32-bit RISC
// Description: Unit testbench for multi-channel streaming FIFO fabric.
// =============================================================================

import 'dart:async';
import 'dart:math';
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

    test('Random pushes, pops and resets match a queue model', () async {
      // The storage is block RAM with registered reads, so the head word
      // comes from the RAM, or from the bypass register when it was written
      // at the same edge it is read. This drives random traffic (phases that
      // fill to full, drain to empty, and mix both, with occasional resets)
      // and checks every channel output against a queue each cycle. Inputs
      // change and outputs are sampled at the falling edge.
      final rnd = Random(20261119);
      final queues = List.generate(4, (_) => <int>[]);
      reset.put(0);
      pushEn.put(0);
      popEn.put(0);
      var pushBias = 0.5;
      var popBias = 0.5;
      var fullSeen = 0;
      var pushedWhenEmpty = 0;
      for (var cycle = 0; cycle < 4000; cycle++) {
        await clkGen.clk.nextNegedge;
        final ch = chanSelect.value.toInt();
        final q = queues[ch];
        expect(fifo.empty.value.toInt(), equals(q.isEmpty ? 1 : 0),
            reason: 'empty, cycle $cycle, channel $ch');
        expect(fifo.full.value.toInt(), equals(q.length == 256 ? 1 : 0),
            reason: 'full, cycle $cycle, channel $ch');
        expect((fifo.statusWord.value.toInt() >> 8) & 0xFF,
            equals(q.length & 0xFF),
            reason: 'depth, cycle $cycle, channel $ch');
        if (q.isNotEmpty) {
          expect(fifo.popData.value.toInt(), equals(q.first),
              reason: 'head, cycle $cycle, channel $ch');
        }
        if (q.length == 256) fullSeen++;

        // What the edge after this one does, given the inputs set below
        if (cycle % 400 == 0) {
          const phases = [(0.9, 0.1), (0.1, 0.9), (0.5, 0.5), (0.7, 0.6)];
          // The first phase only pushes, so channel 0 fills to 256
          (pushBias, popBias) = cycle == 0
              ? (1.0, 0.0)
              : phases[rnd.nextInt(phases.length)];
        }
        final doReset = cycle >= 400 && rnd.nextInt(700) == 0;
        // Mostly channel 0, so it fills; sometimes the others
        final nextCh = rnd.nextInt(4) == 0 ? rnd.nextInt(4) : 0;
        final push = rnd.nextDouble() < pushBias;
        final pop = rnd.nextDouble() < popBias;
        final data = rnd.nextInt(1 << 32);
        chanSelect.put(nextCh);
        pushData.put(data);
        pushEn.put(push ? 1 : 0);
        popEn.put(pop ? 1 : 0);
        reset.put(doReset ? 1 : 0);

        final nq = queues[nextCh];
        if (doReset) {
          for (final x in queues) {
            x.clear();
          }
        } else {
          final doPop = pop && nq.isNotEmpty;
          final doPush = push && nq.length < 256;
          if (doPush && nq.isEmpty) pushedWhenEmpty++;
          if (doPop) nq.removeAt(0);
          if (doPush) nq.add(data);
        }
      }
      // The run must have reached the cases the bypass is for
      expect(fullSeen, greaterThan(0), reason: 'channel never filled');
      expect(pushedWhenEmpty, greaterThan(20));
    });
  });
}
