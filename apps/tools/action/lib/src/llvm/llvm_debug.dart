part of '../compiler.dart';

// ------------------------------------------------------------------------------
// DWARF debug information for the LLVM generator
// ------------------------------------------------------------------------------
//
// Builds the metadata of a module: the compile unit, a file per source,
// a subprogram per function, a location per source position, and the types
// and variables, so that a debugger shows Action lines, variables and
// values. DWARF version 4.

class _DebugInfo {
  final LlvmGen g;

  /// Metadata nodes by number; each is the text after `!N = `.
  final List<String> _nodes = [];
  final Map<String, int> _unique = {};
  final Map<String, int> _files = {};
  final Map<String, int> _types = {};
  final List<int> _globals = [];
  late final int cu;
  late final int _globalsList;
  int _firstFile = -1;

  _DebugInfo(this.g, String mainPath) {
    _firstFile = file(mainPath);
    cu = _reserve();
    _globalsList = _reserve();
    _set(cu,
        'distinct !DICompileUnit(language: DW_LANG_C99, file: !$_firstFile, producer: "action_llvm", '
        'isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, globals: !$_globalsList)');
  }

  int _reserve() {
    _nodes.add('');
    return _nodes.length - 1;
  }

  void _set(int id, String text) => _nodes[id] = text;

  /// A uniqued node: the same text gives the same number.
  int node(String text) => _unique.putIfAbsent(text, () {
        _nodes.add(text);
        return _nodes.length - 1;
      });

  int file(String path) => _files.putIfAbsent(path, () {
        final slash = path.lastIndexOf('/');
        final name = slash < 0 ? path : path.substring(slash + 1);
        final dir = slash < 0 ? '.' : path.substring(0, slash);
        _nodes.add('!DIFile(filename: "${_esc(name)}", directory: "${_esc(dir)}")');
        return _nodes.length - 1;
      });

  static String _esc(String s) => s.replaceAll('\\', '\\5C').replaceAll('"', '\\22');

  /// A subprogram for function [name] of [path], starting on [line].
  int subprogram(String name, String path, int line) {
    final f = file(path);
    final type = node('!DISubroutineType(types: !${node('!{null}')})');
    final id = _reserve();
    _set(id,
        'distinct !DISubprogram(name: "${_esc(name)}", scope: !$f, '
        'file: !$f, line: $line, type: !$type, scopeLine: $line, '
        'spFlags: DISPFlagDefinition, unit: !$cu, retainedNodes: !${node('!{}')})');
    return id;
  }

  /// A block inside [scope] (a subprogram or another block), opened at
  /// [line]:[col] of [path].
  int lexicalBlock(int scope, String path, int line, int col) {
    final id = _reserve();
    _set(id, 'distinct !DILexicalBlock(scope: !$scope, file: !${file(path)}, line: $line, column: $col)');
    return id;
  }

  int location(int line, int col, int scope) =>
      node('!DILocation(line: $line, column: $col, scope: !$scope)');

  /// A parameter ([arg] from 1) or local variable.
  int variable(String name, int scope, String path, int line, int type, {int arg = 0}) {
    final a = arg > 0 ? 'arg: $arg, ' : '';
    return node('!DILocalVariable(name: "${_esc(sourceName(name))}", ${a}scope: !$scope, '
        'file: !${file(path)}, line: $line, type: !$type)');
  }

  int expression() => node('!DIExpression()');

  /// A global variable; returns its DIGlobalVariableExpression.
  int global(String name, String path, int line, int type) {
    final v = node('distinct !DIGlobalVariable(name: "${_esc(name)}", scope: !$cu, '
        'file: !${file(path)}, line: $line, type: !$type, isLocal: true, isDefinition: true)');
    final e = node('!DIGlobalVariableExpression(var: !$v, expr: !${expression()})');
    _globals.add(e);
    return e;
  }

  // ---------------------------------------------------------------- types

  int _basic(String name, int bits, String enc) =>
      node('!DIBasicType(name: "$name", size: $bits, encoding: $enc)');

  int get _char => _basic('char', 8, 'DW_ATE_unsigned_char');

  int pointerTo(int base) =>
      node('!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !$base, size: ${g.target.pointerSize * 8})');

