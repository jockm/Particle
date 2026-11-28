// =============================================================================
// File: hdl/particle/bin/generate_panog2.dart
// Architecture: Particle on the Pano Logic G2 (Spartan-6)
// Description: Generates the Pano G2's ROHD designs as SystemVerilog, for
//              sv2v to turn into the Verilog-2001 that ISE's XST reads.
// =============================================================================
//
// Usage (run from hdl/particle; the make targets do this):
//   dart run bin/generate_panog2.dart --design uart --out <dir>
//       [--clock-hz 25000000] [--baud 1000000]
//   dart run bin/generate_panog2.dart --design particle --hex <program.hex>
//       --out <dir> [--clock-hz 25000000] [--baud 1000000] [--base 0x100]
//
// --design uart (make uart-rohd-pano) writes <dir>/panog2_uart_rohd.sv: the
// serial console test built from Particle's UART (lib/panog2_uart_rohd.dart).
//
// --design particle (make particle-pano) writes, in <dir>:
//   panog2_board.v       the Verilog-2001 top level (lib/panog2_board.dart)
//   particle_core.sv     ParticleSingleCoreTop, for sv2v
//   program_bank0.hex    block RAM bank 0 (halfwords at byte addresses 4n)
//   program_bank1.hex    block RAM bank 1 (halfwords at byte addresses 4n+2)
// <program.hex> is `pasm --format hex` output: one 16-bit word per line,
// starting at --base. The core loads the bank files by name ($readmemh), so
// they go beside the Verilog. --baud is the console UART's (FIFO channel 0).
//
// --clock-hz is the design's clock. The pin Y13 gives 25 MHz (the Ethernet
// PHY held in reset, as it is when a design leaves the PHY's reset pin
// alone); for --design particle any other frequency comes from a Spartan-6
// PLL in the wrapper (lib/panog2_board.dart), if it can make it exactly.

import 'dart:io';

import 'package:particle_rohd/particle_rohd.dart';
import 'package:rohd/rohd.dart';

Never usage(String message) {
  stderr.writeln('generate_panog2: $message');
  stderr.writeln('usage: dart run bin/generate_panog2.dart --design uart|particle '
      '--out <dir> [--hex <program.hex>] [--clock-hz 25000000] [--baud 1000000] '
      '[--base 0x100]');
  exit(2);
}

int parseNumber(String text, String option) {
  final t = text.toLowerCase();
  final value =
      t.startsWith('0x') ? int.tryParse(t.substring(2), radix: 16) : int.tryParse(t);
  if (value == null || value < 0) usage('$option: not a number: $text');
  return value;
}

/// Reads `pasm --format hex` output: one 16-bit hex word per line.
List<int> readHalfwords(String path) {
  final file = File(path);
  if (!file.existsSync()) usage('no such file: $path');
  final words = <int>[];
  var lineNo = 0;
  for (final raw in file.readAsLinesSync()) {
    lineNo++;
    final line = raw.trim();
    if (line.isEmpty) continue;
    final w = int.tryParse(line, radix: 16);
    if (w == null || w > 0xFFFF) usage('$path:$lineNo: not a 16-bit hex word: $line');
    words.add(w);
  }
  return words;
}

/// One $readmemh file per bank: `@index` followed by consecutive words.
String bankFile(Map<int, int> entries) {
  if (entries.isEmpty) return '';
  final buf = StringBuffer();
  final indices = entries.keys.toList()..sort();
  buf.writeln('@${indices.first.toRadixString(16)}');
  for (var i = indices.first; i <= indices.last; i++) {
    buf.writeln((entries[i] ?? 0).toRadixString(16).padLeft(4, '0').toUpperCase());
  }
  return buf.toString();
}

Future<void> main(List<String> args) async {
  String? design;
  String? outDir;
  String? hexPath;
  var clockHz = 25000000;
  var baud = 1000000;
  var base = 0x100;
  for (var i = 0; i < args.length; i++) {
    String next() => i + 1 < args.length ? args[++i] : usage('${args[i]} needs a value');
    switch (args[i]) {
      case '--design':
        design = next();
      case '--out':
        outDir = next();
      case '--hex':
        hexPath = next();
      case '--clock-hz':
        clockHz = parseNumber(next(), '--clock-hz');
      case '--baud':
        baud = parseNumber(next(), '--baud');
      case '--base':
        base = parseNumber(next(), '--base');
      default:
        usage('unknown option: ${args[i]}');
    }
  }
  if (outDir == null) usage('--out is required');
  final dir = Directory(outDir)..createSync(recursive: true);
  switch (design) {
    case 'uart':
      await generateUart(dir, clockHz, baud);
    case 'particle':
      if (hexPath == null) usage('--design particle needs --hex');
      if (base.isOdd) usage('--base must be even: $base');
      await generateParticle(dir, hexPath, clockHz, baud, base);
    default:
      usage('--design must be uart or particle');
  }
}

Future<void> generateUart(Directory dir, int clockHz, int baud) async {
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
  final svFile = File('${dir.path}/panog2_uart_rohd.sv')
    ..writeAsStringSync(top.dumpSystemVerilog());
  print('==> ${svFile.path}: panog2_uart_rohd, $baud baud from a '
      '${clockHz / 1e6} MHz clock');
}

Future<void> generateParticle(
    Directory dir, String hexPath, int clockHz, int baud, int base) async {
  final cfg = CpuConfig(systemClockHz: clockHz);
  final memBytes = cfg.tcmSizeBytes;

  // Split the program into the two 16-bit banks
  final halfwords = readHalfwords(hexPath);
  if (base + halfwords.length * 2 > memBytes) {
    usage('the program (${halfwords.length * 2} bytes at '
        '0x${base.toRadixString(16)}) doesn\'t fit in $memBytes bytes');
  }
  final bank0 = <int, int>{};
  final bank1 = <int, int>{};
  for (var i = 0; i < halfwords.length; i++) {
    final h = (base >> 1) + i;
    (h.isEven ? bank0 : bank1)[h >> 1] = halfwords[i];
  }
  File('${dir.path}/program_bank0.hex').writeAsStringSync(bankFile(bank0));
  File('${dir.path}/program_bank1.hex').writeAsStringSync(bankFile(bank1));

  final divisor = (clockHz / baud).round();
  if (divisor < 2 || divisor > 0xFFFF) {
    usage('--baud $baud gives divisor $divisor at $clockHz Hz; it must be 2 to 65535');
  }
  final top = ParticleSingleCoreTop(
    clk: Logic(name: 'clk'),
    resetN: Logic(name: 'reset_n'),
    ftdiRxPin: Logic(name: 'ftdi_rx_pin'),
    gpioRxPin: Logic(name: 'gpio_rx_pin'),
    config: cfg,
    ftdiBaud: baud,
    initFileBank0: 'program_bank0.hex',
    initFileBank1: 'program_bank1.hex',
  );
  await top.build();
  File('${dir.path}/particle_core.sv').writeAsStringSync(top.dumpSystemVerilog());
  final String board;
  try {
    board = panoG2BoardVerilog(clockHz: clockHz, coreModule: top.definitionName);
  } on ArgumentError catch (e) {
    usage('${e.message}');
  }
  File('${dir.path}/panog2_board.v').writeAsStringSync(board);
  print('==> Pano G2 Particle design written to ${dir.path}: panog2_board.v '
      '(top level) and particle_core.sv, ${clockHz / 1e6} MHz, console '
      '$baud baud');
  print('    program: ${halfwords.length * 2} bytes at 0x${base.toRadixString(16)}, '
      'in program_bank0.hex and program_bank1.hex');
}
