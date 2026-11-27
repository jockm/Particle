// =============================================================================
// File: hdl/particle/lib/particle_ulx3s_top.dart
// Architecture: Particle 32-bit RISC on Lattice ECP5 (ULX3S)
// Description: Board-level design for the ULX3S: one ParticleCpuCore with
//              64 KiB of block RAM, the FTDI USB UART on FIFO channel 0 and a
//              GPIO UART on FIFO channel 1, and the PC shown on the LEDs.
// =============================================================================
//
// The clock comes from the PLL in the board wrapper (lib/ulx3s_board.dart),
// which also maps these ports to the ULX3S pin names. This module is plain
// ROHD, so it can be simulated directly.
//
// FIFO channels, as the core sees them:
//   channel 0: FTDI UART (default 1 Mbps)
//   channel 1: GPIO UART (default 115200 baud, CpuConfig.auxUartDefaultBaud)
//   channels 2, 3: none (FIFO.STAT reports empty and full)
// FIFO.STAT bit 0 = no byte received, bit 1 = transmitter busy. Each UART
// holds one received byte and sends one byte at a time: FIFO.W while the
// transmitter is busy drops the byte, so check bit 1 first or use FIFO.TRYW.

import 'package:rohd/rohd.dart';

import 'block_ram_tdp.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'uart.dart';

class ParticleUlx3sTop extends Module {
  Logic get clk => input('clk');

  /// Active-low reset: low resets the core (button pressed or PLL unlocked).
  Logic get resetN => input('reset_n');

  Logic get ftdiRxPin => input('ftdi_rx_pin');
  Logic get ftdiTxPin => output('ftdi_tx_pin');
  Logic get gpioRxPin => input('gpio_rx_pin');
  Logic get gpioTxPin => output('gpio_tx_pin');
  Logic get leds => output('leds');

  final CpuConfig config;
  final int ftdiBaud;

  /// The memory, for tests that want to look inside it.
  late final ParticleBlockRamTdp ram;

  ParticleUlx3sTop({
    required Logic clk,
    required Logic resetN,
    required Logic ftdiRxPin,
    required Logic gpioRxPin,
    this.config = const CpuConfig(systemClockHz: 35000000),
    this.ftdiBaud = 1000000,
    List<int>? programBytes,
    int programBase = 0x100,
    String? initFileBank0,
    String? initFileBank1,
    super.name = 'particle_ulx3s_top',
  }) : super(definitionName: 'particle_ulx3s_top') {
    addInput('clk', clk);
    addInput('reset_n', resetN);
    addInput('ftdi_rx_pin', ftdiRxPin);
    addInput('gpio_rx_pin', gpioRxPin);
    addOutput('ftdi_tx_pin');
    addOutput('gpio_tx_pin');
    addOutput('leds', width: 8);
    _build(programBytes, programBase, initFileBank0, initFileBank1);
  }

