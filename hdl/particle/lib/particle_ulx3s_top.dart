// =============================================================================
// File: hdl/particle/lib/particle_ulx3s_top.dart
// Architecture: Particle 32-bit RISC on Lattice ECP5 (ULX3S)
// Description: Top-level FPGA wrapper wiring ParticleCpuCore to the fixed 3 Mbps
//              FTDI UART, arbitrary-baud GPIO UART, and onboard LEDs/buttons.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'ftdi_uart.dart';
import 'gpio_uart.dart';

class ParticleUlx3sTop extends Module {
  Logic get clk25MHz => input('clk_25mhz');
  Logic get btnReset => input('btn_reset');

  // Dedicated Onboard FTDI USB-UART Pins (3 Mbps)
  Logic get ftdiRxd => input('ftdi_rxd');
  Logic get ftdiTxd => output('ftdi_txd');

  // Configurable Board Header Pins (PMOD / GPIO)
  Logic get gpioRx => input('gp_rx');
  Logic get gpioTx => output('gp_tx');

  // Debug onboard LEDs
  Logic get leds => output('leds');

  ParticleUlx3sTop({
    required Logic clk25MHz,
    required Logic btnReset,
    required Logic ftdiRxd,
    required Logic gpioRx,
    CpuConfig config = const CpuConfig(),
    super.name = 'particle_ulx3s_top',
  }) {
    addInput('clk_25mhz', clk25MHz);
    addInput('btn_reset', btnReset);
    addInput('ftdi_rxd', ftdiRxd);
    addInput('gp_rx', gpioRx);

    addOutput('ftdi_txd');
    addOutput('gp_tx');
    addOutput('leds', width: 8);

    _build(config);
  }

  void _build(CpuConfig config) {
    final activeLowReset = ~btnReset;

    // FTDI 3 Mbps UART (Channel 0)
    final ftdiTxData = Logic(name: 'ftdiTxData', width: 8);
    final ftdiTxValid = Logic(name: 'ftdiTxValid');
    final ftdiRxReady = Logic(name: 'ftdiRxReady');

    final ftdiUart = ParticleFtdiUart(
      clk: clk25MHz,
      reset: activeLowReset,
      ftdiRxd: ftdiRxd,
      txData: ftdiTxData,
      txValid: ftdiTxValid,
      rxReady: ftdiRxReady,
      clkFreqHz: config.systemClockHz,
      baudRate: 3000000,
    );
    ftdiTxd <= ftdiUart.ftdiTxd;

    // GPIO Configurable UART (Channel 1)
    final gpioTxData = Logic(name: 'gpioTxData', width: 8);
    final gpioTxValid = Logic(name: 'gpioTxValid');
    final gpioRxReady = Logic(name: 'gpioRxReady');
    final mmioDivisor = Logic(name: 'mmioDivisor', width: 16);
    final mmioDivisorWEn = Logic(name: 'mmioDivisorWEn');

    final gpioUart = ParticleGpioUart(
      clk: clk25MHz,
      reset: activeLowReset,
      gpioRxPin: gpioRx,
      txData: gpioTxData,
      txValid: gpioTxValid,
      rxReady: gpioRxReady,
      mmioDivisor: mmioDivisor,
      mmioDivisorWriteEn: mmioDivisorWEn,
      defaultDivisor: (config.systemClockHz / config.auxUartDefaultBaud).round(),
    );
    gpioTx <= gpioUart.gpioTxPin;

    // Dummy Memory Signals (to be wired to TDP BRAM block)
    final memARData = Logic(name: 'memARData', width: 16);
    final memBRData = Logic(name: 'memBRData', width: 32);
    final mboxStrobe = Logic(name: 'mboxStrobe');
    final mboxVector = Logic(name: 'mboxVector', width: 4);

    memARData <= Const(0, width: 16);
    memBRData <= Const(0, width: 32);
    mboxStrobe <= Const(0);
    mboxVector <= Const(0, width: 4);

    // Core Instantiation
    final core = ParticleCpuCore(
      clk: clk25MHz,
      reset: activeLowReset,
      memPortARData: memARData,
      memPortBRData: memBRData,
      mboxStrobeIn: mboxStrobe,
      mboxVectorIn: mboxVector,
      config: config,
    );

    // Tie debug LEDs to PC lower bits or status
    leds <= core.memPortAAddr.slice(7, 0);

    // Default ties for UART stream wires in top wrapper
    ftdiTxData <= Const(0, width: 8);
    ftdiTxValid <= Const(0);
    ftdiRxReady <= Const(1);
    gpioTxData <= Const(0, width: 8);
    gpioTxValid <= Const(0);
    gpioRxReady <= Const(1);
    mmioDivisor <= Const(217, width: 16);
    mmioDivisorWEn <= Const(0);
  }
}
