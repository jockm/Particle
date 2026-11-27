// =============================================================================
// File: hdl/particle/lib/panog2_uart_rohd.dart
// Architecture: Particle on the Pano Logic G2 (Spartan-6)
// Description: The Pano G2's serial console test built from Particle's own
//              UART (ParticleFtdiUart): what arrives is sent back. The first
//              ROHD design for the G2, and the test of its path to ISE:
//              ROHD's SystemVerilog, converted to Verilog-2001 with sv2v
//              (make pano-uart-rohd).
// =============================================================================
//
// Its ports match boards/panog2/panog2_uart.ucf (the hand-written
// panog2_uart.v's): clk on Y13, uart_rx C17 and uart_tx C14 (the DVI
// connector's DDC pins), button H12 (not used), and the LEDs: green for about
// 50 ms after a character is received, blue while one is being sent and for
// about 50 ms after (so typing shows cyan).
//
// There is no reset pin: a counter holds the UART in reset for the first 16
// cycles after configuration (an FPGA's flip-flops start at zero).

import 'package:rohd/rohd.dart';

import 'ftdi_uart.dart';

class PanoG2UartRohd extends Module {
  PanoG2UartRohd({
    required Logic clk,
    required Logic uartRx,
    required Logic button,
    int clkFreqHz = 25000000,
    int baudRate = 1000000,
  }) : super(name: 'panog2_uart_rohd', definitionName: 'panog2_uart_rohd') {
    clk = addInput('clk', clk);
    uartRx = addInput('uart_rx', uartRx);
    addInput('button', button);
    final uartTx = addOutput('uart_tx');
    final ledRed = addOutput('led_red');
    final ledGreen = addOutput('led_green');
    final ledBlue = addOutput('led_blue');

    // Power-on reset: high until the counter reaches 15
    final porCount = Logic(name: 'por_count', width: 4);
    final reset = (~porCount.eq(Const(15, width: 4))).named('por_reset');
    Sequential(clk, [
      If(reset, then: [porCount < porCount + 1]),
    ]);

    // The receive pin through two flip-flops (the UART samples it directly)
    final rxMeta = Logic(name: 'rx_meta');
    final rxSync = Logic(name: 'rx_sync');
    Sequential(clk, [rxMeta < uartRx, rxSync < rxMeta]);

    // Echo: a received byte goes out when the transmitter is ready
    final txReady = Logic(name: 'tx_ready');
    final rxValid = Logic(name: 'rx_valid');
    final take = (rxValid & txReady).named('take');
    final txData = Logic(name: 'tx_data', width: 8);
    final uart = ParticleFtdiUart(
      clk: clk,
      reset: reset,
      ftdiRxd: rxSync,
      txData: txData,
      txValid: take,
      rxReady: take,
      clkFreqHz: clkFreqHz,
      baudRate: baudRate,
    );
    txData <= uart.rxData;
    txReady <= uart.txReady;
    rxValid <= uart.rxValid;
    uartTx <= uart.ftdiTxd;

    // The LED: each colour on for ~50 ms after its event
    final flash = clkFreqHz ~/ 20;
    final width = flash.bitLength;
    Logic stretch(Logic event, String name) {
      final count = Logic(name: name, width: width);
      Sequential(clk, reset: reset, resetValues: {
        count: Const(0, width: width),
      }, [
        If(event, then: [
          count < Const(flash, width: width),
        ], orElse: [
          If(~count.eq(0), then: [count < count - 1]),
        ]),
      ]);
      return ~count.eq(0);
    }

    ledGreen <= stretch(take, 'green_count');
    ledBlue <= stretch(~txReady, 'blue_count');
    ledRed <= Const(0);
  }
}
