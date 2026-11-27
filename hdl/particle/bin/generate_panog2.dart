// =============================================================================
// File: hdl/particle/bin/generate_panog2.dart
// Architecture: Particle on the Pano Logic G2 (Spartan-6)
// Description: Generates the Pano G2's ROHD designs as SystemVerilog, for
//              sv2v to turn into the Verilog-2001 that ISE's XST reads.
// =============================================================================
//
// Usage (run from hdl/particle; `make pano-uart-rohd` does this):
//   dart run bin/generate_panog2.dart --out <dir>
//       [--clock-hz 25000000] [--baud 1000000]
//
// Writes <dir>/panog2_uart_rohd.sv: the serial console test built from
// Particle's UART (lib/panog2_uart_rohd.dart). --clock-hz is the clock on
// pin Y13: 25 MHz while the Ethernet PHY is held in reset, as it is when a
// design leaves the PHY's reset pin alone.

import 'dart:io';

import 'package:particle_rohd/particle_rohd.dart';
import 'package:rohd/rohd.dart';

Never usage(String message) {
  stderr.writeln('generate_panog2: $message');
  stderr.writeln('usage: dart run bin/generate_panog2.dart --out <dir> '
      '[--clock-hz 25000000] [--baud 1000000]');
  exit(2);
}

int parseNumber(String text, String option) {
  final value = int.tryParse(text);
  if (value == null || value <= 0) usage('$option: not a positive number: $text');
  return value;
}

Future<void> main(List<String> args) async {
  String? outDir;
  var clockHz = 25000000;
  var baud = 1000000;
  for (var i = 0; i < args.length; i++) {
    String next() => i + 1 < args.length ? args[++i] : usage('${args[i]} needs a value');
    switch (args[i]) {
      case '--out':
        outDir = next();
      case '--clock-hz':
        clockHz = parseNumber(next(), '--clock-hz');
      case '--baud':
        baud = parseNumber(next(), '--baud');
      default:
        usage('unknown option: ${args[i]}');
    }
  }
  if (outDir == null) usage('--out is required');

  final PanoG2UartRohd top;
  try {
    top = PanoG2UartRohd(
      clk: Logic(name: 'clk'),
      uartRx: Logic(name: 'uart_rx'),
      button: Logic(name: 'button'),
      clkFreqHz: clockHz,
      baudRate: baud,
    );
  } on ArgumentError catch (e) {
    usage('${e.message}');
  }
  await top.build();

  final dir = Directory(outDir)..createSync(recursive: true);
  final svFile = File('${dir.path}/panog2_uart_rohd.sv')
    ..writeAsStringSync(top.dumpSystemVerilog());
  print('==> ${svFile.path}: panog2_uart_rohd, $baud baud from a '
      '${clockHz / 1e6} MHz clock');
}
