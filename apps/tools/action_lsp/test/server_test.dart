import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

const mainAct = '''import "shapes.act";

const u32 LIMIT = 40;
enum Mode { IDLE, RUNNING, STOPPED = 10 }

// Counts how many points are past the limit.
u32 count(Point pts[]) {
    u32 n = 0;
    for (u32 i : 0..pts.len) {
        if (pts[i].x > LIMIT) {
            n += 1;
        }
    }
    return n;
}

void main() {
    Point p = Point.create();
    p.x = 5;
    p.move(1, 2);
    u32 total = count(0);
    trap(0);
}
''';

const shapesAct = '''// A point on the screen.
type Point {
    u32 x;
    u32 y;
    ref Point next;
}

void Point.move(u32 dx, u32 dy) {
    this.x += dx;
    this.y += dy;
}
''';

Map<String, Object?> asMap(Object? o) => o as Map<String, Object?>;

void main() {
  group('lifecycle', () {
    test('initialize reports the features', () async {
      final c = await TestClient.start({});
      final caps = asMap((await c.result('initialize', {'capabilities': {}}) as Map)['capabilities']);
      expect(caps['hoverProvider'], isTrue);
      expect(caps['definitionProvider'], isTrue);
      expect(caps['documentSymbolProvider'], isTrue);
      expect(asMap(caps['completionProvider'])['triggerCharacters'], equals(['.']));
      await c.close();
      expect(await c.exitCode, equals(0));
    });

    test('unknown requests are answered with an error', () async {
      final c = await TestClient.start({});
      final r = await c.request('textDocument/rename', {});
      expect(asMap(r['error'])['code'], equals(-32601));
      await c.close();
    });
  });

  group('diagnostics', () {
    test('an error is shown where the compiler reports it, and cleared when fixed', () async {
      final c = await TestClient.start({'main.act': 'void main() {\n    u8 b = 300;\n}\n'});
      final d = await c.open('main.act');
      expect(d.length, equals(1));
      final first = asMap(d.first);
      expect(first['message'] as String, contains('the constant 300 does not fit in u8'));
      final range = asMap(first['range']);
      expect(asMap(range['start']), equals({'line': 1, 'character': 11}));
      expect(asMap(range['end']), equals({'line': 1, 'character': 14}));

      final fixed = await c.change('main.act', 'void main() {\n    u8 b = 30;\n}\n', 2);
      expect(fixed, isEmpty);
      await c.close();
    });

    test('unsaved text is what gets checked', () async {
      final c = await TestClient.start({'main.act': 'void main() { }\n'});
      expect(await c.open('main.act', 'void main() { u32 x = nope; }\n'), isNot(isEmpty));
      await c.close();
    });

    test('an error in an imported file is shown on that file', () async {
      final c = await TestClient.start({
        'main.act': 'import "lib2.act";\nvoid main() { }\n',
        'lib2.act': 'void helper() {\n    u8 b = 999;\n}\n',
      });
      final libDiags = c.nextDiagnostics('lib2.act');
      await c.open('main.act');
      final d = await libDiags;
      expect(asMap(d.first)['message'] as String, contains('999'));
      await c.close();
    });
  });

  group('project file', () {
    const mathAct = 'const u32 K = 2;\nu32 add(u32 a, u32 b) { return a + b; }\n';
    const useAct = 'void main() { u32 y = K; u32 x = add(y, 2); }\n';

    test('files in a program are checked together', () async {
      final c = await TestClient.start({
        'action.json': '{ "action": { "programs": [ { "files": ["use.act", "math.act"] } ] } }',
        'use.act': useAct,
        'math.act': mathAct,
      });
      expect(await c.open('use.act'), isEmpty);
      await c.close();
    });

    test('without the project file a file is checked on its own', () async {
      final c = await TestClient.start({'use.act': useAct, 'math.act': mathAct});
      final d = await c.open('use.act');
      expect(asMap(d.first)['message'] as String, contains("undefined identifier 'K'"));
      await c.close();
    });

    test('a call to a function defined elsewhere is information when checked alone', () async {
      final c = await TestClient.start({'main.act': 'void main() { u32 x = add(1, 2); }\n'});
      final d = asMap((await c.open('main.act')).first);
      expect(d['severity'], equals(3));
      expect(d['message'] as String, contains("'add' is not declared"));
      expect(d['message'] as String, contains('checked on its own'));
      await c.close();
    });

    test('in a listed program a call to an undeclared function is an error', () async {
      final c = await TestClient.start({
        'action.json': '{ "action": { "programs": [ { "files": ["use.act", "math.act"] } ] } }',
        'use.act': 'void main() { u32 x = sub(1, 2); }\n',
        'math.act': mathAct,
      });
      final d = asMap((await c.open('use.act')).first);
      expect(d['severity'], equals(1));
      expect(d['message'] as String, contains("'sub' is not declared"));
      await c.close();
    });

    test('each folder in a program folder is a program', () async {
      final c = await TestClient.start({
        'action.json': '{ "action": { "programFolders": ["multi"] } }',
        'multi/one/use.act': useAct,
        'multi/one/math.act': mathAct,
        'multi/two/main.act': 'void main() { u32 x = add(1, 2); }\n',
      });
      expect(await c.open('multi/one/use.act'), isEmpty);
      // Another folder is another program: 'add' is not in it, and that is
      // an error, not information
      final d = asMap((await c.open('multi/two/main.act')).first);
      expect(d['severity'], equals(1));
      expect(d['message'] as String, contains("'add' is not declared"));
      await c.close();
    });

    test('the target decides what is allowed', () async {
      const src = 'void main() { u64 big = 1; }\n';
      final p = await TestClient.start({'main.act': src});
      expect(asMap((await p.open('main.act')).first)['message'] as String, contains("'u64'"));
      await p.close();
      final l = await TestClient.start({
        'action.json': '{ "action": { "target": "llvm" } }',
        'main.act': src,
      });
      expect(await l.open('main.act'), isEmpty);
      await l.close();
    });

    test('with both targets, what one of them lacks is a warning naming it', () async {
      final c = await TestClient.start({
        'action.json': '{ "action": { "target": ["particle", "llvm"] } }',
        'fifo.act': 'void main() { u32 v = readFifo(0); }\n',
        'c.act': 'extern s32 puts(string s);\nvoid main() { puts("hi"); }\n',
        'bad.act': 'void main() { u32 v = zz; }\n',
      });
      final f = asMap((await c.open('fifo.act')).first);
      expect(f['severity'], equals(2));
      expect(f['message'] as String, startsWith('for llvm: '));
      final e = asMap((await c.open('c.act')).first);
      expect(e['severity'], equals(2));
      expect(e['message'] as String, startsWith('for particle: '));
      // A file that says it is for one target is checked for that one
      expect(await c.open('only.act', '//act:build particle\nvoid main() { u32 v = readFifo(0); }\n'), isEmpty);
      final b = asMap((await c.open('bad.act')).first);
      expect(b['severity'], equals(1));
      expect(b['message'] as String, startsWith("undefined identifier 'zz'"));
      await c.close();
    });

    test('a file built only for llvm is checked as llvm', () async {
      final c = await TestClient.start({
        'hello_llvm.act': '//act:build llvm\nextern s32 puts(string s);\nvoid main() { puts("hi"); }\n',
      });
      expect(await c.open('hello_llvm.act'), isEmpty);
      await c.close();
    });

    test('a file named for a target its directive does not keep it to is warned about', () async {
      final c = await TestClient.start({
        'a_llvm.act': '//act:build particle\nvoid main() { }\n',
        'b_llvm.act': 'void main() { }\n',
        'c_llvm_macos.act': '//act:build llvm && macos\nvoid main() { }\n',
        'd_status.act': 'void main() { }\n',
      });
      final a = asMap((await c.open('a_llvm.act')).first);
      expect(a['severity'], equals(2));
      expect(a['message'] as String,
          equals("'a_llvm.act' is named for llvm, but '//act:build particle' builds it for particle"));
      final b = asMap((await c.open('b_llvm.act')).first);
      expect(b['message'] as String, contains("by convention it starts with '//act:build llvm'"));
      expect(await c.open('c_llvm_macos.act'), isEmpty);
      expect(await c.open('d_status.act'), isEmpty);
      await c.close();
    });

    test('defines from the project file', () async {
      final c = await TestClient.start({
        'action.json': '{ "action": { "defines": { "SIZE": 4 } } }',
        'main.act': 'u32 buf[SIZE];\nvoid main() { }\n',
      });
      expect(await c.open('main.act'), isEmpty);
      await c.close();
    });

    test('a broken project file is reported on that file', () async {
      final c = await TestClient.start({'action.json': '{\n  "action": {\n    "includeDirs": 5\n  }\n}\n'});
      expect(await c.open('main.act', 'void main() { }\n'), isEmpty);
      final d = c.lastDiagnostics('action.json')!;
      final first = asMap(d.first);
      expect(first['message'] as String, contains('"includeDirs" must be a list'));
      expect(asMap(asMap(first['range'])['start'])['line'], equals(2));
      await c.close();
    });

    test('an unknown target is reported', () async {
      final c = await TestClient.start({'action.json': '{ "action": { "target": "arm" } }'});
      expect(await c.open('main.act', 'void main() { }\n'), isEmpty);
      final d = c.lastDiagnostics('action.json')!;
      expect(asMap(d.first)['message'] as String, contains('"target" must be "particle" or "llvm", or a list of them'));
      await c.close();
    });
  });

  group('features', () {
    Future<TestClient> start() async {
      final c = await TestClient.start({'main.act': mainAct, 'shapes.act': shapesAct});
      await c.open('main.act');
      return c;
    }

    test('hover on a local shows its type', () async {
      final c = await start();
      final (l, ch) = find(mainAct, 'n += 1');
      final h = asMap(await c.result('textDocument/hover', c.at('main.act', l, ch)));
      final v = asMap(h['contents'])['value'] as String;
      expect(v, contains('u32 n'));
      expect(v, contains('Local variable of `count`'));
      await c.close();
    });

    test('hover inside and after a lambda', () async {
      const src = 'type Op = fn(u8) -> u8;\nvoid main() {\n    u32 total = 1;\n'
          '    Op f = fn(u8 val) -> u8 { return val + 1; };\n    total += 2;\n}\n';
      final c = await TestClient.start({'lam.act': src});
      await c.open('lam.act');
      Future<String> hoverAt(String what) async {
        final (l, ch) = find(src, what);
        final h = asMap(await c.result('textDocument/hover', c.at('lam.act', l, ch)));
        return asMap(h['contents'])['value'] as String;
      }

      expect(await hoverAt('val + 1'), contains('u8 val'));
      expect(await hoverAt('total += 2'), contains('u32 total'));
      final syms = await c.result('textDocument/documentSymbol', {
        'textDocument': {'uri': c.uri('lam.act')}
      });
      expect('$syms', isNot(contains('lambda')));
      await c.close();
    });

    test('hover on a fast global shows fast', () async {
      const src = 'fast u32 ticks;\nvoid main() {\n    ticks += 1;\n}\n';
      final c = await TestClient.start({'fast.act': src});
      expect(await c.open('fast.act'), isEmpty);
      final (l, ch) = find(src, 'ticks += 1');
      final h = asMap(await c.result('textDocument/hover', c.at('fast.act', l, ch)));
      expect(asMap(h['contents'])['value'] as String, contains('fast u32 ticks'));
      await c.close();
    });

    test('hover follows block scopes', () async {
      const src = 'void main() {\n    u32 x = 1;\n    {\n        u8 x = 2;\n        x += 1;\n    }\n    x += 5;\n}\n';
      final c = await TestClient.start({'scoped.act': src});
      await c.open('scoped.act');
      Future<String> hoverAt(String what) async {
        final (l, ch) = find(src, what);
        final h = asMap(await c.result('textDocument/hover', c.at('scoped.act', l, ch)));
        return asMap(h['contents'])['value'] as String;
      }

      expect(await hoverAt('x += 1'), contains('u8 x'));
      expect(await hoverAt('x += 5'), contains('u32 x'));
      await c.close();
    });

    test('hover on a constant shows its value', () async {
      final c = await start();
      final (l, ch) = find(mainAct, 'LIMIT)', 1);
      final v = asMap(asMap(await c.result('textDocument/hover', c.at('main.act', l, ch)))['contents'])['value'] as String;
      expect(v, contains('const u32 LIMIT = 40'));
      await c.close();
    });

    test('hover on a type shows its layout and comment', () async {
      final c = await start();
      final (l, ch) = find(mainAct, 'Point p', 1);
      final v = asMap(asMap(await c.result('textDocument/hover', c.at('main.act', l, ch)))['contents'])['value'] as String;
      expect(v, contains('type Point {'));
      expect(v, contains('ref Point next;'));
      expect(v, contains('offset 4'));
      expect(v, contains('Size 12 bytes'));
      expect(v, contains('A point on the screen.'));
      await c.close();
    });

    test('hover on a field and a method through a variable', () async {
      final c = await start();
      var (l, ch) = find(mainAct, 'p.x = 5', 2);
      var v = asMap(asMap(await c.result('textDocument/hover', c.at('main.act', l, ch)))['contents'])['value'] as String;
      expect(v, contains('Field of `Point`, at offset 0, 4 bytes'));
      (l, ch) = find(mainAct, 'p.move', 3);
      v = asMap(asMap(await c.result('textDocument/hover', c.at('main.act', l, ch)))['contents'])['value'] as String;
      expect(v, contains('void Point.move(u32 dx, u32 dy)'));
      await c.close();
    });

    test('hover on an element of an array parameter', () async {
      final c = await start();
      final (l, ch) = find(mainAct, 'pts[i].x', 7);
      final v = asMap(asMap(await c.result('textDocument/hover', c.at('main.act', l, ch)))['contents'])['value'] as String;
      expect(v, contains('Field of `Point`'));
      await c.close();
    });

    test('go to definition across an import', () async {
      final c = await start();
      final (l, ch) = find(mainAct, 'p.move', 3);
      final loc = asMap(await c.result('textDocument/definition', c.at('main.act', l, ch)));
      expect(loc['uri'], equals(c.uri('shapes.act')));
      final (dl, dc) = find(shapesAct, 'move(');
      expect(asMap(asMap(loc['range'])['start']), equals({'line': dl, 'character': dc}));
      await c.close();
    });

    test('go to definition of a local and of an import', () async {
      final c = await start();
      var (l, ch) = find(mainAct, 'return n', 7);
      var loc = asMap(await c.result('textDocument/definition', c.at('main.act', l, ch)));
      final (dl, dc) = find(mainAct, 'n = 0');
      expect(asMap(asMap(loc['range'])['start']), equals({'line': dl, 'character': dc}));
      (l, ch) = find(mainAct, 'shapes.act', 2);
      loc = asMap(await c.result('textDocument/definition', c.at('main.act', l, ch)));
      expect(loc['uri'], equals(c.uri('shapes.act')));
      await c.close();
    });

    test('completion after a dot lists fields and methods', () async {
      final c = await start();
      final (l, ch) = find(mainAct, 'p.x = 5', 2);
      final r = asMap(await c.result('textDocument/completion', c.at('main.act', l, ch)));
      final labels = [for (final i in r['items'] as List) asMap(i)['label']];
      expect(labels, containsAll(['x', 'y', 'next', 'move', 'exists', 'destroy']));
      expect(labels, isNot(contains('main')));
      await c.close();
    });

    test('completion elsewhere lists names in scope and keywords', () async {
      final c = await start();
      final (l, ch) = find(mainAct, 'n += 1');
      final r = asMap(await c.result('textDocument/completion', c.at('main.act', l, ch)));
      final labels = [for (final i in r['items'] as List) asMap(i)['label']];
      expect(labels, containsAll(['n', 'pts', 'i', 'LIMIT', 'RUNNING', 'Point', 'count', 'while', 'u32', 'true']));
      expect(labels, isNot(contains('total')));
      await c.close();
    });

    test('outline of a file', () async {
      final c = await start();
      final syms = await c.result('textDocument/documentSymbol', {
        'textDocument': {'uri': c.uri('main.act')}
      }) as List;
      final names = [for (final s in syms) asMap(s)['name']];
      expect(names, equals(['LIMIT', 'Mode', 'count', 'main']));
      final mode = asMap(syms[1]);
      expect([for (final m in mode['children'] as List) asMap(m)['name']],
          equals(['IDLE', 'RUNNING', 'STOPPED']));
      await c.close();
    });

    test('features keep working while the text does not parse', () async {
      final c = await start();
      final broken = mainAct.replaceFirst('trap(0);', 'trap(0');
      final d = await c.change('main.act', broken, 2);
      expect(d, isNot(isEmpty));
      final (l, ch) = find(broken, 'p.x = 5', 2);
      final r = asMap(await c.result('textDocument/completion', c.at('main.act', l, ch)));
      expect([for (final i in r['items'] as List) asMap(i)['label']], contains('x'));
      await c.close();
    });
  });

  group('packages', () {
    const geoAct = '''package geo;

// A point of the geometry package.
pub type Point {
    u32 x;
    u32 y;
};

pub enum Kind { A, B = 5 }

pub const u32 UNIT = 1;

u32 hidden;

pub void init(Point p, u32 x) {
    p.x = x * UNIT;
    hidden = hidden + 1;
}

pub u32 Point.sum() {
    return this.x + this.y;
}
''';

    const pkgMain = '''package main;
import "example.com/m/geo";

void main() {
    geo.Point p;
    geo.init(p, geo.UNIT);
    u32 s = p.sum();
    u32 k = geo.B;
}
''';

    final prelude = File('${Directory.current.path}/../../../lib/string.act').readAsStringSync();
    final integerPrelude = File('${Directory.current.path}/../../../lib/integer.act').readAsStringSync();

    Future<TestClient> start([Map<String, String> more = const {}]) async {
      final c = await TestClient.start({
        'action.json': '{ "action": { "module": { "name": "example.com/m" } } }',
        'lib/string.act': prelude,
        'lib/integer.act': integerPrelude,
        'geo/geo.act': geoAct,
        'main.act': pkgMain,
        ...more,
      });
      return c;
    }

    Future<String> hover(TestClient c, String rel, String text, String needle, [int offset = 0]) async {
      final (l, ch) = find(text, needle, offset);
      final h = await c.result('textDocument/hover', c.at(rel, l, ch));
      return h == null ? '' : asMap(asMap(h)['contents'])['value'] as String;
    }

    test('a program made of packages checks cleanly', () async {
      final c = await start();
      expect(await c.open('main.act'), isEmpty);
      await c.close();
    });

    test('hover on alias.name shows the declaration and its package', () async {
      final c = await start();
      await c.open('main.act');
      final v = await hover(c, 'main.act', pkgMain, 'geo.Point', 4);
      expect(v, contains('type Point {'));
      expect(v, contains('In package `geo` (example.com/m/geo).'));
      expect(v, contains('A point of the geometry package.'));
      expect(await hover(c, 'main.act', pkgMain, 'geo.UNIT', 4), contains('const u32 UNIT = 1'));
      expect(await hover(c, 'main.act', pkgMain, 'geo.B', 4), contains('B = 5'));
      expect(await hover(c, 'main.act', pkgMain, 'p.sum', 2), contains('u32 Point.sum()'));
      expect(await hover(c, 'main.act', pkgMain, 'geo.init', 1), contains('import "example.com/m/geo"'));
      expect(await hover(c, 'main.act', pkgMain, 'geo.Point p', 10), contains('geo.Point p'));
      await c.close();
    });

    test('go to definition of alias.name and of a package import', () async {
      final c = await start();
      await c.open('main.act');
      var (l, ch) = find(pkgMain, 'geo.init', 5);
      var loc = asMap(await c.result('textDocument/definition', c.at('main.act', l, ch)));
      expect(loc['uri'], equals(c.uri('geo/geo.act')));
      final (dl, dc) = find(geoAct, 'init(');
      expect(asMap(asMap(loc['range'])['start']), equals({'line': dl, 'character': dc}));
      (l, ch) = find(pkgMain, 'example.com', 3);
      loc = asMap(await c.result('textDocument/definition', c.at('main.act', l, ch)));
      expect(loc['uri'], equals(c.uri('geo/geo.act')));
      await c.close();
    });

    test('completion after alias. lists the pub names; elsewhere the import names', () async {
      final c = await start();
      await c.open('main.act');
      var (l, ch) = find(pkgMain, 'geo.UNIT', 4);
      var r = asMap(await c.result('textDocument/completion', c.at('main.act', l, ch)));
      var labels = [for (final i in r['items'] as List) asMap(i)['label']];
      expect(labels, containsAll(['Point', 'init', 'UNIT', 'A', 'B']));
      expect(labels, isNot(contains('hidden')));
      (l, ch) = find(pkgMain, 'u32 s');
      r = asMap(await c.result('textDocument/completion', c.at('main.act', l, ch)));
      labels = [for (final i in r['items'] as List) asMap(i)['label']];
      expect(labels, containsAll(['geo', 'p', 'main']));
      expect(labels, isNot(contains('hidden')));
      expect(labels, isNot(contains('Point')));
      await c.close();
    });

    test("a package's file is checked with its folder, as that package", () async {
      final c = await start({'geo/more.act': 'package geo;\npub u32 twice(Point p) { return p.sum() * 2; }\n'});
      expect(await c.open('geo/more.act'), isEmpty);
      expect(await hover(c, 'geo/geo.act', geoAct, 'hidden = hidden', 0), contains('u32 hidden'));
      final syms = await c.result('textDocument/documentSymbol', {
        'textDocument': {'uri': c.uri('geo/geo.act')}
      }) as List;
      expect([for (final s in syms) asMap(s)['name']],
          equals(['Point', 'Kind', 'UNIT', 'hidden', 'init', 'Point.sum']));
      await c.close();
    });

    test('an unused import and a folder named differently are warnings', () async {
      final c = await start({
        'shapes2/s.act': 'package shapes;\npub u32 one() { return 1; }\n',
        'other.act': 'package main;\nimport "example.com/m/shapes2";\nvoid main() { }\n',
      });
      final d = await c.open('other.act');
      expect(d.map((e) => asMap(e)['message']),
          contains("import 'example.com/m/shapes2' is not used"));
      final w = await c.open('shapes2/s.act');
      expect(w.map((e) => asMap(e)['message']),
          contains("package 'shapes' is in the folder 'shapes2'; by convention a package's folder has its name"));
      await c.close();
    });

    test('a module entry that is not an object is reported', () async {
      final c = await TestClient.start({'action.json': '{ "action": { "module": "x" } }'});
      expect(await c.open('main.act', 'void main() { }\n'), isEmpty);
      final d = c.lastDiagnostics('action.json')!;
      expect(asMap(d.first)['message'] as String, contains('"module" must be an object such as'));
      await c.close();
    });
  });

  group('modules', () {
    final prelude = File('${Directory.current.path}/../../../lib/string.act').readAsStringSync();
    final integerPrelude = File('${Directory.current.path}/../../../lib/integer.act').readAsStringSync();
    const appMain = '''package main;
import "example.com/me/plib/console";

void main() {
    u32 v = console.twice(2);
}
''';

    test('a required module that is not fetched is an error on its entry', () async {
      final c = await TestClient.start({
        'action.json': '{\n  "action": {\n    "module": { "name": "example.com/me/app" },\n'
            '    "requires": {\n      "example.com/me/plib": { "version": "v1.0.0" }\n    }\n  }\n}\n',
        'lib/string.act': prelude,
        'lib/integer.act': integerPrelude,
      });
      final d = await c.open('main.act', appMain);
      expect(asMap(d.first)['message'] as String,
          contains("module example.com/me/plib v1.0.0 is not fetched; run 'action --fetch' (in Particle: make deps)"));
      final p = asMap(c.lastDiagnostics('action.json')!.first);
      expect(p['message'] as String, contains('is not fetched'));
      expect(asMap(asMap(p['range'])['start'])['line'], equals(4));
      await c.close();
    });

    test('hover and go to definition reach into another module', () async {
      final c = await TestClient.start({
        'action.json': '{ "action": { "module": { "name": "example.com/me/app" }, '
            '"requires": { "example.com/me/plib": { "path": "libs/plib" } } } }',
        'lib/string.act': prelude,
        'lib/integer.act': integerPrelude,
        'libs/plib/action.json': '{ "action": { "module": { "name": "example.com/me/plib" } } }',
        'libs/plib/console/console.act':
            'package console;\n\n// Doubles x.\npub u32 twice(u32 x) {\n    return x * 2;\n}\n',
      });
      expect(await c.open('main.act', appMain), isEmpty);
      final (l, ch) = find(appMain, 'twice(2)', 1);
      final h = asMap(await c.result('textDocument/hover', c.at('main.act', l, ch)));
      final v = asMap(h['contents'])['value'] as String;
      expect(v, contains('u32 twice(u32 x)'));
      expect(v, contains('In package `console` (example.com/me/plib/console).'));
      final loc = asMap(await c.result('textDocument/definition', c.at('main.act', l, ch)));
      expect(loc['uri'], equals(c.uri('libs/plib/console/console.act')));
      expect(c.lastDiagnostics('action.json') ?? const [], isEmpty);
      await c.close();
    });

    test('a malformed requirement is reported on action.json', () async {
      final c = await TestClient.start({
        'action.json': '{\n  "action": {\n    "module": { "name": "example.com/me/app" },\n'
            '    "requires": {\n      "example.com/me/plib": { "version": "1.0" }\n    }\n  }\n}\n',
      });
      await c.open('main.act', 'void main() { }\n');
      final p = asMap(c.lastDiagnostics('action.json')!.first);
      expect(p['message'] as String, contains("'1.0' is not a version: write a git tag such as v1.2.0"));
      expect(asMap(asMap(p['range'])['start'])['line'], equals(4));
      await c.close();
    });
  });

  group('types: constants, static functions and overloads', () {
    final integer = File('${Directory.current.path}/../../../lib/integer.act').readAsStringSync();
    final strings = File('${Directory.current.path}/../../../lib/string.act').readAsStringSync();
    const prog = '''import "integer.act";
import "string.act";

u32 twice(u32 x) { return x * 2; }
u32 twice(u8 x) { return x * 3; }

void main() {
    u8 a = 3;
    u8 r = Integer.min(a, Integer.MAX_U8);
    u32 t = twice(a);
    string s[8] = "abc";
    s32 i = s.find(98);
    u32 e = string.equals(s, "abc");
}
''';

    Future<TestClient> start() =>
        TestClient.start({'lib/integer.act': integer, 'lib/string.act': strings});

    Future<String> hover(TestClient c, String needle, [int offset = 0]) async {
      final (l, ch) = find(prog, needle, offset);
      final h = await c.result('textDocument/hover', c.at('main.act', l, ch));
      return h == null ? '' : asMap(asMap(h)['contents'])['value'] as String;
    }

    test('the program checks cleanly', () async {
      final c = await start();
      expect(await c.open('main.act', prog), isEmpty);
      await c.close();
    });

    test('hover shows a type constant, every version of an overloaded function, and string methods', () async {
      final c = await start();
      await c.open('main.act', prog);
      expect(await hover(c, 'Integer.MAX_U8', 8), contains('const u8 Integer.MAX_U8 = 255'));
      final min = await hover(c, 'Integer.min', 8);
      expect(min, contains('u8 Integer.min(u8 a, u8 b)'));
      expect(min, contains('s32 Integer.min(s32 a, s32 b)'));
      expect(min, contains('6 versions.'));
      final tw = await hover(c, 'twice(a)');
      expect(tw, contains('u32 twice(u32 x)'));
      expect(tw, contains('u32 twice(u8 x)'));
      expect(await hover(c, 's.find', 2), contains('s32 string.find(u8 ch)'));
      expect(await hover(c, 'string.equals', 7), contains('u32 string.equals(string s1, string s2)'));
      await c.close();
    });

    test('completion after a type lists its constants and static functions; go to definition finds them',
        () async {
      final c = await start();
      await c.open('main.act', prog);
      var (l, ch) = find(prog, 'Integer.min', 8);
      final r = asMap(await c.result('textDocument/completion', c.at('main.act', l, ch)));
      final labels = [for (final i in r['items'] as List) asMap(i)['label']];
      expect(labels, containsAll(['MIN_U8', 'MAX_S32', 'min', 'max', 'abs', 'sign', 'neg']));
      (l, ch) = find(prog, 'Integer.MAX_U8', 8);
      final loc = asMap(await c.result('textDocument/definition', c.at('main.act', l, ch)));
      expect(loc['uri'], equals(c.uri('lib/integer.act')));
      await c.close();
    });
  });
}
