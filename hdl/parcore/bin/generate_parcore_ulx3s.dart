// =============================================================================
// File: hdl/parcore/bin/generate_parcore_ulx3s.dart
// Description: Writes the Parcore ULX3S design: board wrapper (PLL, pins),
//              ParcoreUlx3sTop, the conductor's TCM contents and the boot
//              image ROM's contents.
// =============================================================================
//
// dart run bin/generate_parcore_ulx3s.dart --conductor <conductor.bin>
//     --image <parcore_image.bin> --out <dir> [--clock-hz <hz>]
//     [--real-flash]
//
// --real-flash (PARCORE_REAL_FLASH=1; 448, 449): no ROM; the conductor reads
// the image from the board's flash (put there with make
// parcore-flash-image-jtag or pmon flash) and pmon can erase and program it.
// The image is then not needed. Off by default.
//
// Writes into <dir>:
//   parcore_ulx3s.sv      top level ulx3s_board
//   <tcm>_bank0/1.hex     each TCM's initial contents ($readmemh): the
//                         conductor's code; the stage cores' TCMs empty (the
//                         conductor loads them from the image)
//   parcore_image_rom.hex the boot image ROM, one byte per line (not with
//                         --real-flash)

import 'dart:io';

import 'package:parcore_rohd/parcore_config.dart';
import 'package:parcore_rohd/parcore_ulx3s_top.dart';
import 'package:parcore_rohd/spi_flash_rom.dart';
import 'package:particle_rohd/particle_rohd.dart';
import 'package:rohd/rohd.dart';

const ulx3sOscillatorHz = 25000000;

Never usage(String message) {
  stderr.writeln('generate_parcore_ulx3s: $message');
  stderr.writeln('usage: dart run bin/generate_parcore_ulx3s.dart '
      '--conductor <bin> --image <bin> --out <dir> [--clock-hz <hz>] '
      '[--real-flash]');
  exit(2);
}

Future<void> main(List<String> args) async {
  String? conductorPath;
  String? imagePath;
  String? outDir;
  var clockHz = 25000000;
  var realFlash = false;
  for (var i = 0; i < args.length; i++) {
    String next() =>
        i + 1 < args.length ? args[++i] : usage('${args[i]} needs a value');
    switch (args[i]) {
      case '--conductor':
        conductorPath = next();
      case '--image':
        imagePath = next();
      case '--out':
        outDir = next();
      case '--clock-hz':
        clockHz = int.tryParse(next()) ?? usage('--clock-hz needs a number');
      case '--real-flash':
        realFlash = true;
      default:
        usage('unknown option: ${args[i]}');
    }
  }
  if (conductorPath == null) usage('--conductor is required');
  if (imagePath == null && !realFlash) usage('--image is required');
  if (outDir == null) usage('--out is required');

  final pll = () {
    try {
      return Ecp5PllSettings.find(ulx3sOscillatorHz, clockHz);
    } on ArgumentError catch (e) {
      usage('${e.message}');
    }
  }();

  final conductor = File(conductorPath).readAsBytesSync();
  final image = imagePath == null ? null : File(imagePath).readAsBytesSync();
  final dir = Directory(outDir)..createSync(recursive: true);

  // Each TCM's bank files, as ParcoreTop(tcmInitDir:) expects
  final tcms = <String, (List<int>, int)>{
    'conductor_tcm': (conductor, ParcoreConfig.conductorConfig.tcmSizeBytes),
    'core0_tcm': (const [], ParcoreConfig.core0If.tcmSizeBytes),
    'core1_tcm': (const [], ParcoreConfig.core1Id.tcmSizeBytes),
    'core2_tcm': (const [], ParcoreConfig.core2Ex.tcmSizeBytes),
    'core3_tcm': (const [], ParcoreConfig.core3Mem.tcmSizeBytes),
  };
  for (final e in tcms.entries) {
    final (bytes, size) = e.value;
    // Binaries start at 0x100, the vector table
    final (bank0, bank1) = ParticleBlockRamTdp.bankFiles(bytes,
        loadOffset: 0x100, depthWords: size ~/ 4);
    File('${dir.path}/${e.key}_bank0.hex').writeAsStringSync(bank0);
    File('${dir.path}/${e.key}_bank1.hex').writeAsStringSync(bank1);
  }

  final top = ParcoreUlx3sTop(
    clk: Logic(name: 'clk'),
    resetN: Logic(name: 'reset_n'),
    ftdiRxPin: Logic(name: 'ftdi_rx_pin'),
    gpioRxPin: Logic(name: 'gpio_rx_pin'),
    buttons: Logic(name: 'buttons', width: 6),
    conductorBinary: conductor,
    image: realFlash ? null : image,
    realFlash: realFlash,
    flashMiso: realFlash ? Logic(name: 'flash_miso') : null,
    clockHz: clockHz,
    tcmInitDir: '.',
    romInitFile: 'parcore_image_rom.hex',
  );
  await top.build();
  final rom = top.subModules.whereType<SpiFlashRom>().firstOrNull;
  if (rom != null) {
    File('${dir.path}/parcore_image_rom.hex')
        .writeAsStringSync(SpiFlashRom.hexFile(rom.contents));
  }

  final sv = StringBuffer()
    ..writeln(ulx3sBoardVerilog(
        pll: pll,
        coreModule: top.definitionName,
        buttons: true,
        flash: realFlash))
    ..writeln(top.dumpSystemVerilog());
  final svFile = File('${dir.path}/parcore_ulx3s.sv')
    ..writeAsStringSync(sv.toString());

  print('==> Parcore ULX3S design written to ${dir.path}');
  print('    ${svFile.path}: top level ulx3s_board, ${clockHz / 1e6} MHz '
      '(PLL: CLKI_DIV ${pll.clkiDiv}, CLKFB_DIV ${pll.clkfbDiv}, '
      'CLKOP_DIV ${pll.clkopDiv}, VCO ${pll.vcoHz / 1e6} MHz)');
  if (rom != null) {
    print('    boot image: ${image!.length} bytes in a ${rom.romBytes}-byte ROM '
        'at flash address 0x${rom.baseAddr.toRadixString(16)}');
  } else {
    print('    boot image: read from the board\'s flash at 0x400000 '
        '(writable: pmon can erase and program it)');
  }
  print('    conductor: ${conductor.length} bytes');
}
