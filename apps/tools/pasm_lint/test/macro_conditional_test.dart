import 'dart:io';

import 'package:pasm/assembler.dart';
import 'package:pasm/preprocessor.dart';
import 'package:test/test.dart';

/// Assembles [source] and returns its halfwords from [from], in order.
List<int> halfwords(String source, int from, int count) {
  final dir = Directory.systemTemp.createTempSync('pasm_macro_');
  final path = '${dir.path}/t.asm';
  File(path).writeAsStringSync(source);
  final (mem, _, _) = ParticleAssembler(Preprocessor(includeDirs: [dir.path])).assemble(path);
  return [
    for (var a = from; a < from + count * 2; a += 2) (mem[a] ?? 0) | ((mem[a + 1] ?? 0) << 8)
  ];
}

void main() {
  test('a conditional inside a macro is evaluated at each expansion', () {
    final words = halfwords('''
.define PICK_3 1
.macro SLOT n
.ifdef PICK_%n
    LD R1, 1
.else
    LD R1, 2
.endif
.endmacro
.org 0x200
    SLOT 2
    SLOT 3
''', 0x200, 2);
    expect(words, equals([0x0112, 0x0111]));
  });

  test('.if inside a macro uses the arguments', () {
    final words = halfwords('''
.macro PUT n
.if %n & 4
    LD R2, %n
.endif
.endmacro
.org 0x200
    PUT 3
    PUT 5
    PUT 7
''', 0x200, 2);
    expect(words, equals([0x0125, 0x0127]));
  });
}
