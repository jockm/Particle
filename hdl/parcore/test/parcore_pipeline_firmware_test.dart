import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

List<int> loadFirmware(String relativePath) {
  final candidates = [
    relativePath,
    '../../$relativePath',
    '../$relativePath',
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
  }
  throw Exception('Unable to locate firmware binary at $relativePath');
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Parcore End-to-End Multi-Core Firmware Pipeline Tests", () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic uartRx;
    late ParcoreTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      uartRx = Logic(name: 'uart_rx');

      final c0Bin = loadFirmware('firmware/parcore/riscv/core0_if_uart.bin');
      final c1Bin = loadFirmware('firmware/parcore/riscv/core1_id.bin');
      final c2Bin = loadFirmware('firmware/parcore/riscv/core2_ex.bin');
      final c3Bin = loadFirmware('firmware/parcore/riscv/core3_mem.bin');

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0Bin,
        core1Binary: c1Bin,
        core2Binary: c2Bin,
        core3Binary: c3Bin,
      );

      await top.build();
    });

    test("Multi-core pipeline executes firmware and clocks through stages cleanly", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      // Hold reset for 10 cycles
      await clk.waitCycles(10);
      reset.put(0);

      // Run pipeline across multiple cycles
      await clk.waitCycles(50);

      await Simulator.endSimulation();

      expect(top.uartTx.value.isValid, isTrue);
    });
  });
}
