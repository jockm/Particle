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
      // Core 0 starts at 0x100, Core 1 at 0x200. One cycle after reset each
      // is executing its first instruction (a NOP) and already fetching the
      // next one.
      expect(multiCore.c0MemPortAAddr.value.toInt(), equals(0x00000102));
      expect(multiCore.c1MemPortAAddr.value.toInt(), equals(0x00000202));
    });

    test('Core 0 strobing MBOX interrupts Core 1 to designated vector slot', () async {
      // Core 0 executes MBOX R1, Vector 2 (Opcode 0xE5, rr=1, rl=2 -> 0xE512)
      // Vector 2 destination for Core 1: 0x200 + (2 * 16) = 0x220
      c0MemARData.put(0xE512);
      c1MemARData.put(0); // NOP

      // The MBOX goes through core 0's pipeline (fetch, decode, execute),
      // then core 1 takes the vector at its next instruction
      var seen = false;
      for (var i = 0; i < 8 && !seen; i++) {
        await stepClocks(1);
        seen = multiCore.c1MemPortAAddr.value.toInt() == 0x00000220;
      }
      expect(seen, isTrue, reason: 'core 1 should fetch its vector 2 (0x220)');
    });

    test('MBOX sends Rr: the target stores it below its trap table', () async {
      // Core 0: LD R1, 5 (0x0115), then MBOX R1, 2 (0xE512). Core 1's table
      // is at 0x200, so it stores 5 at 0x1FC as it takes vector 2 (0x220)
      c0MemARData.put(0x0115);
      c1MemARData.put(0); // NOP
      await stepClocks(1);
      c0MemARData.put(0xE512);
      var seen = false;
      for (var i = 0; i < 4 && !seen; i++) {
        await stepClocks(1);
        if (multiCore.c1MemPortAAddr.value.toInt() == 0x220) {
          seen = true;
          expect(multiCore.c1MemPortBWEn.value.toInt(), equals(1));
          expect(multiCore.c1MemPortBAddr.value.toInt(), equals(0x1FC));
          expect(multiCore.c1MemPortBWData.value.toInt(), equals(5));
          expect(multiCore.c1MemPortBBEn.value.toInt(), equals(0xF));
        }
      }
      expect(seen, isTrue, reason: 'core 1 should take vector 2');
    });
  });
}
