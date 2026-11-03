#!/usr/bin/env bash
set -e

echo "==> Updating hdl/parcore/test/parcore_top_test.dart with precise edge-locked sampler..."
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
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);
      reset.put(0);

      await clk.waitCycles(10);

      const testByte = 0x41; // ASCII 'A'
      const baudCycles = 8;

      // Send Start bit (Low)
      uartRx.put(0);
      await clk.waitCycles(baudCycles);

      // Send 8 Data Bits (LSB first)
      for (int b = 0; b < 8; b++) {
        uartRx.put((testByte >> b) & 1);
        await clk.waitCycles(baudCycles);
      }

      // Send Stop bit (High)
      uartRx.put(1);

      // Detect falling edge (Start bit arrival)
      bool sawStart = false;
      for (int i = 0; i < 200; i++) {
        if (top.uartTx.value.toInt() == 0) {
          sawStart = true;
          break;
        }
        await clk.waitCycles(1);
      }
      expect(sawStart, isTrue, reason: "Core 0 failed to drive UART TX start bit low");

      // Advance to center of first data bit:
      // Half baud period (start bit center) + 1 full baud period (data bit 0 center)
      // Minus 1 cycle since we detected edge after 1 cycle elapsed
      await clk.waitCycles(baudCycles + (baudCycles ~/ 2) - 1);

      int echoedByte = 0;
      for (int b = 0; b < 8; b++) {
        echoedByte |= (top.uartTx.value.toInt() << b);
        await clk.waitCycles(baudCycles);
      }

      expect(echoedByte, equals(testByte), reason: "Core 0 failed to echo character back to UART TX");

      await Simulator.endSimulation();
    });
  });
}
DART_EOF

echo "==> Updating hdl/parcore/test/parcore_pipeline_trace_test.dart..."
cat << 'DART_EOF' > hdl/parcore/test/parcore_pipeline_trace_test.dart
import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

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
        core0Binary: c0Bin,
        core1Binary: c1Bin,
        core2Binary: c2Bin,
        core3Binary: c3Bin,
      );

      await top.build();
    });

    test("Host drives serial character into uartRx and Core 0 echoes to uartTx", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      // Reset sequence
      await clk.waitCycles(5);
      reset.put(0);

      // Settle
      await clk.waitCycles(10);

      const testChar = 75; // ASCII 'K' (0x4B)
      const baudDivisor = 8;

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
      for (int i = 0; i < 200; i++) {
        if (top.uartTx.value.toInt() == 0) {
          sawTxStart = true;
          break;
        }
        await clk.waitCycles(1);
      }
      expect(sawTxStart, isTrue, reason: "Core 0 should echo received character back over uartTx");

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
DART_EOF

echo "==> Running hdl/parcore tests..."
cd hdl/parcore && dart test

