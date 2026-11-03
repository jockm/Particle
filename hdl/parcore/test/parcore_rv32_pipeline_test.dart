import "dart:async";
import "dart:io";
import "dart:typed_data";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

List<int> loadBinary(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw Exception('Binary not found: $path');
  }
  return file.readAsBytesSync();
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Parcore RV32IM Guest Program Execution", () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic uartRx;
    late ParcoreTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      uartRx = Logic(name: 'uart_rx');

      final c0Kernel = loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1Kernel = loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2Kernel = loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3Kernel = loadBinary('../../build/parcore/riscv/core3_mem.bin');
      final guestProg = loadBinary('../../build/guest_rv32_test.bin');

      final c0Merged = Uint8List(0x2000); // 8KB
      for (int i = 0; i < c0Kernel.length; i++) {
        c0Merged[i] = c0Kernel[i];
      }
      const guestOffsetInTcm = 0x0500 - 0x0100;
      for (int i = 0; i < guestProg.length; i++) {
        c0Merged[guestOffsetInTcm + i] = guestProg[i];
      }

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0Merged,
        core1Binary: c1Kernel,
        core2Binary: c2Kernel,
        core3Binary: c3Kernel,
      );

      await top.build();
    });

    test("Guest instructions retire into Core 1 architectural registers (x1..x5)", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      // Reset sequence
      await clk.waitCycles(5);
      reset.put(0);

      final core0 = top.subModules.firstWhere((m) => m.name == 'core0_if');
      final core1 = top.subModules.firstWhere((m) => m.name == 'core1_id');

      final c0Pc = core0.output('memPortAAddr');
      final c1Pc = core1.output('memPortAAddr');

      final c0FifoPush = core0.output('fifoPushEn');
      final c0FifoData = core0.output('fifoPushData');
      final c0FifoChan = core0.output('fifoChanSelect');

      final c1FifoPop = core1.output('fifoPopEn');

      int pushes = 0;
      int pops = 0;

      // Sample first 150 cycles to observe IF -> ID handshake
      for (int cycle = 0; cycle < 150; cycle++) {
        await clk.waitCycles(1);
        if (c0FifoPush.value.isValid && c0FifoPush.value.toInt() == 1) {
          pushes++;
          print("Cycle $cycle: Core0 PUSH #$pushes to Ch${c0FifoChan.value.toInt()} Data=0x${c0FifoData.value.toInt().toRadixString(16)} (C0 PC=0x${c0Pc.value.toInt().toRadixString(16)})");
        }
        if (c1FifoPop.value.isValid && c1FifoPop.value.toInt() == 1) {
          pops++;
          print("Cycle $cycle: Core1 POP  #$pops (C1 PC=0x${c1Pc.value.toInt().toRadixString(16)})");
        }
      }

      print("Summary: Total C0 Pushes = $pushes, Total C1 Pops = $pops");
      print("Final C0 PC = 0x${c0Pc.value.toInt().toRadixString(16)}, C1 PC = 0x${c1Pc.value.toInt().toRadixString(16)}");

      await Simulator.endSimulation();
    });
  });
}
