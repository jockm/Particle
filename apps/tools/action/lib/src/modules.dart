// ------------------------------------------------------------------------------
// Modules and versions
// ------------------------------------------------------------------------------
//
// A module is a collection of packages, usually one git repository, named
// by a path as in Go (`github.com/jockm/plib`). Its action.json names it and
// lists the modules it needs:
//
//   {
//     "action": {
//       "module": { "name": "github.com/jockm/firmware" },
//       "requires": {
//         "github.com/jockm/plib": { "version": "v1.4.0" },
//         "github.com/jockm/proto": { "path": "../proto" }
//       }
//     }
//   }
//
// A version is a git tag vMAJOR.MINOR.PATCH (with an optional pre-release
// part). `"git"` gives the repository's address when it is not `https://`
// and the module path. `"path"` uses a folder instead of a fetched version;
// it counts only in the main module's action.json.
//
// The versions used are chosen by minimal version selection: every module
// states the lowest version of each module it needs, and the build uses the
// highest of those, across the whole requirement graph. One build may hold
// only one major version of a module.
//
// The compiler never touches the network. `action --fetch` fetches with git
// into the cache (~/.cache/action, or $ACTION_CACHE) and records a checksum
// of every version in action.sum, next to action.json. `action --vendor`
// copies the chosen versions into vendor/, which, when it exists, is used
// instead of the cache. `action --verify` checks both against action.sum.

import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'paths.dart' as p;
import 'sha256.dart';

/// The command named in messages about fetching (`action` or
/// `action_llvm`); the command-line tool sets it.
String moduleCommand = 'action';

/// How a message names the command that does [mode] (`--fetch`,
/// `--vendor`).
String commandHint(String mode) =>
    "run '$moduleCommand $mode' (in Particle: make ${mode == '--fetch' ? 'deps' : 'vendor'})";

/// One entry of `requires`.
class Requirement {
  final String path;
  final String? version;
  final String? git;
  final String? localPath;
  const Requirement(this.path, {this.version, this.git, this.localPath});
}

/// A module's action.json: where it is, its name and what it requires.
class ModuleFile {
  final String root;
  final String name;
  final Map<String, Requirement> requires;
  ModuleFile(this.root, this.name, this.requires);

  String get sumPath => p.join(root, 'action.sum');
  String get vendorDir => p.join(root, 'vendor');
}

/// A problem with modules; [module] is the module it is about, when there
/// is one.
class ModuleError extends CompileError {
  final String? module;
  ModuleError(super.message, [this.module]);
}

final _element = RegExp(r'^[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$');

/// Null when [path] is a valid module path; otherwise why not. Each part
/// between `/` is letters and digits, with single `.` or `-` between them.
/// A module that is fetched ([fetched]) has a dot in its first part
/// (`github.com/...`).
String? modulePathProblem(String path, {bool fetched = false}) {
  final parts = path.split('/');
  if (parts.any((e) => !_element.hasMatch(e))) {
    return "'$path' is not a module path: each part between '/' is letters and digits, "
        "with single '.' or '-' between them";
  }
  if (fetched && !parts.first.contains('.')) {
    return "'$path' is not a module path that can be fetched: its first part names a "
        "server and has a dot, as in 'github.com/you/lib'";
  }
  return null;
}

/// The prefix of the internal names of package [rel] (its folder inside
/// the module, `/` between parts, or empty) of the module [modulePath]:
/// `/` becomes `.`, `.` becomes `_` and `-` becomes `__`, so
/// `github.com/jockm/plib` + `console` is `github_com.jockm.plib.console`.
String modulePrefix(String modulePath, String rel) {
  final m = modulePath
      .split('/')
      .map((e) => e.replaceAll('-', '__').replaceAll('.', '_'))
      .join('.');
  return rel.isEmpty ? m : '$m.${rel.replaceAll('/', '.')}';
}

// ---------------------------------------------------------------- versions

