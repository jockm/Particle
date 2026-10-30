// =============================================================================
// File: hdl/rohd/lib/uart_engine.dart
// Architecture: Particle 32-bit RISC
// Description: Core parameterized 8-N-1 UART Transceiver engine with configurable
//              baud rate divider and streaming handshake interface.
// =============================================================================

import 'package:rohd/rohd.dart';

class ParticleUartEngine extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // Physical serial pins
  Logic get rxPin => input('rxPin');
  Logic get txPin => output('txPin');

  // Core / FIFO Streaming Transmit Interface
  Logic get txData => input('txData');      // 8-bit byte to transmit
  Logic get txValid => input('txValid');    // Push strobe from TX FIFO
  Logic get txReady => output('txReady');   // Transmitter idle / ready for next byte

  // Core / FIFO Streaming Receive Interface
  Logic get rxData => output('rxData');    // 8-bit byte received
  Logic get rxValid => output('rxValid');  // Push strobe into RX FIFO
  Logic get rxReady => input('rxReady');   // RX FIFO ready to receive

  // Programmable clock divider for baud rate generation
  Logic get baudDivisor => input('baudDivisor');

  ParticleUartEngine({
    required Logic clk,
    required Logic reset,
    required Logic rxPin,
    required Logic txData,
    required Logic txValid,
    required Logic rxReady,
    required Logic baudDivisor,
    super.name = 'particle_uart_engine',
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
      If(txClkCounter >= (baudDivisor - Const(1, width: 16)), then: [
        txClkCounter < Const(0, width: 16),
      ], orElse: [
        txClkCounter < txClkCounter + Const(1, width: 16),
      ]),
    ]);
    txTick <= txClkCounter.eq(0);

    // ---------------- TX Shift Engine (8-N-1) ----------------
    final txBitIdx = Logic(name: 'txBitIdx', width: 4);
    final txShift = Logic(name: 'txShift', width: 10); // Stop(1) + Data[7:0] + Start(0)
    final txBusy = Logic(name: 'txBusy');

    Sequential(clk, reset: reset, resetValues: {
      txShift: Const(0x3FF, width: 10),
      txBitIdx: Const(0, width: 4),
      txBusy: Const(0),
    }, [
      If(~txBusy, then: [
        If(txValid, then: [
          // Frame format: [Stop bit (1), Data bit 7..0, Start bit (0)]
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

    // ---------------- RX 2FF Synchronizer & Receiver Engine ----------------
    final rxSync1 = Logic(name: 'rxSync1');
    final rxSync2 = Logic(name: 'rxSync2');
    Sequential(clk, reset: reset, resetValues: {rxSync1: Const(1), rxSync2: Const(1)}, [
      rxSync1 < rxPin,
      rxSync2 < rxSync1,
    ]);

    final rxBitIdx = Logic(name: 'rxBitIdx', width: 4);
    final rxShiftReg = Logic(name: 'rxShiftReg', width: 8);
    final rxReceiving = Logic(name: 'rxReceiving');
    final rxDone = Logic(name: 'rxDone');

    Sequential(clk, reset: reset, resetValues: {
      rxBitIdx: Const(0, width: 4),
      rxShiftReg: Const(0, width: 8),
      rxReceiving: Const(0),
      rxDone: Const(0),
    }, [
      rxDone < Const(0),
      If(~rxReceiving, then: [
        If(~rxSync2, then: [ // Falling edge indicates start bit
          rxReceiving < Const(1),
          rxBitIdx < Const(0, width: 4),
        ]),
      ], orElse: [
        If(txTick, then: [
          If(rxBitIdx.eq(8), then: [
            rxReceiving < Const(0),
            rxDone < Const(1),
          ], orElse: [
            rxShiftReg < [rxSync2, rxShiftReg.slice(7, 1)].swizzle(),
            rxBitIdx < rxBitIdx + Const(1, width: 4),
          ]),
        ]),
      ]),
    ]);

    rxData <= rxShiftReg;
    rxValid <= rxDone;
  }
}
