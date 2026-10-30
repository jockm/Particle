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
  Logic get txData => input('txData'); // 8-bit byte from FIFO
  Logic get txValid => input('txValid'); // FIFO not empty & pop strobe
  Logic get txReady =>
      output('txReady'); // Transmitter idle/ready for next byte

  Logic get rxData => output('rxData'); // 8-bit byte received
  Logic get rxValid => output('rxValid'); // Strobe to push into RX FIFO
  Logic get rxReady => input('rxReady'); // RX FIFO ready to accept byte

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

    Sequential(
      clk,
      reset: reset,
      resetValues: {txClkCounter: Const(0, width: 16)},
      [
        If(
          txClkCounter >= baudDivisor - Const(1, width: 16),
          then: [txClkCounter < Const(0, width: 16)],
          orElse: [txClkCounter < txClkCounter + Const(1, width: 16)],
        ),
      ],
    );
    txTick <= txClkCounter.eq(0);

    // ---------------- TX Shift Engine (8-N-1) ----------------
    final txBitIdx = Logic(name: 'txBitIdx', width: 4);
    final txShift = Logic(
      name: 'txShift',
      width: 10,
    ); // Start(0) + Data[7:0] + Stop(1)
    final txBusy = Logic(name: 'txBusy');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        txShift: Const(0x3FF, width: 10),
        txBitIdx: Const(0, width: 4),
        txBusy: Const(0),
      },
      [
        If(
          ~txBusy,
          then: [
            If(
              txValid,
              then: [
                // Frame: [Stop bit (1), Data bit 7..0, Start bit (0)]
                txShift <
                    [Const(1, width: 1), txData, Const(0, width: 1)].swizzle(),
                txBusy < Const(1),
                txBitIdx < Const(0, width: 4),
              ],
            ),
          ],
          orElse: [
            If(
              txTick,
              then: [
                txShift < [Const(1, width: 1), txShift.slice(9, 1)].swizzle(),
                If(
                  txBitIdx.eq(9),
                  then: [txBusy < Const(0)],
                  orElse: [txBitIdx < txBitIdx + Const(1, width: 4)],
                ),
              ],
            ),
          ],
        ),
      ],
    );

    txPin <= txShift.slice(0, 0);
    txReady <= ~txBusy;

    // ---------------- RX Oversampling Engine ----------------
    // For simplicity, samples mid-bit at 1x tick rate
    final rxBitIdx = Logic(name: 'rxBitIdx', width: 4);
    final rxShiftReg = Logic(name: 'rxShiftReg', width: 8);
    final rxReceiving = Logic(name: 'rxReceiving');
    final rxDone = Logic(name: 'rxDone');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        rxBitIdx: Const(0, width: 4),
        rxShiftReg: Const(0, width: 8),
        rxReceiving: Const(0),
        rxDone: Const(0),
      },
      [
        rxDone < Const(0),
        If(
          ~rxReceiving,
          then: [
            If(
              ~rxPin,
              then: [
                // Falling edge start bit detected
                rxReceiving < Const(1),
                rxBitIdx < Const(0, width: 4),
              ],
            ),
          ],
          orElse: [
            If(
              txTick,
              then: [
                If(
                  rxBitIdx.eq(8),
                  then: [rxReceiving < Const(0), rxDone < Const(1)],
                  orElse: [
                    rxShiftReg < [rxPin, rxShiftReg.slice(7, 1)].swizzle(),
                    rxBitIdx < rxBitIdx + Const(1, width: 4),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );

    rxData <= rxShiftReg;
    rxValid <= rxDone;
  }
}