final _versionRe = RegExp(r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$');

/// A version: a git tag vMAJOR.MINOR.PATCH, with an optional pre-release
/// part (`v1.4.0-beta.1`), ordered as semantic versioning orders them.
class Version implements Comparable<Version> {
  final int major, minor, patch;
  final String? pre;
  final String text;
  Version._(this.major, this.minor, this.patch, this.pre, this.text);

  static Version? tryParse(String s) {
    final m = _versionRe.firstMatch(s);
    if (m == null) return null;
    return Version._(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m[4], s);
  }

  @override
  int compareTo(Version o) {
    for (final (a, b) in [(major, o.major), (minor, o.minor), (patch, o.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    if (pre == o.pre) return 0;
    if (pre == null) return 1;
    if (o.pre == null) return -1;
    final x = pre!.split('.'), y = o.pre!.split('.');
    for (var i = 0; i < x.length && i < y.length; i++) {
      final xi = int.tryParse(x[i]), yi = int.tryParse(y[i]);
      final c = (xi != null && yi != null)
          ? xi.compareTo(yi)
          : xi != null
              ? -1
              : yi != null
                  ? 1
                  : x[i].compareTo(y[i]);
      if (c != 0) return c;
    }
    return x.length.compareTo(y.length);
  }

  @override
  String toString() => text;
}

// ------------------------------------------------------------ action.json

/// Reads the action.json in [dir], or returns null when there is none or
/// it names no module.
ModuleFile? readModuleFile(String dir) {
  final f = File(p.join(dir, 'action.json'));
  if (!f.existsSync()) return null;
  final Object? json;
  try {
    json = jsonDecode(f.readAsStringSync());
  } on FormatException {
    throw ModuleError('${f.path}: not valid JSON');
  }
  final section = json is Map ? (json['action'] ?? json) : null;
  if (section is! Map) return null;
  final module = section['module'];
  final name = module is Map ? module['name'] : null;
  if (name is! String || name.isEmpty) return null;
  final problem = modulePathProblem(name);
  if (problem != null) throw ModuleError('${f.path}: $problem');
  final requires = <String, Requirement>{};
  final req = section['requires'];
  if (req != null) {
    if (req is! Map) throw ModuleError('${f.path}: "requires" must be an object');
    req.forEach((path, entry) {
      path as String;
      String fail(String why) => throw ModuleError("${f.path}: requirement '$path': $why", path);
      if (entry is! Map) fail('must be an object such as { "version": "v1.2.0" }');
      final version = entry['version'], git = entry['git'], local = entry['path'];
      if (version != null && (version is! String || Version.tryParse(version) == null)) {
        fail("'$version' is not a version: write a git tag such as v1.2.0");
      }
      if (git != null && git is! String) fail('"git" must be a string');
      if (local != null && local is! String) fail('"path" must be a string');
      if (version == null && local == null) fail('needs a "version" (or a "path")');
      final pp = modulePathProblem(path, fetched: local == null);
      if (pp != null) fail(pp);
      requires[path] = Requirement(path,
          version: version as String?, git: git as String?, localPath: local as String?);
    });
  }
  return ModuleFile(p.realPath(dir), name, requires);
}

/// The nearest action.json naming a module, in [startDir] or a folder
/// above it.
ModuleFile? findModuleFile(String startDir) {
  var dir = p.realPath(startDir);
  while (true) {
    final m = readModuleFile(dir);
    if (m != null) return m;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

// ------------------------------------------------------------------ cache

/// When set, the cache folder to use instead of \$ACTION_CACHE (for tests).
String? cacheRootOverride;

/// The folder fetched modules are kept in.
String cacheRoot() {
  if (cacheRootOverride != null) return cacheRootOverride!;
  final env = Platform.environment['ACTION_CACHE'];
  if (env != null && env.isNotEmpty) return env;
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return p.join(home, '.cache', 'action');
}

/// The folder of [path] at [version] in the cache. Capital letters are
/// written `!` and the letter, as Go does, so that paths differing only in
/// case stay apart on file systems that ignore case.
String cacheDir(String path, String version) {
  final escaped = path.replaceAllMapped(RegExp('[A-Z]'), (m) => '!${m[0]!.toLowerCase()}');
  return p.join(cacheRoot(), '$escaped@$version');
}

// ------------------------------------------------------------- checksums

/// The files of a module, relative to [dir] with `/`, sorted, leaving out
/// `.git` folders.
List<String> moduleFiles(String dir) {
  final out = <String>[];
  void walk(Directory d, String rel) {
    for (final e in d.listSync(followLinks: false)) {
      final name = p.basename(e.path);
      final r = rel.isEmpty ? name : '$rel/$name';
      if (e is Directory) {
        if (name != '.git') walk(e, r);
      } else if (e is File) {
        out.add(r);
      }
    }
  }

  walk(Directory(dir), '');
  return out..sort();
}

/// The checksum of the module in [dir]: SHA-256 over one line per file
/// (the file's SHA-256 and its path), in path order.
String dirHash(String dir) {
  final buf = StringBuffer();
  for (final rel in moduleFiles(dir)) {
    buf.write('${sha256Hex(File(p.join(dir, rel)).readAsBytesSync())}  $rel\n');
  }
  return 'sha256:${sha256Hex(utf8.encode(buf.toString()))}';
}

final Map<String, String> _hashMemo = {};

String _cachedHash(String dir) => _hashMemo[dir] ??= dirHash(dir);

/// action.sum: the checksum of each module version, keyed `path version`.
Map<String, String> readSums(String sumPath) {
  final f = File(sumPath);
  final out = <String, String>{};
  if (!f.existsSync()) return out;
  for (final line in f.readAsLinesSync()) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length == 3) out['${parts[0]} ${parts[1]}'] = parts[2];
  }
  return out;
}

void writeSums(String sumPath, Map<String, String> sums) {
  final keys = sums.keys.toList()
    ..sort((a, b) {
      final (pa, va) = _split(a);
      final (pb, vb) = _split(b);
      final c = pa.compareTo(pb);
      return c != 0 ? c : Version.tryParse(va)!.compareTo(Version.tryParse(vb)!);
    });
  File(sumPath).writeAsStringSync(keys.map((k) => '$k ${sums[k]}\n').join());
}

(String, String) _split(String key) {
  final i = key.indexOf(' ');
  return (key.substring(0, i), key.substring(i + 1));
}

// -------------------------------------------------------------- selection

/// A module of the build: its version (null for one used from a `path`)
/// and its folder.
class SelectedModule {
  final String path;
  final String? version;
  final String dir;
  const SelectedModule(this.path, this.version, this.dir);
}

/// The modules a build uses, besides the main one.
class BuildList {
  final ModuleFile main;
  final Map<String, SelectedModule> modules;
  final bool vendored;
  BuildList(this.main, this.modules, this.vendored);

  /// The module that provides the package [importPath], or null.
  SelectedModule? moduleOf(String importPath) {
    SelectedModule? best;
    for (final m in modules.values) {
      if ((importPath == m.path || importPath.startsWith('${m.path}/')) &&
          (best == null || m.path.length > best.path.length)) {
        best = m;
      }
    }
    return best;
  }
}

/// Walks the requirement graph of [main]. [dirOf] gives the folder of a
/// version, fetching it if the caller fetches, and returns null when it is
/// not there. Returns every version reached (for action.sum) and the
/// selected build list.
(Set<(String, String)>, Map<String, SelectedModule>) walkRequirements(
    ModuleFile main, String? Function(String path, String version, String? git) dirOf) {
  final replaced = <String, String>{};
  final required = <String, List<(Version, String)>>{}; // path -> (version, required by)
  final reached = <(String, String)>{};
  final queue = <(String, String, String?, String)>[]; // path, version, git, by
  final gits = <String, String>{};

  void addRequires(ModuleFile m, {required bool isMain}) {
    for (final r in m.requires.values) {
      if (r.path == main.name) continue;
      if (r.localPath != null && isMain) {
        if (replaced.containsKey(r.path)) continue;
        final dir = p.realPath(File(r.localPath!).isAbsolute ? r.localPath! : p.join(m.root, r.localPath!));
        if (!Directory(dir).existsSync()) {
          throw ModuleError("requirement '${r.path}': the folder '${r.localPath}' does not exist", r.path);
        }
        final mf = readModuleFile(dir);
        if (mf == null || mf.name != r.path) {
          throw ModuleError("requirement '${r.path}': '${r.localPath}' must have an action.json that names "
              "the module '${r.path}'${mf == null ? '' : ", not '${mf.name}'"}", r.path);
        }
        replaced[r.path] = dir;
        addRequires(mf, isMain: false);
        continue;
      }
      if (r.version == null) continue; // a path in a dependency's file is ignored
      if (r.git != null) gits.putIfAbsent(r.path, () => r.git!);
      queue.add((r.path, r.version!, r.git, m == main ? 'the main module' : m.name));
    }
  }

  addRequires(main, isMain: true);
  final seen = <String>{};
  while (queue.isNotEmpty) {
    final (path, version, git, by) = queue.removeAt(0);
    (required[path] ??= []).add((Version.tryParse(version)!, by));
    if (replaced.containsKey(path) || !seen.add('$path $version')) continue;
    reached.add((path, version));
    final dir = dirOf(path, version, git ?? gits[path]);
    if (dir == null) {
      throw ModuleError('module $path $version is not fetched; ${commandHint('--fetch')}', path);
    }
    final mf = readModuleFile(dir);
    if (mf == null || mf.name != path) {
      throw ModuleError('module $path $version: its action.json must name the module '
          "'$path'${mf == null ? '' : ", not '${mf.name}'"}", path);
    }
    addRequires(mf, isMain: false);
  }

  final selected = <String, SelectedModule>{};
  for (final e in replaced.entries) {
    selected[e.key] = SelectedModule(e.key, null, e.value);
  }
  for (final e in required.entries) {
    if (replaced.containsKey(e.key)) continue;
    final versions = e.value;
    final majors = {for (final (v, _) in versions) v.major};
    if (majors.length > 1) {
      final who = versions.map((x) => '${x.$2} needs ${x.$1}').toSet().join(', ');
      throw ModuleError('module ${e.key}: a build can use only one major version of a module, '
          'but $who', e.key);
    }
    final best = versions.map((x) => x.$1).reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    selected[e.key] = SelectedModule(e.key, best.text, dirOf(e.key, best.text, gits[e.key])!);
  }
  return (reached, selected);
}

/// The build list of the main module [main]: from vendor/ when it exists,
/// otherwise from the cache, with every cached version checked against
/// action.sum.
BuildList buildList(ModuleFile main) {
  if (Directory(main.vendorDir).existsSync()) return _vendoredList(main);
  final (_, selected) = walkRequirements(main, (path, version, _) {
    final d = cacheDir(path, version);
    return Directory(d).existsSync() ? d : null;
  });
  final sums = readSums(main.sumPath);
  for (final m in selected.values) {
    if (m.version == null) continue;
    final want = sums['${m.path} ${m.version}'];
    if (want == null) {
      throw ModuleError('module ${m.path} ${m.version} has no checksum in action.sum; '
          '${commandHint('--fetch')}', m.path);
    }
    final got = _cachedHash(m.dir);
    if (got != want) {
      throw ModuleError('module ${m.path} ${m.version} in the cache (${m.dir}) does not match '
          'action.sum: it has $got, action.sum has $want. The cache was changed, or the '
          'version was fetched again after its tag moved; check before trusting it', m.path);
    }
  }
  return BuildList(main, selected, false);
}

/// The modules listed in vendor/modules.txt (`path version`, or
/// `path local`), checked against the main module's requirements.
BuildList _vendoredList(ModuleFile main) {
  final list = File(p.join(main.vendorDir, 'modules.txt'));
  if (!list.existsSync()) {
    throw ModuleError('${main.vendorDir} has no modules.txt; ${commandHint('--vendor')}');
  }
  final modules = <String, SelectedModule>{};
  for (final line in list.readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    final dir = p.join(main.vendorDir, parts[0]);
    modules[parts[0]] = SelectedModule(parts[0], parts[1] == 'local' ? null : parts[1], dir);
  }
  for (final r in main.requires.values) {
    final m = modules[r.path];
    final stale = m == null ||
        (r.localPath != null) != (m.version == null) ||
        (r.version != null &&
            m.version != null &&
            Version.tryParse(m.version!)!.compareTo(Version.tryParse(r.version!)!) < 0);
    if (stale) {
      throw ModuleError('vendor/ does not match the requirement of ${r.path} in action.json; '
          '${commandHint('--vendor')}', r.path);
    }
  }
  return BuildList(main, modules, true);
}

// ------------------------------------------------------------ the modes

/// `--fetch`: fetches every version the requirement graph of [main] needs
/// into the cache, checks or records its checksum, and rewrites action.sum.
/// Returns the lines to print.
List<String> fetchModules(ModuleFile main) {
  if (main.requires.isEmpty && !File(main.sumPath).existsSync()) {
    return ['${p.join(main.root, 'action.json')} requires no modules'];
  }
  final sums = readSums(main.sumPath);
  final out = <String>[];
  final newSums = <String, String>{};
  final (reached, _) = walkRequirements(main, (path, version, git) {
    final dir = cacheDir(path, version);
    final key = '$path $version';
    if (!Directory(dir).existsSync()) {
      final tmp = _fetchWithGit(path, version, git);
      final mf = readModuleFile(tmp);
      if (mf == null || mf.name != path) {
        Directory(tmp).deleteSync(recursive: true);
        throw ModuleError('module $path $version: its action.json must name the module '
            "'$path'${mf == null ? '' : ", not '${mf.name}'"}", path);
      }
      final got = dirHash(tmp);
      final want = sums[key];
      if (want != null && want != got) {
        Directory(tmp).deleteSync(recursive: true);
        throw ModuleError('module $path $version does not match action.sum: the fetched copy has '
            '$got, action.sum has $want. The tag may have been moved; check with the module\'s '
            'author before changing action.sum', path);
      }
      Directory(p.dirname(dir)).createSync(recursive: true);
      Directory(tmp).renameSync(dir);
      _makeReadOnly(dir);
      out.add('fetched $path $version');
    }
    final got = dirHash(dir);
    final want = sums[key];
    if (want != null && want != got) {
      throw ModuleError('module $path $version in the cache ($dir) does not match action.sum: '
          'it has $got, action.sum has $want', path);
    }
    newSums[key] = got;
    _hashMemo[dir] = got;
    return dir;
  });
  assert(reached.length == newSums.length);
  writeSums(main.sumPath, newSums);
  if (out.isEmpty) out.add('all required modules are in the cache');
  return out;
}

String _fetchWithGit(String path, String version, String? git) {
  final url = git ?? 'https://$path';
  final root = cacheRoot();
  Directory(root).createSync(recursive: true);
  final tmp = Directory(root).createTempSync('fetch-').path;
  final ProcessResult r;
  try {
    r = Process.runSync('git', [
      '-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', //
      '--branch', version, url, tmp,
    ]);
  } on ProcessException {
    Directory(tmp).deleteSync(recursive: true);
    throw ModuleError('fetching modules needs git, which was not found; install git and try again', path);
  }
  if (r.exitCode != 0) {
    if (Directory(tmp).existsSync()) Directory(tmp).deleteSync(recursive: true);
    throw ModuleError('could not fetch module $path $version from $url: '
        '${(r.stderr as String).trim()}', path);
  }
  final dotGit = Directory(p.join(tmp, '.git'));
  if (dotGit.existsSync()) dotGit.deleteSync(recursive: true);
  return tmp;
}

void _makeReadOnly(String dir) {
  if (Platform.isWindows) return;
  Process.runSync('chmod', ['-R', 'a-w', dir]);
}

/// `--vendor`: copies the selected versions (from the cache, which must
/// hold them) into vendor/ and writes vendor/modules.txt.
List<String> vendorModules(ModuleFile main) {
  final vendor = Directory(main.vendorDir);
  // The cache's list, not the one already vendored
  final hidden = '${main.vendorDir}.old';
  if (vendor.existsSync()) {
    if (Directory(hidden).existsSync()) Directory(hidden).deleteSync(recursive: true);
    vendor.renameSync(hidden);
  }
  final BuildList list;
  try {
    list = buildList(main);
  } catch (_) {
    if (Directory(hidden).existsSync()) Directory(hidden).renameSync(main.vendorDir);
    rethrow;
  }
  if (Directory(hidden).existsSync()) Directory(hidden).deleteSync(recursive: true);
  final out = <String>[];
  final lines = <String>['# Written by $moduleCommand --vendor: the modules this build uses.'];
  final paths = list.modules.keys.toList()..sort();
  for (final path in paths) {
    final m = list.modules[path]!;
    final to = p.join(main.vendorDir, path);
    for (final rel in moduleFiles(m.dir)) {
      final dst = File(p.join(to, rel));
      dst.parent.createSync(recursive: true);
      dst.writeAsBytesSync(File(p.join(m.dir, rel)).readAsBytesSync());
    }
    lines.add('$path ${m.version ?? 'local'}');
    out.add('vendored $path ${m.version ?? '(local)'}');
  }
  if (paths.isEmpty) return ['no modules to vendor'];
  File(p.join(main.vendorDir, 'modules.txt')).writeAsStringSync('${lines.join('\n')}\n');
  return out;
}

/// `--verify`: checks the cached versions listed in action.sum, and the
/// vendored ones, against action.sum, without the network. Returns the
/// lines to print and whether everything matched.
(List<String>, bool) verifyModules(ModuleFile main) {
  final sums = readSums(main.sumPath);
  final out = <String>[];
  var ok = true;
  for (final key in sums.keys.toList()..sort()) {
    final (path, version) = _split(key);
    final dir = cacheDir(path, version);
    if (!Directory(dir).existsSync()) {
      out.add('$path $version: not in the cache (not checked)');
      continue;
    }
    final got = dirHash(dir);
    if (got == sums[key]) {
      out.add('$path $version: ok');
    } else {
      ok = false;
      out.add('$path $version: MISMATCH in the cache: $got, action.sum has ${sums[key]}');
    }
  }
  if (Directory(main.vendorDir).existsSync()) {
    final list = _vendoredList(main);
    for (final m in list.modules.values) {
      if (m.version == null) continue;
      final want = sums['${m.path} ${m.version}'];
      final got = Directory(m.dir).existsSync() ? dirHash(m.dir) : null;
      if (want == null) {
        ok = false;
        out.add('vendor/${m.path} ${m.version}: no checksum in action.sum');
      } else if (got != want) {
        ok = false;
        out.add('vendor/${m.path} ${m.version}: MISMATCH: ${got ?? 'missing'}, action.sum has $want');
      } else {
        out.add('vendor/${m.path} ${m.version}: ok');
      }
    }
  }
  return (out, ok);
}
