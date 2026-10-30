// =============================================================================
// File: hdl/rohd/lib/ftdi_uart.dart
// Architecture: Particle 32-bit RISC
// Description: ULX3S Fixed 3 Mbps FTDI hardware UART peripheral. Ties baud
//              divisor to fixed 3 Mbps rate and connects to FIFO channel interface.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'uart_engine.dart';

class ParticleFtdiUart extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // Physical board pins
  Logic get ftdiRxd => input('ftdiRxd');
  Logic get ftdiTxd => output('ftdiTxd');

  // Streaming FIFO interface (mapped to FIFO Channel 0)
  Logic get txData => input('txData');
  Logic get txValid => input('txValid');
  Logic get txReady => output('txReady');

  Logic get rxData => output('rxData');
  Logic get rxValid => output('rxValid');
  Logic get rxReady => input('rxReady');

  /// Constructor
  /// [clkFreqHz] defaults to 25 MHz (standard ULX3S oscillator)
  /// [baudRate] defaults to 3,000,000 baud
  ParticleFtdiUart({
    required Logic clk,
    required Logic reset,
    required Logic ftdiRxd,
    required Logic txData,
    required Logic txValid,
    required Logic rxReady,
    int clkFreqHz = 25000000,
    int baudRate = 3000000,
    super.name = 'ftdi_uart_peripheral',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('ftdiRxd', ftdiRxd);
    addInput('txData', txData, width: 8);
    addInput('txValid', txValid);
    addInput('rxReady', rxReady);

    addOutput('ftdiTxd');
    addOutput('txReady');
    addOutput('rxData', width: 8);
    addOutput('rxValid');

    final divisor = (clkFreqHz / baudRate).round();

    final engine = ParticleUartEngine(
      clk: clk,
      reset: reset,
      rxPin: ftdiRxd,
      txData: txData,
      txValid: txValid,
      rxReady: rxReady,
      baudDivisor: Const(divisor, width: 16),
    );

    ftdiTxd <= engine.txPin;
    txReady <= engine.txReady;
    rxData <= engine.rxData;
    rxValid <= engine.rxValid;
  }
}
