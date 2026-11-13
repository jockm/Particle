// ------------------------------------------------------------------------------
// Declarations in a checked program
// ------------------------------------------------------------------------------
//
// Built from the syntax tree the compiler produced and what the checker
// worked out (type layouts, constant values, function signatures). The
// compiler records where each declaration starts; the position of its name
// is found by looking for the name from there in the source text.

import 'package:action/action.dart';

import 'documents.dart';

enum SymKind {
  function,
  method,
  task,
  trapHandler,
  prototype,
  type,
  field,
  alias,
  functionType,
  enumType,
  enumMember,
  global,
  constant,
  local,
  localConstant,
  parameter,
}

/// A source location in LSP terms: [line] and [character] from 0.
class SrcLoc {
  final String path;
  final Pos start;
  final Pos end;
  const SrcLoc(this.path, this.start, this.end);

  Map<String, Object?> toLocationJson() =>
      {'uri': pathToUri(path), 'range': rangeJson(start, end)};
}

/// One declared name.
class Sym {
  /// The name as written: `move` for the method `Point.move`.
  final String name;
  final SymKind kind;

  /// Where the name is written, or null if unknown.
  final SrcLoc? at;

  /// Where the declaration starts (its first token), or null.
  final SrcLoc? declStart;

  /// The enclosing type (fields, methods), enum (members) or function
  /// (locals, parameters).
  final String? container;

  /// The value's type, for variables, parameters, fields and constants.
  final String? type;

  /// True for arrays: fixed (`T a[N]`), heap (`T a[]`) and open (`T a[]`
  /// parameters).
  final bool isArray;

  /// True for references that may be null: heap arrays and `ref` fields.
  final bool isHeapRef;

  /// The declaration in the syntax tree.
  final Object? decl;

  /// `// comments` written just above the declaration.
  final String? doc;

  final List<Sym> children = [];

  /// For a local: the end of the block that declares it (null when it is
  /// the function's outermost block).
  Pos? visibleUntil;

  Sym(this.name, this.kind,
      {this.at,
      this.declStart,
      this.container,
      this.type,
      this.isArray = false,
      this.isHeapRef = false,
      this.decl,
      this.doc});

  /// The name shown to the user: `Point.move` for a method.
  String get displayName =>
      kind == SymKind.method && container != null ? '$container.$name' : name;
}

final _locRe = RegExp(r'^(.*):(\d+):(\d+)$');

/// Splits a compiler location (`file:line:col`, line from 1) into a path
/// and an LSP position.
(String, Pos)? parseLoc(String? loc) {
  if (loc == null) return null;
  final m = _locRe.firstMatch(loc);
  if (m == null) return null;
  return (m.group(1)!, Pos(int.parse(m.group(2)!) - 1, int.parse(m.group(3)!)));
}

/// Names declared in a program, with where they are and what they mean.
class ProgramIndex {
  final ProgramNode program;
  final ProgramInfo? info;
  final SourceTexts texts;

  /// Top-level declarations by file, in source order.
  final Map<String, List<Sym>> byFile = {};

  /// Top-level names: functions (by their generated name, `Point_move` for
  /// methods), types, aliases, function types, enum members, globals and
  /// constants.
  final Map<String, Sym> globals = {};

  /// Function definitions with bodies, with their locals and parameters.
  final List<(Sym, List<Sym>)> bodies = [];

  /// Every file in the program.
  final Set<String> files = {};

  ProgramIndex(this.program, this.info, this.texts) {
    for (final d in program.decls) {
      final start = parseLoc(d.loc);
      if (start != null) files.add(start.$1);
      final syms = _declare(d);
      for (final s in syms) {
        final path = s.declStart?.path;
        if (path != null) (byFile[path] ??= []).add(s);
      }
    }
  }

  /// The function whose body contains [pos] in [path], with its locals and
  /// parameters.
  (Sym, List<Sym>)? functionAt(String path, Pos pos) {
    (Sym, List<Sym>)? best;
    for (final b in bodies) {
      final s = b.$1.declStart;
      if (s == null || s.path != path || pos < s.start) continue;
      if (best == null || best.$1.declStart!.start < s.start) best = b;
    }
    if (best == null) return null;
    // Past the start of a later top-level declaration in this file: outside
    for (final d in byFile[path] ?? const <Sym>[]) {
      final s = d.declStart!;
      if (best.$1.declStart!.start < s.start && s.start <= pos) return null;
    }
    return best;
  }

