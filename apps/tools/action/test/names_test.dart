// Type constants, static functions, overloads, methods of string, Integer,
// and pub on the members of a type.

import 'dart:io';

import 'package:action/action.dart';
import 'package:test/test.dart';

import 'support.dart';

String _clean(String? m) => (m ?? '').replaceAll(RegExp(r'^.*?main\.act:'), 'main.act:');

void main() {
  final libDir = '${Directory.current.path}/../../../lib';
  final integer = File('$libDir/integer.act').readAsStringSync();
  final strings = File('$libDir/string.act').readAsStringSync();

  String build(String src) => compileSource(src, extraFiles: {'integer.act': integer, 'string.act': strings});

  String? errorOf(String src) {
    try {
      build(src);
      return null;
    } on CompileError catch (e) {
      return _clean(e.message);
    }
  }

  group('type constants', () {
    test('are written in the type and used as Type.NAME, constant expressions included', () {
      final asm = build('''
type Limits {
    const u32 MAX = 7;
    const s8 LOW = -3;
};
u8 table[Limits.MAX + 1];
const u32 TWICE = Limits.MAX * 2;
void main() {
    s32 v = Limits.LOW;
    u32 n = table.len + TWICE;
    switch (n) { case Limits.MAX: n = 0; }
}
''');
      expect(asm, contains('_table:'));
      expect(errorOf('type T { const u8 X = 300; };\nvoid main() { }\n'), contains("constant 'T.X': the value 300 does not fit in u8"));
      expect(errorOf('type T { const u8 X[2] = 1; };\nvoid main() { }\n'), contains('a constant of a type holds one value'));
    });
  });

  group('static functions', () {
    test('are called on the type; a method is not, and a static function is not called on a value', () {
      final asm = build('''
type Counter { u32 n; };
static u32 Counter.start() { return 5; }
u32 Counter.next() { this.n = this.n + 1; return this.n; }
void main() {
    Counter c;
    c.n = Counter.start();
    u32 v = c.next();
}
''');
      expect(asm, contains('_Counter.start:'));
      expect(asm, contains('RCALL   _Counter.start'));
      const base = 'type C { u32 n; };\nstatic u32 C.s() { return 1; }\nu32 C.m() { return 2; }\n';
      expect(errorOf('${base}void main() { u32 v = C.m(); }\n'),
          contains("'C.m' is a method: call it on a value, as x.m(...)"));
      expect(errorOf('${base}void main() { C c; u32 v = c.s(); }\n'),
          contains("'C.s' is a static function of 'C': call it as C.s(...)"));
      expect(errorOf('${base}void main() { u32 v = C.x(); }\n'), contains("type 'C' has no static function 'x'"));
      expect(errorOf('static u32 f() { return 1; }\nvoid main() { }\n'),
          contains("'static' is for a function of a type"));
    });
  });

  group('overloads', () {
    const twice = 'u32 twice(u32 x) { return x * 2; }\nu32 twice(u8 x) { return x * 3; }\n';

    test('each version has its own label: the name, .., then the parameter types', () {
      final asm = build('${twice}type B { u32 v; };\nu32 B.get() { return 1; }\nu32 B.get(u32 k) { return k; }\n'
          'void main() { u32 a = 1; u8 b = 2; B x; u32 r = twice(a) + twice(b) + x.get() + x.get(3); }\n');
      expect(asm, contains('_twice..u32:'));
      expect(asm, contains('_twice..u8:'));
      expect(asm, contains('RCALL   _twice..u32'));
      expect(asm, contains('RCALL   _twice..u8'));
      expect(asm, contains('_B.get..void:'));
      expect(asm, contains('_B.get..u32:'));
      // A name with one version keeps its label
      expect(build('u32 once(u32 x) { return x; }\nvoid main() { u32 r = once(1); }\n'), contains('_once:'));
    });

    test('an exact match wins; an integer constant matches any type it fits, and counts as s32 to break a tie', () {
      final asm = build('u8 f(u8 x) { return 1; }\nu16 f(u16 x) { return 2; }\ns32 f(s32 x) { return 3; }\n'
          'void main() { u16 a = 1; u32 r = f(a) + f(5) + f(-1); }\n');
      expect(asm, contains('RCALL   _f..u16'));
      expect(asm, contains('RCALL   _f..s32'));
      expect(asm, isNot(contains('RCALL   _f..u8')));
    });

    test('ambiguous calls and calls no version takes are errors that list the versions', () {
      const f = 'u8 f(u8 x, u8 y) { return 1; }\nu16 f(u16 x, u16 y) { return 2; }\n';
      expect(errorOf('${f}void main() { u8 a = 1; u16 b = 2; u32 r = f(a, b); }\n'),
          contains("the call of 'f' with (u8, u16) could be f(u8, u8) or f(u16, u16)"));
      expect(errorOf('${f}void main() { s8 c = 1; u32 r = f(c, c); }\n'),
          contains("the call of 'f' with (s8, s8) could be f(u8, u8) or f(u16, u16); convert an argument"));
      expect(errorOf('${f}void main() { string s[4] = "a"; u32 r = f(s, s); }\n'),
          contains("no version of 'f' takes (string, string); the versions are f(u8, u8), f(u16, u16)"));
    });

    test('a function type picks the version a function value is', () {
      final asm = build('${twice}type Op = fn(u8) -> u32;\nu32 run(Op o) { return o(2); }\n'
          'void main() { Op g = twice; u32 r = g(1) + run(twice); }\n');
      expect(asm, contains('_twice..u8'));
      expect(errorOf('${twice}type Op = fn(u16) -> u32;\nvoid main() { Op g = twice; }\n'),
          contains("no version of 'twice' is a 'Op'; the versions are twice(u32), twice(u8)"));
      expect(errorOf('${twice}void main() { u32 r = 0; if (twice == twice) { r = 1; } }\n'),
          contains("'twice' has more than one version; give it to a variable, parameter or result of a function type"));
    });

    test('what cannot be overloaded, and a version defined twice', () {
      expect(errorOf('asm u32 g(u32 a);\nasm u32 g(u8 a);\nvoid main() { }\n'),
          contains("'g' has more than one version, but an 'asm' routine names one label"));
      expect(errorOf('u32 g(u32 a) { return 1; }\ntype N = u32;\nu32 g(N a) { return 2; }\nvoid main() { }\n'),
          contains("Redefinition of function 'g'"));
      expect(errorOf('type T { u32 v; };\nstatic u32 T.h(u32 a) { return 1; }\nu32 T.h(u32 a) { return 2; }\nvoid main() { }\n'),
          contains("a static function and a method of 'T' cannot have the same parameters"));
    });
  });

  group('the standard library', () {
    test('string methods, with the capacity of the string they are called on', () {
      final asm = build('import "string.act";\nvoid main() {\n    string s[4];\n    s.copy("abcdef");\n'
          '    u32 e = s.equals("abc") + string.equals(s, "abc");\n    s32 c = s.compare("abd") + string.compare(s, "abd");\n'
          '    s32 i = s.find(99);\n}\n');
      expect(asm, contains('RCALL   _string.copy'));
      expect(asm, contains('RCALL   _string.equals..string'));
      expect(asm, contains('RCALL   _string.equals..string.string'));
      expect(errorOf('import "string.act";\nvoid main() { string s[4]; u32 e = stringEquals(s, s); }\n'),
          contains("'stringEquals' is not declared"));
      expect(errorOf('void main() { string a[4]; string b[4]; u32 e = 0; if (a == b) { e = 1; } }\n'),
          contains('use a.equals(b) or a.compare(b)'));
    });

    test('Integer: limits and functions', () {
      final asm = build('import "integer.act";\nvoid main() {\n    u8 a = Integer.MAX_U8;\n    s16 b = -3;\n'
          '    u32 r = Integer.min(a, 9) + Integer.abs(b) + Integer.abs(Integer.MIN_S32);\n    s16 s = Integer.sign(b);\n}\n');
      expect(asm, contains('RCALL   _Integer.min..u8.u8'));
      expect(asm, contains('RCALL   _Integer.abs..s16'));
      expect(asm, contains('RCALL   _Integer.abs..s32'));
      expect(asm, contains('RCALL   _Integer.sign..s16'));
    });
  });

  group('pub on the members of a type', () {
    late Directory dir;

    void write(String rel, String text) => File('${dir.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('action_pub_');
      write('action.json', '{ "action": { "module": { "name": "example.com/m" } } }');
      write('geo/geo.act', '''
package geo;

pub type Point {
    pub u32 x;
    u32 hidden;
    pub const u32 ORIGIN = 0;
    const u32 SECRET = 1;
};

pub u32 Point.sum() { return this.x + this.hidden; }
u32 Point.inner() { return this.hidden; }
pub static u32 Point.make() { return 1; }
static u32 Point.helper() { return 2; }
''');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    String? errorOfPkg(String body) {
      write('main.act', 'package main;\nimport "example.com/m/geo";\nvoid main() { geo.Point p; $body }\n');
      try {
        compile(['${dir.path}/main.act'], options: CompileOptions(includeDirs: [libDir]));
        return null;
      } on CompileError catch (e) {
        return _clean(e.message);
      }
    }

    test('pub members can be used from another package; the others cannot', () {
      expect(errorOfPkg('p.x = 1; u32 a = p.sum() + geo.Point.make() + geo.Point.ORIGIN;'), isNull);
      expect(errorOfPkg('u32 a = p.hidden;'), contains("'hidden' of 'geo.Point' is not pub: only its own package can use it"));
      expect(errorOfPkg('u32 a = p.inner();'), contains("'inner' of 'geo.Point' is not pub"));
      expect(errorOfPkg('u32 a = geo.Point.helper();'), contains("'helper' of 'geo.Point' is not pub"));
      expect(errorOfPkg('u32 a = geo.Point.SECRET;'), contains("'SECRET' of 'geo.Point' is not pub"));
      expect(errorOfPkg('geo.Point q = geo.Point.create(hidden: 1); q.destroy();'),
          contains("'hidden' of 'geo.Point' is not pub"));
    });
  });
}
