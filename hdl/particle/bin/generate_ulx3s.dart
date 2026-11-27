// =============================================================================
// File: hdl/particle/bin/generate_ulx3s.dart
// Architecture: Particle 32-bit RISC on Lattice ECP5 (ULX3S)
// Description: Generates the ULX3S design: SystemVerilog for the board
//              (ulx3s_board around ParticleUlx3sTop) and the block RAM
//              initialisation files for a program.
// =============================================================================
//
// Usage (run from hdl/particle; `make generate-ulx3s` does this):
//   dart run bin/generate_ulx3s.dart --hex <program.hex> --out <dir>
//       [--base 0x100] [--clock-hz 35000000]
//
// <program.hex> is `pasm --format hex` output: one 16-bit word per line,
// starting at --base. The generator writes, in <dir>:
//   particle_ulx3s.sv    ulx3s_board (top level) and particle_ulx3s_top
//   program_bank0.hex    block RAM bank 0 (halfwords at byte addresses 4n)
//   program_bank1.hex    block RAM bank 1 (halfwords at byte addresses 4n+2)
// The .sv file loads the bank files by name, so run Yosys in <dir>.

import 'dart:io';

import 'package:particle_rohd/particle_rohd.dart';
import 'package:rohd/rohd.dart';

const ulx3sOscillatorHz = 25000000;

Never usage(String message) {
  stderr.writeln('generate_ulx3s: $message');
  stderr.writeln('usage: dart run bin/generate_ulx3s.dart --hex <program.hex> '
      '--out <dir> [--base 0x100] [--clock-hz 35000000]');
  exit(2);
}

int parseNumber(String text, String option) {
  final t = text.toLowerCase();
  final value =
      t.startsWith('0x') ? int.tryParse(t.substring(2), radix: 16) : int.tryParse(t);
  if (value == null) usage('$option: not a number: $text');
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
  final buf = StringBuffer();
  if (entries.isEmpty) return '';
  final indices = entries.keys.toList()..sort();
  final first = indices.first;
  final last = indices.last;
  buf.writeln('@${first.toRadixString(16)}');
  for (var i = first; i <= last; i++) {
    buf.writeln((entries[i] ?? 0).toRadixString(16).padLeft(4, '0').toUpperCase());
  }
  return buf.toString();
}

Future<void> main(List<String> args) async {
  String? hexPath;
  String? outDir;
  var base = 0x100;
  var clockHz = 35000000;

  for (var i = 0; i < args.length; i++) {
    String next() => i + 1 < args.length ? args[++i] : usage('${args[i]} needs a value');
    switch (args[i]) {
      case '--hex':
        hexPath = next();
      case '--out':
        outDir = next();
      case '--base':
        base = parseNumber(next(), '--base');
      case '--clock-hz':
        clockHz = parseNumber(next(), '--clock-hz');
      default:
        usage('unknown option: ${args[i]}');
    }
  }
  if (hexPath == null) usage('--hex is required');
  if (outDir == null) usage('--out is required');
  if (base.isOdd) usage('--base must be even: $base');

  final cfg = CpuConfig(systemClockHz: clockHz);
  final memBytes = cfg.tcmSizeBytes;

  final pll = () {
    try {
      return Ecp5PllSettings.find(ulx3sOscillatorHz, clockHz);
    } on ArgumentError catch (e) {
      usage('${e.message}');
    }
  }();

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

  final dir = Directory(outDir)..createSync(recursive: true);
  File('${dir.path}/program_bank0.hex').writeAsStringSync(bankFile(bank0));
  File('${dir.path}/program_bank1.hex').writeAsStringSync(bankFile(bank1));

  // Build the design
  final top = ParticleUlx3sTop(
    clk: Logic(name: 'clk'),
    resetN: Logic(name: 'reset_n'),
    ftdiRxPin: Logic(name: 'ftdi_rx_pin'),
    gpioRxPin: Logic(name: 'gpio_rx_pin'),
    config: cfg,
    initFileBank0: 'program_bank0.hex',
    initFileBank1: 'program_bank1.hex',
  );
  await top.build();

  final sv = StringBuffer()
    ..writeln(ulx3sBoardVerilog(pll: pll, coreModule: top.definitionName))
    ..writeln(top.dumpSystemVerilog());
  final svFile = File('${dir.path}/particle_ulx3s.sv')..writeAsStringSync(sv.toString());

  final mhz = clockHz / 1e6;
  print('==> ULX3S design written to ${dir.path}');
  print('    ${svFile.path}: top level ulx3s_board, $mhz MHz '
      '(PLL: CLKI_DIV ${pll.clkiDiv}, CLKFB_DIV ${pll.clkfbDiv}, '
      'CLKOP_DIV ${pll.clkopDiv}, VCO ${pll.vcoHz / 1e6} MHz)');
  print('    program: ${halfwords.length * 2} bytes at 0x${base.toRadixString(16)}, '
      'in program_bank0.hex and program_bank1.hex');
}
