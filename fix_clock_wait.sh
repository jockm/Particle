#!/usr/bin/env bash
set -e

echo "==> 1. Updating hdl/rohd/test/test_helpers.dart with safe cycle stepper..."
cat << 'DART_EOF' > hdl/rohd/test/test_helpers.dart
// =============================================================================
// File: hdl/rohd/test/test_helpers.dart
// =============================================================================

import 'package:rohd/rohd.dart';

extension ClockWaitCycles on SimpleClockGenerator {
  /// Safely steps [cycles] clock cycles by listening to posedge events.
  Future<void> waitCycles(int cycles) async {
    for (int i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
  }
}
DART_EOF

echo "==> 2. Updating hdl/parcore/test/parcore_top_test.dart..."
cat << 'DART_TEST_EOF' > hdl/parcore/test/parcore_top_test.dart
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

      // Allow Core 0 to settle into polling loop
      await clk.waitCycles(20);

      const testByte = 0x41; // ASCII 'A'
      const baudCycles = 8;

      // Start serial transmission:
      // Start bit (Low)
      uartRx.put(0);
      await clk.waitCycles(baudCycles);

      // 8 Data Bits (LSB first)
      for (int b = 0; b < 8; b++) {
        uartRx.put((testByte >> b) & 1);
        await clk.waitCycles(baudCycles);
      }

      // Stop bit (High)
      uartRx.put(1);
      await clk.waitCycles(baudCycles);

      // Await and sample Core 0 echo response on top.uartTx
      int cyclesWaited = 0;
      while (top.uartTx.value.toInt() != 0 && cyclesWaited < 300) {
        await clk.waitCycles(1);
        cyclesWaited++;
      }

      expect(top.uartTx.value.toInt(), equals(0),
          reason: "Did not observe UART TX start bit within timeout window");

      // Sample middle of start bit
      await clk.waitCycles(baudCycles ~/ 2);

      // Sample 8 data bits
      int echoedByte = 0;
      for (int b = 0; b < 8; b++) {
        await clk.waitCycles(baudCycles);
        echoedByte |= (top.uartTx.value.toInt() << b);
      }

      // Stop bit
      await clk.waitCycles(baudCycles);

      expect(echoedByte, equals(testByte), reason: "Core 0 failed to echo character back to UART TX");

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
DART_TEST_EOF

echo "==> 3. Running dart test..."
cd hdl/parcore && dart test test/parcore_top_test.dart

