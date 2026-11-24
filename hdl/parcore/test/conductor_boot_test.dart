// =============================================================================
// File: hdl/parcore/test/conductor_boot_test.dart
// Architecture: Parcore Conductor System Lifecycle & Boot Verification
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================
//
// The conductor (build/parcore/conductor/conductor.bin) loads a format 2
// image from a SpiFlashRom on ParcoreTop's SPI pins, as on the board.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../../particle/test/test_helpers.dart';
import '../lib/parcore_image.dart';
import '../lib/parcore_top.dart';
import '../lib/spi_flash_rom.dart';

Uint8List _words(List<int> words) {
  final b = Uint8List(words.length * 4);
  final bd = ByteData.sublistView(b);
  for (var i = 0; i < words.length; i++) {
    bd.setUint32(i * 4, words[i], Endian.little);
  }
  return b;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final condBinFile = File('../../build/parcore/conductor/conductor.bin');

  // Builds ParcoreTop with the conductor and a SpiFlashRom holding [image],
  // runs until the conductor releases the cores or shows a fault (STATUS
  // bits 3:0 not zero while the cores are held), and returns the top.
  Future<ParcoreTop> boot(List<int> image,
      {required Future<void> Function(ParcoreTop top) check}) async {
    final clk = SimpleClockGenerator(10);
    final reset = Logic(name: 'reset');
    final uartRx = Logic(name: 'uart_rx');
    final spiMiso = Logic(name: 'spi_miso');
    final top = ParcoreTop(
      clk: clk.clk,
      reset: reset,
      uartRx: uartRx,
      spiMiso: spiMiso,
      conductorBinary: condBinFile.readAsBytesSync(),
    );
    final rom = SpiFlashRom(
      clk: clk.clk,
      reset: reset,
      csN: top.spiCsN,
      sck: top.spiSck,
      mosi: top.spiMosi,
      image: image,
      baseAddr: parcoreImageFlashAddr,
    );
    spiMiso <= rom.miso;
    await top.build();
    await rom.build();

    final rstCtrl =
        top.internalSignals.firstWhere((s) => s.name == 'reg_rst_ctrl');
    final status =
        top.internalSignals.firstWhere((s) => s.name == 'reg_status');
    reset.put(1);
    uartRx.put(1);
    unawaited(Simulator.run());
    try {
      await clk.waitCycles(5);
      reset.put(0);
      for (var cycle = 0; cycle < 60000; cycle++) {
        await clk.waitCycles(1);
        final r = rstCtrl.value, st = status.value;
        if (!r.isValid || !st.isValid) continue;
        if (r.toInt() == 0x80000000) {
          // Released: give the conductor a moment to hand over the LEDs
          await clk.waitCycles(50);
          break;
        }
        // A fault: the cores held and the code on LEDs 0-3 with LED 7 on
        // (the fault display's first state). The boot-progress pattern
        // lights LED 0 and one more per section, so with LED 7 on its low
        // seven bits are all ones, never a code of 1 to 5.
        final lowBits = st.toInt() & 0x7F;
        if (r.toInt() == 0x3F &&
            (st.toInt() & 0x180) == 0x80 &&
            lowBits >= 1 &&
            lowBits <= 5) {
          break;
        }
      }
      await check(top);
    } finally {
      await Simulator.endSimulation();
    }
    return top;
  }

  int rst(ParcoreTop top) => top.internalSignals
      .firstWhere((s) => s.name == 'reg_rst_ctrl')
      .value
      .toInt();
  int status(ParcoreTop top) => top.internalSignals
      .firstWhere((s) => s.name == 'reg_status')
      .value
      .toInt();
  dynamic tcm(ParcoreTop top, int core) =>
      top.subModules.firstWhere((m) => m.name == 'core${core}_tcm') as dynamic;

  final core0Code = _words([0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00]);
  final core1Code = _words([0xCAFEBABE, 0xDEADBEEF]);
  final shared = _words([0x0BADF00D, 0x12345678]);
  Uint8List goodImage() => buildParcoreImage([
        ParcoreImageSection(1 << 0, 0x100, core0Code),
        ParcoreImageSection(1 << 1, 0x100, core1Code),
        // One section written into two cores (0 and 3)
        ParcoreImageSection((1 << 0) | (1 << 3), 0x200, shared),
      ]);

  group('Parcore Conductor Boot & Staging Verification', () {
    test(
        'ParcoreTop elaborates Conductor and SPI controller into SystemVerilog',
        () async {
      final top = ParcoreTop(
        clk: SimpleClockGenerator(10).clk,
        reset: Logic(name: 'reset'),
        uartRx: Logic(name: 'uart_rx'),
        conductorBinary: condBinFile.readAsBytesSync(),
      );
      await top.build();
      final sv = top.generateSynth();
      expect(sv, contains('module ParcoreTop'));
      expect(sv, contains('SpiController'));
      expect(sv, contains('parcore_conductor'));
    });

    test(
        'Conductor loads a format 2 image, checks its CRC-32 and releases the cores',
        () async {
      await boot(goodImage(), check: (top) async {
        expect(rst(top), equals(0x80000000),
            reason: 'cores released, boot complete');
        expect(status(top), equals(0x100), reason: 'the guest has the LEDs');
        expect(
            [0x100, 0x104, 0x108, 0x10C]
                .map((a) => tcm(top, 0).readWord(a))
                .toList(),
            equals([0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00]));
        expect([0x100, 0x104].map((a) => tcm(top, 1).readWord(a)).toList(),
            equals([0xCAFEBABE, 0xDEADBEEF]));
        for (final core in [0, 3]) {
          expect([0x200, 0x204].map((a) => tcm(top, core).readWord(a)).toList(),
              equals([0x0BADF00D, 0x12345678]),
              reason: 'the shared section in core $core');
        }
        expect([0x200, 0x204].map((a) => tcm(top, 1).readWord(a)).toList(),
            isNot(equals([0x0BADF00D, 0x12345678])),
            reason: 'not in core 1');
      });
    }, timeout: const Timeout(Duration(minutes: 20)));

    // Each fault leaves the cores held and shows its code on LEDs 0-3
    Future<void> expectFault(List<int> image, int code) =>
        boot(image, check: (top) async {
          expect(rst(top), equals(0x3F), reason: 'every core still held');
          expect(status(top) & 0x10F, equals(code),
              reason: 'fault code $code on LEDs 0-3');
        });

    Uint8List patched(void Function(ByteData bd) change, {bool fixCrc = true}) {
      final image = goodImage();
      final bd = ByteData.sublistView(image);
      change(bd);
      if (fixCrc) {
        bd.setUint32(8, 0, Endian.little);
        bd.setUint32(8, parcoreCrc32(image), Endian.little);
      }
      return image;
    }

    test('Fault 1: bad magic', () async {
      await expectFault(
          patched((bd) => bd.setUint32(0, 0x50415244, Endian.little)), 1);
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('Fault 2: not format version 2 (a version 1 image has 0 there)',
        () async {
      await expectFault(patched((bd) => bd.setUint32(12, 0, Endian.little)), 2);
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('Fault 3: more than 8 sections', () async {
      await expectFault(patched((bd) => bd.setUint32(4, 9, Endian.little)), 3);
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('Fault 4: a section for core 6', () async {
      await expectFault(
          patched((bd) => bd.setUint32(16, 1 << 6, Endian.little)), 4);
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('Fault 5: CRC-32 mismatch (one payload bit flipped)', () async {
      await expectFault(
          patched(
              (bd) => bd.setUint8(
                  bd.lengthInBytes - 1, bd.getUint8(bd.lengthInBytes - 1) ^ 1),
              fixCrc: false),
          5);
    }, timeout: const Timeout(Duration(minutes: 20)));
  });

  test('CRC-32 matches the standard check value', () {
    // The CRC-32 of "123456789" is 0xCBF43926 (zlib, Python's binascii)
    expect(parcoreCrc32('123456789'.codeUnits), equals(0xCBF43926));
  });
}
