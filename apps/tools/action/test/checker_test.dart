// The checker on its own: it finds the errors code generation used to find,
// emits nothing, and records the type of each expression.

import 'dart:io';

import 'package:action/action.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Parses [source] (as `main.act` in a temporary directory) and checks it
/// with a fresh checker, which is returned.
Checker checkSource(String source, {Target? target}) {
  final dir = Directory.systemTemp.createTempSync('action_check_');
  try {
    final main = File('${dir.path}/main.act')..writeAsStringSync(source);
    final options = CompileOptions(includeDirs: [dir.path]);
    final program = loadProgram([main.path], options);
    return Checker(target ?? ParticleAsmBackend())..check(program);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The message of the error checking [source] throws, without the file
/// name, or null if it passes.
String? checkErrorOf(String source) {
  try {
    checkSource(source);
    return null;
  } on CompileError catch (e) {
    return e.message.replaceFirst(RegExp(r'^.*?main\.act:'), '');
  }
}

void main() {
  group('errors', () {
    const programs = {
      'undefined name in a body': 'void main() { u32 v = zz; }',
      'break outside a loop': 'void main() { break; }',
      'constant out of range': 'void main() { u8 x = 1; x = 300; }',
      'undeclared function': 'void main() { nope(1); }',
      'string too long': 'void main() { string s[2] = "abc"; }',
      'global initializer': 'u32 v = 3;\nu32 g = v + 1;\nvoid main() { }',
      'inline argument': 'inline u8 f(u8 a) { return a; }\nvoid main() { u32 v = f(300); }',
    };
    for (final e in programs.entries) {
      test('${e.key}: same message and place as compiling', () {
        final checked = checkErrorOf(e.value);
        expect(checked, isNot(isNull));
        String? compiled;
        try {
          compileSource(e.value);
        } on CompileError catch (err) {
          compiled = err.message.replaceFirst(RegExp(r'^.*?main\.act:'), '');
        }
        expect(checked, compiled);
      });
    }

    test('a branch left out by a constant condition is not checked', () {
      expect(checkErrorOf('void main() { if (0) { u32 v = zz; } }'), isNull);
      expect(checkErrorOf('void main() { if (1) { u32 v = zz; } }'),
          contains("undefined identifier 'zz'"));
    });
  });

  test('checking emits nothing', () {
    final backend = ParticleAsmBackend();
    checkSource('u32 f(u32 a) { return a + 1; }\nvoid main() { u32 v = f(2); }',
        target: backend);
    expect(backend.asm, isEmpty);
  });

  test('the type of each expression is recorded', () {
    final c = checkSource('''
type P { s16 x; };
u16 f(u8 a) { return a; }
void main() {
    P p = P.create();
    s8 a = -1;
    u32 v = f(2);
    u32 w = a + v;
    s16 y = p.x;
}
''');
    String typeOf(bool Function(AstNode) which) {
      final e = c.exprTypes.entries.lastWhere((e) => which(e.key));
      return '${e.value.$1}${e.value.$2 ? '*' : ''}';
    }

    expect(typeOf((n) => n is CallNode && n.name == 'f'), 'u16');
    expect(typeOf((n) => n is VarAccessNode && n.name == 'a'), 's8');
    expect(typeOf((n) => n is MemberAccessNode && n.member == 'x'), 's16');
    expect(typeOf((n) => n is HeapAllocNode), 'P*');
  });

  group('scopes', () {
    test('a local constant ends with its block', () {
      expect(checkErrorOf('void main() { { const u32 K = 1; } u32 v = K; }'),
          contains("undefined identifier 'K'"));
      expect(checkErrorOf('void main() { u32 v = K; const u32 K = 1; }'),
          contains("undefined identifier 'K'"));
      expect(checkErrorOf('void main() { { const u32 K = 1; } { const u32 K = 2; } }'), isNull);
    });

    test("a function's constants are not seen by the next one", () {
      expect(checkErrorOf('void f() { const u32 N = 1; }\nvoid main() { u32 v = N; }'),
          contains("undefined identifier 'N'"));
    });

    test('a local constant cannot reuse a name in scope', () {
      expect(checkErrorOf('const u32 G = 2;\nvoid main() { const u32 G = 3; }'),
          contains("local constant 'G' has the same name as a global constant"));
      expect(checkErrorOf('u32 g;\nvoid main() { const u32 g = 3; }'),
          contains('the same name as a global variable'));
      expect(checkErrorOf('void main() { const u32 K = 1; const u32 K = 2; }'),
          contains("constant 'K' is already declared in this block"));
      expect(checkErrorOf('void f(u32 n) { const u32 n = 2; }\nvoid main() { }'),
          contains("constant 'n' has the name of a parameter of 'f'"));
    });

    test("a local's type does not replace a global's in later functions", () {
      final asm = compileSource(
          'u8 count;\nvoid a() { u32 count = 1; }\nvoid main() { count = 255; }');
      expect(functionBody(asm, 'main'), contains('ST8'));
    });

    test("an inner block's constant hides an outer block's until the block ends", () {
      final asm = compileSource('void main() {\n'
          '    const u32 K = 1;\n'
          '    u32 a = K;\n'
          '    { const u32 K = 2; a = K; }\n'
          '    a = K + 4;\n'
          '}\n');
      final body = functionBody(asm, 'main');
      expect(body, contains('LD      R1, 2'));
      expect(body, contains('LD      R1, 5'));
    });

    test("an inline function's body cannot use the caller's constants or variables", () {
      expect(checkErrorOf('inline u32 f() { return N; }\nvoid main() { const u32 N = 1; u32 v = f(); }'),
          contains("'N' belongs to 'main', which inline function 'f' is expanded into"));
      expect(checkErrorOf('inline u32 f() { return i + 1; }\nvoid main() { u32 i = 1; u32 v = f(); }'),
          contains("'i' belongs to 'main', which inline function 'f' is expanded into"));
      expect(checkErrorOf('inline void f() { i = 2; }\nvoid main() { u32 i = 1; f(); }'),
          contains("'i' belongs to 'main'"));
    });

    test("an inline function's body sees the global a caller's local hides", () {
      final asm = compileSource('u8 g;\n'
          'inline void f() { g = 7; }\n'
          'void main() { u32 g = 1; f(); }\n');
      final body = functionBody(asm, 'main');
      expect(body, contains('LOAD32  R14, _g'));
    });

    test("an inline function's arguments are evaluated in the caller's scope", () {
      // The second argument is the caller's x, not the parameter x
      final asm = compileSource('inline u32 f(u32 x, u32 y) { return x + y; }\n'
          'void main() { u32 x = 5; u32 v = f(1, x); }\n');
      expect(asm, contains('_main:'));
      expect(checkErrorOf('inline u32 f(u32 x, u32 y) { return x + y; }\n'
          'void main() { u32 v = f(1, x); }'), contains("undefined identifier 'x'"));
    });
  });

  group('inline functions', () {
    test('may be declared after their callers', () {
      final asm = compileSource('void main() { u32 v = f(2); }\ninline u32 f(u32 a) { return a + 1; }');
      expect(asm, isNot(contains('RCALL   _f')));
    });

    test('cannot be recursive', () {
      expect(checkErrorOf('inline u32 f(u32 a) { return f(a); }\nvoid main() { u32 v = f(1); }'),
          contains("'f' is inline and calls itself; inline functions cannot be recursive"));
      expect(
          checkErrorOf('inline u32 f(u32 a) { return g(a); }\n'
              'inline u32 g(u32 a) { return f(a); }\nvoid main() { u32 v = f(1); }'),
          contains("'f' is inline and calls itself (through 'g')"));
    });
  });

  group('sizeof', () {
    test('of a name that is not declared is an error', () {
      expect(checkErrorOf('void main() { u32 v = sizeof(zz); }'),
          contains("1:22: undefined identifier 'zz'"));
      expect(checkErrorOf('void main() { u32 v = sizeof(q[1]); }'), contains("undefined identifier 'q'"));
    });

    test('of a constant is the size of its type', () {
      expect(checkErrorOf('const u8 K = 1;\nverify(sizeof(K) == 1, "u8");\nvoid main() { }'), isNull);
    });
  });

  group('locations', () {
    test('errors found while classifying references have a place', () {
      expect(checkErrorOf('type P { u32 x; };\nvoid main() { u32 v = P.nope; }'),
          startsWith("2:23: Type 'P' has no method 'nope'"));
    });

    test('an unknown field type, and types that contain each other', () {
      expect(checkErrorOf('type S {\n    Point;\n};\nvoid main() { }'),
          startsWith("2:4: type 'S': 'Point' is not a declared type"));
      expect(checkErrorOf('type A { B b; };\ntype B { A a; };\nvoid main() { }'),
          startsWith("1:0: types 'A', 'B' contain each other"));
    });

    test('an unsupported return type', () {
      expect(checkErrorOf('u64 f() { return 1; }\nvoid main() { }'), startsWith('1:0: 64-bit'));
    });
  });

  group('memory built-ins', () {
    test('peek32, poke32, poke16 and callAddr', () {
      final asm = compileSource('void main() {\n'
          '    u32 a = 0x9000;\n'
          '    poke32(a, 7);\n'
          '    poke16(a + 4, 3);\n'
          '    u32 v = peek32(a);\n'
          '    u32 r = callAddr(a);\n'
          '}\n');
      final body = functionBody(asm, 'main');
      expect(body, contains('ST32    (R1), R2'));
      expect(body, contains('ST16    (R1), R2'));
      expect(body, contains('LD32    R1, (R1)'));
      expect(body, contains('JMP     R13, R14'));
    });

    test('take a fixed number of arguments that fit', () {
      expect(checkErrorOf('void main() { poke32(1); }'),
          contains('poke32 takes 2 arguments (address, value), got 1'));
      expect(checkErrorOf('void main() { u32 v = peek32(); }'),
          contains('peek32 takes 1 argument (address), got 0'));
      expect(checkErrorOf('void main() { poke16(0x9000, 0x10000); }'),
          contains('value of poke16: the constant 65536 does not fit in u16'));
    });

    test('a function of the same name is used instead', () {
      final asm = compileSource('u32 peek32(u32 a) { return a; }\nvoid main() { u32 v = peek32(3); }');
      expect(asm, contains('RCALL   _peek32'));
    });
  });

  group('strings and arrays of references', () {
    test('a fixed array of strings', () {
      expect(checkErrorOf('void main() { string n[3][8]; n[0] = "abc"; u32 a = n.len; u32 b = n[0].len; u32 c = n[1].capacity; }'),
          isNull);
    });

    test('copying into a string buffer', () {
      expect(checkErrorOf('void main() { string s[4]; s = "abcd"; }'),
          contains("String literal length (4) does not fit in 's', which holds 3 characters and the terminator"));
      expect(checkErrorOf('void main() { string s[4]; u32 n = 5; s = n; }'),
          contains("cannot assign a 'u32' to 's'; only a string can be copied into it"));
      expect(checkErrorOf('void main() { string s[3] = "abc"; }'),
          contains('it holds 2 characters and the terminator'));
    });

    test('arrays of references', () {
      expect(checkErrorOf('void main() { ref u32 xs[4]; }'),
          contains("an array of references needs a user-defined type or 'string', not 'u32'"));
      expect(checkErrorOf('type N { u32 v; };\ntype M { u32 w; };\nvoid main() { ref N ns[2]; ns[0] = M.create(); }'),
          contains("Cannot assign instance of type 'M' to an element of 'ns', a reference to 'N'"));
      expect(checkErrorOf('type N { u32 v; };\nvoid main() { ref N ns[2]; N n; ns[0] = n; }'),
          contains("cannot assign 'n', a 'N' stored on the stack, to an element of 'ns'"));
      expect(checkErrorOf('type N { u32 v; };\nu32 t(ref N xs[]) { return xs.len; }\nvoid main() { N plain[2]; u32 v = t(plain); }'),
          contains('an array of references'));
    });

    test("main's command line is read-only", () {
      expect(checkErrorOf('u32 main(ref string args[]) { args[1][0] = 65; return 0; }'),
          contains("'args' is read-only"));
      expect(checkErrorOf('void main(u32 a) { }'),
          contains("'main' takes no parameters, or the command line as 'ref string args[]'"));
      expect(checkErrorOf('u32 main(ref string args[]) { string s[64] = args[0]; return s.len; }'), isNull);
    });
  });

  group('heap arrays of references', () {
    test('createArray makes the kind the target needs', () {
      expect(checkErrorOf('type N { u32 v; };\nvoid main() { ref N xs[] = N.createArray(2); xs[0] = N.create(); u32 n = xs.len; }'),
          isNull);
      expect(checkErrorOf('type N { u32 v; };\nvoid main() { N plain[] = N.createArray(2); ref N refs[] = plain; }'),
          contains("Array type mismatch: 'plain' is an array of values, and 'refs' an array of references"));
    });

    test('fields that are arrays of references', () {
      expect(checkErrorOf('type N { u32 v; ref N kids[2]; ref N more[]; };\n'
          'void main() { N n = N.create(); n.kids[0] = N.create(); n.more = N.createArray(3); }'), isNull);
      expect(checkErrorOf('type T { ref u32 kids[2]; };\nvoid main() { }'),
          contains("an array of references needs a user-defined type or 'string', not 'u32'"));
    });

    test("the command line's strings have no capacity", () {
      expect(checkErrorOf('u32 main(ref string args[]) { return args[0].capacity; }'),
          contains("the command line's strings have no capacity"));
      expect(checkErrorOf('void main() { ref string w[2]; w[0] = "a"; u32 c = w[0].capacity; }'), isNull);
    });
  });

  group('block-scoped variables', () {
    test('a name declared twice in one block', () {
      expect(checkErrorOf('void main() { u32 x = 1; u32 x = 2; }'),
          contains("variable 'x' is already declared in this block (at "));
      expect(checkErrorOf('void main() { u32 x = 1; { u8 x = 2; } { u16 x = 3; } }'), isNull);
    });

    test('a variable is not seen outside its block', () {
      expect(checkErrorOf('void main() { { u32 t = 1; } u32 y = t; }'),
          contains("undefined identifier 't'; the 't' declared at "));
      expect(checkErrorOf('void main() { for (u32 i : 0..2) { } u32 y = i; }'),
          contains("undefined identifier 'i'"));
      expect(checkErrorOf('void main() { u32 y = t; u32 t = 1; }'),
          contains("undefined identifier 't'"));
    });

    test("a parameter's name in the outermost block", () {
      expect(checkErrorOf('u32 f(u32 n) { u32 n = 2; return n; }\nvoid main() { }'),
          contains("variable 'n' has the name of a parameter of 'f'"));
      expect(checkErrorOf('u32 f(u32 n) { if (n > 0) { u32 n = 2; return n; } return n; }\nvoid main() { }'),
          isNull);
    });

    test('a local may hide a global variable, a constant may not', () {
      expect(checkErrorOf('u32 g;\nvoid main() { u32 g = 1; g += 1; }'), isNull);
      expect(checkErrorOf('u32 g;\nvoid main() { { u32 g = 1; } g = 2; }'), isNull);
      expect(checkErrorOf('u32 g;\nvoid main() { const u32 g = 3; }'),
          contains('the same name as a global variable'));
    });

    test('each switch case is a block', () {
      expect(checkErrorOf('void main() { u32 c = 1; switch (c) { case 0: u32 v = 1; break; case 1: u32 v = 2; } }'),
          isNull);
      expect(checkErrorOf('void main() { u32 c = 1; switch (c) { case 0: u32 v = 1; break; case 1: c = v; } }'),
          contains("undefined identifier 'v'"));
    });

    test('messages use the names in the source', () {
      final m = checkErrorOf('void main() { u32 x = 1; { u8 x = 300; } }');
      expect(m, contains("variable 'x': the constant 300"));
      expect(m!.contains('~'), isFalse);
    });
  });

  group('comparisons and references', () {
    const n = 'type N { u32 v; ref N next; };\n';
    test('strings, arrays and records are not compared with ==', () {
      expect(checkErrorOf('void main() { string a[4] = "ab"; string b[4] = "ab"; if (a == b) trap(1); }'),
          contains('use stringEquals(a, b) or stringCompare(a, b)'));
      expect(checkErrorOf('u32 f(string x) { return x != "a"; }\nvoid main() { }'),
          contains("strings cannot be compared with '!='"));
      expect(checkErrorOf('void main() { u32 a[2]; u32 b[2]; if (a == b) trap(1); }'),
          contains("arrays cannot be compared with '=='; compare their elements"));
      expect(checkErrorOf('${n}void main() { N a; N b; u32 c = a == b; }'),
          contains('values of user-defined types cannot be compared'));
    });

    test('references are compared with sameAs', () {
      expect(checkErrorOf('${n}void main() { N a = N.create(); N b = N.create(); bool s = a == b; a.destroy(); b.destroy(); }'),
          contains('references are compared with a.sameAs(b)'));
      expect(checkErrorOf('${n}void main() { N a = N.create(); bool s = a.sameAs(a); a.destroy(); }'), isNull);
      expect(checkErrorOf('${n}void main() { N a; N b; bool s = a.sameAs(b); }'),
          contains("the 'N' value 'a' is not a reference"));
      expect(checkErrorOf('${n}void main() { ref N r; if (r != 0) trap(1); }'),
          contains('use r.exists()'));
    });

    test('0 is not a reference', () {
      expect(checkErrorOf('${n}void main() { N p = 0; }'),
          contains("declare one that starts empty as 'ref N p;'"));
      expect(checkErrorOf('${n}void main() { N p = N.create(); p.next = 0; p.destroy(); }'),
          contains("empty it with p.next.unset()"));
      expect(checkErrorOf('${n}N f() { return 0; }\nvoid main() { }'),
          contains("the result of 'f' is a reference, so it cannot be 0"));
      expect(checkErrorOf('void main() { u32 a[] = 0; }'), contains("starts empty: 'u32 a[];'"));
    });

    test('ref T name; and unset()', () {
      expect(checkErrorOf('${n}ref N g;\nvoid main() { ref N r; r = N.create(); r.next = N.create(); '
          'r.next.destroy(); r.next.unset(); g = r; }'), isNull);
      expect(checkErrorOf('void main() { ref u32 x; }'),
          contains("a reference needs a user-defined type"));
      expect(checkErrorOf('${n}void main() { N p = N.create(); p.unset(); }'),
          contains("'p' still owns its value"));
      expect(checkErrorOf('void main() { u32 x; x.unset(); }'),
          contains('unset() empties a reference'));
      expect(checkErrorOf('${n}void main() { ref N r; u32 v = r.unset(); }'),
          contains('unset() is a statement'));
    });

    test('arrays are not assigned', () {
      expect(checkErrorOf('void main() { u32 a[2]; u32 b[2]; b = a; }'),
          contains("arrays cannot be assigned; 'b' is an array, so copy its elements"));
    });
  });

  group('calls and returns', () {
    test('the number of arguments', () {
      expect(checkErrorOf('u32 one(u32 a) { return a; }\nvoid main() { u32 v = one(1, 2); }'),
          contains("'one' takes 1 argument, not 2"));
      expect(checkErrorOf('u32 two(u32 a, u32 b) { return a; }\nvoid main() { u32 v = two(1); }'),
          contains("'two' takes 2 arguments, not 1"));
    });

    test('a function that returns nothing has no value', () {
      expect(checkErrorOf('void f() { }\nvoid main() { u32 v = f(); }'),
          contains("'f' returns nothing, so its call has no value to use"));
      expect(checkErrorOf('void f() { }\nvoid main() { f(); }'), isNull);
    });

    test('a slice of a string is not a string', () {
      expect(checkErrorOf('u32 l(string s) { return s.len; }\nvoid main() { string a[8] = "abc"; u32 v = l(a[1..2]); }'),
          contains('a slice of a string is an array of u8 characters'));
    });

    test('a missing return', () {
      expect(checkErrorOf('u32 f(u32 x) { if (x > 1) { return 1; } }\nvoid main() { }'),
          contains("missing return at the end of 'f'"));
      expect(checkErrorOf('u32 f(u32 x) { trap(15); }\nvoid main() { }'),
          contains("missing return at the end of 'f'"));
      for (final body in [
        'if (x > 1) { return 1; } else { return 2; }',
        'while (1) { if (x > 3) return x; x += 1; }',
        'switch (x) { case 1: return 1; default: return 2; }',
        'trap(0);',
      ]) {
        expect(checkErrorOf('u32 f(u32 x) { $body }\nvoid main() { }'), isNull, reason: body);
      }
      expect(checkErrorOf('u32 f(u32 x) { switch (x) { case 1: return 1; } }\nvoid main() { }'),
          contains('missing return'));
      expect(checkErrorOf('u32 f(u32 x) { while (1) { if (x > 3) break; x += 1; } }\nvoid main() { }'),
          contains('missing return'));
    });
  });

  group('conversions and literals', () {
    test('T(x) converts numbers', () {
      expect(checkErrorOf('void main() { u32 x = 300; u8 a = u8(x); s32 b = s32(x); bool c = bool(x); }'), isNull);
      expect(checkErrorOf('void main() { u8 a = u8(300); }'),
          contains('u8(...): the constant 300 does not fit in u8'));
      expect(checkErrorOf('void main() { string s[4] = "a"; u32 v = u32(s); }'),
          contains("u32(...) converts a number, not the string 's'"));
      expect(checkErrorOf('type Byte = u8;\nvoid main() { u32 x = 9; Byte b = Byte(x); }'), isNull);
    });

    test('binary literals and digit separators', () {
      expect(checkErrorOf('void main() { u32 a = 0b1010_0101; u32 b = 1_000_000; u32 c = 0xFF_FF; }'), isNull);
      expect(checkErrorOf('void main() { u32 a = 0b102; }'),
          contains("invalid number '0b102': a binary number has the digits 0 and 1"));
      expect(checkErrorOf('void main() { u32 a = 1_; }'), contains("invalid number '1_'"));
    });

    test('byte and halfword memory access', () {
      expect(checkErrorOf('void main() { poke8(256, 1); u8 b = peek8(256); u16 h = peek16(256); }'), isNull);
      expect(checkErrorOf('void main() { poke8(256, 300); }'),
          contains('value of poke8: the constant 300 does not fit in u8'));
    });
  });

  group('initializers and constants', () {
    test('brace initializers', () {
      expect(checkErrorOf('u16 g[3] = {1, 2};\nvoid main() { u32 a[3] = {g[0], 2}; u8 m[2][2] = {{1}, {2, 3}}; }'), isNull);
      expect(checkErrorOf('void main() { u32 a[2] = {1, 2, 3}; }'),
          contains("'a' has 2 elements, but 3 values are given"));
      expect(checkErrorOf('u32 g = 1;\nu32 t[2] = {g, 1};\nvoid main() { }'),
          contains("'t[0]': the values of a global are constants"));
      expect(checkErrorOf('void main() { u32 c = 1; if (c) u32 a[2] = {1}; }'),
          contains('must be declared inside'));
      expect(checkErrorOf('void main() { u32 a[] = {1}; }'), contains('a reference to a heap array'));
      expect(checkErrorOf('type P { u32 x; };\nvoid main() { P p = {y: 1}; }'),
          contains("type 'P' has no field 'y'"));
      expect(checkErrorOf('u8 t[2] = {1, 300};\nvoid main() { }'),
          contains("'t[1]': the constant 300 does not fit in u8"));
    });

    test('constant tables and string constants', () {
      expect(checkErrorOf('const u32 T[2] = {1, 2};\nconst string S = "ab";\nu8 b[S.len];\n'
          'void main() { const u8 L[2] = {3, 4}; u32 v = T[1] + L[0] + S.len; }'), isNull);
      expect(checkErrorOf('const u32 T[2] = {1, 2};\nvoid main() { T[0] = 3; }'),
          contains("'T' is a constant; its values cannot be changed"));
      expect(checkErrorOf('const u32 T[3];\nvoid main() { }'), contains("needs its values"));
      expect(checkErrorOf('const string G = 5;\nvoid main() { }'),
          contains("string constant 'G' is given a string literal"));
    });

    test('values that must not change are not passed to parameters that are written', () {
      const fns = 'void zero(u32 xs[]) { xs[0] = 0; }\nvoid viaZero(u32 ys[]) { zero(ys); }\n'
          'u32 sum(u32 xs[]) { return xs[0]; }\nvoid up(string s) { s[0] = 88; }\n';
      expect(checkErrorOf('const u32 T[2] = {1, 2};\n${fns}void main() { u32 v = sum(T); }'), isNull);
      expect(checkErrorOf('const u32 T[2] = {1, 2};\n${fns}void main() { viaZero(T); }'),
          contains("constant 'T' cannot be passed to 'viaZero': it changes its parameter 'ys'"));
      expect(checkErrorOf('${fns}void main() { up("ab"); }'),
          contains("a string literal cannot be passed to 'up'"));
    });
  });

  group('record values and function fields', () {
    const types = 'type Q { u8 a; };\ntype P { u32 x; Q q; };\ntype N { u32 v; ref N next; };\n';
    test('T.create(field: value)', () {
      expect(checkErrorOf('${types}void main() { P p = P.create(x: 1, q: {a: 2}); p.destroy(); }'), isNull);
      expect(checkErrorOf('${types}void main() { P p = P.create(1); p.destroy(); }'),
          contains('P.create() gives fields their values by name'));
      expect(checkErrorOf('${types}void main() { P p = P.create(z: 1); p.destroy(); }'),
          contains("type 'P' has no field 'z'"));
      expect(checkErrorOf('${types}void main() { N n = N.create(next: 0); n.destroy(); }'),
          contains("'next' is a reference, so it cannot be 0"));
    });

    test('copyFrom', () {
      expect(checkErrorOf('${types}void main() { P a; P b = P.create(); a.copyFrom(b); b.destroy(); }'), isNull);
      expect(checkErrorOf('${types}void main() { N a = N.create(); N b = N.create(); a.copyFrom(b); a.destroy(); b.destroy(); }'),
          contains("a 'N' holds references, so it cannot be copied"));
      expect(checkErrorOf('${types}void main() { P a; Q b; a.copyFrom(b); }'),
          contains("copyFrom() copies a 'P' from a 'P', not from a 'Q'"));
      expect(checkErrorOf('${types}void main() { P a; P b; u32 v = a.copyFrom(b); }'),
          contains('copyFrom() is a statement'));
    });

    test('fields and elements of function type', () {
      const fns = 'type Op = fn(u32) -> u32;\ntype H { u32 n; Op f; Op t[2]; };\nu32 id(u32 x) { return x; }\n';
      expect(checkErrorOf('${fns}void main() { H h = H.create(f: id, t: {id, id}); u32 v = h.f(1) + h.t[1](2); h.destroy(); }'),
          isNull);
      expect(checkErrorOf('${fns}u32 H.f(u32 x) { return x; }\nvoid main() { }'),
          contains("type 'H' has both a field and a method named 'f'"));
      expect(checkErrorOf('void main() { u32 a[2]; u32 v = a[0](1); }'),
          contains('is not a function value, so it cannot be called'));
    });
  });

  group('array results and open dimensions', () {
    test('functions return heap arrays and strings', () {
      expect(checkErrorOf('u32[] f(u32 n) { u32 a[] = u32.createArray(n); return a; }\n'
          'string[] g() { string s[] = string.create(4); return s; }\n'
          '(u16[], u32) h() { u16 a[] = u16.createArray(2); return (a, 2); }\n'
          'void main() { u32 a[] = f(2); a.destroyArray(); string s[] = g(); s.destroy(); '
          '(u16 b[], u32 n) = h(); b.destroyArray(); }'), isNull);
      expect(checkErrorOf('u32[] f() { u32 a[3]; return a; }\nvoid main() { }'),
          contains("the array 'a' is stored in place, so it cannot be returned"));
      expect(checkErrorOf('u32[] f(u32 xs[]) { return xs; }\nvoid main() { }'),
          contains("'xs' is borrowed from the caller"));
      expect(checkErrorOf('u32 f() { u32 a[] = u32.createArray(2); return a; }\nvoid main() { }'),
          contains("the result of 'f' is a u32, not the array 'a'"));
      expect(checkErrorOf('u32[] f() { return 0; }\nvoid main() { }'),
          contains("return a variable declared 'u32 name[];'"));
    });

    test('open array parameters of more dimensions', () {
      const t = 'u32 t(u32 m[][]) { return m.len + m[0].len + m[1][2]; }\n';
      expect(checkErrorOf('${t}void main() { u32 a[2][3]; u32 v = t(a); }'), isNull);
      expect(checkErrorOf('${t}void main() { u32 a[3]; u32 v = t(a); }'),
          contains("an array of 2 dimensions is expected here; 'a' has 1"));
      expect(checkErrorOf('${t}void main() { u8 a[2][2]; u32 v = t(a); }'),
          contains("an array of 'u32' is expected here; 'a' is an array of 'u8'"));
      expect(checkErrorOf('void f(u32 m[][][][]) { }\nvoid main() { }'),
          contains('at most 3 dimensions'));
    });
  });

  group('floating point on Particle', () {
    test('f32 and f64 are for the LLVM compiler', () {
      expect(checkErrorOf('void main() { f32 x = 1.5; }'),
          contains("floating-point type 'f32' is not supported by target backend 'particle' yet"));
    });
  });

  group('lambdas', () {
    const op = 'type Op = fn(u32) -> u32;\n';
    test('a lambda is a function value', () {
      expect(checkErrorOf('${op}u32 run(Op f) { return f(2); }\n'
          'void main() { const u32 K = 3; Op f = fn(u32 x) -> u32 { return x + K; }; '
          'u32 v = run(fn sq(u32 x) -> u32 { if (x == 0) return 0; return x * x + sq(0); }); }'), isNull);
    });

    test('it cannot use the variables of the function it is written in', () {
      expect(checkErrorOf('${op}void main() { u32 k = 3; Op f = fn(u32 x) -> u32 { return x + k; }; }'),
          contains("cannot use 'k', a variable of the function it is written in"));
      expect(checkErrorOf('${op}void main() { u32 k = 3; Op f = fn(u32 k) -> u32 { return k; }; }'), isNull);
    });

    test('its name is seen only inside it', () {
      expect(checkErrorOf('${op}void main() { Op f = fn sq(u32 x) -> u32 { return x; }; u32 v = sq(2); }'),
          contains("'sq' is not declared"));
    });

    test('a lambda is a value, of the right signature', () {
      expect(checkErrorOf('void main() { fn(u32 x) -> u32 { return x; }; }'),
          contains('a lambda is a value'));
      expect(checkErrorOf('${op}void main() { Op f = fn(u32 x, u32 y) -> u32 { return x; }; }'),
          contains('Function signature mismatch: cannot assign lambda at'));
      expect(checkErrorOf('${op}void main() { Op f = fn named(u32 x) -> u32 { if (x > 1) { return x; } }; }'),
          contains("missing return at the end of lambda 'named'"));
      expect(checkErrorOf('${op}Op g = fn(u32 x) -> u32 { return x; };\nvoid main() { }'),
          contains('a global starts with a constant value'));
    });
  });
}
