// ------------------------------------------------------------------------------
// Hover, go to definition, completion and the document outline
// ------------------------------------------------------------------------------

import 'package:action/action.dart';

import 'documents.dart';
import 'symbols.dart';

const _keywords = [
  'asm', 'break', 'case', 'const', 'continue', 'default', 'else', 'enum',
  'fn', 'for', 'if', 'import', 'inline', 'ref', 'return', 'sizeof',
  'switch', 'task', 'type', 'verify', 'void', 'volatile', 'while',
];

const _builtinTypes = {
  'u8': '1 byte, unsigned: 0 to 255',
  's8': '1 byte, signed: -128 to 127',
  'u16': '2 bytes, unsigned: 0 to 65535',
  's16': '2 bytes, signed: -32768 to 32767',
  'u32': '4 bytes, unsigned: 0 to 4294967295',
  's32': '4 bytes, signed: -2147483648 to 2147483647',
  'bool': '1 byte: 0 (false) or 1 (true); other values are stored as 1',
  'string': 'null-terminated bytes: a fixed buffer `string s[N]`, or a heap string',
  'void': 'no value',
};

const _builtinFunctions = {
  'trap': ('trap(N)', 'Executes `TRAP N` (N is a constant from 0 to 15).'),
  'readfifo': ('u32 readfifo(CH)', 'Blocking read of a word from FIFO channel `CH` (a constant).'),
  'writefifo': ('writefifo(CH, value)', 'Writes `value` to FIFO channel `CH` (a constant).'),
  'tryreadfifo': (
    'u32 tryreadfifo(CH, x)',
    'Non-blocking read: if channel `CH` has data, stores it in `x` and gives 1; otherwise gives 0.'
  ),
  'sizeof': ('sizeof(T)', 'Size in bytes of a type, variable or expression, at compile time.'),
};

const _builtinMembers = {
  'len': 'Number of elements (heap or open array: from its header or the length passed in); for a string, the characters before the terminator.',
  'capacity': 'Capacity: elements of an array, or bytes of a string buffer.',
  'create': 'Allocates a zeroed value on the heap and gives a reference to it.',
  'createArray': 'Allocates a zeroed heap array of N elements: `T.createArray(N)`.',
  'destroy': 'Frees the value and sets the reference to 0.',
  'destroyArray': 'Frees the heap array and sets the reference to 0.',
  'resize': 'Resizes the heap array, keeping its contents: `a.resize(N)`.',
  'exists': '1 if the reference is not null, else 0.',
};

/// The part of an expression before the word at the cursor: names joined
/// by `.`, each with the number of `[...]` indexes after it.
class Chain {
  final List<(String, int)> parts;

  /// False when the expression before a `.` is something other than names
  /// and indexes (a call, say).
  final bool known;
  const Chain(this.parts, this.known);
}

/// The word at (or ending at) [character] on [line], and what precedes it.
(int, int, Chain) wordAt(String line, int character) {
  var start = character.clamp(0, line.length);
  while (start > 0 && isWordChar(line[start - 1])) {
    start--;
  }
  var end = character.clamp(0, line.length);
  while (end < line.length && isWordChar(line[end])) {
    end++;
  }
  final parts = <(String, int)>[];
  var known = true;
  var i = start - 1;
  while (i >= 0 && line[i] == '.') {
    var j = i - 1;
    var indexes = 0;
    while (j >= 0 && line[j] == ']') {
      var depth = 0;
      while (j >= 0) {
        if (line[j] == ']') depth++;
        if (line[j] == '[') depth--;
        j--;
        if (depth == 0) break;
      }
      indexes++;
    }
    final nameEnd = j + 1;
    while (j >= 0 && isWordChar(line[j])) {
      j--;
    }
    if (j + 1 == nameEnd) {
      known = false;
      break;
    }
    parts.insert(0, (line.substring(j + 1, nameEnd), indexes));
    i = j;
  }
  return (start, end, Chain(parts, known));
}

/// What a name or a `.` chain stands for, as far as types go.
class Val {
  final String type;
  final bool isArray;
  final bool isHeapRef;

