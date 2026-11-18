// ------------------------------------------------------------------------------
// The project file (action.json)
// ------------------------------------------------------------------------------
//
// Optional, at the workspace root:
//
//   {
//     "action": {
//       "module": { "name": "github.com/you/project" },
//       "includeDirs": ["lib", "apps/act"],
//       "defines": { "DEBUG": 1, "BAUD": 115200 },
//       "target": ["particle", "llvm"],
//       "programFolders": ["apps/act/multi"],
//       "programs": [
//         { "files": ["tools/gen_main.act", "tools/gen_tables.act"] }
//       ]
//     }
//   }
//
// Paths are relative to the project file. Each folder inside a folder named
// in "programFolders" is one program: all the .act files in it, found again
// each time it is checked, so adding a folder or a file needs no change
// here. "programs" lists other groups file by file. A file in a program is
// checked together with the rest of that program; any other file is checked
// on its own, with its imports.
//
// "module" names the module: a package's import path is that name, then
// the package's folder inside the project file's folder. "requires" lists
// the modules it uses (see the compiler's modules.dart); one that cannot be
// used yet (not fetched, say) is shown as an error on its entry.
//
// "target" is the compiler programs are checked for: "particle" (the
// default) or "llvm", or a list of both. With both, an error found for only
// one of them is shown as a warning that names it. Without a project file the include
// directories are the workspace root and its `lib` directory (the compiler
// always searches the importing file's own directory first).

import 'dart:convert';
import 'dart:io';

import 'package:action/action.dart' show analysisTargets, ModuleError, readModuleFile, buildList;

import 'documents.dart';

/// Name of the project file at the workspace root.
const projectFileName = 'action.json';

/// A problem in the project file, with the line it is on when known.
class ProjectError {
  final String path;
  final int line; // from 0
  final String message;
  const ProjectError(this.path, this.line, this.message);
}

/// What the project file says (or the defaults).
class Project {
  /// The workspace root, or null when the editor gave none.
  final String? root;

  /// The project file's path, when there is one.
  final String? file;

  /// Include directories, absolute.
  final List<String> includeDirs;

  /// `-D` definitions, as the compiler's command line takes them.
  final List<String> defines;

  /// Groups of files compiled together, as canonical absolute paths.
  final List<List<String>> programs;

  /// Folders each of whose subfolders is a program, as canonical absolute
  /// paths.
  final List<String> programFolders;

  /// The targets programs are checked for, the first one used for types
  /// and values shown in the editor.
  final List<String> targets;

  /// Set when the project file could not be used; the defaults apply.
  final ProjectError? error;

  const Project(this.root, this.file, this.includeDirs, this.defines, this.programs,
      [this.error, this.programFolders = const [], this.targets = const ['particle']]);

  /// The defaults for [root].
  factory Project.defaults(String? root, {String? file, ProjectError? error}) => Project(
      root, file, root == null ? const [] : [root, '$root/lib'],
      const [], const [], error);

  /// Reads [projectFileName] from [root], if it is there.
  factory Project.load(String? root) {
    if (root == null) return Project.defaults(null);
    final path = '$root/$projectFileName';
    final f = File(path);
    if (!f.existsSync()) return Project.defaults(root);
    final text = f.readAsStringSync();
    try {
      return Project.parse(root, path, text);
    } on ProjectError catch (e) {
      return Project.defaults(root, file: path, error: e);
    }
  }

  /// Parses the text of a project file at [path] in [root].
  factory Project.parse(String root, String path, String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw ProjectError(path, _lineOfOffset(text, e.offset), 'action.json: ${e.message}');
    }
    ProjectError fail(String key, String msg) =>
        ProjectError(path, _lineOfKey(text, key), 'action.json: $msg');
    if (json is! Map<String, Object?>) throw fail('', 'the file must contain a JSON object');
    final section = json['action'];
    if (section == null) return Project.defaults(root, file: path);
    if (section is! Map<String, Object?>) {
      throw fail('action', '"action" must be an object');
    }
    String abs(String rel) => canonicalPath(
        File(rel).isAbsolute ? rel : '$root/$rel');

    final includeDirs = <String>[];
    final inc = section['includeDirs'];
    if (inc != null) {
      if (inc is! List || inc.any((e) => e is! String)) {
        throw fail('includeDirs', '"includeDirs" must be a list of directory names');
      }
      includeDirs.addAll([for (final d in inc) abs(d as String)]);
    }
    for (final d in [root, canonicalPath('$root/lib')]) {
      if (!includeDirs.contains(d)) includeDirs.add(d);
    }

