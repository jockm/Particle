// The 2-word PC-relative instructions (item 13 of Road to GHz) and the
// forms JUMP, JUMP.cc and RCALL take with and without them.

import 'dart:io';

import 'package:pasm/assembler.dart';
import 'package:pasm/isa.dart';
import 'package:pasm/preprocessor.dart';
import 'package:test/test.dart';

/// The halfwords assembled from [body] at 0x200, with a label `far` at
/// 0x1200 and `near` just after the body.
List<int> assembleAt(String body, {bool long = true}) {
  final dir = Directory.systemTemp.createTempSync('pasm_long_');
  final root = Directory.current.path.replaceAll(RegExp(r'/apps/tools/pasm_lint$'), '');
  final path = '${dir.path}/t.asm';
  File(path).writeAsStringSync(
      '.include "lib/common.inc"\n.org 0x200\nstart:\n$body\nnear:\n    NOP\n.org 0x1200\nfar:\n    NOP\n');
  final prep = Preprocessor(
      includeDirs: [dir.path, root],
      defines: long ? {} : {ParticleAssembler.noLongBranchesSymbol: 1});
  final (mem, _, _) = ParticleAssembler(prep).assemble(path);
  final out = <int>[];
  for (var a = 0x200; mem.containsKey(a) && a < 0x1200; a += 2) {
    out.add(mem[a]! | (mem[a + 1]! << 8));
  }
  return out;
}

void main() {
  test('the 2-word forms', () {
    // BRA far: 0x1000 bytes = 0x800 halfwords forward
    expect(assembleAt('    BRA far').take(2).toList(), equals([0xCC00, 0x0800]));
    // Backward: start is 0 halfwords from itself at 0x200
    expect(assembleAt('    BRA.Z R1, start').take(2).toList(), equals([0xBC10, 0x0000]));
    expect(assembleAt('    BRA.NZ R2, far').take(2).toList(), equals([0xBD20, 0x0800]));
    expect(assembleAt('    BRA.N R3, far').take(2).toList(), equals([0xBE30, 0x0800]));
    expect(assembleAt('    BRA.P R14, far').take(2).toList(), equals([0xBFE0, 0x0800]));
    expect(assembleAt('    BEQ R2, R3, far').take(2).toList(), equals([0xCE23, 0x0800]));
    expect(assembleAt('    NOP\n    BNE R2, R3, start').skip(1).take(2).toList(),
        equals([0xCF23, 0xFFFF]));
    expect(assembleAt('    RJUMP far, R5').take(2).toList(), equals([0xCD05, 0x0800]));
    // RJUMP Rr, Rl stays one word
    expect(assembleAt('    RJUMP R1, R2').first, equals(0xA112));
    // LEA counts bytes: near is 4 bytes on
    expect(assembleAt('    LEA R6, near').take(2).toList(), equals([0x0906, 0x0004]));
  });

  test('RCALL is RJUMP label, R14, or LDI + JMP without the 2-word branches', () {
    expect(assembleAt('    RCALL far').take(2).toList(), equals([0xCD0E, 0x0800]));
    expect(assembleAt('    RCALL far', long: false).take(3).toList(),
        equals([0x070E, 0x1200, 0xA0EE]));
  });

  test('JUMP and JUMP.cc grow to the 2-word forms', () {
    expect(assembleAt('    JUMP near'), equals([0xB001, 0x0000]));
    expect(assembleAt('    JUMP far').take(2).toList(), equals([0xCC00, 0x0800]));
    // A short conditional branch: Imm4 for any register, Imm8 for R14
    expect(assembleAt('    JUMP.Z R3, near').first, equals(0xB431));
    expect(assembleAt('    JUMP.NZ R14, far', long: true).take(2).toList(), equals([0xBDE0, 0x0800]));
    expect(assembleAt('    JUMP.N R2, far').take(2).toList(), equals([0xBE20, 0x0800]));
  });

  test('without the 2-word branches JUMP.cc goes around the far form', () {
    // JUMP.Z R1, far: FBRA.NZ R1 past LDI R14 + JMP R14, R0
    expect(assembleAt('    JUMP.Z R1, far', long: false).take(4).toList(),
        equals([0xBA14, 0x070E, 0x1200, 0xA0E0]));
    expect(assembleAt('    JUMP.NZ R1, far', long: false).take(4).toList(),
        equals([0xB414, 0x070E, 0x1200, 0xA0E0]));
    // JUMP.N R2, far: FBRA.N R2 to the far form, FBRA past it
    expect(assembleAt('    JUMP.N R2, far', long: false).take(5).toList(),
        equals([0xB522, 0xB004, 0x070E, 0x1200, 0xA0E0]));
    expect(assembleAt('    JUMP far', long: false).take(3).toList(),
        equals([0x070E, 0x1200, 0xA0E0]));
  });

  test('errors', () {
    void rejects(String body, String code, {bool long = true}) {
      try {
        assembleAt(body, long: long);
        fail('accepted: $body');
      } on AssemblerErrors catch (e) {
        expect(e.errors.first.code, equals(code), reason: body);
      } on AssemblerError catch (e) {
        expect(e.code, equals(code), reason: body);
      }
    }

    rejects('    BRA far', 'long-branch', long: false);
    rejects('    LEA R1, far', 'long-branch', long: false);
    rejects('    BRA 0x201', 'jump');
    rejects('    BRA 0x30000', 'branch-range');
    rejects('    LEA R1, 0x9000', 'branch-range');
    rejects('    BEQ R1, R2', 'syntax');
    rejects('    BRA R1', 'syntax');
    expect(regMap.containsKey('r1'), isTrue);
  });
}
