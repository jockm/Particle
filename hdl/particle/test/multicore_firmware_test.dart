// =============================================================================
// File: hdl/particle/test/multicore_firmware_test.dart
// Description: ParticleMultiCore running real programs from synchronous block
//              RAM: core 1 runs firmware/parcore/riscv/core1_dispatch.asm and
//              core 0 runs apps/asm/c0_stimulus.asm, which sends it a taken
//              BEQ token. Needs `make firmware` and `make apps`.
// =============================================================================

import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:particle_rohd/block_ram_tdp.dart";
import "package:particle_rohd/cpu_config.dart";
import "package:particle_rohd/particle_multi_core.dart";
import "package:rohd/rohd.dart";
import "package:test/test.dart";

Uint8List _loadBinary(List<String> candidatePaths) {
  for (final path in candidatePaths) {
    final file = File(path);
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
  }
  throw Exception('Unable to locate binary in candidates: $candidatePaths');
}

/// ParticleMultiCore with 64 KiB of block RAM per core, each loaded with its
/// program at 0x100.
class _MultiCoreBoard extends Module {
  late final ParticleMultiCore multiCore;

  _MultiCoreBoard(Logic clk, Logic reset, List<int> c0Program,
      List<int> c1Program)
      : super(name: 'multicore_board') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    final c0A = Logic(name: 'c0A', width: 16);
    final c0B = Logic(name: 'c0B', width: 32);
    final c1A = Logic(name: 'c1A', width: 16);
    final c1B = Logic(name: 'c1B', width: 32);
    multiCore = ParticleMultiCore(
      clk: clk,
      reset: reset,
      c0MemPortARData: c0A,
      c0MemPortBRData: c0B,
      c1MemPortARData: c1A,
      c1MemPortBRData: c1B,
      configCore0: const CpuConfig(trapTableBase: 0x00000100),
      configCore1: const CpuConfig(trapTableBase: 0x00000100),
    );
    final ram0 = ParticleBlockRamTdp(
      clk: clk,
      addrA: multiCore.c0MemPortAAddr.slice(15, 1),
      addrB: multiCore.c0MemPortBAddr.slice(15, 2),
      wDataB: multiCore.c0MemPortBWData,
      bEnB: multiCore.c0MemPortBBEn,
      wEnB: multiCore.c0MemPortBWEn,
      rEnB: multiCore.c0MemPortBREn,
      initialBytes: c0Program,
      loadOffset: 0x100,
      name: 'ram0',
    );
    final ram1 = ParticleBlockRamTdp(
      clk: clk,
      addrA: multiCore.c1MemPortAAddr.slice(15, 1),
      addrB: multiCore.c1MemPortBAddr.slice(15, 2),
      wDataB: multiCore.c1MemPortBWData,
      bEnB: multiCore.c1MemPortBBEn,
      wEnB: multiCore.c1MemPortBWEn,
      rEnB: multiCore.c1MemPortBREn,
      initialBytes: c1Program,
      loadOffset: 0x100,
      name: 'ram1',
    );
    c0A <= ram0.rDataA;
    c0B <= ram0.rDataB;
    c1A <= ram1.rDataA;
    c1B <= ram1.rDataB;
  }
}

void main() {
  group("Core 1 Firmware Dispatch Verification", () {
    late Logic clk;
    late Logic reset;
    late ParticleMultiCore multiCore;

    Future<void> step(int n) async {
      for (var i = 0; i < n; i++) {
        await clk.nextPosedge;
      }
    }

    setUp(() async {
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      final c1FirmwareBytes = _loadBinary([
        '../../build/parcore/riscv/core1_dispatch.bin',
        'build/parcore/riscv/core1_dispatch.bin',
      ]);
      final c0StimulusBytes = _loadBinary([
        '../../build/c0_stimulus.bin',
        'build/c0_stimulus.bin',
      ]);

      final board =
          _MultiCoreBoard(clk, reset, c0StimulusBytes, c1FirmwareBytes);
      await board.build();
      multiCore = board.multiCore;

      reset.inject(1);
      Simulator.setMaxSimTime(1 << 30);
      unawaited(Simulator.run());
      await step(4);
      reset.inject(0);
    });

    tearDown(() async {
      await Simulator.endSimulation();
      await Simulator.simulationEnded;
      await Simulator.reset();
    });

    test("Core 1 boots and stalls on FIFO.R waiting for token", () async {
      // Core 0's stimulus sends tokens, so look before it has run far: core 1
      // reaches its FIFO.R (0x102) and waits there for the first token
      await step(3);
      expect(multiCore.c1MemPortAAddr.value.toInt(), equals(0x00000102));
    });

    test("Branch TAKEN: Core 0 pushes tokens -> Core 1 evaluates BEQ and strobes MBOX", () async {
      bool mboxStrobeSeen = false;
      int mboxVector = 0;

      multiCore.c0MboxStrobeIn.changed.listen((event) {
        if (multiCore.c0MboxStrobeIn.value.isValid &&
            multiCore.c0MboxStrobeIn.value.toInt() == 1) {
          mboxStrobeSeen = true;
          if (multiCore.c0MboxVectorIn.value.isValid) {
            mboxVector = multiCore.c0MboxVectorIn.value.toInt();
          }
        }
      });

      await step(200);

      expect(mboxStrobeSeen, isTrue, reason: "Taken branch must strobe Core 0 MBOX");
      expect(mboxVector, equals(1), reason: "Branch redirect vector is 1");
    });
  });
}
