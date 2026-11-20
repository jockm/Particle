import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../particle/test/test_helpers.dart";
import "../lib/parcore_top.dart";
import "guest_echo.dart";

List<int> loadFirmware(String relativePath) {
  final candidates = [
    '../../$relativePath',
    relativePath,
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

      final c0Bin = loadFirmware('build/parcore/riscv/core0_if_uart.bin');
      final c1Bin = loadFirmware('build/parcore/riscv/core1_id.bin');
      final c2Bin = loadFirmware('build/parcore/riscv/core2_ex.bin');
      final c3Bin = loadFirmware('build/parcore/riscv/core3_mem.bin');

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: kernelWithGuest(c0Bin, guestEchoProgram),
        core1Binary: c1Bin,
        core2Binary: c2Bin,
        core3Binary: kernelWithGuest(c3Bin, guestEchoProgram),
      );

      await top.build();
    });

    test("Host drives a character into uartRx and the guest echo program sends it back on uartTx", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      // Reset sequence
      await clk.waitCycles(5);
      reset.put(0);

      // Settle
      await clk.waitCycles(10);

      const testChar = 75; // ASCII 'K' (0x4B)
      final baudDivisor = top.ftdiDivisor; // 25 at 25 MHz, 1 Mbps

      // Send Start bit (Low)
      uartRx.put(0);
      await clk.waitCycles(baudDivisor);

      // Send 8 data bits LSB first
      for (int i = 0; i < 8; i++) {
        uartRx.put((testChar >> i) & 1);
        await clk.waitCycles(baudDivisor);
      }

      // Send Stop bit (High)
      uartRx.put(1);

      // Detect falling edge (Start bit arrival)
      bool sawTxStart = false;
      for (int i = 0; i < 20000; i++) {
        if (top.uartTx.value.toInt() == 0) {
          sawTxStart = true;
          break;
        }
        await clk.waitCycles(1);
      }
      expect(sawTxStart, isTrue, reason: "the guest did not echo: no start bit on uartTx");

      // Advance to center of first data bit
      await clk.waitCycles(baudDivisor + (baudDivisor ~/ 2) - 1);

      int receivedByte = 0;
      for (int i = 0; i < 8; i++) {
        receivedByte |= (top.uartTx.value.toInt() << i);
        await clk.waitCycles(baudDivisor);
      }

      expect(receivedByte, equals(testChar));

      await Simulator.endSimulation();
    });
  });
}
