#!/usr/bin/env bash
set -e

echo "==> 1. Patching hdl/rohd/lib/uart.dart..."
cat << 'DART_EOF' > hdl/rohd/lib/uart.dart
// =============================================================================
// File: hdl/rohd/lib/uart.dart
// Architecture: Particle 32-bit RISC
// Description: Pure ROHD 8-N-1 UART Transceiver with configurable clock divisor
//              and FIFO streaming interface.
// =============================================================================

import 'package:rohd/rohd.dart';

class ParticleUartTransceiver extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // Physical serial pins
  Logic get rxPin => input('rxPin');
  Logic get txPin => output('txPin');

  // FIFO / Core Streaming Interface
  Logic get txData => input('txData');      // 8-bit byte from FIFO
  Logic get txValid => input('txValid');    // FIFO not empty & pop strobe
  Logic get txReady => output('txReady');   // Transmitter idle/ready for next byte

  Logic get rxData => output('rxData');    // 8-bit byte received
  Logic get rxValid => output('rxValid');  // FIFO not empty
  Logic get rxReady => input('rxReady');   // RX FIFO / Core pop strobe

  // Optional dynamic divisor update (for arbitrary baud configuration)
  Logic get baudDivisor => input('baudDivisor');

  ParticleUartTransceiver({
    required Logic clk,
    required Logic reset,
    required Logic rxPin,
    required Logic txData,
    required Logic txValid,
    required Logic rxReady,
    required Logic baudDivisor,
    super.name = 'uart_transceiver',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('rxPin', rxPin);
    addInput('txData', txData, width: 8);
    addInput('txValid', txValid);
    addInput('rxReady', rxReady);
    addInput('baudDivisor', baudDivisor, width: 16);

    addOutput('txPin');
    addOutput('txReady');
    addOutput('rxData', width: 8);
    addOutput('rxValid');

    _build();
  }

  void _build() {
    // ---------------- Baud Rate Clock Generation ----------------
    final txClkCounter = Logic(name: 'txClkCounter', width: 16);
    final txTick = Logic(name: 'txTick');

    Sequential(clk, reset: reset, resetValues: {txClkCounter: Const(0, width: 16)}, [
      If(txClkCounter >= baudDivisor - Const(1, width: 16), then: [
        txClkCounter < Const(0, width: 16),
      ], orElse: [
        txClkCounter < txClkCounter + Const(1, width: 16),
      ]),
    ]);
    txTick <= txClkCounter.eq(0);

    // ---------------- TX Shift Engine (8-N-1) ----------------
    final txBitIdx = Logic(name: 'txBitIdx', width: 4);
    final txShift = Logic(name: 'txShift', width: 10); // Start(0) + Data[7:0] + Stop(1)
    final txBusy = Logic(name: 'txBusy');

    Sequential(clk, reset: reset, resetValues: {
      txShift: Const(0x3FF, width: 10),
      txBitIdx: Const(0, width: 4),
      txBusy: Const(0),
    }, [
      If(~txBusy, then: [
        If(txValid, then: [
          // Frame: [Stop bit (1), Data bit 7..0, Start bit (0)]
          txShift < [Const(1, width: 1), txData, Const(0, width: 1)].swizzle(),
          txBusy < Const(1),
          txBitIdx < Const(0, width: 4),
        ]),
      ], orElse: [
        If(txTick, then: [
          txShift < [Const(1, width: 1), txShift.slice(9, 1)].swizzle(),
          If(txBitIdx.eq(9), then: [
            txBusy < Const(0),
          ], orElse: [
            txBitIdx < txBitIdx + Const(1, width: 4),
          ]),
        ]),
      ]),
    ]);

    txPin <= txShift.slice(0, 0);
    txReady <= ~txBusy;

    // ---------------- RX Oversampling Engine ----------------
    final rxClkCounter = Logic(name: 'rxClkCounter', width: 16);
    final rxBitIdx = Logic(name: 'rxBitIdx', width: 4);
    final rxShiftReg = Logic(name: 'rxShiftReg', width: 8);
    final rxReceiving = Logic(name: 'rxReceiving');
    final rxBuf = Logic(name: 'rxBuf', width: 8);
    final rxBufValid = Logic(name: 'rxBufValid');

    Sequential(clk, reset: reset, resetValues: {
      rxClkCounter: Const(0, width: 16),
      rxBitIdx: Const(0, width: 4),
      rxShiftReg: Const(0, width: 8),
      rxReceiving: Const(0),
      rxBuf: Const(0, width: 8),
      rxBufValid: Const(0),
    }, [
      // Pop / consume buffer handshake
      If(rxReady & rxBufValid, then: [
        rxBufValid < Const(0),
      ]),

      If(~rxReceiving, then: [
        If(~rxPin, then: [
          // Falling edge indicates start bit
          rxReceiving < Const(1),
          rxBitIdx < Const(0, width: 4),
          // Sample in the middle of the start bit
          rxClkCounter < (baudDivisor >> 1),
        ]),
      ], orElse: [
        If(rxClkCounter.eq(0), then: [
          rxClkCounter < baudDivisor - Const(1, width: 16),
          If(rxBitIdx.eq(0), then: [
            // Center of Start bit: verify still 0
            If(~rxPin, then: [
              rxBitIdx < Const(1, width: 4),
            ], orElse: [
              // Glitch
              rxReceiving < Const(0),
            ]),
          ], orElse: [
            If(rxBitIdx.lte(Const(8, width: 4)), then: [
              // Sample 8 data bits LSB first
              rxShiftReg < [rxPin, rxShiftReg.slice(7, 1)].swizzle(),
              rxBitIdx < rxBitIdx + Const(1, width: 4),
            ], orElse: [
              // rxBitIdx == 9: Center of Stop bit
              rxReceiving < Const(0),
              rxBuf < rxShiftReg,
              rxBufValid < Const(1),
            ]),
          ]),
        ], orElse: [
          rxClkCounter < rxClkCounter - Const(1, width: 16),
        ]),
      ]),
    ]);

    rxData <= rxBuf;
    rxValid <= rxBufValid;
  }
}
DART_EOF

