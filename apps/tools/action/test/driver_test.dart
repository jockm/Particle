import 'dart:io';

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

  group('analyze', () {
    test('gives the error with its location, and the program info', () {
      final dir = Directory.systemTemp.createTempSync('action_analyze_');
      try {
        final main = File('${dir.path}/main.act')
          ..writeAsStringSync('const u8 K = 7;\nvoid main() {\n    u8 b = 300;\n}\n');
        final r = analyze([main.path]);
        expect(r.program == null, isFalse);
        expect(r.error!.line, equals(3));
        expect(r.error!.column, equals(11));
        expect(r.error!.message, contains('does not fit in u8'));
        expect(r.info!.constants['K'], equals(7));
        expect(r.info!.constType('K'), equals('u8'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('unsaved text replaces the file on disk', () {
      final dir = Directory.systemTemp.createTempSync('action_analyze_');
      try {
        final main = File('${dir.path}/main.act')..writeAsStringSync('void main() { }\n');
        final real = main.resolveSymbolicLinksSync();
        final r = analyze([main.path],
            options: CompileOptions(overlays: {real: 'void main() { u32 x = nope; }\n'}));
        expect(r.error!.message, contains("undefined identifier 'nope'"));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('a syntax error leaves no program', () {
      final dir = Directory.systemTemp.createTempSync('action_analyze_');
      try {
        final main = File('${dir.path}/main.act')..writeAsStringSync('void main() {\n');
        final r = analyze([main.path]);
        expect(r.program, isNull);
        expect(r.error == null, isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
