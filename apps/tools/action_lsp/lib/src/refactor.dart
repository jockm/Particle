// ------------------------------------------------------------------------------
// Find all references and rename
// ------------------------------------------------------------------------------
//
// The references of a declaration are the words in the program's files that
// go to it (as go to definition goes), and the places it is declared. All
// the versions of an overloaded function are one name, and so are a
// prototype and its definition. Rename replaces every reference; it does
// not change files of fetched modules (the cache or vendor/).

import 'package:action/action.dart';

import 'documents.dart';
import 'features.dart';
import 'symbols.dart';

const actionKeywords = {
  'asm', 'bool', 'break', 'case', 'const', 'continue', 'default', 'else', 'enum', 'extern', 'f32',
  'f64', 'false', 'fast', 'fn', 'for', 'if', 'import', 'inline', 'package', 'pub', 'ref', 'return',
  's8', 's16', 's32', 's64', 'sizeof', 'static', 'string', 'switch', 'true', 'type', 'u8', 'u16',
  'u32', 'u64', 'verify', 'void', 'volatile', 'while', 'this',
};

/// The identifiers of [lines] outside comments, strings and character
/// literals: (line, start, end).
List<(int, int, int)> identifiersIn(List<String> lines) {
  final out = <(int, int, int)>[];
  var inBlock = false;
  for (var l = 0; l < lines.length; l++) {
    final s = lines[l];
    var i = 0;
    while (i < s.length) {
      if (inBlock) {
        final e = s.indexOf('*/', i);
        if (e < 0) {
          i = s.length;
        } else {
          inBlock = false;
          i = e + 2;
        }
        continue;
      }
      final c = s[i];
      if (c == '/' && i + 1 < s.length && s[i + 1] == '/') break;
      if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
        inBlock = true;
        i += 2;
        continue;
      }
      if (c == '"' || c == "'") {
        i++;
        while (i < s.length && s[i] != c) {
          if (s[i] == '\\') i++;
          i++;
        }
        i++;
        continue;
      }
      if (isWordChar(c) && !RegExp(r'[0-9]').hasMatch(c)) {
        final start = i;
        while (i < s.length && isWordChar(s[i])) {
          i++;
        }
        out.add((l, start, i));
        continue;
      }
      if (RegExp(r'[0-9]').hasMatch(c)) {
        while (i < s.length && isWordChar(s[i])) {
          i++;
        }
        continue;
      }
      i++;
    }
  }
  return out;
}

class Refactor {
  final ProgramIndex index;

  /// The features of another file of the program, or null when its text
  /// cannot be read.
  final Features? Function(String path) featuresFor;

  /// Folders whose files are not the user's to change (the module cache,
  /// vendor/).
  final bool Function(String path) isReadOnly;

  Refactor(this.index, this.featuresFor, this.isReadOnly);

  static const _functionKinds = {SymKind.function, SymKind.prototype, SymKind.task, SymKind.method};

  /// Whether [a] and [b] are one name: the same declaration, the versions
  /// of an overloaded function, or a prototype and its definition.
  bool same(Sym a, Sym b) {
    if (identical(a, b)) return true;
    if (!_functionKinds.contains(a.kind) || !_functionKinds.contains(b.kind)) return false;
    if ((a.kind == SymKind.method) != (b.kind == SymKind.method)) return false;
    return a.container == b.container && withoutOverload(a.key) == withoutOverload(b.key);
  }

  /// Every declared name of the program.
  Iterable<Sym> _allSyms() sync* {
    final seen = <Sym>{};
    Iterable<Sym> walk(Sym s) sync* {
      if (!seen.add(s)) return;
      yield s;
      for (final c in s.children) {
        yield* walk(c);
      }
    }

    for (final g in [...index.globals.values, ...index.otherDecls]) {
      yield* walk(g);
    }
    for (final (f, locals) in index.bodies) {
      yield* walk(f);
      for (final l in locals) {
        yield* walk(l);
      }
    }
  }

  /// The places [target] is declared or used, in the program's files.
  List<SrcLoc> references(Sym target, {bool includeDeclaration = true}) {
    final out = <String, SrcLoc>{};
    void add(SrcLoc l) => out['${l.path}:${l.start.line}:${l.start.character}'] = l;
    final decls = <String>{};
    for (final s in _allSyms()) {
      if (s.at == null || !same(s, target)) continue;
      decls.add('${s.at!.path}:${s.at!.start.line}:${s.at!.start.character}');
      if (includeDeclaration) add(s.at!);
    }
    for (final file in index.files) {
      final f = featuresFor(file);
      if (f == null) continue;
      for (final (l, start, end) in identifiersIn(f.lines)) {
        if (f.lines[l].substring(start, end) != target.name) continue;
        final s = f.symbolAt(Pos(l, start));
        if (s == null || !same(s, target)) continue;
        final loc = SrcLoc(file, Pos(l, start), Pos(l, end));
        if (!includeDeclaration && decls.contains('$file:$l:$start')) continue;
        add(loc);
      }
    }
    if (!includeDeclaration) {
      out.removeWhere((k, _) => decls.contains(k));
    }
    final list = out.values.toList()
      ..sort((a, b) {
        final c = a.path.compareTo(b.path);
        if (c != 0) return c;
        final d = a.start.line.compareTo(b.start.line);
        return d != 0 ? d : a.start.character.compareTo(b.start.character);
      });
    return list;
  }

  /// Why [target] cannot be renamed to [newName], or null.
  String? renameProblem(Sym target, String newName) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(newName) || newName == '_') {
      return "'$newName' is not a name: a letter or _, then letters, digits or _";
    }
    if (actionKeywords.contains(newName)) return "'$newName' is a keyword";
    final at = target.at;
    if (at == null) return "'${target.name}' is built in";
    if (isReadOnly(at.path)) {
      return "'${target.name}' is declared in a fetched module, which is not yours to change";
    }
    return null;
  }

  /// The edit that renames [target] to [newName]: `{uri: [TextEdit]}`.
  Map<String, Object?> rename(Sym target, String newName) {
    final changes = <String, List<Map<String, Object?>>>{};
    for (final r in references(target)) {
      if (isReadOnly(r.path)) continue;
      (changes[pathToUri(r.path)] ??= []).add({'range': rangeJson(r.start, r.end), 'newText': newName});
    }
    return {'changes': changes};
  }
}