  /// The chain named a type itself (`Point` in `Point.create()`).
  final bool isTypeName;
  const Val(this.type, {this.isArray = false, this.isHeapRef = false, this.isTypeName = false});
}

/// Answers editor questions about one file of a checked program.
class Features {
  final ProgramIndex index;
  final String path;
  final List<String> lines;

  /// Finds an imported file, for go to definition on an `import`.
  final String? Function(String target, String fromFile) resolveImport;

  Features(this.index, this.path, this.lines, this.resolveImport);

  String _clean(String t) {
    var r = t.startsWith('type ') ? t.substring(5) : t;
    final alias = index.globals[r];
    if (alias != null && alias.kind == SymKind.alias && alias.type != null) r = alias.type!;
    return r;
  }

  /// The declaration [name] refers to at [pos].
  Sym? lookup(String name, Pos pos) {
    final fn = index.functionAt(path, pos);
    if (fn != null) {
      Sym? found;
      for (final s in fn.$2) {
        if (s.name != name) continue;
        // Locals are function-scoped; prefer the declaration before the use
        if (found == null || (s.at != null && s.at!.start <= pos)) found = s;
      }
      if (found != null) return found;
    }
    final g = index.globals[name];
    if (g != null && g.kind != SymKind.method) return g;
    return null;
  }

  Val? _valOf(Sym s) {
    switch (s.kind) {
      case SymKind.local:
      case SymKind.parameter:
      case SymKind.global:
      case SymKind.constant:
      case SymKind.localConstant:
      case SymKind.field:
        final t = s.type;
        if (t == null) return null;
        return Val(_clean(t), isArray: s.isArray, isHeapRef: s.isHeapRef);
      case SymKind.type:
      case SymKind.alias:
        return Val(_clean(s.name), isTypeName: true);
      default:
        return null;
    }
  }

  /// The value a chain names, or null if it cannot be followed.
  Val? resolveChain(Chain chain, Pos pos) {
    if (!chain.known || chain.parts.isEmpty) return null;
    final (base, baseIdx) = chain.parts.first;
    Val? v;
    final s = lookup(base, pos);
    if (s != null) {
      v = _valOf(s);
    } else if (_builtinTypes.containsKey(base)) {
      v = Val(base, isTypeName: true);
    }
    if (v == null) return null;
    v = _index(v, baseIdx);
    for (final (name, idx) in chain.parts.skip(1)) {
      if (v == null || v.isTypeName) return null;
      if (v.isArray && (name == 'len' || name == 'capacity')) {
        v = const Val('u32');
      } else {
        final f = index.fieldOf(v.type, name);
        if (f == null) return null;
        v = _valOf(f);
      }
      if (v != null) v = _index(v, idx);
    }
    return v;
  }

  Val? _index(Val v, int count) {
    if (count == 0) return v;
    if (v.isArray) return Val(v.type);
    if (v.type == 'string') return const Val('u8');
    return null;
  }

  // ---------------------------------------------------------------- hover

  Map<String, Object?>? hover(Pos pos) {
    if (pos.line >= lines.length) return null;
    final line = lines[pos.line];
    final (start, end, chain) = wordAt(line, pos.character);
    if (start == end) return null;
    final word = line.substring(start, end);
    final text = _hoverText(word, chain, pos);
    if (text == null) return null;
    return {
      'contents': {'kind': 'markdown', 'value': text},
      'range': rangeJson(Pos(pos.line, start), Pos(pos.line, end)),
    };
  }

