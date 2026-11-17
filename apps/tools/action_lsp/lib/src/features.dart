// ------------------------------------------------------------------------------
// Hover, go to definition, completion and the document outline
// ------------------------------------------------------------------------------

import 'package:action/action.dart';

import 'documents.dart';
import 'symbols.dart';

const _keywords = [
  'asm', 'break', 'case', 'const', 'continue', 'default', 'else', 'enum',
  'extern', 'fast', 'fn', 'for', 'if', 'import', 'inline', 'package', 'pub', 'ref', 'return',
  'sizeof', 'static', 'switch', 'task', 'type', 'verify', 'void', 'volatile', 'while',
];

const _builtinTypes = {
  'u8': '1 byte, unsigned: 0 to 255',
  's8': '1 byte, signed: -128 to 127',
  'u16': '2 bytes, unsigned: 0 to 65535',
  's16': '2 bytes, signed: -32768 to 32767',
  'u32': '4 bytes, unsigned: 0 to 4294967295',
  's32': '4 bytes, signed: -2147483648 to 2147483647',
  'u64': '8 bytes, unsigned: 0 to 18446744073709551615 (LLVM compiler only)',
  's64': '8 bytes, signed: -9223372036854775808 to 9223372036854775807 (LLVM compiler only)',
  'f32': '4 bytes, IEEE 754 single precision (LLVM compiler only)',
  'f64': '8 bytes, IEEE 754 double precision (LLVM compiler only)',
  'bool': '1 byte: 0 (false) or 1 (true); other values are stored as 1',
  'string': 'null-terminated bytes: a fixed buffer `string s[N]`, or a heap string',
  'void': 'no value',
};

const _builtinFunctions = {
  'trap': ('trap(N)', 'Executes `TRAP N` (N is a constant from 0 to 15).'),
  'readFifo': ('u32 readFifo(CH)', 'Blocking read of a word from FIFO channel `CH` (a constant).'),
  'writeFifo': ('writeFifo(CH, value)', 'Writes `value` to FIFO channel `CH` (a constant).'),
  'tryReadFifo': (
    'u32 tryReadFifo(CH, x)',
    'Non-blocking read: if channel `CH` has data, stores it in `x` and gives 1; otherwise gives 0.'
  ),
  'peek8': ('u8 peek8(addr)', 'Reads the byte at address `addr`, which may be computed at run time.'),
  'peek16': ('u16 peek16(addr)', 'Reads the halfword at address `addr`, which may be computed at run time.'),
  'peek32': ('u32 peek32(addr)', 'Reads the word at address `addr`, which may be computed at run time.'),
  'poke8': ('poke8(addr, value)', 'Writes the low byte of `value` at address `addr`.'),
  'poke16': ('poke16(addr, value)', 'Writes the low halfword of `value` at address `addr`.'),
  'poke32': ('poke32(addr, value)', 'Writes the word `value` at address `addr`.'),
  'callAddr': ('u32 callAddr(addr)', 'Calls the code at address `addr` and gives what it returns in R1.'),
  'sizeof': ('sizeof(T)', 'Size in bytes of a type, variable or expression, at compile time.'),
};