    final module = section['module'];
    if (module != null) {
      final name = module is Map<String, Object?> ? module['name'] : null;
      if (name is! String || name.isEmpty) {
        throw fail('module', '"module" must be an object such as { "name": "github.com/you/project" }');
      }
    }
    // The module's name and requirements, as the compiler reads them
    try {
      readModuleFile(File(path).parent.path);
    } on ModuleError catch (e) {
      final msg = e.message.replaceFirst(RegExp(r'^.*?action\.json: '), '');
      throw ProjectError(path, _lineOfKey(text, e.module ?? (module != null ? 'module' : 'requires')),
          'action.json: $msg');
    }

    final defines = <String>[];
    final defs = section['defines'];
    if (defs != null) {
      if (defs is! Map<String, Object?>) {
        throw fail('defines', '"defines" must be an object such as { "DEBUG": 1 }');
      }
      defs.forEach((name, value) {
        if (value is int) {
          defines.add('$name=$value');
        } else if (value is bool) {
          defines.add('$name=${value ? 1 : 0}');
        } else if (value is String) {
          defines.add('$name=$value');
        } else {
          throw fail(name, 'define "$name" must be an integer');
        }
      });
    }

    final programs = <List<String>>[];
    final progs = section['programs'];
    if (progs != null) {
      if (progs is! List) throw fail('programs', '"programs" must be a list');
      for (final p in progs) {
        final files = p is Map<String, Object?> ? p['files'] : null;
        if (files is! List || files.isEmpty || files.any((e) => e is! String)) {
          throw fail('programs', 'each program must be { "files": ["a.act", ...] }');
        }
        programs.add([for (final f in files) abs(f as String)]);
      }
    }

    final folders = <String>[];
    final pf = section['programFolders'];
    if (pf != null) {
      if (pf is! List || pf.any((e) => e is! String)) {
        throw fail('programFolders', '"programFolders" must be a list of directory names');
      }
      folders.addAll([for (final d in pf) abs(d as String)]);
    }

    var targets = const ['particle'];
    final tg = section['target'];
    if (tg != null) {
      final list = tg is String ? [tg] : (tg is List ? tg : null);
      if (list == null ||
          list.isEmpty ||
          list.any((e) => e is! String || !analysisTargets.contains(e))) {
        throw fail('target',
            '"target" must be ${analysisTargets.map((t) => '"$t"').join(' or ')}, or a list of them');
      }
      targets = [for (final t in list) t as String];
    }
    return Project(root, path, includeDirs, defines, programs, null, folders, targets);
  }

  /// The first required module that cannot be used as it is (not
  /// fetched, not matching action.sum, vendor/ out of date), with the line
  /// of its entry; null when all can be used.
  ProjectError? moduleProblem() {
    final f = file;
    if (f == null) return null;
    try {
      final main = readModuleFile(File(f).parent.path);
      if (main == null || main.requires.isEmpty) return null;
      buildList(main);
      return null;
    } on ModuleError catch (e) {
      final text = File(f).readAsStringSync();
      return ProjectError(f, _lineOfKey(text, e.module ?? 'requires'), e.message);
    } on FileSystemException {
      return null;
    }
  }

  /// The files compiled together with [path] (itself included).
  List<String> programFor(String path) {
    for (final p in programs) {
      if (p.contains(path)) return p;
    }
    return _folderProgram(path) ?? [path];
  }

  /// True when [sources] is a program the project file describes.
  bool isProgram(List<String> sources) =>
      programs.any((p) => p.length == sources.length && p.every(sources.contains)) ||
      (sources.isNotEmpty && _sameList(_folderProgram(sources.first), sources));

  /// The .act files of the program folder [path] is in, when it is in one.
  List<String>? _folderProgram(String path) {
    final dir = File(path).parent;
    if (!programFolders.contains(canonicalPath(dir.parent.path))) return null;
    final List<String> files;
    try {
      files = [
        for (final e in dir.listSync())
          if (e is File && e.path.endsWith('.act')) canonicalPath(e.path)
      ];
    } on FileSystemException {
      return null;
    }
    if (!files.contains(path)) files.add(path);
    return files..sort();
  }

  static bool _sameList(List<String>? a, List<String> b) =>
      a != null && a.length == b.length && a.every(b.contains);

  static int _lineOfOffset(String text, int? offset) {
    if (offset == null) return 0;
    final end = offset.clamp(0, text.length);
    return '\n'.allMatches(text.substring(0, end)).length;
  }

  static int _lineOfKey(String text, String key) {
    if (key.isEmpty) return 0;
    final i = text.indexOf('"$key"');
    return i < 0 ? 0 : _lineOfOffset(text, i);
  }
}
