// ------------------------------------------------------------------------------
// Code actions: quick fixes, organize imports, extract and inline a
// constant, and a method stub
// ------------------------------------------------------------------------------
//
// Each quick fix answers one of the compiler's messages, from the place the
// message gives and what it says. The other actions work on the text at the
// cursor or the selection.

import 'dart:io';

import 'package:action/action.dart';

import 'documents.dart';
import 'features.dart';
import 'refactor.dart';
import 'symbols.dart';

const _intTypes = {'u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'bool'};

/// The name an extracted constant is given; a rename starts on it at once.
const newConstantName = 'NEW_CONSTANT';

class CodeActions {
  final Features f;
  final Refactor rf;

  /// Folders searched for a file that declares a missing name (the
  /// project's include folders, its root and lib/).
  final List<String> searchDirs;

  /// The import paths of this file that the compiler warned are unused.
  final Set<String> unusedImports;

  CodeActions(this.f, this.rf, this.searchDirs, this.unusedImports);

  List<String> get lines => f.lines;
  String get uri => pathToUri(f.path);

  Map<String, Object?> _edit(Pos start, Pos end, String text) =>
      {'range': rangeJson(start, end), 'newText': text};

  Map<String, Object?> _action(String title, String kind, List<Map<String, Object?>> edits,
          {Map<String, Object?>? diagnostic, bool preferred = false, Map<String, Object?>? command, String? onUri}) =>
      {
        'title': title,
        'kind': kind,
        if (diagnostic != null) 'diagnostics': [diagnostic],
        if (preferred) 'isPreferred': true,
        'edit': {
          'changes': {onUri ?? uri: edits}
        },
        if (command != null) 'command': command,
      };

  /// The actions for [range], given the diagnostics the editor shows there.
  List<Map<String, Object?>> actions(Pos rangeStart, Pos rangeEnd, List<Object?> diagnostics, {List<String>? only}) {
    final out = <Map<String, Object?>>[];
    bool wants(String kind) => only == null || only.any((k) => kind == k || kind.startsWith('$k.'));
    if (wants('quickfix')) {
      for (final d in diagnostics) {
        if (d is Map<String, Object?>) out.addAll(_quickFixes(d));
      }
    }
    if (wants('source.organizeImports')) {
      final a = organizeImports();
      if (a != null) out.add(a);
    }
    if (wants('refactor.extract')) out.addAll(_extractConstant(rangeStart, rangeEnd));
    if (wants('refactor.inline')) out.addAll(_inlineConstant(rangeStart));
    return out;
  }

  // -------------------------------------------------------------- quick fixes

  List<Map<String, Object?>> _quickFixes(Map<String, Object?> d) {
    final message = d['message'] as String? ?? '';
    final range = d['range'] as Map<String, Object?>?;
    if (range == null) return const [];
    final at = Pos.fromJson(range['start']);
    if (at.line >= lines.length) return const [];
    RegExpMatch? m;

    // An unused import: remove its line
    if ((m = RegExp(r"^import '([^']+)' is not used").firstMatch(message)) != null) {
      return [
        _action("Remove the unused import '${m!.group(1)}'", 'quickfix',
            [_edit(Pos(at.line, 0), Pos(at.line + 1, 0), '')],
            diagnostic: d, preferred: true)
      ];
    }
    // A missing import
    if (message.contains('import "integer.act"')) return [_importFix('integer.act', d)];
    if (message.contains('import "string.act"')) return [_importFix('string.act', d)];
    if ((m = RegExp(r"^(?:type )?'(\w+)' is not declared").firstMatch(message)) != null) {
      return [for (final file in _filesDeclaring(m!.group(1)!)) _importFix(file, d)];
    }
    // Not pub
    if ((m = RegExp(r"^'(\w+)' of '([\w.]+)' is not pub").firstMatch(message)) != null) {
      final fix = _pubFix(_memberDecl(m!.group(2)!, m.group(1)!), m.group(1)!, d);
      return fix == null ? const [] : [fix];
    }
    if ((m = RegExp(r"^'(\w+)' is not pub in package '(\w+)'").firstMatch(message)) != null) {
      final pkg = f.index.program.packages.values.where((p) => p.name == m!.group(2)).firstOrNull;
      final s = pkg == null ? null : f.index.globals[pkg.internal(m!.group(1)!)];
      final fix = _pubFix(s, m!.group(1)!, d);
      return fix == null ? const [] : [fix];
    }
    // An ambiguous call: one fix per version
    if ((m = RegExp(r"^the call of '([^']+)' with \((.*?)\) could be (.+); convert").firstMatch(message)) != null) {
      return _versionFixes(at, m!.group(2)!, m.group(3)!, d);
    }
    // A reference that may be empty
    if ((m = RegExp(r"'(\w+)' may be empty here; check it with '([\w.]+)\.exists\(\)' first").firstMatch(message)) !=
        null) {
      final fix = _existsFix(at.line, m!.group(2)!, d);
      return fix == null ? const [] : [fix];
    }
    // Strings compared with == or !=
    if ((m = RegExp(r"^strings cannot be compared with '(==|!=)'").firstMatch(message)) != null) {
      final fix = _equalsFix(at, m!.group(1)!, d);
      return fix == null ? const [] : [fix];
    }
    // A package named differently from its folder
    if ((m = RegExp(r"^package '(\w+)' is in the folder '([^']+)'").firstMatch(message)) != null) {
      final folder = m!.group(2)!;
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(folder)) return const [];
      final pm = RegExp(r'^(\s*package\s+)(\w+)').firstMatch(lines[at.line]);
      if (pm == null) return const [];
      return [
        _action("Name the package '$folder', as its folder", 'quickfix',
            [_edit(Pos(at.line, pm.group(1)!.length), Pos(at.line, pm.end), folder)],
            diagnostic: d)
      ];
    }
    // A method that is not declared: a stub
    if ((m = RegExp(r"^method '(\w+)' of '([\w.]+)' is not declared").firstMatch(message)) != null) {
      final fix = _methodStub(at, m!.group(1)!, m.group(2)!, d);
      return fix == null ? const [] : [fix];
    }
    return const [];
  }

  /// Where a new import goes: after the last import, else after the
  /// package line, else before the first declaration.
  int _importLine() {
    var last = -1, pkg = -1, first = -1;
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.startsWith('import ')) last = i;
      if (t.startsWith('package ')) pkg = i;
      if (first < 0 && t.isNotEmpty && !t.startsWith('//')) first = i;
    }
    if (last >= 0) return last + 1;
    if (pkg >= 0) return pkg + 1;
    return first < 0 ? lines.length : first;
  }

  Map<String, Object?> _importFix(String file, Map<String, Object?> d) {
    final line = _importLine();
    return _action('Import "$file"', 'quickfix', [_edit(Pos(line, 0), Pos(line, 0), 'import "$file";\n')],
        diagnostic: d, preferred: true);
  }

  /// The files (as an import names them) that declare [name]: a function,
  /// type or constant, in the search folders. Package files are not
  /// imported as files, so they are left out.
  List<String> _filesDeclaring(String name) {
    final decl = RegExp('^\\s*(?:pub\\s+)?(?:(?:static|inline|asm|extern)\\s+)*(?:'
        '(?:const\\s+)?[\\w.\\[\\]]+\\s+$name\\s*(?:\\(|=|;)|type\\s+$name\\b|enum\\s+$name\\b)');
    final out = <String>{};
    for (final dir in searchDirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        if (e is! File || !e.path.endsWith('.act') || canonicalPath(e.path) == f.path) continue;
        final List<String> text;
        try {
          text = e.readAsLinesSync();
        } on FileSystemException {
          continue;
        }
        if (text.any((l) => RegExp(r'^\s*package\s+\w+\s*;').hasMatch(l))) continue;
        if (text.any(decl.hasMatch)) out.add(e.uri.pathSegments.last);
      }
    }
    return out.toList()..sort();
  }

  /// The declaration of member [member] of the type shown as [type]
  /// (`geo.Point`).
  Sym? _memberDecl(String type, String member) {
    var key = type;
    final dot = type.indexOf('.');
    if (dot > 0) {
      final pkg = f.index.program.packages.values.where((p) => p.name == type.substring(0, dot)).firstOrNull;
      if (pkg != null) key = pkg.internal(type.substring(dot + 1));
    }
    return f.index.fieldOf(key, member) ??
        f.index.methodsOf(key)[member] ??
        f.index.staticsOf(key)[member]?.first;
  }

  /// `pub` in front of the declaration [s], when it is in the user's files.
  Map<String, Object?>? _pubFix(Sym? s, String name, Map<String, Object?> d) {
    final at = s?.declStart ?? s?.at;
    if (at == null || rf.isReadOnly(at.path)) return null;
    final text = rf.featuresFor(at.path)?.lines;
    if (text == null || at.start.line >= text.length) return null;
    final line = text[at.start.line];
    final col = s!.declStart != null ? at.start.character : line.length - line.trimLeft().length;
    return _action("Make '$name' pub", 'quickfix', [_edit(Pos(at.start.line, col), Pos(at.start.line, col), 'pub ')],
        diagnostic: d, onUri: pathToUri(at.path));
  }

  /// The arguments of the call whose name (or `.` before it) is at [at]:
  /// the `(`, the `)` and each argument's start and end, on one line.
  (int, int, List<(int, int)>)? _callArgs(Pos at) {
    final line = lines[at.line];
    final open = line.indexOf('(', at.character);
    if (open < 0) return null;
    final args = <(int, int)>[];
    var depth = 0, start = open + 1;
    for (var i = open + 1; i < line.length; i++) {
      final c = line[i];
      if (c == '"' || c == "'") {
        i++;
        while (i < line.length && line[i] != c) {
          if (line[i] == '\\') i++;
          i++;
        }
        continue;
      }
      if (c == '(' || c == '[') depth++;
      if (c == ')' || c == ']') {
        if (depth == 0 && c == ')') {
          if (line.substring(start, i).trim().isNotEmpty || args.isNotEmpty) args.add(_trimmed(line, start, i));
          return (open, i, args);
        }
        depth--;
      }
      if (c == ',' && depth == 0) {
        args.add(_trimmed(line, start, i));
        start = i + 1;
      }
    }
    return null;
  }

  (int, int) _trimmed(String line, int s, int e) {
    while (s < e && line[s] == ' ') {
      s++;
    }
    while (e > s && line[e - 1] == ' ') {
      e--;
    }
    return (s, e);
  }

  List<Map<String, Object?>> _versionFixes(Pos at, String given, String versions, Map<String, Object?> d) {
    final call = _callArgs(at);
    if (call == null) return const [];
    final (_, _, args) = call;
    final givenTypes = given.split(', ');
    final out = <Map<String, Object?>>[];
    for (final v in versions.split(' or ')) {
      final vm = RegExp(r'^(.*)\((.*)\)$').firstMatch(v.trim());
      if (vm == null) continue;
      final params = vm.group(2)!.isEmpty ? <String>[] : vm.group(2)!.split(', ');
      if (params.length != args.length || givenTypes.length != args.length) continue;
      final edits = <Map<String, Object?>>[];
      for (var i = 0; i < args.length; i++) {
        if (givenTypes[i] == params[i] || !_intTypes.contains(params[i])) continue;
        final (s, e) = args[i];
        edits.add(_edit(Pos(at.line, s), Pos(at.line, e), '${params[i]}(${lines[at.line].substring(s, e)})'));
      }
      if (edits.isEmpty) continue;
      out.add(_action('Call ${v.trim()}', 'quickfix', edits, diagnostic: d));
    }
    return out;
  }

  Map<String, Object?>? _existsFix(int line, String name, Map<String, Object?> d) {
    final text = lines[line];
    final t = text.trim();
    if (!t.endsWith(';') || t.startsWith('}') || t.startsWith('if ') || t.startsWith('return')) return null;
    final indent = text.substring(0, text.length - text.trimLeft().length);
    return _action("Check '$name.exists()' first", 'quickfix', [
      _edit(Pos(line, 0), Pos(line, text.length), '${indent}if ($name.exists()) {\n$indent    $t\n$indent}')
    ], diagnostic: d);
  }

  /// The operand next to [i] on [line], going left or right: names joined
  /// by `.`, with indexes and calls, or a string literal.
  (int, int)? _operand(String line, int i, {required bool left}) {
    bool part(String c) => isWordChar(c) || c == '.';
    if (left) {
      var e = i;
      while (e > 0 && line[e - 1] == ' ') {
        e--;
      }
      var s = e;
      while (s > 0) {
        final c = line[s - 1];
        if (part(c)) {
          s--;
        } else if (c == ']' || c == ')' || c == '"') {
          final open = c == ']' ? '[' : (c == ')' ? '(' : '"');
          var depth = 0, j = s - 1;
          for (; j >= 0; j--) {
            if (line[j] == c && (c != '"' || j == s - 1)) depth++;
            if (line[j] == open && (c != '"' || j < s - 1)) depth--;
            if (depth == 0) break;
          }
          if (j < 0) return null;
          s = j;
        } else {
          break;
        }
      }
      return s < e ? (s, e) : null;
    }
    var s = i;
    while (s < line.length && line[s] == ' ') {
      s++;
    }
    var e = s;
    if (e < line.length && line[e] == '"') {
      e = line.indexOf('"', e + 1) + 1;
      return e > s ? (s, e) : null;
    }
    while (e < line.length) {
      final c = line[e];
      if (part(c)) {
        e++;
      } else if (c == '[' || c == '(') {
        final close = c == '[' ? ']' : ')';
        var depth = 0, j = e;
        for (; j < line.length; j++) {
          if (line[j] == c) depth++;
          if (line[j] == close) depth--;
          if (depth == 0) break;
        }
        if (j >= line.length) return null;
        e = j + 1;
      } else {
        break;
      }
    }
    return s < e ? (s, e) : null;
  }

  Map<String, Object?>? _equalsFix(Pos at, String op, Map<String, Object?> d) {
    final line = lines[at.line];
    var opAt = line.indexOf(op, at.character);
    if (opAt < 0) opAt = line.lastIndexOf(op, at.character);
    if (opAt < 0) return null;
    final l = _operand(line, opAt, left: true);
    final r = _operand(line, opAt + 2, left: false);
    if (l == null || r == null) return null;
    final a = line.substring(l.$1, l.$2), b = line.substring(r.$1, r.$2);
    final text = '${op == '!=' ? '!' : ''}$a.equals($b)';
    return _action('Compare with $text', 'quickfix', [_edit(Pos(at.line, l.$1), Pos(at.line, r.$2), text)],
        diagnostic: d, preferred: true);
  }

  // ------------------------------------------------------------ method stub

  /// The type of the argument [text]: a variable's type, or a literal's.
  String _argType(String text, Pos at) {
    final t = text.trim();
    if (t.startsWith('"')) return 'string';
    if (t.startsWith("'")) return 'u8';
    if (RegExp(r'^-\d').hasMatch(t)) return 's32';
    if (RegExp(r'^\d').hasMatch(t)) return 'u32';
    if (RegExp(r'^[A-Za-z_]\w*$').hasMatch(t)) {
      final col = lines[at.line].indexOf(t, at.character);
      final s = col < 0 ? null : f.symbolAt(Pos(at.line, col));
      if (s?.type != null) return sourceName(s!.type!);
    }
    return 'u32';
  }

  Map<String, Object?>? _methodStub(Pos at, String method, String type, Map<String, Object?> d) {
    // The type's declaration, in the user's files
    var key = type;
    final dot = type.indexOf('.');
    if (dot > 0) {
      final pkg = f.index.program.packages.values.where((p) => p.name == type.substring(0, dot)).firstOrNull;
      if (pkg == null) return null;
      key = pkg.internal(type.substring(dot + 1));
    }
    final ts = f.index.globals[key];
    final tAt = ts?.at;
    if (ts == null || ts.kind != SymKind.type || tAt == null || rf.isReadOnly(tAt.path)) return null;
    final call = _callArgs(at);
    if (call == null) return null;
    final (_, _, args) = call;
    final used = <String>{};
    final params = <String>[];
    for (var i = 0; i < args.length; i++) {
      final (s, e) = args[i];
      final text = lines[at.line].substring(s, e);
      var name = RegExp(r'^[A-Za-z_]\w*$').hasMatch(text) ? text : String.fromCharCode(0x61 + i);
      while (!used.add(name)) {
        name = '${name}_';
      }
      params.add('${_argType(text, Pos(at.line, s))} $name');
    }
    // The result: what the call is given to
    var ret = 'void';
    final line = lines[at.line];
    final decl = RegExp(r'^\s*([\w.]+)\s+\w+\s*=').firstMatch(line);
    final assign = RegExp(r'^\s*(\w+)\s*=').firstMatch(line);
    if (decl != null && !actionKeywords.contains(decl.group(1)) || decl != null && _intTypes.contains(decl.group(1))) {
      ret = decl.group(1)!;
    } else if (assign != null) {
      final s = f.symbolAt(Pos(at.line, line.indexOf(assign.group(1)!)));
      if (s?.type != null) ret = sourceName(s!.type!);
    }
    final shownType = type.contains('.') ? type.substring(type.indexOf('.') + 1) : type;
    final body = _intTypes.contains(ret) ? '    return 0;\n' : '';
    final stub = '\n$ret $shownType.$method(${params.join(', ')}) {\n$body}\n';
    // After the type's last method in its file, or after the type
    final typeLines = rf.featuresFor(tAt.path)?.lines;
    if (typeLines == null) return null;
    var after = -1;
    for (final (s, _) in f.index.bodies) {
      if (s.kind == SymKind.method && s.container == key && s.at?.path == tAt.path) {
        final end = f.index.bodyEnd(s);
        if (end != null && end.line > after) after = end.line;
      }
    }
    if (after < 0) {
      for (var i = tAt.start.line; i < typeLines.length; i++) {
        if (typeLines[i].trimLeft().startsWith('}')) {
          after = i;
          break;
        }
      }
    }
    if (after < 0) return null;
    return _action("Create the method '$shownType.$method'", 'quickfix', [_edit(Pos(after + 1, 0), Pos(after + 1, 0), stub)],
        diagnostic: d, onUri: pathToUri(tAt.path));
  }

  // -------------------------------------------------------- organize imports

  /// Sorts the imports (files first, then packages, each alphabetical, a
  /// blank line between), and removes duplicates and unused ones. A comment
  /// on the lines just above an import moves with it.
  Map<String, Object?>? organizeImports() {
    final imp = RegExp(r'^\s*import\s+"([^"]+)"(\s+as\s+(\w+))?\s*;?\s*(//.*)?$');
    final first = lines.indexWhere((l) => imp.hasMatch(l));
    if (first < 0) return null;
    final last = lines.lastIndexWhere((l) => imp.hasMatch(l));
    // Comments just above the first import belong to it
    var start = first;
    while (start > 0 && lines[start - 1].trimLeft().startsWith('//')) {
      start--;
    }
    final files = <String, String>{}, packages = <String, String>{};
    var comments = <String>[];
    for (var i = start; i <= last; i++) {
      final l = lines[i];
      final m = imp.firstMatch(l);
      if (m == null) {
        if (l.trimLeft().startsWith('//')) {
          comments.add(l);
        } else if (l.trim().isNotEmpty) {
          return null; // something else among the imports: leave them be
        } else {
          comments = [];
        }
        continue;
      }
      final path = m.group(1)!;
      final text = 'import "$path"${m.group(3) != null ? ' as ${m.group(3)}' : ''};${m.group(4) != null ? ' ${m.group(4)}' : ''}';
      if (!unusedImports.contains(path)) {
        final group = path.endsWith('.act') ? files : packages;
        group.putIfAbsent('$path ${m.group(3) ?? ''}', () => [...comments, text].join('\n'));
      }
      comments = [];
    }
    String block(Map<String, String> g) => (g.keys.toList()..sort()).map((k) => g[k]!).join('\n');
    final parts = [if (files.isNotEmpty) block(files), if (packages.isNotEmpty) block(packages)];
    final text = parts.isEmpty ? '' : '${parts.join('\n\n')}\n';
    final old = '${lines.sublist(start, last + 1).join('\n')}\n';
    if (old == text) return null;
    return _action('Organize imports', 'source.organizeImports', [_edit(Pos(start, 0), Pos(last + 1, 0), text)]);
  }

  // ------------------------------------------------------ extract a constant

  /// The type a value written at [line] takes, from the declaration or
  /// assignment it is in; otherwise from the value.
  String _valueType(int line, String value) {
    final text = lines[line];
    final decl = RegExp(r'^\s*(?:const\s+)?([\w.]+)\s+(\w+)\s*=').firstMatch(text);
    if (decl != null && (_intTypes.contains(decl.group(1)) || decl.group(1) == 'string')) return decl.group(1)!;
    final assign = RegExp(r'^\s*(\w+)\s*(?:[-+*/%&|^]|<<|>>)?=').firstMatch(text);
    if (assign != null) {
      final s = f.symbolAt(Pos(line, text.indexOf(assign.group(1)!)));
      final t = s?.type;
      if (t != null && (_intTypes.contains(t) || t == 'string') && !s!.isArray) return t;
    }
    final v = value.trim();
    if (v.startsWith('"')) return 'string';
    if (v.startsWith("'")) return 'u8';
    if (v.startsWith('-')) return 's32';
    return 'u32';
  }

  /// Whether [text] is a constant expression: literals, constants and
  /// operators.
  bool _isConstant(String text, int line, int col) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (RegExp(r'^"([^"\\]|\\.)*"$').hasMatch(t)) return true;
    if (!RegExp(r"""^[\w\s+\-*/%&|^~!<>=().'\\]+$""").hasMatch(t)) return false;
    for (final m in RegExp(r'[A-Za-z_][\w.]*').allMatches(text)) {
      if (RegExp(r'^0[xb]').hasMatch(text.substring(m.start > 0 ? m.start - 1 : 0))) continue;
      final word = m.group(0)!;
      if (RegExp(r'^\d').hasMatch(word)) continue;
      final s = f.symbolAt(Pos(line, col + m.end - 1));
      if (s == null || (s.kind != SymKind.constant && s.kind != SymKind.enumMember)) return false;
    }
    return true;
  }

  String _freeName() {
    var name = newConstantName;
    var n = 1;
    while (lines.any((l) => RegExp('\\b$name\\b').hasMatch(l))) {
      name = '$newConstantName${++n}';
    }
    return name;
  }

  List<Map<String, Object?>> _extractConstant(Pos start, Pos end) {
    if (start.line != end.line || start.character >= end.character || start.line >= lines.length) return const [];
    final line = lines[start.line];
    final value = line.substring(start.character, end.character.clamp(0, line.length));
    if (!_isConstant(value, start.line, start.character)) return const [];
    final type = _valueType(start.line, value);
    final name = _freeName();
    final indent = line.substring(0, line.length - line.trimLeft().length);
    final out = <Map<String, Object?>>[];
    Map<String, Object?> rename(int l, int c) => {
          'title': 'Rename the constant',
          'command': 'action.renameAt',
          'arguments': [uri, l, c],
        };
    final replace = _edit(start, end, name);
    // A constant of the function, just before the statement
    if (f.index.functionAt(f.path, start) != null) {
      out.add(_action('Extract to a constant', 'refactor.extract', [
        _edit(Pos(start.line, 0), Pos(start.line, 0), '${indent}const $type $name = ${value.trim()};\n'),
        replace,
      ], command: rename(start.line + 1, start.character)));
    }
    // A constant of the file, after the imports
    final at = _importLine();
    final decl = 'const $type $name = ${value.trim()};\n';
    final lead = at > 0 && lines[at - 1].trim().isNotEmpty ? '\n' : '';
    final trail = at < lines.length && lines[at].trim().isNotEmpty ? '\n' : '';
    final shift = '$lead$decl$trail'.split('\n').length - 1;
    out.add(_action('Extract to a file constant', 'refactor.extract', [
      _edit(Pos(at, 0), Pos(at, 0), '$lead$decl$trail'),
      replace,
    ], command: rename(start.line + (start.line >= at ? shift : 0), start.character)));
    return out;
  }

  // ------------------------------------------------------- inline a constant

  /// The start of the `Type.` or `alias.` before the name at [pos].
  int _chainStart(String line, int start) {
    var s = start;
    while (s > 1 && line[s - 1] == '.' && isWordChar(line[s - 2])) {
      s -= 2;
      while (s > 0 && isWordChar(line[s - 1])) {
        s--;
      }
    }
    return s;
  }

  List<Map<String, Object?>> _inlineConstant(Pos pos) {
    if (pos.line >= lines.length) return const [];
    final target = f.symbolAt(pos);
    final at = target?.at;
    if (target == null || target.kind != SymKind.constant || at == null || target.isArray) return const [];
    if (target.type == 'string' || rf.isReadOnly(at.path)) return const [];
    final declLines = rf.featuresFor(at.path)?.lines;
    if (declLines == null) return const [];
    final dm = RegExp('const\\s+[\\w.]+\\s+${target.name}\\s*=\\s*(.+?);\\s*(//.*)?\$').firstMatch(declLines[at.start.line]);
    if (dm == null) return const [];
    var value = dm.group(1)!.trim();
    if (!RegExp(r'^[\w.]+$').hasMatch(value)) value = '($value)';
    final out = <Map<String, Object?>>[];
    final (ws, we, _) = wordAt(lines[pos.line], pos.character);
    final onDecl = at.path == f.path && at.start.line == pos.line && at.start.character == ws;
    if (!onDecl) {
      out.add(_action("Inline '${target.name}' here", 'refactor.inline',
          [_edit(Pos(pos.line, _chainStart(lines[pos.line], ws)), Pos(pos.line, we), value)]));
    }
    // Every use, and the declaration removed
    final changes = <String, List<Map<String, Object?>>>{};
    for (final r in rf.references(target, includeDeclaration: false)) {
      final text = rf.featuresFor(r.path)?.lines;
      if (text == null) continue;
      (changes[pathToUri(r.path)] ??= []).add({
        'range': rangeJson(Pos(r.start.line, _chainStart(text[r.start.line], r.start.character)), r.end),
        'newText': value,
      });
    }
    (changes[pathToUri(at.path)] ??= [])
        .add({'range': rangeJson(Pos(at.start.line, 0), Pos(at.start.line + 1, 0)), 'newText': ''});
    out.add({
      'title': "Inline every use of '${target.name}' and remove it",
      'kind': 'refactor.inline',
      'edit': {'changes': changes},
    });
    return out;
  }
}