  /// The type of a scalar, string, record or function type name.
  int scalar(Object? tName) {
    final t = g.cleanName(tName);
    switch (t) {
      case 'u8':
      case 'u16':
      case 'u32':
      case 'u64':
        return _basic(t, _bitsOf(t), 'DW_ATE_unsigned');
      case 's8':
      case 's16':
      case 's32':
      case 's64':
        return _basic(t, _bitsOf(t), 'DW_ATE_signed');
      case 'bool':
        return _basic('bool', 8, 'DW_ATE_boolean');
      case 'f32':
        return _basic('f32', 32, 'DW_ATE_float');
      case 'f64':
        return _basic('f64', 64, 'DW_ATE_float');
      case 'string':
        return pointerTo(_char);
    }
    if (g.fnTypes.containsKey(t)) {
      return pointerTo(node('!DISubroutineType(types: !${node('!{null}')})'));
    }
    if (g.structs.containsKey(t)) return record(t);
    return _basic('u32', 32, 'DW_ATE_unsigned');
  }

  static int _bitsOf(String t) =>
      t.endsWith('8') ? 8 : (t.endsWith('16') ? 16 : (t.endsWith('64') ? 64 : 32));

  /// The element type of an array of [tName]: a string's elements are chars.
  int element(Object? tName, bool isPtr) {
    if (isPtr && !g.structs.containsKey(g.cleanName(tName))) {
      return g.cleanName(tName) == 'string' ? _char : scalar(tName);
    }
    return g.cleanName(tName) == 'string' ? _char : scalar(tName);
  }

  int array(int elem, int elemBytes, List<int> dims) {
    var total = elemBytes;
    for (final d in dims) {
      total *= d;
    }
    final subs = [for (final d in dims) '!${node('!DISubrange(count: $d)')}'].join(', ');
    return node('!DICompositeType(tag: DW_TAG_array_type, baseType: !$elem, size: ${total * 8}, '
        'elements: !${node('!{$subs}')})');
  }

  int record(String name) {
    final known = _types[name];
    if (known != null) return known;
    final info = g.structs[name]!;
    final id = _reserve();
    _types[name] = id;
    final members = <String>[];
    for (final e in info.fields.entries) {
      if (e.key.contains('~')) continue;
      final f = e.value;
      final int t;
      final int bytes;
      if (f.refElems) {
        final elem = g.cleanName(f.type) == 'string' ? scalar('string') : pointerTo(scalar(f.type));
        final dims = f.dim is List<int> ? f.dim as List<int> : (f.dim is int ? [f.dim as int] : <int>[]);
        t = f.isArrayRef || dims.isEmpty ? pointerTo(elem) : array(elem, g.target.pointerSize, dims);
        bytes = f.isArrayRef || dims.isEmpty
            ? g.target.pointerSize
            : dims.fold(g.target.pointerSize, (a, d) => a * d);
      } else if (f.isArrayRef) {
        t = pointerTo(element(f.type, false));
        bytes = g.target.pointerSize;
      } else if (f.isPtr) {
        t = pointerTo(scalar(f.type));
        bytes = g.target.pointerSize;
      } else {
        final elemBytes = g._getElemSize(f.type, false);
        final dims = f.dim is List<int> ? f.dim as List<int> : (f.dim is int ? [f.dim as int] : <int>[]);
        t = dims.isEmpty ? scalar(f.type) : array(element(f.type, false), elemBytes, dims);
        bytes = dims.isEmpty ? elemBytes : dims.fold(elemBytes, (a, d) => a * d);
      }
      members.add('!${node('!DIDerivedType(tag: DW_TAG_member, name: "${_esc(e.key)}", scope: !$id, '
          'baseType: !$t, size: ${bytes * 8}, offset: ${f.offset * 8})')}');
    }
    _set(id,
        'distinct !DICompositeType(tag: DW_TAG_structure_type, name: "${_esc(name)}", '
        'size: ${info.size * 8}, align: ${info.align * 8}, elements: !${node('!{${members.join(', ')}}')})');
    return id;
  }

  /// The metadata section of the module.
  List<String> emit() {
    final flags4 = node('!{i32 7, !"Dwarf Version", i32 4}');
    final flagsDi = node('!{i32 2, !"Debug Info Version", i32 3}');
    _set(_globalsList, '!{${_globals.map((e) => '!$e').join(', ')}}');
    return [
      '!llvm.dbg.cu = !{!$cu}',
      '!llvm.module.flags = !{!$flags4, !$flagsDi}',
      '!llvm.ident = !{!${node('!{!"action_llvm"}')}}',
      for (var i = 0; i < _nodes.length; i++) '!$i = ${_nodes[i]}',
    ];
  }
}
