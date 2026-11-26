// The immediate BEXTR and SBEXTR, and JTBL's entry sizes (item 13 of Road to
// GHz, package 2).

import 'dart:io';

import 'package:pasm/assembler.dart';
import 'package:pasm/isa.dart';
import 'package:pasm/preprocessor.dart';
import 'package:test/test.dart';

/// The halfwords assembled from [body] at 0x200.
List<int> assembleAt(String body) {
  final dir = Directory.systemTemp.createTempSync('pasm_bextr_');
  final path = '${dir.path}/t.asm';
  File(path).writeAsStringSync('.org 0x200\n$body\n');
  final (mem, _, _) =
      ParticleAssembler(Preprocessor(includeDirs: [dir.path])).assemble(path);
  final out = <int>[];
  for (var a = 0x200; mem.containsKey(a); a += 2) {
    out.add(mem[a]! | (mem[a + 1]! << 8));
  }
  return out;
}

String? errorCode(String body) {
  try {
    assembleAt(body);
    return null;
  } on AssemblerErrors catch (e) {
    return e.errors.first.code;
  } on AssemblerError catch (e) {
    return e.code;
  }
}

void main() {
  test('BEXTR and SBEXTR with the field in the second word', () {
    // RISC-V rd: bits 11:7 of R5 into R6
    expect(assembleAt('    BEXTR R6, R5, 7, 5'), equals([0x8D65, (5 << 5) | 7]));
    // An I-type immediate: bits 31:20, sign-extended
    expect(assembleAt('    SBEXTR R2, R3, 20, 12'),
        equals([0x8D23, 0x8000 | (12 << 5) | 20]));
    // The register form stays one word
    expect(assembleAt('    BEXTR R6, R5'), equals([0x8065]));
    // The next instruction follows the 2 words
    expect(assembleAt('    BEXTR R1, R2, 0, 8\n    NOP').length, equals(3));
  });

  test('JTBL entry sizes', () {
    expect(assembleAt('    JTBL R3'), equals([0x8130]));
    expect(assembleAt('    JTBL R3, 2'), equals([0x8130]));
    expect(assembleAt('    JTBL R3, 4'), equals([0x8131]));
    expect(assembleAt('    JTBL R3, 8'), equals([0x8132]));
    expect(assembleAt('    JTBL R3, 16'), equals([0x8133]));
  });

  test('errors', () {
    expect(errorCode('    BEXTR R1, R2, 32, 1'), equals('range'));
    expect(errorCode('    SBEXTR R1, R2, 0, 32'), equals('range'));
    expect(errorCode('    BEXTR R1, R2, 3'), equals('syntax'));
    expect(errorCode('    SBEXTR R1, R2'), equals('syntax'));
    expect(errorCode('    BEXTR R1, R2, R3, 4'), equals('register'));
    expect(errorCode('    JTBL R1, 6'), equals('range'));
    expect(regMap.containsKey('r1'), isTrue);
  });
}
