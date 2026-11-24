// =============================================================================
// File: hdl/parcore/test/spi_flash_rom_test.dart
// Description: SpiFlashRom read through the conductor's SPI controller.
// =============================================================================

import 'dart:async';
import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../particle/test/test_helpers.dart';
import '../lib/spi_controller.dart';
import '../lib/spi_flash_rom.dart';

const _ctrl = 0xF0000010;
const _data = 0xF0000014;
const _div = 0xF0000018;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Drives the controller's registers as the conductor does (one write per
  // cycle), with the ROM on its pins
  Future<void> run(int spiDiv) async {
    final clk = SimpleClockGenerator(10);
    final reset = Logic(name: 'reset');
    final addr = Logic(name: 'addr', width: 32);
    final wData = Logic(name: 'wData', width: 32);
    final wEn = Logic(name: 'wEn');
    final rEn = Logic(name: 'rEn');
    final miso = Logic(name: 'miso');
    final spi = SpiController(
      clk: clk.clk,
      reset: reset,
      addr: addr,
      wData: wData,
      wEn: wEn,
      rEn: rEn,
      spiMiso: miso,
    );
    final rnd = Random(7);
    const base = 0x00400000;
    final image = List<int>.generate(1000, (_) => rnd.nextInt(256));
    final rom = SpiFlashRom(
      clk: clk.clk,
      reset: reset,
      csN: spi.spiCsN,
      sck: spi.spiSck,
      mosi: spi.spiMosi,
      image: image,
      baseAddr: base,
    );
    miso <= rom.miso;
    await spi.build();
    await rom.build();
    expect(rom.romBytes, equals(1024));

    reset.put(1);
    wEn.put(0);
    rEn.put(0);
    addr.put(0);
    wData.put(0);
    unawaited(Simulator.run());
    try {
      await clk.waitCycles(3);
      reset.put(0);
      await clk.clk.nextNegedge;

      Future<void> write(int a, int v) async {
        addr.put(a);
        wData.put(v);
        wEn.put(1);
        await clk.clk.nextNegedge;
        wEn.put(0);
      }

      Future<int> read(int a) async {
        addr.put(a);
        await clk.clk.nextNegedge;
        return spi.rData.value.toInt();
      }

      Future<int> transfer(int tx) async {
        await write(_data, tx);
        var guard = 0;
        while ((await read(_ctrl)) & 4 != 0) {
          if (++guard > 1000) fail('SPI transfer never finished');
        }
        return (await read(_data)) & 0xFF;
      }

      Future<List<int>> readBytes(int flashAddr, int n,
          {int cmd = 0x03}) async {
        await write(_ctrl, 1);
        await write(_ctrl, 0);
        await transfer(cmd);
        await transfer((flashAddr >> 16) & 0xFF);
        await transfer((flashAddr >> 8) & 0xFF);
        await transfer(flashAddr & 0xFF);
        final out = <int>[];
        for (var i = 0; i < n; i++) {
          out.add(await transfer(0));
        }
        await write(_ctrl, 1);
        return out;
      }

      await write(_div, spiDiv);

      expect(await readBytes(base, 16), equals(image.sublist(0, 16)),
          reason: 'the first bytes');
      expect(await readBytes(base + 500, 40), equals(image.sublist(500, 540)),
          reason: 'from the middle, after CS_N went high and low again');
      // Past the image (0xFF in the ROM), then past the ROM's end (0xFF)
      expect(await readBytes(base + 990, 40),
          equals([...image.sublist(990), ...List.filled(30, 0xFF)]),
          reason: 'past the image and past the ROM');
      expect(await readBytes(base - 4, 4), equals(List.filled(4, 0xFF)),
          reason: 'below the ROM');
      expect(await readBytes(base, 4, cmd: 0x0B), equals(List.filled(4, 0)),
          reason: 'an unknown command: MISO stays low');
      expect(await readBytes(base + 3, 3), equals(image.sublist(3, 6)),
          reason: 'after an unknown command');
    } finally {
      // Also after a failure, so the simulator stops cleanly
      await Simulator.endSimulation();
    }
  }

  test('SpiFlashRom answers the read command (SPI_DIV 1)', () => run(1));
  test('SpiFlashRom answers the read command (SPI_DIV 3)', () => run(3));
}
