// =============================================================================
// File: hdl/particle/test/uart_engine_test.dart
// Architecture: Particle 32-bit RISC
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// Description: Unit testbench for 8-N-1 UART Transceiver Engine verifying
//              baud tick divisor, TX shift register, and loopback RX decoding.
// =============================================================================

import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/uart_engine.dart';
import 'test_helpers.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle UART Engine Tests', () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic rxPin;
    late Logic txData;
    late Logic txValid;
    late Logic rxReady;
    late Logic baudDivisor;
    late ParticleUartEngine uart;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      rxPin = Logic(name: 'rxPin');
      txData = Logic(name: 'txData', width: 8);
      txValid = Logic(name: 'txValid');
      rxReady = Logic(name: 'rxReady');
      baudDivisor = Logic(name: 'baudDivisor', width: 16);

      uart = ParticleUartEngine(
        clk: clk.clk,
        reset: reset,
        rxPin: rxPin,
        txData: txData,
        txValid: txValid,
        rxReady: rxReady,
        baudDivisor: baudDivisor,
      );
      await uart.build();

      reset.put(1);
      rxPin.put(1); // Serial idle high
      txData.put(0);
      txValid.put(0);
      rxReady.put(1);
      baudDivisor.put(4); // 4 clock cycles per baud bit for rapid simulation

      // Start asynchronous simulator loop
      unawaited(Simulator.run());

      await clk.waitCycles(2);
      reset.put(0);
    });

    test('Transmitter starts idle and asserts txReady', () async {
      await clk.waitCycles(1);
      expect(uart.txReady.value.toInt(), equals(1));
      expect(uart.txPin.value.toInt(), equals(1)); // Line idle high
      await Simulator.endSimulation();
    });

    test('Loopback Transmission: TX pin drives RX to receive byte', () async {
      await clk.waitCycles(1);

      // Transmit byte 0x55 (binary 01010101)
      txData.put(0x55);
      txValid.put(1);
      await clk.waitCycles(1);
      txValid.put(0);

      // Verify TX transitioned to busy
      expect(uart.txReady.value.toInt(), equals(0));

      // Continuously forward TX pin to RX pin across transmission cycles
      // Baud divisor is 4, 10 bits per frame = ~40-60 cycles
      int cycles = 0;
      bool received = false;

      while (cycles < 120) {
        // Drive rxPin with current txPin output value
        rxPin.put(uart.txPin.value.toInt());
        await clk.waitCycles(1);
        cycles++;

        if (uart.rxValid.value.toInt() == 1) {
          received = true;
          break;
        }
      }

      expect(received, isTrue,
          reason: 'UART receiver timed out without asserting rxValid');
      expect(uart.rxData.value.toInt(), equals(0x55));
      await Simulator.endSimulation();
    });
  });
}