  /// The methods of type [typeName] (including those of embedded types),
  /// by method name.
  Map<String, Sym> methodsOf(String typeName) {
    final out = <String, Sym>{};
    void add(String t, Set<String> seen) {
      if (!seen.add(t)) return;
      for (final s in globals.values) {
        if (s.kind == SymKind.method && s.container == t) out.putIfAbsent(s.name, () => s);
      }
      for (final (embedded, _) in info?.types[t]?.embedded ?? const <(String, int)>[]) {
        add(embedded, seen);
      }
    }

    add(typeName, {});
    return out;
  }

  /// The declaration of field [field] of [typeName] (also through embedded
  /// types), or null.
  Sym? fieldOf(String typeName, String field) {
    final seen = <String>{};
    Sym? find(String t) {
      if (!seen.add(t)) return null;
      final ts = globals[t];
      if (ts == null || ts.kind != SymKind.type) return null;
      for (final f in ts.children) {
        if (f.name == field) return f;
      }
      for (final (embedded, _) in info?.types[t]?.embedded ?? const <(String, int)>[]) {
        final r = find(embedded);
        if (r != null) return r;
      }
      return null;
    }

    return find(typeName);
  }

  // --------------------------------------------------------------------------

  List<Sym> _declare(AstNode d) {
    if (d is FuncDeclNode) return _function(d);
    if (d is TypeDefNode) return [_type(d)];
    if (d is TypeAliasNode) {
      return [_sym(d.name, SymKind.alias, d.loc, decl: d, type: d.target)];
    }
    if (d is FnTypeNode) return [_sym(d.name, SymKind.functionType, d.loc, decl: d)];
    if (d is EnumDeclNode) return [_enum(d)];
    if (d is VarDeclNode) {
      final s = _variable(d, d.isConst ? SymKind.constant : SymKind.global, null);
      globals[d.name] = s;
      return [s];
    }
    return const [];
  }

  Sym _sym(String name, SymKind kind, String? loc,
      {String? container,
      String? type,
      bool isArray = false,
      bool isHeapRef = false,
      Object? decl,
      String? searchFor}) {
    // Block-scoped locals carry internal names; show the source's
    name = sourceName(name);
    final start = parseLoc(loc);
    SrcLoc? at;
    SrcLoc? declStart;
    String? doc;
    if (start != null) {
      final (path, pos) = start;
      declStart = SrcLoc(path, pos, pos);
      at = _findName(path, pos, searchFor ?? name);
      doc = _docComment(path, pos.line);
    }
    final s = Sym(name, kind,
        at: at,
        declStart: declStart,
        container: container,
        type: type,
        isArray: isArray,
        isHeapRef: isHeapRef,
        decl: decl,
        doc: doc);
    if (const {
      SymKind.type,
      SymKind.alias,
      SymKind.functionType,
      SymKind.enumMember,
    }.contains(kind)) {
      globals[name] = s;
    }
    return s;
  }

  List<Sym> _function(FuncDeclNode f) {
    final isMethod = f.params.isNotEmpty && f.params.first.name == 'this';
    String name = f.name;
    String? container;
    if (isMethod) {
      final t = f.params.first.type;
      container = t;
      if (name.startsWith('${t}_')) name = name.substring(t.length + 1);
    }
    final kind = f.body == null
        ? SymKind.prototype
        : f.isTask
            ? SymKind.task
            : f.trapExpr != null
                ? SymKind.trapHandler
                : isMethod
                    ? SymKind.method
                    : SymKind.function;
    final s = _sym(name, kind, f.loc, container: container, decl: f);
    // A prototype does not hide the definition
    final prev = globals[f.name];
    if (prev == null || prev.kind == SymKind.prototype) {
      globals[f.name] = s;
    }
    if (f.body != null) {
      final locals = <Sym>[];
      for (final p in f.params) {
        if (p.name == 'this') continue;
        locals.add(_sym(p.name, SymKind.parameter, p.loc ?? f.loc,
            container: f.name,
            type: p.type,
            isArray: p.isOpenArr || p.isPtr,
            decl: p));
      }
      for (final s in f.body?.stmts ?? const <AstNode>[]) {
        _collectLocals(s, f.name, locals, null);
      }
      bodies.add((s, locals));
      s.children.addAll(locals);
    }
    return [s];
  }

