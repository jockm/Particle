import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/cpu_config.dart';
import '../lib/particle_multi_core.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  group('ParticleMultiCore Integration Tests', () {
    late SimpleClockGenerator clkGen;
    late Logic reset;

    late Logic c0MemARData;
    late Logic c0MemBRData;
    late Logic c1MemARData;
    late Logic c1MemBRData;

    late ParticleMultiCore multiCore;

    Future<void> stepClocks(int cycles) async {
      for (int i = 0; i < cycles; i++) {
        await clkGen.clk.nextPosedge;
      }
    }

    setUp(() async {
      clkGen = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');

      c0MemARData = Logic(name: 'c0MemARData', width: 16);
      c0MemBRData = Logic(name: 'c0MemBRData', width: 32);
      c1MemARData = Logic(name: 'c1MemARData', width: 16);
      c1MemBRData = Logic(name: 'c1MemBRData', width: 32);

      multiCore = ParticleMultiCore(
        clk: clkGen.clk,
        reset: reset,
        c0MemPortARData: c0MemARData,
        c0MemPortBRData: c0MemBRData,
        c1MemPortARData: c1MemARData,
        c1MemPortBRData: c1MemBRData,
        configCore0: const CpuConfig(trapTableBase: 0x00000100),
        configCore1: const CpuConfig(trapTableBase: 0x00000200),
      );

      await multiCore.build();

      unawaited(Simulator.run());

      // Reset sequence
      reset.put(1);
      c0MemARData.put(0); // NOP
      c0MemBRData.put(0);
      c1MemARData.put(0); // NOP
      c1MemBRData.put(0);

      await stepClocks(2);
      reset.put(0);
      await stepClocks(1);
    });

    test('Initial boot vectors for Core 0 and Core 1', () async {
      // Core 0 starts at 0x100, Core 1 starts at 0x200
      expect(multiCore.c0MemPortAAddr.value.toInt(), equals(0x00000100));
      expect(multiCore.c1MemPortAAddr.value.toInt(), equals(0x00000200));
    });

    test('Core 0 strobing MBOX interrupts Core 1 to designated vector slot', () async {
      // Core 0 executes MBOX R1, Vector 2 (Opcode 0xE5, rr=1, rl=2 -> 0xE512)
      // Vector 2 destination for Core 1: 0x200 + (2 * 64) = 0x280
      c0MemARData.put(0xE512);
      c1MemARData.put(0); // NOP

      // StateFetch -> StateExec
      await stepClocks(1);

      // Core 0 executes MBOX strobe, Core 1 latches vector
      await stepClocks(1);

      expect(multiCore.c1MemPortAAddr.value.toInt(), equals(0x00000280));
    });
  });
}
