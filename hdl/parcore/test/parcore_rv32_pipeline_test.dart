import 'package:parcore_rohd/parcore_tcm.dart';
import "dart:async";
import "dart:io";
import "dart:typed_data";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "package:parcore_rohd/parcore_top.dart";

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

      final c0Pc = core0.output('memPortAAddr');
      final core1 = top.subModules.firstWhere((m) => m.name == 'core1_id');
      final c1Pc = core1.output('memPortAAddr');

      final c0FifoPush = core0.output('fifoPushEn');
      final c0FifoData = core0.output('fifoPushData');
      final c0FifoChan = core0.output('fifoChanSelect');

      final c1FifoPop = core1.output('fifoPopEn');
      final c1FifoPush = core1.output('fifoPushEn');
      final c1FifoPushData = core1.output('fifoPushData');
      final c1FifoChan = core1.output('fifoChanSelect');

      int pushes = 0;
      int pops = 0;

      // Sample first 150 cycles to observe IF -> ID handshake
      for (int cycle = 0; cycle < 4000; cycle++) {
        await clk.waitCycles(1);
        if (c0FifoPush.value.isValid && c0FifoPush.value.toInt() == 1) {
          pushes++;
          print("Cycle $cycle: Core0 PUSH #$pushes to Ch${c0FifoChan.value.toInt()} Data=0x${c0FifoData.value.toInt().toRadixString(16)} (C0 PC=0x${c0Pc.value.toInt().toRadixString(16)})");
        }
        if (c1FifoPop.value.isValid && c1FifoPop.value.toInt() == 1) {
          pops++;
          print("Cycle $cycle: Core1 POP  #$pops (C1 PC=0x${c1Pc.value.toInt().toRadixString(16)})");
        }
        final core2 = top.subModules.firstWhere((m) => m.name == "core2_ex");
        final core3 = top.subModules.firstWhere((m) => m.name == "core3_mem");
        final c2Pc = core2.output("memPortAAddr");
        final c3Pc = core3.output("memPortAAddr");
        final c2Pop = core2.output("fifoPopEn");
        final c2Push = core2.output("fifoPushEn");
        final c3Push = core3.output("fifoPushEn");
        final c3Pop = core3.output("fifoPopEn");

        if (c2Pop.value.isValid && c2Pop.value.toInt() == 1) {
          print("Cycle $cycle: Core2 POP (PC=0x${c2Pc.value.toInt().toRadixString(16)})");
        }
        if (c2Push.value.isValid && c2Push.value.toInt() == 1) {
          print("Cycle $cycle: Core2 PUSH Data=0x${core2.output("fifoPushData").value.toInt().toRadixString(16)} Chan=${core2.output("fifoChanSelect").value.toInt()}");
        }
        if (c3Push.value.isValid && c3Push.value.toInt() == 1) {
          print("Cycle $cycle: Core3 PUSH Data=0x${core3.output("fifoPushData").value.toInt().toRadixString(16)} Chan=${core3.output("fifoChanSelect").value.toInt()}");
        }
        if (c1FifoPush.value.isValid && c1FifoPush.value.toInt() == 1) {
          print("Cycle $cycle: Core1 PUSH to Ch${c1FifoChan.value.toInt()} Data=0x${c1FifoPushData.value.toInt().toRadixString(16)} (C1 PC=0x${c1Pc.value.toInt().toRadixString(16)})");
        }
      }
      print("Summary: Total C0 Pushes = $pushes, Total C1 Pops = $pops");
      print("Final C0 PC = 0x${c0Pc.value.toInt().toRadixString(16)}, C1 PC = 0x${c1Pc.value.toInt().toRadixString(16)}");

      expect(pops, greaterThan(0), reason: "Core 1 should pop instructions from IF FIFO");

      const int regBase = 0x0600;

      final c1Tcm = top.subModules.firstWhere((m) => m.name == 'core1_tcm') as ParcoreTcm;
      final x1 = c1Tcm.readWord(regBase + 1 * 4);
      final x2 = c1Tcm.readWord(regBase + 2 * 4);
      final x3 = c1Tcm.readWord(regBase + 3 * 4);
      final x4 = c1Tcm.readWord(regBase + 4 * 4);
      final x5 = c1Tcm.readWord(regBase + 5 * 4);
      final x6 = c1Tcm.readWord(regBase + 6 * 4);

      print("Architectural Registers in Core 1 TCM: x1=$x1, x2=$x2, x3=$x3, x4=$x4, x5=$x5, x6=$x6");

      expect(x1, equals(10), reason: "x1 should be 10 (0x0A)");
      expect(x2, equals(20), reason: "x2 should be 20 (0x14)");
      expect(x3, equals(30), reason: "x3 should be 30 (0x1E)");
      expect(x4, equals(120), reason: "x4 should be 120 (0x78)");
      expect(x5, equals(110), reason: "x5 should be 110 (0x6E)");
      expect(x6, equals(120), reason: "x6 should be 120 from lw 16(x1)");

      await Simulator.endSimulation();
    });
  });
}