  String? _hoverText(String word, Chain chain, Pos pos) {
    if (chain.parts.isNotEmpty) {
      final base = resolveChain(chain, pos);
      if (base == null) {
        final b = _builtinMembers[word];
        return b == null ? null : _code('.$word') + b;
      }
      if (base.isTypeName) {
        final m = index.methodsOf(base.type)[word];
        if (m != null) return describe(m);
        final b = _builtinMembers[word];
        return b == null ? null : _code('${base.type}.$word') + b;
      }
      final f = base.isArray ? null : index.fieldOf(base.type, word);
      if (f != null) return describe(f);
      final m = base.isArray ? null : index.methodsOf(base.type)[word];
      if (m != null) return describe(m);
      final b = _builtinMembers[word];
      return b == null ? null : _code('.$word') + b;
    }
    final s = lookup(word, pos);
    if (s != null) return describe(s);
    final bt = _builtinTypes[word];
    if (bt != null) return _code(word) + bt;
    final bf = _builtinFunctions[word];
    if (bf != null) return _code(bf.$1) + bf.$2;
    if (word == 'true' || word == 'false') {
      return '${_code('const $word = ${word == 'true' ? 1 : 0}')}Built-in constant.';
    }
    return null;
  }

  String _code(String s) => '```action\n$s\n```\n';

  String _typeText(String t, bool isArray) => isArray ? '$t[]' : t;

  /// Markdown describing a declaration.
  String describe(Sym s) {
    final buf = StringBuffer();
    final info = index.info;
    switch (s.kind) {
      case SymKind.function:
      case SymKind.method:
      case SymKind.task:
      case SymKind.trapHandler:
      case SymKind.prototype:
        buf.write(_code(_signature(s)));
      case SymKind.type:
        buf.write(_code(_typeDecl(s)));
        final st = info?.types[s.name];
        if (st != null) buf.write('Size ${st.size} bytes, aligned to ${st.align}.\n');
      case SymKind.field:
        final decl = s.decl;
        var t = s.type ?? '?';
        if (decl is FieldDecl) {
          t = decl.isPtr && !decl.isArrayRef ? 'ref ${decl.type}' : decl.type;
        }
        final dims = s.isArray && decl is FieldDecl && decl.isArrayRef ? '[]' : '';
        buf.write(_code('$t ${s.name}$dims'));
        final fi = info?.types[s.container]?.fields[s.name];
        buf.write('Field of `${s.container}`');
        if (fi != null) {
          buf.write(', at offset ${fi.offset}');
          final sz = _fieldSize(fi);
          if (sz != null) buf.write(', $sz bytes');
        }
        buf.write('.\n');
      case SymKind.alias:
        buf.write(_code('type ${s.name} = ${s.type}'));
      case SymKind.functionType:
        final d = s.decl as FnTypeNode;
        buf.write(_code('type ${s.name} = fn(${d.paramTypes.join(', ')}) -> ${d.retType}'));
      case SymKind.enumType:
        final members = [
          for (final m in s.children) '    ${m.name} = ${info?.constants[m.name] ?? '?'},'
        ];
        buf.write(_code('enum ${s.name} {\n${members.join('\n')}\n}'));
      case SymKind.enumMember:
        buf.write(_code('${s.name} = ${_value(s.name)}'));
        buf.write('Member of enum `${s.container}`.\n');
      case SymKind.constant:
      case SymKind.localConstant:
        final t = info?.constType(s.name) ?? s.type ?? '';
        buf.write(_code('const $t ${s.name} = ${_value(s.name)}'));
      case SymKind.global:
      case SymKind.local:
      case SymKind.parameter:
        buf.write(_code(_varDecl(s)));
        buf.write(switch (s.kind) {
          SymKind.global => 'Global variable.\n',
          SymKind.parameter => 'Parameter of `${_display(s.container)}`.\n',
          _ => 'Local variable of `${_display(s.container)}`.\n',
        });
    }
    if (s.doc != null) buf.write('\n${s.doc}\n');
    return buf.toString();
  }

  String _display(String? fn) {
    if (fn == null) return '';
    final g = index.globals[fn];
    return g?.displayName ?? fn;
  }

  String _value(String name) {
    final v = index.info?.constants[name];
    if (v == null) return '?';
    final signedType = index.info?.constType(name);
    final shown = (signedType != null && signedType.startsWith('s') && v > 0x7FFFFFFF)
        ? v - 0x100000000
        : v;
    return shown > 9
        ? '$shown (0x${shown.toRadixString(16).toUpperCase()})'
        : '$shown';
  }