  /// The locals [n] declares; [until] is where the block around it ends.
  void _collectLocals(AstNode? n, String fn, List<Sym> out, Pos? until) {
    if (n == null) return;
    Pos? endOf(AstNode b) {
      if (b is! BlockNode) return until;
      final e = parseLoc(b.endLoc);
      return e?.$2 ?? until;
    }

    void add(Sym s) => out.add(s..visibleUntil = until);
    if (n is BlockNode) {
      final end = endOf(n);
      for (final s in n.stmts) {
        _collectLocals(s, fn, out, end);
      }
    } else if (n is IfNode) {
      _collectLocals(n.thenBody, fn, out, endOf(n.thenBody));
      if (n.elseBody != null) _collectLocals(n.elseBody, fn, out, endOf(n.elseBody!));
    } else if (n is WhileNode) {
      _collectLocals(n.body, fn, out, endOf(n.body));
    } else if (n is ForRangeNode) {
      final end = endOf(n.body);
      out.add(_sym(n.varName, SymKind.local, n.loc,
          container: fn, type: n.varType, decl: n)..visibleUntil = end);
      _collectLocals(n.body, fn, out, end);
    } else if (n is SwitchNode) {
      _collectLocals(n.body, fn, out, endOf(n.body));
    } else if (n is VarDeclNode) {
      add(_variable(n, n.isConst ? SymKind.localConstant : SymKind.local, fn));
    } else if (n is TupleAssignNode) {
      for (final t in n.targets) {
        if (t.isWildcard || t.typeName == null || t.name == null) continue;
        add(_sym(t.name!, SymKind.local, n.loc,
            container: fn, type: t.typeName, isArray: t.isPtr, decl: n));
      }
    }
  }

  Sym _variable(VarDeclNode d, SymKind kind, String? fn) {
    final t = d.typeName;
    return _sym(d.name, kind, d.loc,
        container: fn,
        type: t is String ? t : t.toString(),
        isArray: d.isPtr || d.dimExprs.isNotEmpty,
        isHeapRef: d.isPtr,
        decl: d);
  }

  Sym _type(TypeDefNode d) {
    final s = _sym(d.name, SymKind.type, d.loc, decl: d);
    for (final f in d.fields) {
      final fs = _sym(f.name, SymKind.field, f.loc ?? d.loc,
          container: d.name,
          type: f.type,
          isArray: f.isArrayRef || f.dimExprs.isNotEmpty,
          isHeapRef: f.isPtr,
          decl: f);
      s.children.add(fs);
    }
    return s;
  }

  Sym _enum(EnumDeclNode d) {
    final s = _sym(d.name, SymKind.enumType, d.loc, decl: d);
    for (var i = 0; i < d.members.length; i++) {
      final (m, _) = d.members[i];
      final loc = i < d.memberLocs.length ? d.memberLocs[i] : d.loc;
      s.children.add(_sym(m, SymKind.enumMember, loc, container: d.name, decl: d));
    }
    return s;
  }

  /// The first whole-word occurrence of [name] at or after [from] in
  /// [path], within a few lines.
  SrcLoc? _findName(String path, Pos from, String name) {
    final lines = texts.lines(path);
    if (lines == null) return null;
    final re = RegExp('(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])');
    for (var l = from.line; l < lines.length && l < from.line + 6; l++) {
      final line = lines[l];
      final startCol = l == from.line ? from.character.clamp(0, line.length) : 0;
      final m = re.firstMatch(line.substring(startCol));
      if (m != null) {
        final c = startCol + m.start;
        return SrcLoc(path, Pos(l, c), Pos(l, c + name.length));
      }
    }
    return SrcLoc(path, from, from);
  }

  /// The `//` comment lines directly above [line], joined.
  String? _docComment(String path, int line) {
    final lines = texts.lines(path);
    if (lines == null) return null;
    final out = <String>[];
    for (var l = line - 1; l >= 0; l--) {
      final t = lines[l].trim();
      if (!t.startsWith('//')) break;
      out.insert(0, t.substring(2).trim());
    }
    return out.isEmpty ? null : out.join('\n');
  }
}
