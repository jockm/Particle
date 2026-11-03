#!/usr/bin/env bash
set -e

echo "==> Updating hdl/parcore/test/parcore_top_test.dart..."
cat << 'DART_EOF' > hdl/parcore/test/parcore_top_test.dart
import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

List<int>? _loadBinary(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsBytesSync() : null;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Parcore 4-Stage Multi-Core System Verification", () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic uartRx;
    late ParcoreTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      uartRx = Logic(name: 'uart_rx');

      final c0 = _loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1 = _loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2 = _loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3 = _loadBinary('../../build/parcore/riscv/core3_mem.bin');

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0,
        core1Binary: c1,
        core2Binary: c2,
        core3Binary: c3,
      );

      await top.build();
    });

    test("ParcoreTop elaborates, builds synthesis graph, and generates SystemVerilog", () {
      final sv = top.generateSynth();
      expect(sv, contains("module ParcoreTop"));
      expect(sv, contains("parcore_fifo_if_to_id"));
      expect(sv, contains("parcore_fifo_id_to_ex"));
      expect(sv, contains("parcore_fifo_ex_to_mem"));
      expect(sv, contains("parcore_fifo_mem_to_wb"));
      expect(sv, contains("parcore_ftdi_uart"));
    });

    test("ParcoreTop holds reset and maintains valid UART line", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);

      expect(top.uartTx.value.isValid, isTrue);
      expect(top.uartTx.value.toInt(), equals(1));

      await Simulator.endSimulation();
    });

    test("Host-to-Core-0 UART Echo: transmits 0x41 on uartRx and verifies echo on uartTx", () async {
      reset.put(1);
      uartRx.put(1); // Line idle high

      unawaited(Simulator.run());

      // Hold reset for 5 cycles
      await clk.waitCycles(5);
      reset.put(0);

      // Settle into polling loop
      await clk.waitCycles(20);

      const testByte = 0x41; // ASCII 'A'
      const baudCycles = 8;

      // Track received samples across cycles concurrently
      final txSamples = <int>[];
      bool transmissionStarted = false;

      // Launch transmitter and receiver concurrently using a cycle-by-cycle driver
      // Total transmission = 1 (start) + 8 (data) + 1 (stop) = 10 bits = 80 cycles
      int echoedByte = 0;
      bool sawStartBit = false;

      for (int cycle = 0; cycle < 200; cycle++) {
        // Drive UART RX according to bit time
        if (cycle < 8) {
          uartRx.put(0); // Start bit
        } else if (cycle < 72) {
          final bitIdx = (cycle - 8) ~/ 8;
          uartRx.put((testByte >> bitIdx) & 1); // 8 Data bits
        } else {
          uartRx.put(1); // Stop bit / Idle
        }

        await clk.waitCycles(1);

        // Monitor UART TX
        if (!sawStartBit && top.uartTx.value.toInt() == 0) {
          sawStartBit = true;
          // Capture mid-bit samples for 8 data bits
          // Advance to middle of start bit (4 cycles) then sample every 8 cycles
          for (int b = 0; b < 8; b++) {
            await clk.waitCycles(baudCycles);
            echoedByte |= (top.uartTx.value.toInt() << b);
          }
          break;
        }
      }

      expect(sawStartBit, isTrue, reason: "Core 0 failed to assert UART TX start bit");
      expect(echoedByte, equals(testByte), reason: "Echoed byte did not match transmitted byte 0x41");

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
DART_EOF

echo "==> Executing dart test..."
cd hdl/parcore && dart test test/parcore_top_test.dart

