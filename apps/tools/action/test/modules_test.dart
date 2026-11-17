// Modules and versions: requirements in action.json, fetching with git
// (from repositories made here), minimal version selection, action.sum,
// vendor/ and local replacements.

import 'dart:io';

import 'package:action/action.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  final libDir = '${Directory.current.path}/../../../lib';

  void write(String path, String text) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  void git(String dir, List<String> args) {
    final r = Process.runSync('git', args, workingDirectory: dir);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  /// A git repository for module [name] in repos/[short], with one commit
  /// and tag per version: each version's files.
  String repo(String short, String name, Map<String, Map<String, String>> versions,
      {Map<String, String> requires = const {}}) {
    final dir = '${tmp.path}/repos/$short';
    Directory(dir).createSync(recursive: true);
    git(dir, ['init', '-q']);
    git(dir, ['config', 'user.email', 'test@example.com']);
    git(dir, ['config', 'user.name', 'test']);
    for (final v in versions.entries) {
      final req = [
        for (final r in requires.entries)
          '"${r.key}": { "version": "${r.value}", "git": "${tmp.path}/repos/${r.key.split('/').last}" }'
      ].join(', ');
      write('$dir/action.json',
          '{ "action": { "module": { "name": "$name" }, "requires": { $req } } }');
      v.value.forEach((f, text) => write('$dir/$f', text));
      git(dir, ['add', '-A']);
      git(dir, ['commit', '-qm', v.key]);
      git(dir, ['tag', v.key]);
    }
    return dir;
  }

  String pkg(String name, int version) => '''
package $name;

pub const u32 VERSION = $version;

pub u32 twice(u32 x) {
    return x * 2;
}
''';

  late String app;

  /// The program's module, requiring [requires] (path to its entry).
  void appModule(Map<String, String> requires, String mainAct) {
    app = '${tmp.path}/app';
    final req = requires.entries.map((e) => '"${e.key}": ${e.value}').join(', ');
    write('$app/action.json',
        '{ "action": { "module": { "name": "example.com/me/app" }, "requires": { $req } } }');
    write('$app/main.act', mainAct);
  }

  ModuleFile mainModule() => readModuleFile(app)!;

  String build() => compile(['$app/main.act'], options: CompileOptions(includeDirs: [libDir]));

  String? errorOf(void Function() f) {
    try {
      f();
      return null;
    } on CompileError catch (e) {
      return e.message;
    }
  }

  String gitEntry(String short, String version) =>
      '{ "version": "$version", "git": "${tmp.path}/repos/$short" }';

  const usesConsole = '''
package main;
import "example.com/me/plib/console";
void main() { u32 v = console.twice(console.VERSION); }
''';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('action_mod_');
    cacheRootOverride = '${tmp.path}/cache';
    moduleCommand = 'action';
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', tmp.path]);
    tmp.deleteSync(recursive: true);
    cacheRootOverride = null;
  });

  test('versions are ordered as semantic versioning orders them', () {
    final order = ['v1.0.0-alpha', 'v1.0.0-alpha.1', 'v1.0.0-beta.2', 'v1.0.0-beta.11', 'v1.0.0', 'v1.2.0', 'v1.10.0', 'v2.0.0'];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(Version.tryParse(order[i])!.compareTo(Version.tryParse(order[i + 1])!), equals(-1),
          reason: '${order[i]} < ${order[i + 1]}');
    }
    expect(Version.tryParse('1.0.0'), isNull);
    expect(Version.tryParse('v1.0'), isNull);
    expect(Version.tryParse('v01.0.0'), isNull);
  });

  test('module paths, and the prefixes of their packages', () {
    expect(modulePathProblem('github.com/jockm/Particle'), isNull);
    expect(modulePathProblem('example.com/my-lib', fetched: true), isNull);
    expect(modulePathProblem('example.com/my_lib'), contains('is not a module path'));
    expect(modulePathProblem('example.com/a..b'), contains('is not a module path'));
    expect(modulePathProblem('plib', fetched: true), contains('has a dot'));
    expect(modulePrefix('github.com/jock/plib', 'console'), equals('github_com.jock.plib.console'));
    expect(modulePrefix('example.com/my-lib', 'a/b'), equals('example_com.my__lib.a.b'));
  });

  test('a required module is fetched, checked into action.sum and imported', () {
    repo('plib', 'example.com/me/plib', {'v1.0.0': {'console/console.act': pkg('console', 1)}});
    appModule({'example.com/me/plib': gitEntry('plib', 'v1.0.0')}, usesConsole);
    expect(errorOf(build),
        contains("main.act:2:7: module example.com/me/plib v1.0.0 is not fetched; run 'action --fetch' (in Particle: make deps)"));
    expect(fetchModules(mainModule()), equals(['fetched example.com/me/plib v1.0.0']));
    expect(fetchModules(mainModule()), equals(['all required modules are in the cache']));
    final sum = File('$app/action.sum').readAsStringSync();
    expect(sum, startsWith('example.com/me/plib v1.0.0 sha256:'));
    expect(Directory('${tmp.path}/cache/example.com/me/plib@v1.0.0/console').existsSync(), isTrue);
    expect(Directory('${tmp.path}/cache/example.com/me/plib@v1.0.0/.git').existsSync(), isFalse);
    final asm = build();
    expect(asm, contains('_example_com.me.plib.console..twice:'));
    expect(verifyModules(mainModule()).$2, isTrue);
  });

  test('minimal version selection takes the highest of the lowest versions required', () {
    repo('plib', 'example.com/me/plib', {
      'v1.0.0': {'console/console.act': pkg('console', 1)},
      'v1.1.0': {'console/console.act': pkg('console', 2)},
      'v1.2.0': {'console/console.act': pkg('console', 3)},
    });
    repo('util', 'example.com/me/util', {'v1.0.0': {'text/text.act': 'package text;\npub u32 one() { return 1; }\n'}},
        requires: {'example.com/me/plib': 'v1.1.0'});
    appModule({
      'example.com/me/plib': gitEntry('plib', 'v1.0.0'),
      'example.com/me/util': gitEntry('util', 'v1.0.0'),
    }, usesConsole);
    expect(fetchModules(mainModule()), containsAll(['fetched example.com/me/plib v1.0.0', 'fetched example.com/me/plib v1.1.0']));
    final list = buildList(mainModule());
    expect(list.modules['example.com/me/plib']!.version, equals('v1.1.0'));
    // Never a newer version than anything asks for
    expect(Directory('${tmp.path}/cache/example.com/me/plib@v1.2.0').existsSync(), isFalse);
    expect(File('$app/action.sum').readAsLinesSync().length, equals(3));
    expect(build(), contains('Imm4 load (2)'));
  });

  test('two major versions of one module are an error', () {
    repo('plib', 'example.com/me/plib', {
      'v1.0.0': {'console/console.act': pkg('console', 1)},
      'v2.0.0': {'console/console.act': pkg('console', 2)},
    });
    repo('util', 'example.com/me/util', {'v1.0.0': {'text/text.act': 'package text;\n'}},
        requires: {'example.com/me/plib': 'v2.0.0'});
    appModule({
      'example.com/me/plib': gitEntry('plib', 'v1.0.0'),
      'example.com/me/util': gitEntry('util', 'v1.0.0'),
    }, usesConsole);
    expect(errorOf(() => fetchModules(mainModule())),
        contains('module example.com/me/plib: a build can use only one major version of a module, but '
            'the main module needs v1.0.0, example.com/me/util needs v2.0.0'));
  });

  test('a version whose contents changed is found by its checksum', () {
    final r = repo('plib', 'example.com/me/plib', {'v1.0.0': {'console/console.act': pkg('console', 1)}});
    appModule({'example.com/me/plib': gitEntry('plib', 'v1.0.0')}, usesConsole);
    fetchModules(mainModule());
    // The tag is moved to other contents, and the cache is cleared
    write('$r/console/console.act', pkg('console', 9));
    git(r, ['commit', '-qam', 'moved']);
    git(r, ['tag', '-f', 'v1.0.0']);
    Process.runSync('chmod', ['-R', 'u+w', '${tmp.path}/cache']);
    Directory('${tmp.path}/cache').deleteSync(recursive: true);
    expect(errorOf(() => fetchModules(mainModule())),
        contains('module example.com/me/plib v1.0.0 does not match action.sum: the fetched copy has sha256:'));
    expect(Directory('${tmp.path}/cache/example.com/me/plib@v1.0.0').existsSync(), isFalse);
  });

  test('a cached version that changed, or one missing from action.sum, is an error when building', () {
    repo('plib', 'example.com/me/plib', {'v1.0.0': {'console/console.act': pkg('console', 1)}});
    appModule({'example.com/me/plib': gitEntry('plib', 'v1.0.0')}, usesConsole);
    fetchModules(mainModule());
    File('$app/action.sum').writeAsStringSync('');
    expect(errorOf(build),
        contains("module example.com/me/plib v1.0.0 has no checksum in action.sum; run 'action --fetch'"));
    fetchModules(mainModule());
    final f = File('${tmp.path}/cache/example.com/me/plib@v1.0.0/console/console.act');
    Process.runSync('chmod', ['-R', 'u+w', '${tmp.path}/cache']);
    f.writeAsStringSync(pkg('console', 7));
    final (lines, ok) = verifyModules(mainModule());
    expect(ok, isFalse);
    expect(lines.single, contains('example.com/me/plib v1.0.0: MISMATCH in the cache'));
  });

  test('vendor/ holds the versions used, and is used instead of the cache', () {
    repo('plib', 'example.com/me/plib', {
      'v1.0.0': {'console/console.act': pkg('console', 1)},
      'v1.1.0': {'console/console.act': pkg('console', 2)},
    });
    appModule({'example.com/me/plib': gitEntry('plib', 'v1.1.0')}, usesConsole);
    expect(errorOf(() => vendorModules(mainModule())), contains("is not fetched; run 'action --fetch'"));
    fetchModules(mainModule());
    expect(vendorModules(mainModule()), equals(['vendored example.com/me/plib v1.1.0']));
    expect(File('$app/vendor/modules.txt').readAsLinesSync().last, equals('example.com/me/plib v1.1.0'));
    expect(File('$app/vendor/example.com/me/plib/console/console.act').existsSync(), isTrue);
    // Without the cache, the build uses vendor/
    Process.runSync('chmod', ['-R', 'u+w', '${tmp.path}/cache']);
    Directory('${tmp.path}/cache').deleteSync(recursive: true);
    expect(build(), contains('_example_com.me.plib.console..twice:'));
    expect(verifyModules(mainModule()).$2, isTrue);
    // A requirement raised after vendoring
    write('$app/action.json',
        '{ "action": { "module": { "name": "example.com/me/app" }, "requires": { "example.com/me/plib": ${gitEntry('plib', 'v1.2.0')} } } }');
    expect(errorOf(build),
        contains("vendor/ does not match the requirement of example.com/me/plib in action.json; run 'action --vendor' (in Particle: make vendor)"));
  });

  test('a path requirement uses a folder, only in the main module', () {
    write('${tmp.path}/plib/action.json', '{ "action": { "module": { "name": "example.com/me/plib" } } }');
    write('${tmp.path}/plib/console/console.act', pkg('console', 5));
    repo('util', 'example.com/me/util', {'v1.0.0': {'text/text.act': 'package text;\n'}});
    appModule({'example.com/me/plib': '{ "path": "../plib" }'}, usesConsole);
    expect(build(), contains('Imm4 load (5)'));
    expect(File('$app/action.sum').existsSync(), isFalse);
    write('${tmp.path}/plib/action.json', '{ "action": { "module": { "name": "example.com/me/other" } } }');
    expect(errorOf(build),
        contains("requirement 'example.com/me/plib': '../plib' must have an action.json that names the module 'example.com/me/plib', not 'example.com/me/other'"));
  });

  test('errors in requires and imports name what to do', () {
    appModule({'example.com/me/plib': '{ "version": "1.0" }'}, usesConsole);
    expect(errorOf(build), contains("requirement 'example.com/me/plib': '1.0' is not a version: write a git tag such as v1.2.0"));
    appModule({'plib': '{ "version": "v1.0.0" }'}, usesConsole);
    expect(errorOf(build), contains("its first part names a server and has a dot"));
    appModule({}, usesConsole);
    expect(errorOf(build),
        contains("no required module provides the package 'example.com/me/plib/console'; add its module to \"requires\""));
    repo('plib', 'example.com/me/plib', {'v1.0.0': {'console/console.act': pkg('console', 1)}});
    appModule({'example.com/me/plib': gitEntry('plib', 'v9.0.0')}, usesConsole);
    expect(errorOf(() => fetchModules(mainModule())), contains('could not fetch module example.com/me/plib v9.0.0 from'));
    moduleCommand = 'action_llvm';
    appModule({'example.com/me/plib': gitEntry('plib', 'v1.0.0')}, usesConsole);
    expect(errorOf(build), contains("run 'action_llvm --fetch' (in Particle: make deps)"));
  });

  group('commits', () {
    String head(String dir) => (Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: dir).stdout as String).trim();

    /// Adds a commit (no tag) to the repository [dir] with [files].
    String commitTo(String dir, Map<String, String> files) {
      files.forEach((f, text) => write('$dir/$f', text));
      git(dir, ['add', '-A']);
      git(dir, ['commit', '-qm', 'more']);
      return head(dir);
    }

    String commitEntry(String short, String commit) =>
        '{ "commit": "$commit", "git": "${tmp.path}/repos/$short" }';

    test('a commit after a tag is given the version after it, recorded in action.sum', () {
      final r = repo('plib', 'example.com/me/plib', {'v1.0.0': {'console/console.act': pkg('console', 1)}});
      final c = commitTo(r, {'console/console.act': pkg('console', 2)});
      appModule({'example.com/me/plib': commitEntry('plib', c.substring(0, 12))}, usesConsole);
      expect(errorOf(build),
          contains("module example.com/me/plib commit ${c.substring(0, 12)} is not fetched; run 'action --fetch'"));
      final lines = fetchModules(mainModule());
      expect(lines.single, matches(r'^fetched example.com/me/plib commit [0-9a-f]{12} as v1\.0\.1-0\.\d{14}-' + c.substring(0, 12) + r'$'));
      final sums = readSums('$app/action.sum');
      final v = sums['example.com/me/plib commit:${c.substring(0, 12)}']!;
      expect(v, startsWith('v1.0.1-0.'));
      expect(sums['example.com/me/plib $v'], startsWith('sha256:'));
      expect(build(), contains('Imm4 load (2)'));
      // Ordered before the next release, after the tag
      expect(Version.tryParse(v)!.compareTo(Version.tryParse('v1.0.1')!), equals(-1));
      expect(Version.tryParse(v)!.compareTo(Version.tryParse('v1.0.0')!), equals(1));
      expect(verifyModules(mainModule()).$2, isTrue);
      expect(fetchModules(mainModule()), equals(['all required modules are in the cache']));
    });

    test('with no tag before it, v0.0.0; a tagged commit is its tag', () {
      final r = repo('plib', 'example.com/me/plib', {});
      write('$r/action.json', '{ "action": { "module": { "name": "example.com/me/plib" } } }');
      final c = commitTo(r, {'console/console.act': pkg('console', 1)});
      appModule({'example.com/me/plib': commitEntry('plib', c)}, usesConsole);
      fetchModules(mainModule());
      expect(readSums('$app/action.sum')['example.com/me/plib commit:$c'], matches(r'^v0\.0\.0-\d{14}-[0-9a-f]{12}$'));
      git(r, ['tag', 'v0.3.0']);
      Process.runSync('chmod', ['-R', 'u+w', '${tmp.path}/cache']);
      Directory('${tmp.path}/cache').deleteSync(recursive: true);
      File('$app/action.sum').deleteSync();
      fetchModules(mainModule());
      expect(readSums('$app/action.sum')['example.com/me/plib commit:$c'], equals('v0.3.0'));
    });

    test('a commit takes part in version selection, and is vendored', () {
      final r = repo('plib', 'example.com/me/plib', {
        'v1.0.0': {'console/console.act': pkg('console', 1)},
        'v1.1.0': {'console/console.act': pkg('console', 3)},
      });
      git(r, ['checkout', '-q', 'v1.0.0']);
      final c = commitTo(r, {'console/console.act': pkg('console', 2)});
      repo('util', 'example.com/me/util', {'v1.0.0': {'text/text.act': 'package text;\n'}},
          requires: {'example.com/me/plib': 'v1.1.0'});
      appModule({
        'example.com/me/plib': commitEntry('plib', c),
        'example.com/me/util': gitEntry('util', 'v1.0.0'),
      }, usesConsole);
      fetchModules(mainModule());
      // v1.1.0 is later than v1.0.1-0.... (the commit after v1.0.0)
      expect(buildList(mainModule()).modules['example.com/me/plib']!.version, equals('v1.1.0'));
      expect(build(), contains('Imm4 load (3)'));
      vendorModules(mainModule());
      expect(build(), contains('Imm4 load (3)'));
    });

    test('a commit that does not exist, and an entry with both a version and a commit', () {
      repo('plib', 'example.com/me/plib', {'v1.0.0': {'console/console.act': pkg('console', 1)}});
      appModule({'example.com/me/plib': commitEntry('plib', 'abcdef1234567')}, usesConsole);
      expect(errorOf(() => fetchModules(mainModule())), contains('module example.com/me/plib has no commit abcdef1234567 in'));
      appModule({'example.com/me/plib': '{ "version": "v1.0.0", "commit": "abcdef1" }'}, usesConsole);
      expect(errorOf(build), contains('needs one of "version", "commit" or "path"'));
      appModule({'example.com/me/plib': '{ "commit": "ABC" }'}, usesConsole);
      expect(errorOf(build), contains("'ABC' is not a commit"));
    });
  });
}
