// =============================================================================
// File: hdl/particle/lib/ftdi_uart.dart
// Architecture: Particle 32-bit RISC
// Description: ULX3S FTDI UART peripheral: a ParticleUartTransceiver with its
//              divisor fixed by the clock and baud rate (1 Mbps by default,
//              as in ParticleUlx3sTop and ParcoreTop).
// =============================================================================

import 'package:rohd/rohd.dart';
import 'uart.dart';

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

  // rxValid is high while a received byte waits; rxReady pops it
  Logic get rxData => output('rxData');
  Logic get rxValid => output('rxValid');
  Logic get rxReady => input('rxReady');

  /// Constructor
  /// [clkFreqHz] defaults to 25 MHz (standard ULX3S oscillator)
  /// [baudRate] defaults to 1,000,000 baud
  ParticleFtdiUart({
    required Logic clk,
    required Logic reset,
    required Logic ftdiRxd,
    required Logic txData,
    required Logic txValid,
    required Logic rxReady,
    int clkFreqHz = 25000000,
    int baudRate = 1000000,
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
    if (divisor < 2 || divisor > 0xFFFF) {
      throw ArgumentError(
          'baudRate $baudRate gives divisor $divisor at $clkFreqHz Hz; it must be 2 to 65535');
    }

    // The transceiver connects to this module's own ports (the getters),
    // not to the signals passed in
    final engine = ParticleUartTransceiver(
      clk: input('clk'),
      reset: input('reset'),
      rxPin: input('ftdiRxd'),
      txData: input('txData'),
      txValid: input('txValid'),
      rxReady: input('rxReady'),
      baudDivisor: Const(divisor, width: 16),
    );

    ftdiTxd <= engine.txPin;
    txReady <= engine.txReady;
    rxData <= engine.rxData;
    rxValid <= engine.rxValid;
  }
}
