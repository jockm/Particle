// =============================================================================
// File: hdl/particle/test/uart_test.dart
// Architecture: Particle 32-bit RISC
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// Description: ParticleUartTransceiver (8-N-1): idle state, and a byte sent in
//              loopback (TX pin driving the RX pin) is received, held until
//              popped with rxReady. The FTDI and GPIO wrappers do the same at
//              their divisors.
// =============================================================================

import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/ftdi_uart.dart';
import '../lib/gpio_uart.dart';
import '../lib/uart.dart';
import 'test_helpers.dart';

/// Sends [byte] with [txData]/[txValid], wires [txPin] back to [rxPin], and
/// returns whether [rxValid] rose within [limit] cycles.
Future<bool> loopback(SimpleClockGenerator clk, Logic txData, Logic txValid,
    Logic txPin, Logic rxPin, Logic rxValid, int byte, int limit) async {
  txData.put(byte);
  txValid.put(1);
  await clk.waitCycles(1);
  txValid.put(0);
  for (var i = 0; i < limit; i++) {
    rxPin.put(txPin.value.toInt());
    await clk.waitCycles(1);
    if (rxValid.value.toInt() == 1) return true;
  }
  return false;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('ParticleUartTransceiver', () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic rxPin;
    late Logic txData;
    late Logic txValid;
    late Logic rxReady;
    late Logic baudDivisor;
    late ParticleUartTransceiver uart;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      rxPin = Logic(name: 'rxPin');
      txData = Logic(name: 'txData', width: 8);
      txValid = Logic(name: 'txValid');
      rxReady = Logic(name: 'rxReady');
      baudDivisor = Logic(name: 'baudDivisor', width: 16);

      uart = ParticleUartTransceiver(
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
      rxReady.put(0);
      baudDivisor.put(4); // 4 clock cycles per bit for a fast simulation

      unawaited(Simulator.run());

      await clk.waitCycles(2);
      reset.put(0);
    });

    test('Transmitter starts idle and asserts txReady', () async {
      await clk.waitCycles(1);
      expect(uart.txReady.value.toInt(), equals(1));
      expect(uart.txPin.value.toInt(), equals(1)); // Line idle high
      expect(uart.rxValid.value.toInt(), equals(0));
      await Simulator.endSimulation();
    });

    test('A byte sent in loopback is received and held until popped', () async {
      await clk.waitCycles(1);

      // 10 bits per frame at 4 cycles per bit: about 40 cycles
      final sending = loopback(
          clk, txData, txValid, uart.txPin, rxPin, uart.rxValid, 0x55, 120);
      await clk.waitCycles(1);
      expect(uart.txReady.value.toInt(), equals(0), reason: 'TX busy');
      expect(await sending, isTrue,
          reason: 'UART receiver timed out without asserting rxValid');
      expect(uart.rxData.value.toInt(), equals(0x55));

      // The byte stays until rxReady pops it
      await clk.waitCycles(5);
      expect(uart.rxValid.value.toInt(), equals(1));
      rxReady.put(1);
      await clk.waitCycles(1);
      rxReady.put(0);
      await clk.waitCycles(1);
      expect(uart.rxValid.value.toInt(), equals(0));
      await Simulator.endSimulation();
    });
  });

  group('UART wrappers', () {
    test('ParticleFtdiUart loops a byte back at its clock / baud divisor',
        () async {
      final clk = SimpleClockGenerator(10);
      final reset = Logic(name: 'reset');
      final rxPin = Logic(name: 'rxPin');
      final txData = Logic(name: 'txData', width: 8);
      final txValid = Logic(name: 'txValid');
      final rxReady = Logic(name: 'rxReady');
      // 8 cycles per bit
      final uart = ParticleFtdiUart(
          clk: clk.clk,
          reset: reset,
          ftdiRxd: rxPin,
          txData: txData,
          txValid: txValid,
          rxReady: rxReady,
          clkFreqHz: 8000000,
          baudRate: 1000000);
      await uart.build();
      reset.put(1);
      rxPin.put(1);
      txData.put(0);
      txValid.put(0);
      rxReady.put(0);
      unawaited(Simulator.run());
      await clk.waitCycles(2);
      reset.put(0);
      await clk.waitCycles(1);

      expect(
          await loopback(
              clk, txData, txValid, uart.ftdiTxd, rxPin, uart.rxValid, 0xA3, 200),
          isTrue);
      expect(uart.rxData.value.toInt(), equals(0xA3));
      await Simulator.endSimulation();
    });

    test('ParticleGpioUart uses the divisor written to it', () async {
      final clk = SimpleClockGenerator(10);
      final reset = Logic(name: 'reset');
      final rxPin = Logic(name: 'rxPin');
      final txData = Logic(name: 'txData', width: 8);
      final txValid = Logic(name: 'txValid');
      final rxReady = Logic(name: 'rxReady');
      final divisor = Logic(name: 'divisor', width: 16);
      final divisorWe = Logic(name: 'divisorWe');
      final uart = ParticleGpioUart(
          clk: clk.clk,
          reset: reset,
          gpioRxPin: rxPin,
          txData: txData,
          txValid: txValid,
          rxReady: rxReady,
          mmioDivisor: divisor,
          mmioDivisorWriteEn: divisorWe);
      await uart.build();
      reset.put(1);
      rxPin.put(1);
      txData.put(0);
      txValid.put(0);
      rxReady.put(0);
      divisor.put(6);
      divisorWe.put(0);
      unawaited(Simulator.run());
      await clk.waitCycles(2);
      reset.put(0);
      // Default 217 cycles per bit would take over 2000 cycles; 6 takes ~60
      divisorWe.put(1);
      await clk.waitCycles(1);
      divisorWe.put(0);
      await clk.waitCycles(1);

      expect(
          await loopback(clk, txData, txValid, uart.gpioTxPin, rxPin,
              uart.rxValid, 0x3C, 150),
          isTrue);
      expect(uart.rxData.value.toInt(), equals(0x3C));
      await Simulator.endSimulation();
    });
  });
}
