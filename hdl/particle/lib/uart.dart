// =============================================================================
// File: hdl/particle/lib/uart.dart
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
    // ---------------- TX Shift Engine (8-N-1) ----------------
    final txClkCounter = Logic(name: 'txClkCounter', width: 16);
    final txBitIdx = Logic(name: 'txBitIdx', width: 4);
    final txShift = Logic(name: 'txShift', width: 10); // Start(0) + Data[7:0] + Stop(1)
    final txBusy = Logic(name: 'txBusy');

    Sequential(clk, reset: reset, resetValues: {
      txClkCounter: Const(0, width: 16),
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
          // Reset counter so start bit is held for the full baudDivisor period
          txClkCounter < baudDivisor - Const(1, width: 16),
        ]),
      ], orElse: [
        If(txClkCounter.eq(0), then: [
          txClkCounter < baudDivisor - Const(1, width: 16),
          txShift < [Const(1, width: 1), txShift.slice(9, 1)].swizzle(),
          If(txBitIdx.eq(9), then: [
            txBusy < Const(0),
          ], orElse: [
            txBitIdx < txBitIdx + Const(1, width: 4),
          ]),
        ], orElse: [
          txClkCounter < txClkCounter - Const(1, width: 16),
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
