// =============================================================================
// File: hdl/parcore/bin/build_parcore_image.dart
// Description: Builds the firmware image the conductor loads (format 2).
// =============================================================================
//
// dart run bin/build_parcore_image.dart --core0 <bin> --core1 <bin>
//     --core2 <bin> --core3 <bin> [--guest <bin>] --out <image.bin>
//
// Each stage core's firmware goes to 0x100 in its TCM; the guest program
// (a flat RV32 image linked at 0x500) to 0x500 in cores 0 and 3. See
// lib/parcore_image.dart for the format.

import 'dart:io';
import 'dart:typed_data';

import 'package:parcore_rohd/parcore_image.dart';

Never usage(String message) {
  stderr.writeln('build_parcore_image: $message');
  stderr.writeln('usage: dart run bin/build_parcore_image.dart --core0 <bin> '
      '--core1 <bin> --core2 <bin> --core3 <bin> [--guest <bin>] '
      '--out <image.bin>');
  exit(2);
}

void main(List<String> args) {
  final files = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final opt = args[i];
    if (!['--core0', '--core1', '--core2', '--core3', '--guest', '--out']
        .contains(opt)) {
      usage('unknown option: $opt');
    }
    if (i + 1 >= args.length) usage('$opt needs a value');
    files[opt.substring(2)] = args[++i];
  }
  for (final need in ['core0', 'core1', 'core2', 'core3', 'out']) {
    if (!files.containsKey(need)) usage('--$need is required');
  }
  List<int> read(String key) {
    final f = File(files[key]!);
    if (!f.existsSync()) usage('${f.path} not found');
    return f.readAsBytesSync();
  }

  try {
    final image = buildParcoreStageImage(
      core0: read('core0'),
      core1: read('core1'),
      core2: read('core2'),
      core3: read('core3'),
      guest: files.containsKey('guest') ? read('guest') : null,
    );
    File(files['out']!).writeAsBytesSync(image);
    print('==> Parcore image: ${files['out']} (${image.length} bytes, '
        'CRC-32 0x${ByteData.sublistView(image).getUint32(8, Endian.little).toRadixString(16).padLeft(8, '0')})');
  } on ArgumentError catch (e) {
    usage('${e.message}');
  }
}
