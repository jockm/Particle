// The linter and the assembler agree on every single instruction they can
// both judge. The linter knows no addresses and does not expand macros, so
// errors that need a label's address (a value or branch out of range, an
// odd JUMP target, a symbol defined elsewhere) are left to the assembler.

import 'dart:io';

import 'package:pasm/assembler.dart';
import 'package:pasm/isa.dart';
import 'package:pasm/preprocessor.dart';
import 'package:pasm_lint/linter.dart';
import 'package:test/test.dart';

/// Operands tried with every instruction.
const operandSets = [
  '', 'R1', 'R1, R2', 'R1, R2, R3', 'R1 R2', 'R1, 5', 'R1, 99999', 'R1, -3',
  'R14, 200', 'R14, -200', 'R1, label', 'label', '5', '(R1), R2', 'R1, (R2)',
  '(R1++), R2', 'R1, (--R2)', 'R16, R1', 'R1,', 'R1, 1 + 2', 'SP, 4',
];

/// Errors only the assembler can find: they need addresses.
const addressCodes = {'branch-range', 'jump', 'undefined-symbol'};

void main() {
  final mnemonics = instructionForms.keys.toList()..sort();
  final dir = Directory.systemTemp.createTempSync('pasm_agree_');
  final path = '${dir.path}/t.asm';

  (bool, String) assemble(String line) {
    File(path).writeAsStringSync('.org 0x200\nstart:\n    $line\nlabel:\n    NOP\n');
    try {
      ParticleAssembler(Preprocessor(includeDirs: [dir.path])).assemble(path);
      return (true, '');
    } on AssemblerError catch (e) {
      return (false, '${e.message} [${e.code}]');
    } on AssemblerErrors catch (e) {
      final first = e.errors.first;
      return (false, '${first.message} [${first.code}]');
    }
  }

  (bool, String) lint(String line) {
    final lines = ['.org 0x200', 'start:', '    $line', 'label:', '    NOP'];
    final r = lintLines(path, lines, [dir.path]);
    return r.errors.isEmpty ? (true, '') : (false, '${r.errors.first.$3} [${r.errors.first.$2}]');
  }

  test('the linter and the assembler agree on every instruction', () {
    final disagreements = <String>[];
    var compared = 0;
    for (final m in mnemonics) {
      for (final o in operandSets) {
        final line = '$m $o'.trim();
        final (asmOk, asmWhy) = assemble(line);
        final (lintOk, lintWhy) = lint(line);
        // An error that needs an address: only the assembler finds it
        if (!asmOk && lintOk) {
          final code = RegExp(r'\[([a-z0-9-]+)\]$').firstMatch(asmWhy)?.group(1);
          final usesLabel = o.contains('label');
          if (addressCodes.contains(code) || (code == 'range' && usesLabel)) continue;
          if (code == 'range' && (m.startsWith('FBRA') || m.startsWith('BBRA') || m == 'JUMP')) continue;
        }
        compared++;
        if (asmOk != lintOk) {
          disagreements.add('$line: assembler ${asmOk ? 'accepts' : 'rejects ($asmWhy)'}, '
              'linter ${lintOk ? 'accepts' : 'rejects ($lintWhy)'}');
        }
      }
    }
    expect(compared, greaterThan(1000));
    expect(disagreements, isEmpty, reason: disagreements.join('\n'));
  });

  test('both reject what the spec does not allow', () {
    for (final line in [
      'ADD R1, 16', 'SADD R1, 8', 'SSLT R1, 8', 'SMULH R1, 8', 'TRAP 16', 'RBASE 32',
      'PUSH8 R1, 5', 'LD R1, (R2)', 'ST8 R1, (R2)', 'TAS (R1++), R2', 'CLZ R1',
      'FIFO.STAT R1, 3', 'MBOX R1, R2', 'NEG R1, R2', 'XCHG R1,', 'BBRA R1',
    ]) {
      expect(assemble(line).$1, isFalse, reason: 'assembler accepts $line');
      expect(lint(line).$1, isFalse, reason: 'linter accepts $line');
    }
  });

  test('both accept the spec forms', () {
    for (final line in [
      'ADD R1, 15', 'SADD R1, -8', 'SSLT R1, 7', 'SSLT R1, -15', 'SSLT R14, 127',
      'SLT R14, 255', 'SMULH R1, -8', 'TRAP 15', 'TRAP R3', 'RBASE 31', 'RBASE R2',
      'PUSH8 R14, 255', 'PUSH4 R1, 15', 'LD R14, -255', 'LD R1, -15', 'LD8 R1, (R2++)',
      'ST32 (--R15), R1', 'LD32 (R1), R2', 'TAS (R1), R2', 'CLZ R1, R2',
      'FIFO.STAT R1, R2', 'FIFO.TRYR R1, R2', 'MBOX R1, 3', 'JMP R14, R14', 'NOP',
    ]) {
      expect(assemble(line).$1, isTrue, reason: 'assembler rejects $line: ${assemble(line).$2}');
      expect(lint(line).$1, isTrue, reason: 'linter rejects $line: ${lint(line).$2}');
    }
  });
}
