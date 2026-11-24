// =============================================================================
// File: hdl/parcore/lib/parcore_ulx3s_top.dart
// Architecture: Parcore on the ULX3S (ECP5-85F)
// Description: ParcoreTop with its conductor, the boot image in an on-chip
//              SPI-style ROM, and the board's reset, UART, LEDs and buttons.
// =============================================================================
//
// Instantiated by the board wrapper (ulx3sBoardVerilog in the particle
// package, with buttons), which supplies the PLL clock and the pins:
//
//   clk          system clock from the PLL
//   reset_n      the power button and PLL lock (active low)
//   ftdi_rx_pin  FTDI UART receive: the guest's UART (core 3)
//   ftdi_tx_pin  FTDI UART transmit
//   gpio_rx_pin  unused (the wrapper's second UART)
//   gpio_tx_pin  held high
//   buttons      FIRE1, FIRE2, UP, DOWN, LEFT, RIGHT (1 = pressed)
//   leds         the conductor's boot progress and fault codes, then the
//                guest's LEDs
//
// At reset the conductor (whose code is built into its TCM) holds the four
// stage cores, loads the image from the ROM over SPI into their TCMs, checks
// its CRC-32 and releases them. The stage cores' TCMs start empty.

import 'package:rohd/rohd.dart';

import 'parcore_image.dart';
import 'parcore_top.dart';
import 'spi_flash_rom.dart';

class ParcoreUlx3sTop extends Module {
  Logic get ftdiTxPin => output('ftdi_tx_pin');
  Logic get gpioTxPin => output('gpio_tx_pin');
  Logic get leds => output('leds');

  /// The ParcoreTop inside, for tests.
  late final ParcoreTop parcore;

  ParcoreUlx3sTop({
    required Logic clk,
    required Logic resetN,
    required Logic ftdiRxPin,
    required Logic gpioRxPin,
    required Logic buttons,
    required List<int> conductorBinary,
    required List<int> image,
    int clockHz = 25000000,
    String? tcmInitDir,
    String? romInitFile,
    super.name = 'parcore_ulx3s_top',
  }) : super(definitionName: 'ParcoreUlx3sTop') {
    clk = addInput('clk', clk);
    resetN = addInput('reset_n', resetN);
    ftdiRxPin = addInput('ftdi_rx_pin', ftdiRxPin);
    addInput('gpio_rx_pin', gpioRxPin);
    buttons = addInput('buttons', buttons, width: 6);
    addOutput('ftdi_tx_pin');
    addOutput('gpio_tx_pin');
    addOutput('leds', width: 8);

    // reset_n is asynchronous (a button and the PLL's lock): two flip-flops
    // bring it into the clock domain, so every part leaves reset together
    final resetMeta = Logic(name: 'reset_meta');
    final reset = Logic(name: 'reset_sync');
    Sequential(clk, [resetMeta < ~resetN, reset < resetMeta]);

    final miso = Logic(name: 'spi_miso');
    parcore = ParcoreTop(
      clk: clk,
      reset: reset,
      uartRx: ftdiRxPin,
      spiMiso: miso,
      buttons: buttons,
      clkFreqMhz: (clockHz / 1e6).round(),
      conductorBinary: conductorBinary,
      tcmInitDir: tcmInitDir,
    );
    final rom = SpiFlashRom(
      clk: clk,
      reset: reset,
      csN: parcore.spiCsN,
      sck: parcore.spiSck,
      mosi: parcore.spiMosi,
      image: image,
      baseAddr: parcoreImageFlashAddr,
      initFile: romInitFile,
    );
    miso <= rom.miso;

    ftdiTxPin <= parcore.uartTx;
    gpioTxPin <= Const(1);
    leds <= parcore.leds;
  }
}
