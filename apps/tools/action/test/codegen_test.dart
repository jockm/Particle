// Code generation checks for the changes made in the port. Behaviour is
// tested end to end by the apps/act/*_test.act programs; these tests pin
// the generated instructions and the compile-time errors.

import 'package:action/action.dart';
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

  group('tasks', () {
    const kernel = {
      'lib/protokernel.act': '''
        const u16 PK_WAITING = 0;
        const u16 PK_YIELDED = 1;
        const u16 PK_EXITED  = 2;
        const u16 PK_ENDED   = 3;
        type pt { u16 lc; };
        u16 yield(type pt p);
        u16 wait_until(type pt p, u32 cond);
        u16 pk_exit(type pt p);
      '''
    };

    String? taskError(String src) {
      try {
        compileSource('import "lib/protokernel.act";\n$src', extraFiles: kernel);
        return null;
      } on Object catch (e) {
        return e.toString();
      }
    }

    test('pauses are generated in place and numbered automatically', () {
      final asm = compileSource('''
        import "lib/protokernel.act";
        task worker(pt p) {
          yield(p);
          wait_until(p, 1);
          pk_exit(p);
        }
        void main() { }
      ''', extraFiles: kernel);
      expect(asm, isNot(contains('RCALL   _yield')));
      expect(asm, isNot(contains('RCALL   _pk_exit')));
      expect(asm, contains('._step_worker_1:'));
      expect(asm, contains('._step_worker_2:'));
      expect(asm, contains('Exit coroutine'));
      expect(asm, contains('._task_end_worker:'));
    });

    test('resume points inside while and switch bodies are dispatched', () {
      final asm = compileSource('''
        import "lib/protokernel.act";
        task worker(pt p) {
          while (1) { yield(p); }
          switch (p.lc) { case 0: yield(p); }
        }
        void main() { }
      ''', extraFiles: kernel);
      expect(asm, contains('Wide branch to step 1'));
      expect(asm, contains('Wide branch to step 2'));
    });

    test('a task returns its status and can be a function value', () {
      expect(taskError('''
        type Job = fn(pt, u32) -> u16;
        task run(pt p, u32 n) { yield(p); }
        void main() { pt t; u16 s = run(t, 2); Job j = run; s = j(t, 3); }
      '''), isNull);
    });

    test('task rules', () {
      expect(taskError('u16 f(pt t) { yield(t); }\nvoid main() { }'),
          contains("can only be used in a task function"));
      expect(taskError('task f() { }\nvoid main() { }'),
          contains('needs its state as the first parameter'));
      expect(taskError('type S { u32 a; u16 lc; };\ntask f(S s) { yield(s); }\nvoid main() { }'),
          contains('first field is a u16'));
      expect(taskError('type S { u16 lc; };\ntask f(S s, S o) { yield(o); }\nvoid main() { }'),
          contains("must name the task's state 's'"));
      expect(taskError('task f(pt t) { return 3; }\nvoid main() { }'),
          contains('cannot return a value'));
      expect(taskError('task f(pt t) { yield(t, 1); }\nvoid main() { }'),
          contains("'yield' takes 1 argument"));
      expect(taskError('task f(pt t) { u16 r = yield(t); }\nvoid main() { }'),
          contains('use it as a statement'));
    });

    test('locals do not survive a pause', () {
      expect(taskError('task f(pt t) { for (u32 i : 0..3) { yield(t); } }\nvoid main() { }'),
          contains("the 'for' loop over 'i' pauses"));
      expect(taskError('task f(pt t) { u32 x = 5; yield(t); u32 y = x; }\nvoid main() { }'),
          contains("'x' is read after a pause"));
      expect(taskError('u32 g = 0;\ntask f(pt t) { u32 x; if (g == 1) { x = 1; } yield(t); g = x; }\nvoid main() { }'),
          contains("'x' is read after a pause"));
      expect(taskError('task f(pt t) { u32 n = 3; wait_until(t, n == 3); }\nvoid main() { }'),
          contains("'n' is read after a pause"));
      // Set again after the pause, or never set: fine
      expect(taskError('task f(pt t) { u32 x = 5; yield(t); x = 6; u32 y = x; }\nvoid main() { }'),
          isNull);
      expect(taskError('u32 g = 0;\ntask f(pt t) { u32 x; yield(t); g = x; }\nvoid main() { }'),
          isNull);
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

  group('trap numbers', () {
    test('must be 0 to 15', () {
      expect(compileErrorOf(wrapMain('trap(16);')), contains('trap number 16 is out of range'));
      expect(compileErrorOf(wrapMain('trap(-1);')), contains('trap number -1 is out of range'));
      expect(compileErrorOf('const u32 T = 20;\n${wrapMain('trap(T);')}'),
          contains('trap number 20 is out of range'));
      expect(compileErrorOf(wrapMain('trap(15);')), isNull);
    });
  });

  group('%=', () {
    test('uses MOD, or SMOD for signed operands', () {
      final ops = mnemonics(compileSource(wrapMain('''
        u32 a = 7;
        a %= 3;
        s32 b = -7;
        b %= 3;
      ''')));
      expect(ops, contains('MOD'));
      expect(ops, contains('SMOD'));
    });
  });

  group('asm prototypes', () {
    test('a prototype with no definition must be marked asm', () {
      expect(compileErrorOf('u32 f(u32 a);\n${wrapMain('f(1);')}'),
          contains("'f' is declared but never defined"));
      expect(compileErrorOf('type P { u32 x; };\nu32 P.get();\nvoid main() { }'),
          contains("'P.get' is declared but never defined"));
      final asm = compileSource('asm u32 f(u32 a);\n${wrapMain('u32 r = f(1);')}');
      expect(asm, contains('RCALL   _f'));
    });

    test('a prototype defined later is fine', () {
      expect(compileErrorOf('u32 f(u32 a);\n${wrapMain('f(1);')}u32 f(u32 a) { return a; }'),
          isNull);
    });

    test('asm and an Action definition conflict', () {
      expect(compileErrorOf('asm u32 f(u32 a);\nu32 f(u32 a) { return a; }\nvoid main() { }'),
          contains("declared 'asm' but is also defined"));
    });

    test('asm must be followed by a prototype', () {
      expect(compileErrorOf('asm u32 x;\nvoid main() { }'),
          contains("'asm' must be followed by a function prototype"));
      expect(compileErrorOf('asm u32 f() { return 1; }\nvoid main() { }'),
          contains("'asm' must be followed by a function prototype"));
    });
  });

  group('type aliases', () {
    test('an alias is interchangeable with its type', () {
      expect(
          compileErrorOf('''
            type size_t = u32;
            type Pos = Point;
            type Point { s32 x; }
            type Op = fn(u32) -> u32;
            type F = Op;
            u32 inc(u32 v) { return v + 1; }
            size_t g(u32 v) { return v; }
            void Pos.zero() { this.x = 0; }
            void main() {
              size_t n = g(3);
              u32 m = n;
              Pos p;
              p.zero();
              F f = inc;
              Pos h = Pos.create();
              h.destroy();
              size_t a[] = size_t.createArray(2);
              a.destroyArray();
              verify(sizeof(size_t) == 4, "size");
              verify(sizeof(Pos) == 4, "size");
            }
          '''),
          isNull);
    });

    test('a signed alias is signed', () {
      final ops = mnemonics(compileSource('type delta = s32;\n${wrapMain('delta d = -8; d = d / 2;')}'));
      expect(ops, contains('SDIV'));
    });

    test('alias errors', () {
      expect(compileErrorOf('type B = u8[4];\nvoid main() { }'), contains('cannot alias an array'));
      expect(compileErrorOf('type A = B;\ntype B = A;\nvoid main() { }'), contains('refers to itself'));
      expect(compileErrorOf('type A = Nope;\nvoid main() { }'), contains("unknown type 'Nope'"));
      expect(compileErrorOf('type A = u8;\ntype A = u16;\nvoid main() { }'), contains('already defined'));
      expect(compileErrorOf('type P { u32 x; };\ntype P = u32;\nvoid main() { }'),
          contains("type 'P' is already defined"));
    });
  });

  group('constants (Go rules)', () {
    test('an untyped constant must fit the type it is used as', () {
      expect(compileErrorOf(wrapMain('u32 m = ~0;')),
          contains('the constant -1 does not fit in u32'));
      expect(compileErrorOf(wrapMain('u8 b = 300;')),
          contains('the constant 300 does not fit in u8'));
      expect(compileErrorOf(wrapMain('u8 b = 1; b = 256;')), contains("assignment to 'b'"));
      expect(compileErrorOf(wrapMain('u8 b = 1; b += 300;')), contains("'+=' on 'b'"));
      expect(compileErrorOf(wrapMain('u32 x = 1; if (x < -1) { x = 2; }')),
          contains("operand of '<'"));
      expect(compileErrorOf('void f(u8 a) { }\n${wrapMain('f(256);')}'),
          contains('argument 1'));
      expect(compileErrorOf('u8 f() { return 256; }\n${wrapMain('f();')}'),
          contains("return value of 'f'"));
      expect(compileErrorOf(wrapMain('u8 b = 1; switch (b) { case 300: break; }')),
          contains('case label'));
      expect(compileErrorOf('u8 g = 256;\n${wrapMain('')}'),
          contains("global variable 'g'"));
    });

    test('values that fit are accepted', () {
      expect(
          compileErrorOf(wrapMain(
              'u32 m = 0xFFFFFFFF; s32 n = -1; u8 b = 255; s8 c = -128; s32 x = 1; if (x < -1) { x = 2; }')),
          isNull);
      expect(compileErrorOf(wrapMain('u32 x = (1 << 40) >> 20;')), isNull);
    });

    test('a const has its declared type and must fit it', () {
      expect(compileErrorOf('const u32 X = -1;\n${wrapMain('')}'),
          contains("constant 'X': the value -1 does not fit in u32"));
      expect(compileErrorOf('const u8 A = 200;\n${wrapMain('u32 x = A + A;')}'),
          contains('overflows u8'));
      expect(compileErrorOf('const s32 N = -5;\n${wrapMain('s32 x = N * 2;')}'), isNull);
    });

    test('constant operations are folded exactly', () {
      final asm = compileSource(wrapMain('u32 r = 0; if (-1 < 0) { r = 1; } else { r = 2; }'));
      expect(mnemonics(asm), isNot(contains('SLE')));
      expect(asm, isNot(contains('LD      R1, 2')));
      expect(compileErrorOf(wrapMain('u32 x = 5 / 0;')),
          contains('division by zero in constant expression'));
      expect(compileErrorOf(wrapMain('u32 y = 3; u32 x = y / 0;')), contains('division by zero'));
    });
  });

  group('reference flow analysis', () {
    const point = 'type P { u32 x; };\n';
    String prog(String body, [String before = '']) => '$point$before${wrapMain(body)}';

    test('a destroyed or unset reference is null', () {
      expect(compileErrorOf(prog('P p = P.create(); p.destroy(); p.x = 1;')),
          contains("'p' is null here"));
      expect(compileErrorOf(prog('u32 a[]; a[0] = 1;')), contains("'a' is null here"));
    });

    test('moves are followed through branches', () {
      expect(
          compileErrorOf(
              prog('P p = P.create(); P q = 0; u32 c = 1; if (c == 1) { q = p; } p.x = 1;')),
          contains("'p' may have been moved"));
      expect(
          compileErrorOf(prog(
              'P p = P.create(); P q = 0; u32 c = 1; if (c == 1) { q = p; } else { p.x = 1; }')),
          isNull);
      expect(compileErrorOf(prog('u32 a[] = u32.createArray(3); u32 b[] = a; a[0] = 1;')),
          contains("'a' was moved"));
    });

    test('exists() narrows a reference', () {
      const find = 'P find(u32 k) { if (k == 0) { return 0; } return P.create(); }\n';
      expect(compileErrorOf(prog('P p = find(1); p.x = 1;', find)),
          contains("'p' may be null here; check it with 'p.exists()' first"));
      expect(compileErrorOf(prog('P p = find(1); if (p.exists()) { p.x = 1; }', find)), isNull);
      expect(compileErrorOf(prog('P p = find(1); if (!p.exists()) { return; } p.x = 1;', find)),
          isNull);
      expect(compileErrorOf(prog('P p = 0; if (p == 0) { p = P.create(); } p.x = 1;')), isNull);
      expect(compileErrorOf(prog('P p = find(1); if (p.exists() && p.x == 0) { p.x = 2; }', find)),
          isNull);
    });

    test('a function whose every return is valid gives valid references', () {
      expect(compileErrorOf(prog('P p = make(); p.x = 1;', 'P make() { return P.create(); }\n')),
          isNull);
      expect(
          compileErrorOf(prog('P p = make(3); p.x = 1;',
              'P make(u32 n) { if (n == 0) { return P.create(); } return make(n - 1); }\n')),
          isNull);
    });

    test('loops are followed to a fixed point', () {
      expect(
          compileErrorOf(prog(
              'u32 a[] = u32.createArray(3); u32 i = 0; while (i < 3) { a[i] = i; if (i == 1) { a.destroyArray(); } i += 1; }')),
          contains("'a' may be null here"));
    });

    test('references from globals may be null', () {
      expect(compileErrorOf('u32 g[];\n${wrapMain('u32 d[] = g; d[0] = 1;')}'),
          contains("'d' may be null here"));
    });

    test('a null argument for a record parameter is an error', () {
      expect(compileErrorOf(prog('use(0);', 'void use(P a) { a.x = 1; }\n')),
          contains("argument 1 of 'use' is null"));
    });
  });

  group('run-time reference checks', () {
    const prog = 'type P { u32 x; };\nP g = 0;\nu32 arr[];\n'
        'void main() { g.x = 1; arr[0] = 2; u32 n = arr.len; }\n';

    test('references in globals are checked before use', () {
      final asm = compileSource(prog);
      expect(asm, contains("Null reference trap (global 'g')"));
      expect(asm, contains("Null reference trap (global 'arr')"));
    });

    test('allocation failure traps', () {
      final asm = compileSource(wrapMain('u32 a[] = u32.createArray(4); a.destroyArray();'));
      expect(asm, contains('Null reference trap (allocation failed)'));
    });

    test('-fno-reference-check removes the checks', () {
      final asm = compileSource(prog, referenceCheck: false);
      expect(asm, isNot(contains('Null reference trap')));
    });
  });

  group('error locations', () {
    test('code generation errors name file, line and column', () {
      final err = compileErrorOf('void main() {\n    u8 b = 300;\n}\n')!;
      expect(err, matches(r'main\.act:2:\d+: variable .b.: the constant 300'));
      final flow = compileErrorOf('type P { u32 x; };\nvoid main() {\n'
          '    P p = P.create();\n    p.destroy();\n    p.x = 1;\n}\n')!;
      expect(flow, matches(r'main\.act:5:\d+: '));
      expect(compileErrorOf('u32 f(u32 a);\nvoid main() { }\n'),
          matches(r'main\.act:1:\d+: .f. is declared but never defined'));
    });
  });

  group('bool, true and false', () {
    test('true and false are 1 and 0', () {
      expect(compileErrorOf(wrapMain('u32 n = true + true; bool z = false;')), isNull);
      expect(compileErrorOf(wrapMain('u32 true = 2;')), contains('true'));
    });

    test('a bool constant must be 0 or 1', () {
      expect(compileErrorOf(wrapMain('bool b = 2;')),
          contains('the constant 2 does not fit in bool'));
      expect(compileErrorOf(wrapMain('bool b = true; if (b == 2) { }')), contains('bool'));
    });

    test('other values are stored as 0 or 1', () {
      final asm = compileSource(wrapMain('u32 x = 7; bool b = x; bool c = x > 3;'));
      expect('Store as a bool'.allMatches(asm).length, 1);
    });

    test('-D cannot redefine true or false', () {
      expect(compileErrorOf(wrapMain(''), defines: ['true=0']), contains('cannot be redefined'));
    });
  });

  group('reference fields', () {
    const node = 'type N { u32 v; ref N next; u32 d[]; };\n';

    test('layout: a reference field is one pointer', () {
      expect(compileErrorOf('${node}verify(sizeof(N) == 12, "size");\n${wrapMain('')}'), isNull);
    });

    test('ref needs a user-defined type', () {
      expect(compileErrorOf('type N { ref u32 x; };\n${wrapMain('')}'),
          contains("'ref' needs a user-defined type"));
    });

    test('a value stored on the stack cannot go in a reference field', () {
      expect(compileErrorOf('$node${wrapMain('N a = N.create(); N s; a.next = s;')}'),
          contains("to reference field 'next'"));
    });

    test('storing a variable in a field moves it', () {
      expect(compileErrorOf('$node${wrapMain('N a = N.create(); N b = N.create(); a.next = b; b.v = 1;')}'),
          contains("'b' was moved"));
    });

    test('uses through a field are checked at run time', () {
      final asm = compileSource('$node${wrapMain('N a = N.create(); a.next.v = 1; a.d[0] = 2;')}');
      expect(asm, contains("Null reference trap (field 'next')"));
      expect(asm, contains("Null reference trap (field 'd')"));
      expect(asm, contains('Dynamic heap out-of-bounds trap (d)'));
    });
  });

  group('allocation', () {
    test('allocations are zeroed', () {
      final asm = compileSource(wrapMain('u32 a[] = u32.createArray(4); a.destroyArray();'));
      expect(asm, contains('_rt_alloc_zero'));
    });
  });

  group('undeclared functions', () {
    test('a call to a function nothing declares is an error', () {
      expect(compileErrorOf(wrapMain('u32 x = add(1, 2);')),
          contains("'add' is not declared; import the file that defines it"));
    });

    test('an asm prototype promises the routine', () {
      expect(compileErrorOf('asm u32 add(u32 a, u32 b);\n${wrapMain('u32 x = add(1, 2);')}'), isNull);
    });
  });

  group('warnings and information', () {
    test('notes carry their location and severity', () {
      final cg = CodeGen();
      cg.note(NoteSeverity.info, 'just so you know', VarAccessNode('x')..loc = 'a.act:3:4');
      expect(cg.notes.single.format('action'), equals('action: info: a.act:3:4: just so you know'));
      final d = Diagnostic.fromNote(cg.notes.single);
      expect(d.severity, equals(DiagnosticSeverity.info));
      expect(d.line, equals(3));
      expect(d.message, equals('just so you know'));
    });
  });
}
