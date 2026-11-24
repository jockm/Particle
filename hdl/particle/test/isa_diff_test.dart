// =============================================================================
// File: hdl/particle/test/isa_diff_test.dart
// Description: Differential ISA test. Each program in test/isa/ is assembled
//              with pasm and run in psim and on the ROHD core (CoreHarness:
//              synchronous block RAM, loop-back FIFOs). Both must end with the
//              same PC, registers and shadow registers, and the same
//              bytes in each memory area the program names.
//
// Needs build/tools/pasm and build/tools/psim (`make tools`).
//
// A program starts at 0x100 (the reset vector) and ends in a jump to itself.
// Comments in it set:
//   ; check-memory: <addr> <bytes>   a memory area to compare (any number)
//   ; max-cycles: <n>                cycle limit (default 20000)
// It must avoid what psim and the hardware are allowed to do differently:
// TRAP 0 and TRAP 15 (psim stops), and filling a FIFO to 256 entries.
// (Undefined opcodes and misaligned accesses behave the same in both: see
// 11_misaligned.asm and 12_reserved.asm.)
// =============================================================================

import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'core_harness.dart';
import 'isa_random.dart';

const toolDir = '../../build/tools';
const libDir = '../../lib';

/// Assembles [source] into a binary next to it in [workDir].
List<int> assemble(File source, Directory workDir) {
  final name = source.uri.pathSegments.last.replaceAll('.asm', '');
  final out = '${workDir.path}/$name.bin';
  final res = Process.runSync(
      '$toolDir/pasm', [source.path, '-I', libDir, '-o', out]);
  if (res.exitCode != 0) {
    throw StateError('pasm failed for ${source.path}:\n${res.stdout}${res.stderr}');
  }
  return File(out).readAsBytesSync();
}

class PsimResult {
  final int pc;
  final List<int> regs;
  final List<int> shadow;
  final Map<int, List<int>> memory;
  PsimResult(this.pc, this.regs, this.shadow, this.memory);
}

/// Runs [binary] in psim for [maxCycles] and reads its state through the
/// debugger's `r` and `m` commands.
PsimResult runPsim(String binary, int maxCycles, List<(int, int)> areas) {
  final commands = StringBuffer('c\nr\n');
  for (final (addr, len) in areas) {
    commands.writeln('m 0x${addr.toRadixString(16)} $len');
  }
  commands.writeln('q');
  final proc = Process.runSync(
    'bash',
    [
      '-c',
      'printf "%s" "\$1" | "\$2" "\$3" -d --max-cycles "\$4"',
      'psim-run',
      commands.toString(),
      '$toolDir/psim',
      binary,
      '$maxCycles',
    ],
  );
  final out = '${proc.stdout}';
  int hex(String s) => int.parse(s, radix: 16);
  final pcM = RegExp(r'PC: 0x([0-9A-Fa-f]+)\s+Cycles: \d+').firstMatch(out);
  if (pcM == null) throw StateError('Could not read psim state:\n$out');
  final regs = List<int>.filled(16, 0);
  final shadow = List<int>.filled(16, 0);
  for (final m in RegExp(r'R(\d\d): 0x([0-9A-Fa-f]{8})').allMatches(out)) {
    regs[int.parse(m.group(1)!)] = hex(m.group(2)!);
  }
  for (final m in RegExp(r'S(\d\d): 0x([0-9A-Fa-f]{8})').allMatches(out)) {
    shadow[int.parse(m.group(1)!)] = hex(m.group(2)!);
  }
  final memory = <int, List<int>>{};
  for (final (addr, len) in areas) {
    final bytes = <int>[];
    for (var a = addr; a < addr + len; a += 16) {
      final line = RegExp('0x${a.toRadixString(16).padLeft(8, '0')}:\\s+((?:[0-9A-Fa-f]{2}\\s)+)',
              caseSensitive: false)
          .firstMatch(out);
      if (line == null) throw StateError('No psim dump for 0x${a.toRadixString(16)}:\n$out');
      bytes.addAll(line.group(1)!.trim().split(RegExp(r'\s+')).map(hex));
    }
    memory[addr] = bytes.sublist(0, len);
  }
  return PsimResult(hex(pcM.group(1)!), regs, shadow, memory);
}

String h(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

/// Runs one program both ways and returns the differences (empty: equal).
Future<List<String>> compareProgram(File source, Directory workDir) async {
  final text = source.readAsStringSync();
  final areas = [
    for (final m in RegExp(r';\s*check-memory:\s*(0x[0-9A-Fa-f]+|\d+)\s+(\d+)')
        .allMatches(text))
      (int.parse(m.group(1)!.replaceFirst('0x', ''),
              radix: m.group(1)!.startsWith('0x') ? 16 : 10),
          int.parse(m.group(2)!)),
  ];
  final maxM = RegExp(r';\s*max-cycles:\s*(\d+)').firstMatch(text);
  final maxCycles = maxM == null ? 20000 : int.parse(maxM.group(1)!);

  final binary = assemble(source, workDir);
  final name = source.uri.pathSegments.last.replaceAll('.asm', '');
  final ref = runPsim('${workDir.path}/$name.bin', maxCycles, areas);

  final hw = CoreHarness(binary);
  await hw.start();
  await hw.runToHalt(maxCycles: maxCycles);
  final st = hw.snapshot();
  final diffs = <String>[];
  if (st.pc != ref.pc) diffs.add('PC: hardware ${h(st.pc)}, psim ${h(ref.pc)}');
  for (var i = 1; i < 16; i++) {
    if (st.regs[i] != ref.regs[i]) {
      diffs.add('R$i: hardware ${h(st.regs[i])}, psim ${h(ref.regs[i])}');
    }
    if (st.shadow[i] != ref.shadow[i]) {
      diffs.add('S$i: hardware ${h(st.shadow[i])}, psim ${h(ref.shadow[i])}');
    }
  }
  for (final (addr, len) in areas) {
    for (var i = 0; i < len; i++) {
      final hwb = hw.ram.peekByte(addr + i);
      final pb = ref.memory[addr]![i];
      if (hwb != pb) {
        diffs.add('mem[${h(addr + i)}]: hardware 0x${hwb.toRadixString(16)}, '
            'psim 0x${pb.toRadixString(16)}');
      }
    }
  }
  await hw.stop();
  return diffs;
}

void main() {
  final workDir = Directory.systemTemp.createTempSync('particle_isa_');
  final programs = Directory('test/isa')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.asm') && !f.uri.pathSegments.last.startsWith('._'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  tearDown(() async {
    // A failed test may leave its simulation running
    await CoreHarness.stopActive();
  });

  group('Differential ISA test (psim vs ROHD core)', () {
    for (final program in programs) {
      test(program.uri.pathSegments.last, () async {
        final diffs = await compareProgram(program, workDir);
        expect(diffs, isEmpty, reason: diffs.join('\n'));
      }, timeout: const Timeout(Duration(minutes: 5)));
    }

    // Seeded random programs: the same seeds every run
    final seeds = (Platform.environment['ISA_RANDOM_SEEDS'] ?? '1,2,3,4,5,6,7,8')
        .split(',')
        .where((s) => s.isNotEmpty)
        .map(int.parse);
    for (final seed in seeds) {
      test('random program, seed $seed', () async {
        final source = File('${workDir.path}/random_$seed.asm')
          ..writeAsStringSync(randomProgram(seed));
        final diffs = await compareProgram(source, workDir);
        expect(diffs, isEmpty,
            reason: '${source.path}\n${diffs.join('\n')}');
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  });
}
