// =============================================================================
// File: hdl/particle/test/particle_ulx3s_top_test.dart
// Description: Runs apps/asm/ulx3s_echo.asm on ParticleUlx3sTop: the program
//              is fetched from the synchronous block RAM model, prints its
//              banner on both UARTs and echoes bytes sent to each UART.
//              Needs build/ulx3s_echo.bin (`make apps`, or `make test-particle`
//              builds it).
// =============================================================================

import 'dart:async';
import 'dart:io';

import 'package:particle_rohd/particle_rohd.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Both UARTs run at 1 Mbps here (50 clocks per bit at 50 MHz) to keep the
/// simulation short; the real GPIO UART default is 115200.
const clockHz = 50000000;
const baud = 1000000;
const bitClocks = clockHz ~/ baud;

/// Decodes 8-N-1 bytes from a transmit pin, sampling once per clock.
class UartMonitor {
  final List<int> bytes = [];
  int _state = 0; // 0 idle, 1 receiving
  int _count = 0;
  int _bit = 0;
  int _value = 0;

  UartMonitor(Logic clk, Logic pin) {
    clk.posedge.listen((_) {
      final v = pin.value;
      if (!v.isValid) return;
      final level = v.toInt();
      if (_state == 0) {
        if (level == 0) {
          _state = 1;
          _count = bitClocks + bitClocks ~/ 2; // middle of data bit 0
          _bit = 0;
          _value = 0;
        }
      } else if (--_count == 0) {
        if (_bit < 8) {
          _value |= level << _bit;
          _bit++;
          _count = bitClocks;
        } else {
          bytes.add(_value);
          _state = 0;
        }
      }
    });
  }

  String get text => String.fromCharCodes(bytes);
}

Future<void> sendByte(Logic clk, Logic pin, int value) async {
  final bits = [0, for (var i = 0; i < 8; i++) (value >> i) & 1, 1];
  for (final b in bits) {
    pin.inject(b);
    for (var i = 0; i < bitClocks; i++) {
      await clk.nextPosedge;
    }
  }
}

Future<void> waitFor(Logic clk, bool Function() done, int maxCycles) async {
  for (var i = 0; i < maxCycles && !done(); i++) {
    await clk.nextPosedge;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('ParticleUlx3sTop runs ulx3s_echo: banner and echo on both UARTs',
      () async {
    final image = File('../../build/ulx3s_echo.bin');
    expect(image.existsSync(), isTrue,
        reason: 'build/ulx3s_echo.bin is missing: run make apps');

    final clk = SimpleClockGenerator(10).clk;
    final resetN = Logic(name: 'reset_n');
    final ftdiRx = Logic(name: 'ftdi_rx');
    final gpioRx = Logic(name: 'gpio_rx');

    final top = ParticleUlx3sTop(
      clk: clk,
      resetN: resetN,
      ftdiRxPin: ftdiRx,
      gpioRxPin: gpioRx,
      config: const CpuConfig(systemClockHz: clockHz, auxUartDefaultBaud: baud),
      ftdiBaud: baud,
      programBytes: image.readAsBytesSync(),
    );
    await top.build();

    final ftdiOut = UartMonitor(clk, top.ftdiTxPin);
    final gpioOut = UartMonitor(clk, top.gpioTxPin);

    resetN.inject(0);
    ftdiRx.inject(1);
    gpioRx.inject(1);
    Simulator.setMaxSimTime(10 * 200000);
    unawaited(Simulator.run());

    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    resetN.inject(1);

    const banner = 'Particle ULX3S\r\n';
    final bannerClocks = banner.length * bitClocks * 12;
    await waitFor(clk, () => gpioOut.text.length >= banner.length,
        bannerClocks * 2 + 2000);
    expect(ftdiOut.text, equals(banner));
    expect(gpioOut.text, equals(banner));

    // The FTDI UART echoes a byte, and so does the GPIO UART
    await sendByte(clk, ftdiRx, 0x78); // 'x'
    await waitFor(clk, () => ftdiOut.bytes.length > banner.length, bitClocks * 20);
    expect(ftdiOut.bytes.last, equals(0x78));

    await sendByte(clk, gpioRx, 0x5A); // 'Z'
    await waitFor(clk, () => gpioOut.bytes.length > banner.length, bitClocks * 20);
    expect(gpioOut.bytes.last, equals(0x5A));

    // The banner is still in memory where the program read it
    final bytes = image.readAsBytesSync();
    final at = String.fromCharCodes(bytes).indexOf('Particle');
    expect(at, greaterThan(0));
    final word = top.ram.peekWord((0x100 + at) & ~3) >> (((0x100 + at) & 3) * 8);
    expect(word & 0xFF, equals(0x50)); // 'P'

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('ParticleBlockRamTdp: synchronous reads, byte-enable writes', () async {
    final clk = SimpleClockGenerator(10).clk;
    final addrA = Logic(name: 'addrA', width: 9);
    final addrB = Logic(name: 'addrB', width: 8);
    final wData = Logic(name: 'wData', width: 32);
    final bEn = Logic(name: 'bEn', width: 4);
    final wEn = Logic(name: 'wEn');
    final ram = ParticleBlockRamTdp(
      clk: clk,
      addrA: addrA,
      addrB: addrB,
      wDataB: wData,
      bEnB: bEn,
      wEnB: wEn,
      rEnB: Const(1),
      depthWords: 256,
      initialBytes: [0x11, 0x22, 0x33, 0x44],
      loadOffset: 0x10,
    );
    await ram.build();

    addrA.inject(0x10 >> 1);
    addrB.inject(0x10 >> 2);
    wData.inject(0);
    bEn.inject(0);
    wEn.inject(0);
    Simulator.setMaxSimTime(1000);
    unawaited(Simulator.run());

    // An address set before a rising edge gives its data after that edge
    await clk.nextPosedge;
    addrA.inject((0x10 >> 1) + 1);
    await clk.nextPosedge;
    expect(ram.rDataA.value.toInt(), equals(0x4433));
    expect(ram.rDataB.value.toInt(), equals(0x44332211));

    // Write bytes 1 and 3 only; the read in the same cycle returns the old word
    wData.inject(0xAABBCCDD);
    bEn.inject(0xA);
    wEn.inject(1);
    await clk.nextPosedge;
    expect(ram.rDataB.value.toInt(), equals(0x44332211));
    wEn.inject(0);
    await clk.nextPosedge;
    expect(ram.rDataB.value.toInt(), equals(0xAA33CC11));
    expect(ram.peekWord(0x10), equals(0xAA33CC11));

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });
}