  int? _fieldSize(FieldInfo fi) {
    if (fi.isPtr) return 4;
    int elem;
    switch (fi.type) {
      case 'u8' || 's8' || 'bool' || 'string':
        elem = 1;
      case 'u16' || 's16':
        elem = 2;
      default:
        final st = index.info?.types[fi.type];
        elem = st?.size ?? 4;
    }
    final d = fi.dim;
    if (d is int) return elem * d;
    if (d is List<int>) return d.fold<int>(elem, (a, b) => a * b);
    return elem;
  }

  String _varDecl(Sym s) {
    final d = s.decl;
    if (d is VarDeclNode) {
      final dims = d.dimExprs.isNotEmpty
          ? (d.arrayDims != null ? d.arrayDims!.map((n) => '[$n]').join() : '[...]')
          : (d.isPtr ? '[]' : '');
      return '${d.isVolatile && d.boundAddr == null ? 'volatile ' : ''}${d.typeName} ${d.name}$dims'
          '${d.boundAddr != null ? ' @ 0x${d.boundAddr!.toRadixString(16).toUpperCase()}' : ''}';
    }
    return '${s.type ?? '?'} ${s.name}${s.isArray ? '[]' : ''}';
  }

  String _retText(Object t, bool isPtr) {
    if (t is List) {
      return '(${t.map((e) => e is (Object?, bool) ? '${e.$1}${e.$2 ? '[]' : ''}' : '$e').join(', ')})';
    }
    return isPtr ? '$t[]' : '$t';
  }

  String _signature(Sym s) {
    final f = s.decl as FuncDeclNode;
    final params = [
      for (final p in f.params)
        if (p.name != 'this') '${p.type} ${p.name}${p.isOpenArr ? '[]' : ''}'
    ].join(', ');
    if (f.isTask) return 'task ${s.name}($params)';
    if (f.trapExpr != null) {
      final n = f.trapExpr is IntLitNode ? '${(f.trapExpr as IntLitNode).val}' : 'N';
      return 'trap($n) ${s.name}()';
    }
    final prefix = [if (f.isAsm) 'asm', if (f.isInline) 'inline'].join(' ');
    return '${prefix.isEmpty ? '' : '$prefix '}${_retText(f.retType, f.retPtr)} ${s.displayName}($params)';
  }

  String _typeDecl(Sym s) {
    final info = index.info?.types[s.name];
    final rows = <String>[];
    for (final f in s.children) {
      final d = f.decl as FieldDecl;
      String text;
      if (d.isEmbedded) {
        text = '${d.type};';
      } else if (d.isArrayRef) {
        text = '${d.type} ${d.name}[];';
      } else if (d.isPtr) {
        text = 'ref ${d.type} ${d.name};';
      } else {
        final dim = info?.fields[d.name]?.dim;
        final dims = dim is int
            ? '[$dim]'
            : dim is List<int>
                ? dim.map((n) => '[$n]').join()
                : '';
        text = '${d.type} ${d.name}$dims;';
      }
      final fi = info?.fields[d.name];
      final sz = fi == null ? null : _fieldSize(fi);
      final comment = fi == null ? '' : '  // offset ${fi.offset}${sz != null ? ', $sz bytes' : ''}';
      rows.add('    ${text.padRight(24)}$comment');
    }
    return 'type ${s.name} {\n${rows.join('\n')}\n}';
  }

  // ----------------------------------------------------------- definition

  Map<String, Object?>? definition(Pos pos) {
    if (pos.line >= lines.length) return null;
    final line = lines[pos.line];
    // import "file.act";
    final imp = RegExp(r'^\s*import\s+"([^"]*)"').firstMatch(line);
    if (imp != null && pos.character >= imp.start && pos.character <= imp.end) {
      final target = resolveImport(imp.group(1)!, path);
      if (target == null) return null;
      return SrcLoc(target, const Pos(0, 0), const Pos(0, 0)).toLocationJson();
    }
    final (start, end, chain) = wordAt(line, pos.character);
    if (start == end) return null;
    final word = line.substring(start, end);
    Sym? s;
    if (chain.parts.isEmpty) {
      s = lookup(word, pos);
    } else {
      final base = resolveChain(chain, pos);
      if (base != null) {
        s = base.isTypeName
            ? index.methodsOf(base.type)[word]
            : (index.fieldOf(base.type, word) ?? index.methodsOf(base.type)[word]);
      }
    }
    return s?.at?.toLocationJson();
  }

