// =============================================================================
// File: hdl/rohd/lib/gpio_uart.dart
// Architecture: Particle 32-bit RISC
// Description: Configurable GPIO UART Peripheral supporting arbitrary baud rates
//              via MMIO divisor register and routed to board PMOD / GPIO headers.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'uart_engine.dart';

class ParticleGpioUart extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // External board pins (PMOD / GPIO headers)
  Logic get gpioRxPin => input('gpioRxPin');
  Logic get gpioTxPin => output('gpioTxPin');

  // Streaming FIFO interface (mapped to FIFO Channel 1)
  Logic get txData => input('txData');
  Logic get txValid => input('txValid');
  Logic get txReady => output('txReady');

  Logic get rxData => output('rxData');
  Logic get rxValid => output('rxValid');
  Logic get rxReady => input('rxReady');

  // MMIO Config / Control Interface for dynamic baud selection
  Logic get mmioDivisor => input('mmioDivisor');
  Logic get mmioDivisorWriteEn => input('mmioDivisorWriteEn');

  ParticleGpioUart({
    required Logic clk,
    required Logic reset,
    required Logic gpioRxPin,
    required Logic txData,
    required Logic txValid,
    required Logic rxReady,
    required Logic mmioDivisor,
    required Logic mmioDivisorWriteEn,
    int defaultDivisor = 217, // ~115200 baud at 25MHz
    super.name = 'gpio_uart_peripheral',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('gpioRxPin', gpioRxPin);
    addInput('txData', txData, width: 8);
    addInput('txValid', txValid);
    addInput('rxReady', rxReady);
    addInput('mmioDivisor', mmioDivisor, width: 16);
    addInput('mmioDivisorWriteEn', mmioDivisorWriteEn);

    addOutput('gpioTxPin');
    addOutput('txReady');
    addOutput('rxData', width: 8);
    addOutput('rxValid');

    _build(defaultDivisor);
  }

  void _build(int defaultDivisor) {
    // Programmable Baud Divisor Register
    final activeDivisor = Logic(name: 'activeDivisor', width: 16);
    Sequential(clk, reset: reset, resetValues: {
      activeDivisor: Const(defaultDivisor, width: 16),
    }, [
      If(mmioDivisorWriteEn, then: [
        activeDivisor < mmioDivisor,
      ]),
    ]);

    final engine = ParticleUartEngine(
      clk: clk,
      reset: reset,
      rxPin: gpioRxPin,
      txData: txData,
      txValid: txValid,
      rxReady: rxReady,
      baudDivisor: activeDivisor,
    );

    gpioTxPin <= engine.txPin;
    txReady <= engine.txReady;
    rxData <= engine.rxData;
    rxValid <= engine.rxValid;
  }
}
