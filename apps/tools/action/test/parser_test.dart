import 'package:action/action.dart';
import 'package:test/test.dart';

ProgramNode parse(String src) => Parser(tokenize(src)).parseProgram();

String? parseErrorOf(String src) {
  try {
    parse(src);
    return null;
  } on CompileError catch (e) {
    return e.message;
  }
}

void main() {
  group('parser', () {
    test('parses functions, records and globals', () {
      final prog = parse('''
        type P { u32 x; u8 tag[4]; };
        u32 g = 3;
        u32 f(P p, u32 a[]) { return p.x + a[0]; }
      ''');
      expect(prog.decls.length, 3);
    });

    group('pointer syntax is rejected', () {
      test('pointer types', () {
        expect(parseErrorOf('void f(u32* p) { }'), contains('no pointers'));
        expect(parseErrorOf('void main() { u8* p = 0; }'), contains('no pointers'));
        expect(parseErrorOf('u32* g;'), contains('no pointers'));
      });
      test('dereference and address-of', () {
        expect(parseErrorOf('void main() { u32 x = 1; u32 y = *x; }'),
            contains("pointer dereference '*'"));
        expect(parseErrorOf('void main() { u32 x = 1; f(&x); }'),
            contains("address-of '&'"));
      });
      test('-> member access', () {
        expect(parseErrorOf('type P { u32 x; }; void f(P p) { u32 y = p->x; }'),
            isNot(isNull));
      });
      test('multiplication and bitwise and are still fine', () {
        expect(parseErrorOf('void main() { u32 a = 2 * 3; u32 b = a & 1; a *= b; }'),
            isNull);
      });
      test('fn types still use ->', () {
        expect(parseErrorOf('type F = fn(u32) -> u32;'), isNull);
      });
    });

    test('yield and wait_until parse as ordinary calls', () {
      final prog = parse('u16 t(pt p) { yield(p, 1); wait_until(p, 2, 1); }');
      final f = prog.decls.single as FuncDeclNode;
      final stmts = f.body!.stmts;
      expect(stmts[0], isA<ExprStmtNode>());
      expect((stmts[0] as ExprStmtNode).expr, isA<CallNode>());
      expect(((stmts[1] as ExprStmtNode).expr as CallNode).args.length, 3);
    });

    test('continue is a statement', () {
      final f = parse('void f() { while (1) { continue; } }').decls.single as FuncDeclNode;
      final w = f.body!.stmts.single as WhileNode;
      expect((w.body as BlockNode).stmts.single, isA<ContinueNode>());
    });

    test('array dimensions and @ addresses may be constant expressions', () {
      expect(parseErrorOf('const u32 N = 4; u32 a[N * 2]; u32 r @ 0x8000 + N;'), isNull);
    });

    test('trap(N) name() { ... } declares a trap handler', () {
      final f = parse('trap(3) h() { }').decls.single as FuncDeclNode;
      expect(f.name, 'h');
      expect(f.trapExpr, isA<IntLitNode>());
      expect(f.params, isEmpty);
      expect(parseErrorOf('const u32 T = 3; trap(T + 1) h() { }'), isNull);
    });

    test('trap handler syntax is enforced', () {
      expect(parseErrorOf('trap(3) h { }'), contains("written 'trap(N) h() { ... }'"));
      expect(parseErrorOf('trap(3) h(u32 a) { }'), contains('cannot take arguments'));
      expect(parseErrorOf('trap(3) h(void) { }'), contains('cannot take arguments'));
      expect(parseErrorOf('trap(3) h();'), contains('needs a body'));
      expect(parseErrorOf('inline trap(3) h() { }'), contains('cannot be inline'));
      expect(parseErrorOf('void h() @ trap(3) { }'), contains("written 'trap(N) h() { ... }'"));
    });

    test('preprocessor lines are not accepted', () {
      expect(() => parse('#define X 1'), throwsA(isA<CompileError>()));
    });
  });
}
