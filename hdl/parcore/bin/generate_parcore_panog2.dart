// =============================================================================
// File: hdl/parcore/bin/generate_parcore_panog2.dart
// Description: Writes the Parcore design for the Pano Logic G2 (rev C):
//              the Verilog-2001 board wrapper (panog2_board), Parcore's
//              SystemVerilog for sv2v, the TCMs' contents and the boot image
//              ROM's contents.
// =============================================================================
//
// dart run bin/generate_parcore_panog2.dart --conductor <conductor.bin>
//     --image <parcore_image.bin> --out <dir> [--clock-hz 25000000]
//
// Writes into <dir> (make parcore-pano does this, then sv2v and ISE):
//   panog2_board.v        top level panog2_board (particle's
//                         lib/panog2_board.dart): the 25 MHz clock straight
//                         in, the Pano button as reset, the guest's UART
//                         (core 3) on the DVI DDC pins, and the light from
//                         the LEDs (red 7, green 0, blue 1)
//   parcore_core.sv       ParcoreUlx3sTop (its name is still the ULX3S's)
//   <tcm>_bank0/1.hex     each TCM's initial contents ($readmemh): the
//                         conductor's code; the stage cores' TCMs empty (the
//                         conductor loads them from the image)
//   parcore_image_rom.hex the boot image ROM, one byte per line
//
// The pmon console's UART isn't wired yet (its receive is held idle), nor
// are the other five buttons (held at zero); the boot image is in the
// on-chip ROM, not the board's flash.

import 'dart:io';

import 'package:particle_rohd/particle_rohd.dart';
import 'package:parcore_rohd/parcore_config.dart';
import 'package:parcore_rohd/parcore_ulx3s_top.dart';
import 'package:parcore_rohd/spi_flash_rom.dart';
import 'package:rohd/rohd.dart';

Never usage(String message) {
  stderr.writeln('generate_parcore_panog2: $message');
  stderr.writeln('usage: dart run bin/generate_parcore_panog2.dart '
      '--conductor <bin> --image <bin> --out <dir> [--clock-hz 25000000]');
  exit(2);
}

Future<void> main(List<String> args) async {
  String? conductorPath;
  String? imagePath;
  String? outDir;
  var clockHz = 25000000;
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
      default:
        usage('unknown option: ${args[i]}');
    }
  }
  if (conductorPath == null) usage('--conductor is required');
  if (imagePath == null) usage('--image is required');
  if (outDir == null) usage('--out is required');

  final conductor = File(conductorPath).readAsBytesSync();
  final image = File(imagePath).readAsBytesSync();
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
    image: image,
    clockHz: clockHz,
    tcmInitDir: '.',
    romInitFile: 'parcore_image_rom.hex',
  );
  await top.build();
  final rom = top.subModules.whereType<SpiFlashRom>().first;
  File('${dir.path}/parcore_image_rom.hex')
      .writeAsStringSync(SpiFlashRom.hexFile(rom.contents));

  File('${dir.path}/parcore_core.sv').writeAsStringSync(top.dumpSystemVerilog());
  File('${dir.path}/panog2_board.v').writeAsStringSync(panoG2BoardVerilog(
      clockHz: clockHz,
      coreModule: top.definitionName,
      buttons: true,
      coreLeds: true));

  print('==> Parcore Pano G2 design written to ${dir.path}: panog2_board.v '
      '(top level) and parcore_core.sv, ${clockHz / 1e6} MHz');
  print('    boot image: ${image.length} bytes in a ${rom.romBytes}-byte ROM '
      'at flash address 0x${rom.baseAddr.toRadixString(16)}');
  print('    conductor: ${conductor.length} bytes');
}