  // ----------------------------------------------------------- completion

  List<Map<String, Object?>> completion(Pos pos) {
    if (pos.line >= lines.length) return const [];
    final line = lines[pos.line];
    final (_, _, chain) = wordAt(line, pos.character);
    final items = <Map<String, Object?>>[];
    void add(String label, int kind, [String? detail, String? doc]) {
      items.add({
        'label': label,
        'kind': kind,
        if (detail != null) 'detail': detail,
        if (doc != null) 'documentation': {'kind': 'markdown', 'value': doc},
      });
    }

    if (chain.parts.isNotEmpty) {
      final base = resolveChain(chain, pos);
      if (base == null) return const [];
      if (base.isTypeName) {
        for (final m in index.methodsOf(base.type).values) {
          add(m.name, _ciMethod, _signature(m), m.doc);
        }
        if (index.info?.types.containsKey(base.type) == true) {
          add('create', _ciMethod, '${base.type}.create()', _builtinMembers['create']);
        }
        add('createArray', _ciMethod, '${base.type}.createArray(N)', _builtinMembers['createArray']);
        return items;
      }
      if (base.isArray || base.type == 'string') {
        for (final m in ['len', 'capacity']) {
          add(m, _ciProperty, 'u32', _builtinMembers[m]);
        }
        if (base.isHeapRef || base.type == 'string') {
          add('exists', _ciMethod, 'exists()', _builtinMembers['exists']);
          if (base.isArray) {
            add('resize', _ciMethod, 'resize(N)', _builtinMembers['resize']);
            add('destroyArray', _ciMethod, 'destroyArray()', _builtinMembers['destroyArray']);
          } else {
            add('destroy', _ciMethod, 'destroy()', _builtinMembers['destroy']);
          }
        }
        return items;
      }
      final st = index.globals[base.type];
      if (st != null && st.kind == SymKind.type) {
        final seen = <String>{};
        void fieldsOf(Sym t) {
          for (final f in t.children) {
            final d = f.decl as FieldDecl;
            if (d.isEmbedded) {
              final inner = index.globals[d.type];
              if (inner != null) fieldsOf(inner);
              continue;
            }
            if (seen.add(f.name)) add(f.name, _ciField, _fieldDetail(d), f.doc);
          }
        }

        fieldsOf(st);
        for (final m in index.methodsOf(base.type).values) {
          add(m.name, _ciMethod, _signature(m), m.doc);
        }
        add('exists', _ciMethod, 'exists()', _builtinMembers['exists']);
        add('destroy', _ciMethod, 'destroy()', _builtinMembers['destroy']);
      }
      return items;
    }

    final fn = index.functionAt(path, pos);
    if (fn != null) {
      final seen = <String>{};
      for (final s in fn.$2) {
        if (!seen.add(s.name)) continue;
        add(s.name, s.kind == SymKind.localConstant ? _ciConstant : _ciVariable,
            s.kind == SymKind.localConstant ? 'const' : _typeText(s.type ?? '', s.isArray));
      }
    }
    for (final s in index.globals.values) {
      switch (s.kind) {
        case SymKind.function || SymKind.task || SymKind.prototype:
          add(s.name, _ciFunction, _signature(s), s.doc);
        case SymKind.type:
          add(s.name, _ciStruct, 'type', s.doc);
        case SymKind.alias:
          add(s.name, _ciTypeParameter, 'type ${s.name} = ${s.type}', s.doc);
        case SymKind.functionType:
          add(s.name, _ciInterface, 'function type', s.doc);
        case SymKind.enumMember:
          add(s.name, _ciEnumMember, '${s.container} = ${_value(s.name)}', s.doc);
        case SymKind.constant:
          add(s.name, _ciConstant, 'const ${s.type} = ${_value(s.name)}', s.doc);
        case SymKind.global:
          add(s.name, _ciVariable, _typeText(s.type ?? '', s.isArray), s.doc);
        default:
          break;
      }
    }
    for (final k in _keywords) {
      add(k, _ciKeyword);
    }
    for (final e in _builtinTypes.entries) {
      add(e.key, _ciKeyword, e.value);
    }
    for (final e in _builtinFunctions.entries) {
      add(e.key, _ciFunction, e.value.$1, e.value.$2);
    }
    add('true', _ciConstant, '1');
    add('false', _ciConstant, '0');
    return items;
  }

