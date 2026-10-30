// =============================================================================
// File: hdl/rohd/test/uart_engine_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/uart_engine.dart';
import 'test_helpers.dart';

void main() {
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
      rxPin.put(1);
      txData.put(0);
      txValid.put(0);
      rxReady.put(1);
      baudDivisor.put(4);
      await clk.waitCycles(2);
      reset.put(0);
    });

    test('Transmitter starts idle and asserts txReady', () async {
      await clk.waitCycles(1);
      expect(uart.txReady.value.toInt(), equals(1));
      expect(uart.txPin.value.toInt(), equals(1));
    });
  });
}
