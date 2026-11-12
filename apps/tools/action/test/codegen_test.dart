// Code generation checks for the changes made in the port. Behaviour is
// tested end to end by the apps/act/*_test.act programs; these tests pin
// the generated instructions and the compile-time errors.

import 'package:test/test.dart';

import 'support.dart';

String wrapMain(String body) => 'void main() {\n$body\n}\n';

void main() {
  group('arithmetic', () {
    test('signed operands use signed instructions', () {
      final asm = compileSource(wrapMain('''
        s32 a = -7;
        s32 b = 2;
        s32 q = a / b;
        s32 r = a % b;
        s32 s = a >> 1;
        s32 d = (a - b) / 2;
        a /= b;
        a >>= 1;
      '''));
      final ops = mnemonics(asm);
      expect(ops.where((o) => o == 'SDIV').length, 3);
      expect(ops, contains('SMOD'));
      expect(ops.where((o) => o == 'ASHIFTR').length, 2);
      expect(ops, isNot(contains('DIV')));
      expect(ops, isNot(contains('SHIFTR')));
    });

    test('unsigned operands keep unsigned instructions', () {
      final ops = mnemonics(compileSource(wrapMain('''
        u32 a = 7;
        u32 q = a / 2;
        u32 r = a % 2;
        u32 s = a >> 1;
      ''')));
      expect(ops, containsAll(['DIV', 'MOD', 'SHIFTR']));
      expect(ops, isNot(contains('SDIV')));
    });

    test('a for loop over a signed variable compares signed', () {
      expect(mnemonics(compileSource(wrapMain('for (s32 i : -3..3) { }'))), contains('SSLT'));
      expect(mnemonics(compileSource(wrapMain('for (u32 i : 0..3) { }'))),
          isNot(contains('SSLT')));
    });

    test('multiplication is MULL; MUL is not a Particle mnemonic', () {
      final asm = compileSource('''
        type Big { u32 a; u32 b; u32 c; };
        void main() {
          u32 n = 3;
          Big xs[] = Big.createArray(n);
          u32 m = n * n;
          xs.destroyArray();
        }
      ''');
      expect(mnemonics(asm), isNot(contains('MUL')));
      expect(mnemonics(asm), contains('MULL'));
    });
  });

  group('switch and continue', () {
    const src = '''
      u32 f(u32 v) {
        u32 x = 0;
        switch (v) {
          case 1:
            x = 1;
            continue;
          case 2:
            x += 2;
          default:
            x = 9;
        }
        return x;
      }
      void main() { }
    ''';

    test('each case ends with an implicit break', () {
      final body = functionBody(compileSource(src), 'f');
      expect('Implicit break at end of case'.allMatches(body).length, 2);
    });

    test('continue in a case falls through to the next case', () {
      expect(functionBody(compileSource(src), 'f'),
          contains('Continue: fall through to next case'));
    });

    test('continue in loops goes to the next iteration', () {
      final asm = compileSource(wrapMain('''
        u32 i = 0;
        while (i < 3) { i += 1; continue; }
        for (u32 j : 0..3) { continue; }
      '''));
      expect(asm, contains('BBRA    ._while_start'));
      expect(asm, matches(r'FBRA    \._for_step_\d+ +; Continue: next loop iteration'));
    });

    test('continue outside a loop or switch is an error', () {
      expect(compileErrorOf(wrapMain('continue;')), contains("'continue' outside"));
    });
  });

  group('calls', () {
    test('arguments past the fourth go on the stack', () {
      final asm = compileSource('''
        u32 six(u32 a, u32 b, u32 c, u32 d, u32 e, u32 f) { return e + f; }
        void main() { u32 r = six(1, 2, 3, 4, 5, 6); }
      ''');
      expect(asm, contains('Reserve 8 bytes for stack arguments'));
      expect(asm, contains('Stack argument slot 5'));
      expect(asm, contains('Stack argument slot 6'));
      expect(asm, contains('Release stack arguments'));
      // The callee keeps R1..R4 and reads e and f from the caller's area
      expect('Spill param'.allMatches(functionBody(asm, 'six')).length, 4);
    });

    test('simple arguments still load straight into registers', () {
      final asm = compileSource('''
        u32 add(u32 a, u32 b) { return a + b; }
        void main() { u32 x = 1; u32 r = add(x, 2); }
      ''');
      expect(asm, isNot(contains('Hold argument slot')));
    });

    test('computed arguments are held until all are evaluated', () {
      final asm = compileSource('''
        u32 add(u32 a, u32 b) { return a + b; }
        void main() { u32 x = 1; u32 r = add(x + 1, add(x, 2)); }
      ''');
      expect(asm, contains('Hold argument slot 1'));
      expect(asm, contains('POP32   R1               ; Argument slot 1'));
    });
  });

  group('R14 and LOAD macros', () {
    test('field offsets of 16 or more keep a base address held in R14', () {
      final asm = compileSource('''
        type Big { u32 pad[5]; u32 a; };
        void main() { Big b; b.a += 1; }
      ''');
      expect(asm, contains('PUSH32  R14              ; Keep R14 across LOAD macro'));
    });

    test('small offsets need no save', () {
      final asm = compileSource('''
        type P { u32 x; u32 y; };
        void main() { P p; p.y += 1; }
      ''');
      expect(asm, isNot(contains('Keep R14')));
    });
  });

  group('coroutines', () {
    const kernel = {
      'lib/protokernel.act': '''
        const u16 PK_WAITING = 0;
        const u16 PK_YIELDED = 1;
        const u16 PK_EXITED  = 2;
        const u16 PK_ENDED   = 3;
        type pt { u16 lc; };
        u16 yield(type pt p, u16 step);
        u16 wait_until(type pt p, u16 step, u32 cond);
        u16 pk_exit(type pt p);
      '''
    };

    test('yield, wait_until and pk_exit are generated in place', () {
      final asm = compileSource('''
        import "lib/protokernel.act";
        u16 task(type pt p) {
          yield(p, 1);
          wait_until(p, 2, 1);
          pk_exit(p);
        }
        void main() { }
      ''', extraFiles: kernel);
      expect(asm, isNot(contains('RCALL   _yield')));
      expect(asm, isNot(contains('RCALL   _pk_exit')));
      expect(asm, contains('._step_task_1:'));
      expect(asm, contains('._step_task_2:'));
      expect(asm, contains('Exit coroutine'));
    });

    test('steps inside for and switch bodies are dispatched', () {
      final asm = compileSource('''
        import "lib/protokernel.act";
        u16 task(type pt p) {
          for (u32 i : 0..2) { yield(p, 1); }
          switch (p.lc) { case 0: yield(p, 2); }
        }
        void main() { }
      ''', extraFiles: kernel);
      expect(asm, contains('Wide branch to step 1'));
      expect(asm, contains('Wide branch to step 2'));
    });

    test('used in an expression is an error', () {
      expect(
          () => compileSource('''
            import "lib/protokernel.act";
            u16 task(type pt p) { u16 r = yield(p, 1); return r; }
            void main() { }
          ''', extraFiles: kernel),
          throwsA(anything));
    });

    test('without the prototypes, yield is an ordinary call', () {
      final asm = compileSource('''
        u16 yield(u32 a, u32 b) { return a; }
        void main() { yield(1, 2); }
      ''');
      expect(asm, contains('RCALL   _yield'));
    });
  });

  group('tryreadfifo', () {
    test('reads into the variable through FIFO.TRYR with a register channel', () {
      final asm = compileSource(wrapMain('''
        u32 x = 0;
        u32 got = tryreadfifo(2, x);
      '''));
      expect(asm, contains('FIFO.TRYR R1, R2'));
      expect(asm, contains('tryreadfifo status'));
    });

    test('channels may be consts but must be constant', () {
      expect(compileErrorOf('const u32 C = 1;\n${wrapMain('u32 v = readfifo(C);')}'), isNull);
      expect(compileErrorOf(wrapMain('u32 c = 1; u32 v = readfifo(c);')),
          contains('must be a constant'));
    });
  });

  group('records', () {
    test('assigning to a record stored on the stack is an error', () {
      expect(
          compileErrorOf('''
            type P { u32 x; };
            void main() { P a; P b; a = b; }
          '''),
          contains('stored on the stack'));
    });

    test('a record from create() is a reference', () {
      expect(
          compileErrorOf('''
            type P { u32 x; };
            void main() { P a = P.create(); a.x = 1; a.destroy(); }
          '''),
          isNull);
    });

    test('a fixed array cannot take createArray', () {
      expect(compileErrorOf(wrapMain('u32 a[4] = u32.createArray(4);')),
          contains('fixed-size array'));
    });

    test('a dynamic array of records is fine', () {
      expect(
          compileErrorOf('''
            type P { u32 x; };
            void main() { P ps[] = P.createArray(2); ps[1].x = 3; ps.destroyArray(); }
          '''),
          isNull);
    });
  });

  group('names and constants', () {
    test('an undefined identifier is an error', () {
      expect(compileErrorOf(wrapMain('u32 a = nope + 1;')),
          contains("undefined identifier 'nope'"));
      expect(compileErrorOf(wrapMain('nope = 1;')), contains("undefined identifier 'nope'"));
    });

    test('-D defines a const, NAME alone is 1, and overrides the source', () {
      final asm = compileSource('''
        const u32 SIZE = 2;
        u32 g[SIZE];
        void main() { u32 f = FLAG; }
      ''', defines: ['SIZE=0x10', 'FLAG']);
      final data = asm.substring(asm.indexOf('\n_g:'));
      expect(RegExp(r'^\s+\.word +0$', multiLine: true).allMatches(data).length, 16);
      expect(asm, contains('LD      R1, 1'));
    });

    test('a const is usable as an array size and @ address', () {
      expect(compileErrorOf('''
        const u32 N = 3;
        const u32 BASE = 0x8000;
        u32 buf[N + 1];
        u32 reg @ BASE + 4;
        void main() { u32 local[N]; }
      '''), isNull);
    });

    test('a global initializer must be constant', () {
      expect(compileErrorOf('u32 a = 1; u32 b = a + 1; void main() { }'),
          contains('must be a constant expression'));
      expect(compileErrorOf('const u32 K = 4; u32 b = K * 2; void main() { }'), isNull);
    });
  });

  group('strings', () {
    test('string elements are bytes', () {
      final asm = compileSource(wrapMain('''
        string s[8] = "hi";
        u8 c = s[1];
        s[0] = 'H';
      '''));
      final elemLoads = RegExp(r'LD8 +R1, \(R14\)').allMatches(asm).length;
      expect(elemLoads, greaterThan(0));
      expect(asm, contains('ST8      (R14), R1'));
    });
  });

  group('record layout', () {
    test('fields are aligned to their size and records padded', () {
      final asm = compileSource('''
        type Mixed { u8 b; u16 w; u32 g; };
        type Task { u16 lc; u32 count; };
        type Tail { u32 a; u8 b; };
        void main() {
          Mixed m;
          m.w = 1;
          m.g = 2;
          Task t;
          t.count = 3;
          u32 s = sizeof(Tail);
          u32 sm = sizeof(Mixed);
        }
      ''');
      expect(asm, contains("Offset 2 for field 'w'"));
      expect(asm, contains("Offset 4 for field 'g'"));
      expect(asm, contains("Offset 4 for field 'count'"));
      // sizeof(Tail) is 5 bytes of fields padded to 8; sizeof(Mixed) is 8
      expect(RegExp(r'LD      R1, 8 ').allMatches(asm).length, 2);
    });

    test('a nested record is aligned to its own alignment', () {
      final asm = compileSource('''
        type In { u32 a; };
        type Out { u8 head[17]; In inner; };
        void main() { Out o; o.inner.a = 1; u32 s = sizeof(Out); }
      ''');
      expect(asm, contains("Offset 20 for field 'inner'"));
      expect(asm, contains('(24)'));
    });

    test('a global array of records reserves the whole records', () {
      final asm = compileSource('''
        type Big { u32 a; u32 b; u32 c; };
        Big g[3];
        void main() { g[2].c = 1; }
      ''');
      final data = asm.substring(asm.indexOf('\n_g:'));
      final words = RegExp(r'^\s+\.word +0$', multiLine: true).allMatches(data).length;
      expect(words, 9);
    });
  });

  group('trap vectors', () {
    test('every vector is emitted, with the same shape', () {
      final asm = compileSource('void main() { }');
      expect(asm, contains('_vector_reset:'));
      expect(asm, contains('_vector_mbox:'));
      for (var v = 2; v < 16; v++) {
        expect(asm, contains('_vector_$v:'));
      }
      expect('FAST_ENTER_TRAP'.allMatches(asm).length, 15);
      expect('FAST_EXIT_TRAP'.allMatches(asm).length, 15);
    });

    test('a trap(N) handler is called from vector N', () {
      final asm = compileSource('''
        const u32 SERIAL = 3;
        u32 hits = 0;
        trap(SERIAL) on_serial() { hits += 1; }
        trap(15) on_fault() { hits = 99; }
        void main() { trap(3); }
      ''');
      final v3 = asm.substring(asm.indexOf('_vector_3:'), asm.indexOf('_vector_4:'));
      expect(v3, contains('RCALL   _on_serial'));
      final v15 = asm.substring(asm.indexOf('_vector_15:'));
      expect(v15.substring(0, v15.indexOf('.align')), contains('RCALL   _on_fault'));
      final v4 = asm.substring(asm.indexOf('_vector_4:'), asm.indexOf('_vector_5:'));
      expect(v4, isNot(contains('RCALL')));
    });

    test('handler errors', () {
      expect(compileErrorOf('trap(16) h() { }\nvoid main() { }'), contains('out of range'));
      expect(compileErrorOf('trap(0) h() { }\nvoid main() { }'),
          contains('trap 0 (reset) is not supported yet'));
      expect(compileErrorOf('trap(2) a() { }\ntrap(2) b() { }\nvoid main() { }'),
          contains("bound to both 'a' and 'b'"));
      expect(compileErrorOf('u32 n = 2;\ntrap(n) h() { }\nvoid main() { }'),
          contains('must be a constant'));
    });

    test('a handler runs only as a trap', () {
      expect(compileErrorOf('trap(2) h() { }\nvoid main() { h(); }'),
          contains("'h' is a trap handler"));
      expect(
          compileErrorOf('type F = fn() -> void;\ntrap(2) h() { }\nvoid main() { F f = h; }'),
          contains("'h' is a trap handler"));
    });

    test('trap() accepts a const trap number', () {
      final asm = compileSource('const u32 DONE = 0;\nvoid main() { trap(DONE); }');
      expect(asm, contains('TRAP    0'));
      expect(asm, isNot(contains('_trap')));
    });
  });
}