  String _fieldDetail(FieldDecl d) {
    if (d.isArrayRef) return '${d.type}[]';
    if (d.isPtr) return 'ref ${d.type}';
    return d.dimExprs.isNotEmpty ? '${d.type}[...]' : d.type;
  }

  // -------------------------------------------------------------- outline

  List<Map<String, Object?>> documentSymbols() {
    final decls = index.byFile[path] ?? const <Sym>[];
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < decls.length; i++) {
      final s = decls[i];
      final start = s.declStart!.start;
      // A declaration runs up to the next one in the file
      final nextLine = i + 1 < decls.length ? decls[i + 1].declStart!.start.line : lines.length;
      var endLine = nextLine - 1;
      while (endLine > start.line && endLine < lines.length && lines[endLine].trim().isEmpty) {
        endLine--;
      }
      if (endLine < start.line) endLine = start.line;
      final end = Pos(endLine, endLine < lines.length ? lines[endLine].length : 0);
      out.add(_docSymbol(s, start, end));
    }
    return out;
  }

  Map<String, Object?> _docSymbol(Sym s, Pos start, Pos end) {
    var sel = s.at ?? SrcLoc(path, start, start);
    if (sel.start < start || end < sel.end) sel = SrcLoc(path, start, start);
    final children = <Map<String, Object?>>[];
    if (s.kind == SymKind.type || s.kind == SymKind.enumType) {
      for (final c in s.children) {
        final cs = c.at?.start ?? start;
        final ce = c.at?.end ?? start;
        if (cs < start || end < ce) continue;
        children.add({
          'name': c.name,
          'kind': c.kind == SymKind.field ? _skField : _skEnumMember,
          if (c.type != null) 'detail': c.type,
          'range': rangeJson(cs, ce),
          'selectionRange': rangeJson(cs, ce),
        });
      }
    }
    return {
      'name': s.displayName,
      'kind': _symbolKind(s.kind),
      if (_detail(s) != null) 'detail': _detail(s),
      'range': rangeJson(start, end),
      'selectionRange': rangeJson(sel.start, sel.end),
      if (children.isNotEmpty) 'children': children,
    };
  }

  String? _detail(Sym s) => switch (s.kind) {
        SymKind.function ||
        SymKind.method ||
        SymKind.task ||
        SymKind.trapHandler ||
        SymKind.prototype =>
          _signature(s),
        SymKind.global || SymKind.constant => s.type,
        SymKind.alias => '= ${s.type}',
        _ => null,
      };

  int _symbolKind(SymKind k) => switch (k) {
        SymKind.function || SymKind.task || SymKind.trapHandler || SymKind.prototype => 12,
        SymKind.method => 6,
        SymKind.type => 23,
        SymKind.field => _skField,
        SymKind.alias => 26,
        SymKind.functionType => 11,
        SymKind.enumType => 10,
        SymKind.enumMember => _skEnumMember,
        SymKind.constant || SymKind.localConstant => 14,
        _ => 13,
      };
}

// LSP SymbolKind and CompletionItemKind values
const _skField = 8;
const _skEnumMember = 22;
const _ciMethod = 2;
const _ciFunction = 3;
const _ciField = 5;
const _ciVariable = 6;
const _ciInterface = 8;
const _ciProperty = 10;
const _ciKeyword = 14;
const _ciEnumMember = 20;
const _ciConstant = 21;
const _ciStruct = 22;
const _ciTypeParameter = 25;
