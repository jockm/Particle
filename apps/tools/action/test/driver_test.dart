import 'package:action/action.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('imports', () {
    test('a module is loaded once; repeated and circular imports are ignored', () {
      final asm = compileSource('''
        import "mod/helper.act";
        import "mod/helper.act";
        void main() { u32 v = triple(2); }
      ''', extraFiles: {
        'mod/helper.act': '''
          import "../main.act";
          u32 triple(u32 v) { return v * 3; }
        ''',
      });
      expect('\n_triple:'.allMatches(asm).length, 1);
    });

    test('imports are found through the include directories', () {
      expect(
          compileErrorOf('import "lib/k.act";\nvoid main() { u32 v = K; }'),
          isNot(isNull)); // not written: missing
      final asm = compileSource('import "lib/k.act";\nvoid main() { u32 v = K; }',
          extraFiles: {'lib/k.act': 'const u32 K = 9;'});
      expect(asm, contains('LD      R1, 9'));
    });

    test('a function defined twice is an error', () {
      expect(
          () => compileSource('import "a.act";\nu32 f() { return 1; }\nvoid main() { }',
              extraFiles: {'a.act': 'u32 f() { return 2; }'}),
          throwsA(isA<CompileError>()));
    });
  });

  group('-D', () {
    test('parses NAME and NAME=VALUE', () {
      expect(parseDefines(['A', 'B=7', 'C=0x10']), {'A': 1, 'B': 7, 'C': 16});
    });

    test('rejects values that are not integers', () {
      expect(() => parseDefines(['A=hello']), throwsA(isA<CompileError>()));
    });
  });
}
