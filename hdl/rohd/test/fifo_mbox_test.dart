// =============================================================================
// File: hdl/rohd/test/fifo_mbox_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/fifo_subsystem.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle FIFO Subsystem Tests', () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic chanSelect;
    late Logic pushData;
    late Logic pushEn;
    late Logic popEn;
    late ParticleFifoSubsystem fifo;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      chanSelect = Logic(name: 'chanSelect', width: 2);
      pushData = Logic(name: 'pushData', width: ParticleWidths.word);
      pushEn = Logic(name: 'pushEn');
      popEn = Logic(name: 'popEn');

      reset.put(1);
      chanSelect.put(0);
      pushData.put(0);
      pushEn.put(0);
      popEn.put(0);

      fifo = ParticleFifoSubsystem(
        clk: clk.clk,
        reset: reset,
        chanSelect: chanSelect,
        pushData: pushData,
        pushEn: pushEn,
        popEn: popEn,
        channels: 4,
      );
      await fifo.build();
    });

    test('Initial FIFO state is empty for all channels', () async {
      Simulator.registerAction(20, () => reset.put(0));
      Simulator.registerAction(40, () {
        expect(fifo.empty.value.toInt(), equals(1));
        expect(fifo.full.value.toInt(), equals(0));
        expect(fifo.statusWord.value.toInt() & 0x1, equals(1));
      });
      Simulator.registerAction(60, () => Simulator.endSimulation());
      await Simulator.run();
    });
  });
}
