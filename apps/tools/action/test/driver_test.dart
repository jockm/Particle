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

  group('build directive', () {
    BuildDirective? read(String src) => readBuildDirective(src, 'f.act');
    String errorOf(String src) {
      try {
        read(src);
        return '';
      } on CompileError catch (e) {
        return e.message;
      }
    }

    test('reads the expression, with !, && and || and parentheses', () {
      expect(read('void main() { }\n'), isNull);
      final d = read('// header\n\n//act:build llvm && (macos || linux)\nvoid main() { }\n')!;
      expect(d.line, 3);
      expect(d.builds, [('llvm', 'macos'), ('llvm', 'linux')]);
      expect(read('//act:build !llvm\n')!.builds, [('particle', 'none')]);
      expect(read('//act:build particle || llvm && !linux\n')!.builds,
          [('particle', 'none'), ('llvm', 'macos')]);
      expect(read('/* a\n   b */\n//act:build linux\n')!.builds, [('llvm', 'linux')]);
    });

    test('"// act:build" with a space is an ordinary comment', () {
      expect(read('// act:build llvm\nvoid main() { }\n'), isNull);
    });

    test('a misplaced, repeated, malformed or never-true directive is an error', () {
      expect(errorOf('void main() { }\n//act:build llvm\n'),
          contains('f.act:2:1: //act:build must come before the first import or declaration'));
      expect(errorOf('//act:build llvm\n//act:build llvm\n'),
          contains('only one //act:build line is allowed; the first is on line 1'));
      expect(errorOf('//act:build\n'), contains('needs an expression'));
      expect(errorOf('//act:build llmv\n'), contains("unknown name 'llmv'"));
      expect(errorOf('//act:build llvm &&\n'), contains('ends too soon'));
      expect(errorOf('//act:build (llvm\n'), contains("a '(' is not closed"));
      expect(errorOf('//act:build llvm)\n'), contains("unexpected ')'"));
      expect(errorOf('//act:build particle && macos\n'), contains('can never be true'));
    });

    test('a file left out is not parsed; an import of one adds nothing', () {
      final asm = compileSource('''
        import "out_llvm.act";
        import "in_particle.act";
        void main() { u32 v = K; }
      ''', extraFiles: {
        'out_llvm.act': '//act:build llvm\nthis is not Action at all\n',
        'in_particle.act': '//act:build particle\nconst u32 K = 9;\n',
      });
      expect(asm, contains('LD      R1, 9'));
    });

    test('the LLVM compiler takes the other file', () {
      final dir = Directory.systemTemp.createTempSync('action_build_');
      try {
        File('${dir.path}/k_llvm.act').writeAsStringSync('//act:build llvm\nconst u32 K = 5;\n');
        File('${dir.path}/k_particle.act').writeAsStringSync('//act:build particle\nconst u32 K = 9;\n');
        final main = File('${dir.path}/main.act')..writeAsStringSync(
            'import "k_llvm.act";\nimport "k_particle.act";\nu32 g = K;\nvoid main() { }\n');
        expect(compileLlvm([main.path]), contains('i32 5'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('it is an error when every file named is left out', () {
      expect(compileErrorOf('//act:build llvm\nvoid main() { }\n'),
          contains('no source files are built for particle'));
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