echo "==> 2. Re-assembling firmware..."
make firmware

echo "==> 3. Updating test/parcore_top_test.dart with timeout guard and correct paths..."
cat << 'DART_TEST_EOF' > hdl/parcore/test/parcore_top_test.dart
import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

/// Transmits an 8-bit byte over [uartRx] (8-N-1, LSB first).
Future<void> sendUartByte(
  Logic uartRx,
  SimpleClockGenerator clk,
  int byte, {
  int baudCycles = 8,
}) async {
  // Start bit (Low)
  uartRx.put(0);
  await clk.waitCycles(baudCycles);

  // 8 Data Bits (LSB first)
  for (int b = 0; b < 8; b++) {
    uartRx.put((byte >> b) & 1);
    await clk.waitCycles(baudCycles);
  }

  // Stop bit (High)
  uartRx.put(1);
  await clk.waitCycles(baudCycles);
}

/// Awaits start bit on [uartTx] and reads deserialized byte.
Future<int> receiveUartByte(
  Logic uartTx,
  SimpleClockGenerator clk, {
  int baudCycles = 8,
  int timeoutCycles = 1500,
}) async {
  int elapsed = 0;

  // Await falling edge (start bit)
  while (uartTx.value.isValid && uartTx.value.toInt() != 0) {
    await clk.waitCycles(1);
    elapsed++;
    if (elapsed > timeoutCycles) {
      throw TimeoutException('Timed out waiting for UART TX start bit after $elapsed cycles');
    }
  }

  if (!uartTx.value.isValid) {
    throw StateError('uartTx signal became invalid (X/Z)');
  }

  // Advance to middle of start bit
  await clk.waitCycles(baudCycles ~/ 2);

  // Read 8 data bits
  int rxByte = 0;
  for (int b = 0; b < 8; b++) {
    await clk.waitCycles(baudCycles);
    rxByte |= (uartTx.value.toInt() << b);
  }

  // Stop bit
  await clk.waitCycles(baudCycles);

  return rxByte;
}

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

      // Hold reset for 5 cycles
      await clk.waitCycles(5);
      reset.put(0);

      // Allow Core 0 to settle into polling loop
      await clk.waitCycles(20);

      const testByte = 0x41; // ASCII 'A'

      final rxFuture = receiveUartByte(top.uartTx, clk, baudCycles: 8, timeoutCycles: 1500);
      final txFuture = sendUartByte(uartRx, clk, testByte, baudCycles: 8);

      await txFuture;
      final echoedByte = await rxFuture;

      expect(echoedByte, equals(testByte), reason: "Core 0 failed to echo character back to UART TX");

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
DART_TEST_EOF

echo "==> 4. Executing parcore_top_test.dart..."
cd hdl/parcore && dart test test/parcore_top_test.dart