const _builtinMembers = {
  'len': 'Number of elements (heap or open array: from its header or the length passed in); for a string, the characters before the terminator.',
  'capacity': 'Capacity: elements of an array, or bytes of a string buffer.',
  'create': 'Allocates a zeroed value on the heap and gives a reference to it.',
  'createArray': 'Allocates a zeroed heap array of N elements: `T.createArray(N)`.',
  'destroy': 'Frees the value and leaves the reference empty.',
  'destroyArray': 'Frees the heap array and leaves the reference empty.',
  'resize': 'Resizes the heap array, keeping its contents: `a.resize(N)`.',
  'exists': '1 if the reference has a value, 0 if it is empty.',
  'sameAs': '1 if two references are to the same value: `a.sameAs(b)`.',
  'unset': 'Empties the reference (it must not still own its value): `r.unset()`.',
  'copyFrom': 'Copies the fields of another value of the same type (one without references): `a.copyFrom(b)`.',
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
        // Locals are block-scoped: skip those whose block has ended, and
        // prefer the nearest declaration before the use
        if (s.visibleUntil != null && s.visibleUntil! < pos) continue;
        if (found == null || (s.at != null && s.at!.start <= pos)) found = s;
      }
      if (found != null) return found;
    }
    final g = index.globals[index.keyIn(path, name)] ?? index.globals[name];
    if (g != null && g.kind != SymKind.method) return g;
    // A function with more than one version: the first
    final versions = index.overloadsOf(index.keyIn(path, name));
    return versions.isEmpty ? null : versions.first;
  }

  /// [describe] for [s] and, for an overloaded function, its other versions.
  String _describeAll(Sym s) {
    final versions = index.versionsOf(s);
    if (versions.length < 2) return describe(s);
    final buf = StringBuffer();
    for (final v in versions) {
      buf.write(_code(_signature(v)));
    }
    buf.write('${versions.length} versions.\n');
    final doc = versions.map((v) => v.doc).whereType<String>().firstOrNull;
    if (doc != null) buf.write('\n$doc\n');
    return buf.toString();
  }

  /// The package [name] stands for in this file, unless a local hides it.
  PackageInfo? _importAt(String name, Pos pos) {
    final pkg = index.importIn(path, name);
    if (pkg == null) return null;
    final fn = index.functionAt(path, pos);
    if (fn != null && fn.$2.any((s) => s.name == name)) return null;
    return pkg;
  }

  /// The declaration `alias.name` refers to, when it is pub.
  Sym? _qualified(PackageInfo pkg, String name) {
    if (!pkg.pubNames.contains(name)) return null;
    final g = index.globals[ProgramIndex.keyOf(pkg, name)];
    return g == null || g.kind == SymKind.method ? null : g;
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
    var (base, baseIdx) = chain.parts.first;
    var rest = chain.parts.skip(1);
    Val? v;
    // alias.name...: a declaration of an imported package
    final pkg = baseIdx == 0 && chain.parts.length > 1 ? _importAt(base, pos) : null;
    Sym? s;
    if (pkg != null) {
      (base, baseIdx) = chain.parts[1];
      rest = chain.parts.skip(2);
      s = _qualified(pkg, base);
      if (s == null) return null;
    } else {
      s = lookup(base, pos);
    }
    if (s != null) {
      v = _valOf(s);
    } else if (base == 'this' && pkg == null) {
      // In a method, a value of the method's type
      final fn = index.functionAt(path, pos)?.$1;
      if (fn != null && fn.kind == SymKind.method && fn.container != null) {
        v = Val(_clean(fn.container!), isArray: fn.container == 'string');
      }
    } else if (_builtinTypes.containsKey(base)) {
      v = Val(base, isTypeName: true);
    }
    if (v == null) return null;
    v = _index(v, baseIdx);
    for (final (name, idx) in rest) {
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
      'contents': {'kind': 'markdown', 'value': sourceName(text)},
      'range': rangeJson(Pos(pos.line, start), Pos(pos.line, end)),
    };
  }

  String? _hoverText(String word, Chain chain, Pos pos) {
    final pkg = _packageBefore(chain, pos);
    if (pkg != null) {
      final s = _qualified(pkg, word);
      return s == null ? null : describe(s);
    }
    if (chain.parts.isNotEmpty) {
      final base = resolveChain(chain, pos);
      if (base == null) {
        final b = _builtinMembers[word];
        return b == null ? null : _code('.$word') + b;
      }
      if (base.isTypeName) {
        final st = index.staticsOf(base.type)[word];
        if (st != null) return _describeAll(st.first);
        final m = index.methodsOf(base.type)[word];
        if (m != null) return _describeAll(m);
        final b = _builtinMembers[word];
        return b == null ? null : _code('${base.type}.$word') + b;
      }
      final f = base.isArray ? null : index.fieldOf(base.type, word);
      if (f != null) return describe(f);
      final m = base.isArray && base.type != 'string' ? null : index.methodsOf(base.type)[word];
      if (m != null) return _describeAll(m);
      final b = _builtinMembers[word];
      return b == null ? null : _code('.$word') + b;
    }
    final s = lookup(word, pos);
    if (s != null) return _describeAll(s);
    final imported = _importAt(word, pos);
    if (imported != null) {
      return '${_code('import "${imported.path}"')}Package `${imported.name}`.\n';
    }
    final bt = _builtinTypes[word];
    if (bt != null) return _code(word) + bt;
    final bf = _builtinFunctions[word];
    if (bf != null) return _code(bf.$1) + bf.$2;
    if (word == 'true' || word == 'false') {
      return '${_code('const $word = ${word == 'true' ? 1 : 0}')}Built-in constant.';
    }
    return null;
  }

  /// The package of `alias.` just before the word, when that is the whole
  /// chain.
  PackageInfo? _packageBefore(Chain chain, Pos pos) =>
      chain.known && chain.parts.length == 1 && chain.parts.first.$2 == 0
          ? _importAt(chain.parts.first.$1, pos)
          : null;

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
        final st = info?.types[s.key];
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
          for (final m in s.children) '    ${m.name} = ${info?.constants[m.key] ?? '?'},'
        ];
        buf.write(_code('enum ${s.name} {\n${members.join('\n')}\n}'));
      case SymKind.enumMember:
        buf.write(_code('${s.name} = ${_value(s.key)}'));
        buf.write('Member of enum `${s.container}`.\n');
      case SymKind.constant:
      case SymKind.localConstant:
        final t = info?.constType(s.key) ?? s.type ?? '';
        buf.write(_code('const $t ${s.name} = ${_value(s.key)}'));
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
    if (s.key.contains(packageMark)) {
      final pkg = index.program.packages[s.key.substring(0, s.key.indexOf(packageMark))];
      if (pkg != null) buf.write('In package `${pkg.name}` (${pkg.path}).\n');
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
      return '${d.isFast ? 'fast ' : ''}${d.isVolatile && d.boundAddr == null ? 'volatile ' : ''}${d.typeName} ${s.name}$dims'
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
    final info = index.info?.types[s.key];
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
      final pkg = index.program.packages.values.where((p) => p.path == imp.group(1)).firstOrNull;
      if (pkg != null) {
        final first = (index.files.where((f) => f.startsWith('${pkg.folder}/')).toList()..sort()).firstOrNull;
        return first == null ? null : SrcLoc(first, const Pos(0, 0), const Pos(0, 0)).toLocationJson();
      }
      final target = resolveImport(imp.group(1)!, path);
      if (target == null) return null;
      return SrcLoc(target, const Pos(0, 0), const Pos(0, 0)).toLocationJson();
    }
    return symbolAt(pos)?.at?.toLocationJson();
  }

  /// The declaration the word at [pos] refers to, or null.
  Sym? symbolAt(Pos pos) {
    if (pos.line >= lines.length) return null;
    final line = lines[pos.line];
    final (start, end, chain) = wordAt(line, pos.character);
    if (start == end) return null;
    final word = line.substring(start, end);
    Sym? s;
    final pkg = _packageBefore(chain, pos);
    if (pkg != null) {
      s = _qualified(pkg, word);
    } else if (chain.parts.isEmpty) {
      s = lookup(word, pos);
    } else {
      final base = resolveChain(chain, pos);
      if (base != null) {
        s = base.isTypeName
            ? (index.staticsOf(base.type)[word]?.first ?? index.methodsOf(base.type)[word])
            : base.type == 'string'
                ? index.methodsOf('string')[word]
                : (index.fieldOf(base.type, word) ?? index.methodsOf(base.type)[word]);
      }
    }
    return s ?? index.declaredAt(path, Pos(pos.line, start));
  }

  // ------------------------------------------------------- signature help

  /// The signatures of the function being called at [pos]: every version
  /// of an overloaded one, with the version the compiler chose (or the
  /// first that takes this many arguments) active.
  Map<String, Object?>? signatureHelp(Pos pos) {
    if (pos.line >= lines.length) return null;
    final line = lines[pos.line];
    // The unclosed '(' before the cursor, and the argument it is in
    var depth = 0, commas = 0, open = -1;
    for (var i = pos.character.clamp(0, line.length) - 1; i >= 0; i--) {
      final c = line[i];
      if (c == ')' || c == ']') depth++;
      if (c == '(' || c == '[') {
        if (depth == 0) {
          if (c == '(') open = i;
          break;
        }
        depth--;
      }
      if (c == ',' && depth == 0) commas++;
    }
    if (open <= 0) return null;
    var nameEnd = open;
    while (nameEnd > 0 && line[nameEnd - 1] == ' ') {
      nameEnd--;
    }
    if (nameEnd == 0 || !isWordChar(line[nameEnd - 1])) return null;
    final s = symbolAt(Pos(pos.line, nameEnd - 1));
    if (s == null || !const {SymKind.function, SymKind.prototype, SymKind.method, SymKind.task}.contains(s.kind)) {
      return null;
    }
    final versions = s.key == withoutOverload(s.key) ? [s] : index.versionsOf(s);
    // The compiler's choice for this call, recorded by place
    var active = -1;
    final (wordStart, _, _) = wordAt(line, nameEnd - 1);
    var chainStart = wordStart;
    while (chainStart > 1 && line[chainStart - 1] == '.' && isWordChar(line[chainStart - 2])) {
      chainStart -= 2;
      while (chainStart > 0 && isWordChar(line[chainStart - 1])) {
        chainStart--;
      }
    }
    for (final e in index.program.callChoices.entries) {
      final loc = parseLoc(e.key);
      if (loc == null || loc.$1 != path || loc.$2.line != pos.line) continue;
      if (loc.$2.character < chainStart || loc.$2.character > open) continue;
      active = versions.indexWhere((v) => v.key == e.value || e.value.endsWith('.${v.key}'));
    }
    if (active < 0) {
      active = versions.indexWhere((v) => _paramsOf(v).length > commas);
      if (active < 0) active = 0;
    }
    return {
      'signatures': [
        for (final v in versions)
          {
            'label': _signature(v),
            'parameters': [
              for (final p in _paramRanges(_signature(v))) {'label': p}
            ],
            if (v.doc != null) 'documentation': {'kind': 'markdown', 'value': v.doc},
          }
      ],
      'activeSignature': active,
      'activeParameter': commas,
    };
  }

  List<Param> _paramsOf(Sym s) {
    final d = s.decl;
    if (d is! FuncDeclNode) return const [];
    return [for (final p in d.params) if (p.name != 'this' || d.isStatic) p];
  }

  /// The [start, end] of each parameter in a signature's text.
  List<List<int>> _paramRanges(String sig) {
    final open = sig.indexOf('(');
    final close = sig.lastIndexOf(')');
    if (open < 0 || close <= open + 1) return const [];
    final out = <List<int>>[];
    var start = open + 1;
    for (var i = open + 1; i <= close; i++) {
      if (i == close || sig[i] == ',') {
        var s = start;
        while (s < i && sig[s] == ' ') {
          s++;
        }
        out.add([s, i]);
        start = i + 1;
      }
    }
    return out;
  }

  // ----------------------------------------------------------- completion

  void _addGlobal(Sym s, void Function(String, int, [String?, String?]) add) {
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
        add(s.name, _ciEnumMember, '${s.container} = ${_value(s.key)}', s.doc);
      case SymKind.constant:
        add(s.name, _ciConstant, 'const ${s.type} = ${_value(s.key)}', s.doc);
      case SymKind.global:
        add(s.name, _ciVariable, _typeText(s.type ?? '', s.isArray), s.doc);
      default:
        break;
    }
  }

  List<Map<String, Object?>> completion(Pos pos) {
    if (pos.line >= lines.length) return const [];
    final line = lines[pos.line];
    final (_, _, chain) = wordAt(line, pos.character);
    final items = <Map<String, Object?>>[];
    void add(String label, int kind, [String? detail, String? doc]) {
      items.add({
        'label': label,
        'kind': kind,
        if (detail != null) 'detail': sourceName(detail),
        if (doc != null) 'documentation': {'kind': 'markdown', 'value': doc},
      });
    }

    final pkg = _packageBefore(chain, pos);
    if (pkg != null) {
      for (final name in pkg.pubNames.toList()..sort()) {
        final s = _qualified(pkg, name);
        if (s != null) _addGlobal(s, add);
      }
      return items;
    }
    if (chain.parts.isNotEmpty) {
      final base = resolveChain(chain, pos);
      if (base == null) return const [];
      if (base.isTypeName) {
        for (final e in index.staticsOf(base.type).entries) {
          final v = e.value.first;
          add(
              e.key,
              v.kind == SymKind.constant ? _ciConstant : _ciFunction,
              v.kind == SymKind.constant
                  ? 'const ${v.type} = ${_value(v.key)}'
                  : e.value.length > 1
                      ? '${e.value.length} versions'
                      : _signature(v),
              v.doc);
        }
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
        // A string's methods (lib/string.act)
        if (base.type == 'string') {
          for (final m in index.methodsOf('string').values) {
            add(m.name, _ciMethod, _signature(m), m.doc);
          }
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
    // Names of other packages are reached through their import names
    final own = index.packageOf(path);
    final mine = own == null ? null : '${own.prefix}$packageMark';
    final shown = <String>{};
    for (final s in index.globals.values) {
      if (s.key.contains(packageMark) && (mine == null || !s.key.startsWith(mine))) continue;
      // A type's constants and static functions are reached through it
      final base = withoutOverload(s.key);
      if ((s.kind == SymKind.constant || s.kind == SymKind.function || s.kind == SymKind.prototype) &&
          baseName(base).contains('.')) {
        continue;
      }
      // One entry for all the versions of an overloaded function
      if (!shown.add('${s.kind}:$base')) continue;
      _addGlobal(s, add);
    }
    for (final e in (index.program.fileImports[path] ?? const <String, PackageInfo>{}).entries) {
      add(e.key, _ciModule, 'import "${e.value.path}"');
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
          if (c.type != null) 'detail': sourceName(c.type!),
          'range': rangeJson(cs, ce),
          'selectionRange': rangeJson(cs, ce),
        });
      }
    }
    return {
      'name': s.displayName,
      'kind': _symbolKind(s.kind),
      if (_detail(s) != null) 'detail': sourceName(_detail(s)!),
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
const _ciModule = 9;
const _ciProperty = 10;
const _ciKeyword = 14;
const _ciEnumMember = 20;
const _ciConstant = 21;
const _ciStruct = 22;
const _ciTypeParameter = 25;
