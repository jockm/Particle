// =============================================================================
// File: hdl/parcore/lib/parcore_ulx3s_top.dart
// Architecture: Parcore on the ULX3S (ECP5-85F)
// Description: ParcoreTop with its conductor, the boot image in an on-chip
//              SPI-style ROM (or, with realFlash, the board's flash), and the
//              board's reset, UART, LEDs and buttons.
// =============================================================================
//
// Instantiated by the board wrapper (ulx3sBoardVerilog in the particle
// package, with buttons), which supplies the PLL clock and the pins:
//
//   clk          system clock from the PLL
//   reset_n      the power button and PLL lock (active low)
//   ftdi_rx_pin  FTDI UART receive: the guest's UART (core 3)
//   ftdi_tx_pin  FTDI UART transmit
//   gpio_rx_pin  the pmon console's UART receive (gp[1], the wrapper's second
//                UART)
//   gpio_tx_pin  the pmon console's UART transmit (gp[0])
//   buttons      FIRE1, FIRE2, UP, DOWN, LEFT, RIGHT (1 = pressed)
//   leds         the conductor's boot progress and fault codes, then the
//                guest's LEDs
//
// With realFlash (PARCORE_REAL_FLASH=1; 448, 449), there is no ROM: the
// conductor's SPI lines go to the board's flash, which pmon can then erase
// and program (STATUS bit 9), and the image is read from it:
//
//   flash_csn, flash_mosi  out
//   flash_sck              out: the wrapper gives it to the flash through
//                          the ECP5's USRMCLK (the flash's clock is the
//                          configuration clock pin)
//   flash_miso             in
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
  Logic get flashCsN => output('flash_csn');
  Logic get flashSck => output('flash_sck');
  Logic get flashMosi => output('flash_mosi');

  /// The board's flash, not the on-chip ROM.
  final bool realFlash;

  /// The ParcoreTop inside, for tests.
  late final ParcoreTop parcore;

  ParcoreUlx3sTop({
    required Logic clk,
    required Logic resetN,
    required Logic ftdiRxPin,
    required Logic gpioRxPin,
    required Logic buttons,
    required List<int> conductorBinary,
    List<int>? image,
    this.realFlash = false,
    Logic? flashMiso,
    int clockHz = 25000000,
    String? tcmInitDir,
    String? romInitFile,
    super.name = 'parcore_ulx3s_top',
  }) : super(definitionName: 'ParcoreUlx3sTop') {
    if (realFlash ? flashMiso == null : image == null) {
      throw ArgumentError(realFlash
          ? 'realFlash needs flashMiso'
          : 'the on-chip ROM needs an image');
    }
    clk = addInput('clk', clk);
    resetN = addInput('reset_n', resetN);
    ftdiRxPin = addInput('ftdi_rx_pin', ftdiRxPin);
    final gpioRx = addInput('gpio_rx_pin', gpioRxPin);
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
      consoleRx: gpioRx,
      spiMiso: miso,
      buttons: buttons,
      clkFreqMhz: (clockHz / 1e6).round(),
      flashWritable: realFlash,
      conductorBinary: conductorBinary,
      tcmInitDir: tcmInitDir,
    );
    if (realFlash) {
      miso <= addInput('flash_miso', flashMiso!);
      addOutput('flash_csn') <= parcore.spiCsN;
      addOutput('flash_sck') <= parcore.spiSck;
      addOutput('flash_mosi') <= parcore.spiMosi;
    } else {
      final rom = SpiFlashRom(
        clk: clk,
        reset: reset,
        csN: parcore.spiCsN,
        sck: parcore.spiSck,
        mosi: parcore.spiMosi,
        image: image!,
        baseAddr: parcoreImageFlashAddr,
        initFile: romInitFile,
      );
      miso <= rom.miso;
    }

    ftdiTxPin <= parcore.uartTx;
    gpioTxPin <= parcore.consoleTx;
    leds <= parcore.leds;
  }
}