  void _build(List<int>? programBytes, int programBase, String? initFileBank0,
      String? initFileBank1) {
    // -------------------------------------------------------------------------
    // Reset: synchronize reset_n, then hold the core in reset for 16 cycles
    // -------------------------------------------------------------------------
    final rstMeta = Logic(name: 'rstMeta');
    final rstReq = Logic(name: 'rstReq');
    Sequential(clk, [
      rstMeta < ~resetN,
      rstReq < rstMeta,
    ]);
    final rstCount = Logic(name: 'rstCount', width: 4);
    Sequential(clk, reset: rstReq, resetValues: {
      rstCount: Const(0, width: 4),
    }, [
      If(~rstCount.eq(Const(15, width: 4)), then: [
        rstCount < rstCount + Const(1, width: 4),
      ]),
    ]);
    final coreReset = Logic(name: 'coreReset');
    coreReset <= ~rstCount.eq(Const(15, width: 4));

    // -------------------------------------------------------------------------
    // Receive pins: two-flop synchronizers (the UART samples them directly)
    // -------------------------------------------------------------------------
    Logic syncPin(Logic pin, String name) {
      final s1 = Logic(name: '${name}Sync1');
      final s2 = Logic(name: '${name}Sync2');
      Sequential(clk, reset: coreReset, resetValues: {
        s1: Const(1),
        s2: Const(1),
      }, [
        s1 < pin,
        s2 < s1,
      ]);
      return s2;
    }

    final ftdiRx = syncPin(ftdiRxPin, 'ftdiRx');
    final gpioRx = syncPin(gpioRxPin, 'gpioRx');

    // -------------------------------------------------------------------------
    // Core
    // -------------------------------------------------------------------------
    final memARData = Logic(name: 'memARData', width: 16);
    final memBRData = Logic(name: 'memBRData', width: 32);
    final fifoPopData = Logic(name: 'fifoPopData', width: 32);
    final fifoStatus = Logic(name: 'fifoStatus', width: 32);

    final core = ParticleCpuCore(
      clk: clk,
      reset: coreReset,
      memPortARData: memARData,
      memPortBRData: memBRData,
      mboxStrobeIn: Const(0),
      mboxVectorIn: Const(0, width: 4),
      fifoPopData: fifoPopData,
      fifoStatus: fifoStatus,
      config: config,
    );

    // -------------------------------------------------------------------------
    // Memory: 64 KiB of synchronous block RAM (tcmSizeBytes)
    // -------------------------------------------------------------------------
    final memBytes = config.tcmSizeBytes;
    final addrBits = (memBytes - 1).bitLength; // 16 for 64 KiB
    ram = ParticleBlockRamTdp(
      clk: clk,
      addrA: core.memPortAAddr.slice(addrBits - 1, 1),
      addrB: core.memPortBAddr.slice(addrBits - 1, 2),
      wDataB: core.memPortBWData,
      bEnB: core.memPortBBEn,
      wEnB: core.memPortBWEn,
      rEnB: core.memPortBREn,
      depthWords: memBytes ~/ 4,
      initialBytes: programBytes,
      loadOffset: programBase,
      initFileBank0: initFileBank0,
      initFileBank1: initFileBank1,
      name: 'ram',
    );
    memARData <= ram.rDataA;
    memBRData <= ram.rDataB;

    // -------------------------------------------------------------------------
    // UARTs on FIFO channels 0 and 1
    // -------------------------------------------------------------------------
    final chan = core.fifoChanSelect;
    final isCh0 = chan.eq(Const(0, width: 2));
    final isCh1 = chan.eq(Const(1, width: 2));
    final txByte = core.fifoPushData.slice(7, 0);

    final ftdiUart = ParticleUartTransceiver(
      clk: clk,
      reset: coreReset,
      rxPin: ftdiRx,
      txData: txByte,
      txValid: core.fifoPushEn & isCh0,
      rxReady: core.fifoPopEn & isCh0,
      baudDivisor: Const((config.systemClockHz / ftdiBaud).round(), width: 16),
      name: 'ftdi_uart',
    );
    final gpioUart = ParticleUartTransceiver(
      clk: clk,
      reset: coreReset,
      rxPin: gpioRx,
      txData: txByte,
      txValid: core.fifoPushEn & isCh1,
      rxReady: core.fifoPopEn & isCh1,
      baudDivisor: Const(
          (config.systemClockHz / config.auxUartDefaultBaud).round(),
          width: 16),
      name: 'gpio_uart',
    );
    ftdiTxPin <= ftdiUart.output('txPin');
    gpioTxPin <= gpioUart.output('txPin');

    Logic statusOf(ParticleUartTransceiver u) => [
          Const(0, width: 30),
          ~u.output('txReady'),
          ~u.output('rxValid'),
        ].concat();

    fifoStatus <= mux(
      isCh0,
      statusOf(ftdiUart),
      mux(isCh1, statusOf(gpioUart), Const(3, width: 32)),
    );
    fifoPopData <= mux(
      isCh1,
      gpioUart.output('rxData').zeroExtend(32),
      ftdiUart.output('rxData').zeroExtend(32),
    );

    // -------------------------------------------------------------------------
    // LEDs: low byte of the fetch address
    // -------------------------------------------------------------------------
    leds <= core.memPortAAddr.slice(7, 0);
  }
}
