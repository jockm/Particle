// The LLVM generator: the IR it writes, and (when clang is installed) what
// the programs do when built and run on this computer.

import 'dart:io';

import 'package:action/action.dart';
import 'package:test/test.dart';

import 'support.dart';

/// LLVM IR for [source] (written to a temporary `main.act`).
String llvmOf(String source, {bool debugInfo = true}) {
  final dir = Directory.systemTemp.createTempSync('action_llvm_');
  try {
    final main = File('${dir.path}/main.act')..writeAsStringSync(source);
    return compileLlvm([main.path],
        options: CompileOptions(includeDirs: [dir.path]), debugInfo: debugInfo);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The error compiling [source] for LLVM gives, without the file name.
String? llvmErrorOf(String source) {
  try {
    llvmOf(source);
    return null;
  } on CompileError catch (e) {
    return e.message.replaceFirst(RegExp(r'^.*main\.act:'), '');
  }
}

final bool haveClang = () {
  try {
    return Process.runSync(Platform.environment['CLANG'] ?? 'clang', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Builds [source] with clang and runs it: (exit status, stderr).
(int, String) run(String source) {
  final dir = Directory.systemTemp.createTempSync('action_llvm_run_');
  try {
    File('${dir.path}/p.ll').writeAsStringSync(llvmOf(source));
    final cc = Process.runSync(Platform.environment['CLANG'] ?? 'clang',
        ['-w', '-g', '${dir.path}/p.ll', '-o', '${dir.path}/p']);
    if (cc.exitCode != 0) throw StateError('clang failed: ${cc.stderr}');
    final r = Process.runSync('${dir.path}/p', []);
    return (r.exitCode, r.stderr as String);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Runs [body] as main's body: it must not reach trap(15).
void expectPasses(String body, {String decls = ''}) {
  if (!haveClang) return;
  final (code, err) = run('$decls\nvoid main() {\n$body\n    trap(0);\n}\n');
  expect(code, 0, reason: err);
}

void main() {
  group('IR', () {
    test('Action functions are prefixed, main and C functions are not', () {
      final ir = llvmOf('extern s32 puts(string s);\n'
          'u32 twice(u32 a) { return a + a; }\n'
          'void main() { u32 v = twice(2); puts("hi"); }\n');
      expect(ir, contains('define i32 @main()'));
      expect(ir, contains('define internal i32 @"act.twice"(i32 %a.a)'));
      expect(ir, contains('declare i32 @puts(ptr)'));
      expect(ir, contains('call i32 @puts('));
    });

    test('a variadic C function is called with its full type', () {
      final ir = llvmOf('extern s32 printf(string f, ...);\nvoid main() { u8 b = 2; printf("%d", b); }\n');
      expect(ir, contains('declare i32 @printf(ptr, ...)'));
      expect(ir, contains('call i32 (ptr, ...) @printf(ptr @.str.0, i32 '));
    });

    test('fixed addresses are volatile', () {
      final ir = llvmOf('u32 R @ 0x1000;\nvoid main() { R = 1; u32 v = R; }\n');
      expect(ir, contains('store volatile i32 1'));
      expect(ir, contains('load volatile i32'));
    });

    test('debug information can be left out', () {
      expect(llvmOf('void main() { }\n'), contains('!llvm.dbg.cu'));
      expect(llvmOf('void main() { }\n', debugInfo: false), isNot(contains('!dbg')));
    });

    test('references are 8 bytes', () {
      expect(llvmErrorOf('type N { u32 v; ref N next; };\nverify(sizeof(N) == 16, "x");\nvoid main() { }'),
          isNull);
    });
  });

  group('errors for LLVM', () {
    test('Particle hardware and assembly', () {
      expect(llvmErrorOf('void main() { asm("NOP"); }'), contains('inline assembly is Particle assembly'));
      expect(llvmErrorOf('void main() { u32 v = readFifo(0); }'), contains('FIFOs are Particle hardware'));
      expect(llvmErrorOf('trap(3) h() { }\nvoid main() { }'), contains('trap handlers are Particle hardware'));
      expect(llvmErrorOf('asm u32 f();\nvoid main() { }'), contains("declare a C function with 'extern' instead"));
    });

    test('C functions', () {
      expect(llvmErrorOf('extern void g(u32 a[]);\nvoid main() { }'),
          contains("parameter 'a' is an open array, which a C function cannot take"));
      expect(llvmErrorOf('u32 f(u32 a, ...);\nvoid main() { }'),
          contains("only a C function declared 'extern' can take '...'"));
    });

    test('extern needs the LLVM compiler', () {
      String? err;
      try {
        compileSource('extern s32 puts(string s);\nvoid main() { }');
      } on CompileError catch (e) {
        err = e.message;
      }
      expect(err, contains("C functions need the LLVM compiler (action_llvm)"));
    });
  });

  group('running', () {
    test('division follows RISC-V', () {
      expectPasses('''
    u32 a = 7;
    u32 z = 0;
    if (a / z != 0xFFFFFFFF) trap(15);
    if (a % z != 7) trap(15);
    s32 m = -2147483647 - 1;
    s32 n = -1;
    if (m / n != m) trap(15);
    if (m % n != 0) trap(15);
    s32 q = -7;
    if (q / 2 != -3) trap(15);
    if (q % 2 != -1) trap(15);''');
    });

    test('shift counts are masked to 5 bits (6 for 64-bit values)', () {
      expectPasses('''
    u32 one = 1;
    u32 c = 33;
    if (one << c != 2) trap(15);
    u64 w = 1;
    u32 c65 = 65;
    if (w << c65 != 2) trap(15);
    s32 neg = -16;
    u32 two = 2;
    if (neg >> two != -4) trap(15);''');
    });

    test('64-bit values: the widest operand decides, signed if either is', () {
      expectPasses('''
    u32 a = 0xFFFFFFFF;
    u64 b = 1;
    if (a + b != 0x100000000) trap(15);
    s32 s = -1;
    s64 w = s;
    if (w != -1) trap(15);
    u64 big = 0x123456789;
    u32 low = big;
    if (low != 0x23456789) trap(15);''');
    });

    test('a failed check prints where and exits with 15', () {
      if (!haveClang) return;
      final (code, err) = run('void main() {\n    u32 a[3];\n    u32 i = 3;\n    a[i] = 1;\n}\n');
      expect(code, 15);
      expect(err, contains("action: index 3 is out of range for 'a' (length 3) at main.act:4:"));
    });

    test('trap(N) exits with N, main returns its result', () {
      if (!haveClang) return;
      expect(run('void main() { trap(9); }').$1, 9);
      expect(run('u32 main() { return 4; }').$1, 4);
    });
  });

  group('strings and arrays of references', () {
    test('string buffers copy, and stop at their capacity', () {
      expectPasses('''
    string names[3][8];
    names[0] = "alpha";
    if (names[0].len != 5) trap(15);
    string longer[16] = "abcdefghijk";
    names[1] = longer;
    if (names[1].len != 7) trap(15);
    if (names.len != 3) trap(15);''');
    });

    test('arrays of references', () {
      expectPasses('''
    ref Node ns[3];
    if (ns[1].exists()) trap(15);
    ns[1] = Node.create();
    ns[1].v = 4;
    if (ns[1].v != 4) trap(15);
    ns[1].destroy();
    if (ns[1].exists()) trap(15);
    ref string w[2];
    w[0] = "abc";
    if (w[0].len != 3) trap(15);
    if (w[0][1] != 98) trap(15);''', decls: 'type Node { u32 v; };');
    });

    test('a null element is a run-time error', () {
      if (!haveClang) return;
      final (code, err) = run('type Node { u32 v; };\nvoid main() {\n    ref Node ns[2];\n    ns[0].v = 1;\n}\n');
      expect(code, 15);
      expect(err, contains("action: null reference in an element of 'ns' at main.act:4:"));
    });
  });

  group('heap arrays of references', () {
    test('grow with null references, and own their strings', () {
      expectPasses('''
    ref Node xs[] = Node.createArray(2);
    xs[1] = Node.create();
    xs.resize(4);
    if (xs.len != 4 || xs[3].exists() || !xs[1].exists()) trap(15);
    xs[1].destroy();
    xs.destroyArray();
    ref string ws[] = string.createArray(2);
    string buf[8] = "abc";
    ws[0] = buf;
    buf[0] = 88;
    if (ws[0][0] != 97 || ws[0].capacity != 4) trap(15);
    ws[0].destroy();
    ws.destroyArray();''', decls: 'type Node { u32 v; };');
    });
  });

  group('block scopes', () {
    test('inner blocks have their own variables, cleared when declared', () {
      expectPasses('''
    u32 x = 1;
    { u8 x = 7; x += 1; if (x != 8) trap(15); }
    if (x != 1) trap(15);
    u32 s = 0;
    for (u32 i : 0..3) { u32 t; t += 1; s += t; }
    if (s != 3) trap(15);''');
    });
  });

  group('references', () {
    test('sameAs, unset and ref declarations', () {
      expectPasses('''
    ref Node a;
    if (a.exists()) trap(15);
    Node b = Node.create();
    a = b;
    ref Node c;
    c = Node.create();
    if (a.sameAs(c) || !a.sameAs(a)) trap(15);
    c.destroy();
    a.destroy();
    a.unset();''', decls: 'type Node { u32 v; };');
    });
  });

  group('floating point', () {
    test('f32 and f64 arithmetic, conversions and constants', () {
      expectPasses('''
    f64 a = 1.0 / 4.0;
    f32 b = 0.5;
    f32 c = b * 3;
    if (a != 0.25 || c != 1.5 || -c >= 0.0) trap(15);
    if (s32(-2.9) != -2 || f64(u32(7)) != 7.0 || u8(c) != 1) trap(15);
    if (HALF * 4.0 != 2.0) trap(15);
    f32 xs[2] = {1.25, 2.5};
    if (xs[0] + xs[1] != 3.75) trap(15);''', decls: 'const f64 HALF = 0.5;');
    });

    test('mixing and misuse are errors', () {
      expect(llvmErrorOf('void main() { f32 a = 1.5; u32 b = 2; f32 c = a + b; }'),
          contains('an f32 value and a u32 value do not mix'));
      expect(llvmErrorOf('void main() { f32 a = 1.5; f64 b = 2.0; f64 c = a + b; }'),
          contains('f32 and f64 values do not mix'));
      expect(llvmErrorOf('void main() { f64 a = 1.5; f64 b = a % 2.0; }'),
          contains("'%' is for integers, not f64 values"));
      expect(llvmErrorOf('void main() { f64 a = 1.5; if (a) { } }'),
          contains('a condition is an integer or bool'));
      expect(llvmErrorOf('void main() { u32 x = 1.5; }'), contains('1.5 is not an integer'));
    });
  });
}
