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
      expect(await c.open('only.act', '// Target: particle\nvoid main() { u32 v = readFifo(0); }\n'), isEmpty);
      final b = asMap((await c.open('bad.act')).first);
      expect(b['severity'], equals(1));
      expect(b['message'] as String, startsWith("undefined identifier 'zz'"));
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
}
