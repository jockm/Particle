part of '../compiler.dart';

// ------------------------------------------------------------------------------
// Brace initializers
// ------------------------------------------------------------------------------
//
// `T a[N] = {...}` gives an array its elements (rows for more than one
// dimension), and `T r = {field: v, ...}` gives a record stored in place its
// fields; elements and fields not given are zero. A local's initializer is
// turned by the parser into assignments after the declaration, so here it is
// only checked for its shape. A global's (or a constant table's) values must
// be constants, and become the initial contents of its storage
// ([_Initializers._initImage]).

extension _Initializers on Checker {
  /// Checks the brace initializer of [d] against its type: an array gets a
  /// list of at most as many elements as its first dimension, a record
  /// stored in place gets its fields by name, a string row gets a string.
  /// [isGlobal]: its values must be constants.
  void _checkInitializer(VarDeclNode d, {required bool isGlobal}) {
    final init = d.initList;
    if (init == null) {
      if (d.isReadOnly && d.initExpr == null) {
        throw CompileError("constant table '${d.name}' needs its values: "
                "'const ${cleanName(d.typeName)} ${d.name}[...] = {...};'")
            .at(d.loc);
      }
      return;
    }
    try {
      if (!isGlobal && d.isReadOnly) {
        throw CompileError("constant '${d.name}' must be declared inside '{ }' (not as the "
            'whole body of an if, while or for)');
      }
      if (!isGlobal && !d.expanded) {
        throw CompileError("'${d.name}' has a brace initializer, so it must be declared inside "
            "'{ }' (not as the whole body of an if, while or for)");
      }
      if (d.isPtr) {
        throw CompileError("'${d.name}' is a reference; a brace initializer gives values to an "
            'array or a record stored in place, so give a heap array its elements after '
            'createArray()');
      }
      if (d.dimExprs.isEmpty && !_isStorageRecordDecl(d)) {
        throw CompileError("a brace initializer gives values to an array or a record; "
            "'${d.name}' is a ${cleanName(d.typeName)}");
      }
      if (isGlobal && d.isRefArray) {
        throw CompileError("'${d.name}' is an array of references; a global one starts empty, "
            'so give its elements values in code');
      }
      final dims = d.arrayDims ?? (d.arrayDim != null ? [d.arrayDim!] : <int>[]);
      _checkInitValue(d.typeName, dims, init, d.name, isGlobal: isGlobal);
    } on CompileError catch (e) {
      throw e.at(init.loc ?? d.loc);
    }
  }

  String _q(String what) => "'$what'";

  bool _isStorageRecordDecl(VarDeclNode d) =>
      !d.isPtr &&
      !d.isRefDecl &&
      structs.containsKey(cleanName(d.typeName)) &&
      !_globalRefs.contains(d.name) &&
      !(_functionRefs[currentFuncName]?.contains(d.name) ?? false);

  /// [init] for a value of type [t] with array dimensions [dims] (for a
  /// string, the last is its capacity).
  void _checkInitValue(Object t, List<int> dims, AstNode init, String what,
      {required bool isGlobal}) {
    final ct = cleanName(t);
    final isString = ct == 'string';
    final rows = isString && dims.isNotEmpty ? dims.sublist(0, dims.length - 1) : dims;
    if (rows.isNotEmpty) {
      if (init is! InitListNode) {
        throw CompileError('${_q(what)} is an array, so its values are written in braces: {a, b, ...}')
            .at(init.loc);
      }
      if (init.elems.length > rows[0]) {
        throw CompileError(
                '${_q(what)} has ${rows[0]} element${rows[0] == 1 ? '' : 's'}, but ${init.elems.length} values are given')
            .at(init.loc);
      }
      final inner = dims.sublist(1);
      for (var i = 0; i < init.elems.length; i++) {
        _checkInitValue(t, inner, init.elems[i], '$what[$i]', isGlobal: isGlobal);
      }
      return;
    }
    if (isString) {
      if (init is InitListNode || init is RecordInitNode) {
        throw CompileError('${_q(what)} is a string, so its value is a string, not a brace list')
            .at(init.loc);
      }
      if (isGlobal) {
        if (init is! StringLitNode) {
          throw CompileError('${_q(what)}: a global string starts as a string literal').at(init.loc);
        }
        final cap = dims.isNotEmpty ? dims.last : 0;
        if (init.val.length >= cap) {
          throw CompileError('String literal length (${init.val.length}) does not fit in ${_q(what)}, '
                  'which holds ${cap - 1} characters and the terminator')
              .at(init.loc);
        }
      }
      return;
    }
    final info = structs[ct];
    if (info != null) {
      if (init is! RecordInitNode) {
        throw CompileError("${_q(what)} is a '$ct', so its value is written {field: value, ...}")
            .at(init.loc);
      }
      final seen = <String>{};
      for (var i = 0; i < init.fields.length; i++) {
        final (f, v) = init.fields[i];
        final loc = init.fieldLocs[i] ?? init.loc;
        final fi = info.fields[f];
        if (fi == null) throw CompileError("type '$ct' has no field '$f'").at(loc);
        if (!seen.add(f)) throw CompileError("field '$f' is given twice").at(loc);
        if (fi.isPtr || fi.refElems) {
          if (isGlobal) {
            throw CompileError("'$what.$f' is a reference; a global's references start empty")
                .at(loc);
          }
          continue;
        }
        final fdims = fi.dim is List<int>
            ? fi.dim as List<int>
            : fi.dim is int
                ? [fi.dim as int]
                : <int>[];
        _checkInitValue(fi.type, fdims, v, '$what.$f', isGlobal: isGlobal);
      }
      return;
    }
    if (init is InitListNode || init is RecordInitNode) {
      throw CompileError('${_q(what)} is a $ct, so its value is a single value, not a brace list')
          .at(init.loc);
    }
    if (isGlobal) {
      final c = _tryConst(init) ?? (_tryFloatConst(init) != null ? _ConstVal(BigInt.zero, null) : null);
      if (c == null) {
        throw CompileError('${_q(what)}: the values of a global are constants').at(init.loc);
      }
      _checkConstFits(init, ct, false, _q(what));
    }
  }

  /// The initial bytes of global [d] ([size] bytes): zero, with the values
  /// of its brace initializer or string literal written in.
  List<int> _initImage(VarDeclNode d, int size) {
    final bytes = List<int>.filled(size, 0, growable: true);
    final dims = d.arrayDims ?? (d.arrayDim != null ? [d.arrayDim!] : <int>[]);
    final init = d.initList ?? d.initExpr;
    if (init != null) _writeInit(bytes, 0, d.typeName, dims, init);
    return bytes;
  }

  void _writeInit(List<int> bytes, int at, Object t, List<int> dims, AstNode init) {
    final ct = cleanName(t);
    final isString = ct == 'string';
    final rows = isString && dims.isNotEmpty ? dims.sublist(0, dims.length - 1) : dims;
    if (rows.isNotEmpty && init is InitListNode) {
      final inner = dims.sublist(1);
      var stride = _getElemSize(t, false);
      for (final d in inner) {
        stride *= d;
      }
      for (var i = 0; i < init.elems.length; i++) {
        _writeInit(bytes, at + i * stride, t, inner, init.elems[i]);
      }
      return;
    }
    if (isString) {
      if (init is StringLitNode) {
        for (var i = 0; i < init.val.length; i++) {
          bytes[at + i] = init.val.codeUnitAt(i) & 0xFF;
        }
      }
      return;
    }
    final info = structs[ct];
    if (info != null) {
      if (init is! RecordInitNode) return;
      for (final (f, v) in init.fields) {
        final fi = info.fields[f]!;
        final fdims = fi.dim is List<int>
            ? fi.dim as List<int>
            : fi.dim is int
                ? [fi.dim as int]
                : <int>[];
        _writeInit(bytes, at + fi.offset, fi.type, fdims, v);
      }
      return;
    }
    if (ct == 'f32' || ct == 'f64') {
      final f = _tryFloatConst(init)?.$1 ?? _constExact(init).value.toDouble();
      final b = ByteData(8);
      if (ct == 'f32') {
        b.setFloat32(0, f, Endian.little);
      } else {
        b.setFloat64(0, f, Endian.little);
      }
      for (var i = 0; i < (ct == 'f32' ? 4 : 8); i++) {
        bytes[at + i] = b.getUint8(i);
      }
      return;
    }
    var v = _constExact(init).value;
    if (ct == 'bool') v = v == BigInt.zero ? BigInt.zero : BigInt.one;
    final n = _getElemSize(t, false);
    final mask = (BigInt.one << (8 * n)) - BigInt.one;
    var u = v & mask;
    for (var i = 0; i < n; i++) {
      bytes[at + i] = (u & BigInt.from(0xFF)).toInt();
      u >>= 8;
    }
  }
}

/// Where one value of `T.create(field: value, ...)` goes: its byte offset
/// in the record, its type, whether it is a reference, and for a string
/// field its capacity.
class _FieldSlot {
  final int offset;
  final String type;
  final bool isRef;
  final int? stringCap;
  const _FieldSlot(this.offset, this.type, this.isRef, this.stringCap);
}

extension _CreateValues on Checker {
  /// The slot [path] (field names and element indexes) names in a `T`.
  _FieldSlot _fieldSlot(String t, List<Object> path) {
    var type = t;
    var off = 0;
    var dims = <int>[];
    var refElems = false;
    var isPtr = false;
    var shown = '';
    for (final seg in path) {
      if (seg is String) {
        final isStringRow = type == 'string' && dims.length == 1;
        if (dims.isNotEmpty && !isStringRow) {
          throw CompileError("'$shown' is an array, so its values are written in braces: {a, b, ...}");
        }
        final info = structs[type];
        if (info == null || isPtr) {
          throw CompileError(shown.isEmpty
              ? "type '$t' has no field '$seg'"
              : "'$shown' has no fields, so it has no field '$seg'");
        }
        final f = info.fields[seg];
        if (f == null) throw CompileError("type '$type' has no field '$seg'");
        off += f.offset;
        type = cleanName(f.type);
        dims = f.dim is List<int>
            ? List.of(f.dim as List<int>)
            : f.dim is int
                ? [f.dim as int]
                : <int>[];
        refElems = f.refElems;
        isPtr = f.isPtr && !f.refElems;
        if (f.isArrayRef) {
          dims = [];
          isPtr = true;
        }
        shown = shown.isEmpty ? seg : '$shown.$seg';
      } else {
        final i = seg as int;
        final rows = type == 'string' ? dims.length - 1 : dims.length;
        if (rows <= 0) throw CompileError("'$shown' is not an array, so it has no element $i");
        if (i >= dims[0]) {
          throw CompileError("'$shown' has ${dims[0]} element${dims[0] == 1 ? '' : 's'}, "
              'but more values are given');
        }
        var stride = refElems ? target.pointerSize : _getElemSize(type, false);
        for (final d in dims.sublist(1)) {
          stride *= d;
        }
        off += i * stride;
        dims = dims.sublist(1);
        shown = '$shown[$i]';
        if (refElems && dims.isEmpty) isPtr = true;
      }
    }
    if (type == 'string' && dims.length == 1 && !isPtr) {
      return _FieldSlot(off, type, false, dims[0]);
    }
    if (dims.isNotEmpty) {
      throw CompileError("'$shown' is an array, so its values are written in braces: {a, b, ...}");
    }
    if (!isPtr && structs.containsKey(type)) {
      throw CompileError("'$shown' is a '$type', so its value is written {field: value, ...}");
    }
    return _FieldSlot(off, type, isPtr, null);
  }

  /// `T.create(field: value, ...)`: each value fits its field.
  void _checkCreateValues(HeapAllocNode e) {
    final t = cleanName(e.typeName);
    final seen = <String>{};
    for (var i = 0; i < e.args.length; i++) {
      final v = e.args[i];
      try {
        final path = e.fieldPaths[i];
        final key = path.join('.');
        if (!seen.add(key)) throw CompileError("'$key' is given a value twice");
        final slot = _fieldSlot(t, path);
        if (slot.stringCap != null) {
          if (v is! StringLitNode) {
            throw CompileError("string field '${path.join('.')}' is given a string literal here; "
                'copy another string into it after create()');
          }
          if (v.val.length >= slot.stringCap!) {
            throw CompileError('String literal length (${v.val.length}) does not fit in '
                "'${path.join('.')}', which holds ${slot.stringCap! - 1} characters and the terminator");
          }
          continue;
        }
        if (slot.isRef) {
          final k = _kindOf(v);
          final c = _tryConst(v);
          if (c != null && c.value == BigInt.zero) {
            throw CompileError("'${path.join('.')}' is a reference, so it cannot be 0; "
                'leave it out, and it starts empty');
          }
          if (k != _Kind.reference || cleanName(_getExprType(v).$1) != slot.type) {
            throw CompileError("'${path.join('.')}' is a reference to a '${slot.type}', "
                'not the ${_kindWords(k, v)}');
          }
          _checkExpr(v);
          continue;
        }
        final k = _kindOf(v);
        final isFn = fnTypes.containsKey(slot.type);
        if (k != (isFn ? _Kind.function : _Kind.scalar)) {
          throw CompileError(isFn
              ? "'${path.join('.')}' holds a function of type '${slot.type}', not the ${_kindWords(k, v)}"
              : "'${path.join('.')}' is a ${slot.type}, not the ${_kindWords(k, v)}");
        }
        _checkConstFits(v, slot.type, false, "'${path.join('.')}'");
        _checkExpr(v);
      } on CompileError catch (err) {
        throw err.at(v.loc ?? e.loc);
      }
    }
  }

  /// True when values of [t] hold references (in a field, an array of
  /// references, a heap array field, or a record inside them).
  bool _holdsReferences(String t, [Set<String>? seen]) {
    final info = structs[t];
    if (info == null) return false;
    final visited = seen ?? <String>{};
    if (!visited.add(t)) return false;
    for (final f in info.fields.values) {
      if (f.isPtr || f.refElems || f.isArrayRef) return true;
      final ft = cleanName(f.type);
      if (structs.containsKey(ft) && _holdsReferences(ft, visited)) return true;
    }
    return false;
  }

  /// `dst.copyFrom(src)`: two values of the same user-defined type, which
  /// holds no references.
  void _checkCopyFrom(CallNode call) {
    final dst = call.args[0];
    final src = call.args[1];
    if (!identical(call, _statementExpr)) {
      throw CompileError('copyFrom() is a statement; it has no value');
    }
    for (final (side, what) in [(dst, 'the target'), (src, 'the source')]) {
      final k = _kindOf(side);
      if (k != _Kind.record && k != _Kind.reference) {
        throw CompileError('copyFrom() copies a value of a user-defined type; $what is the '
            '${_kindWords(k, side)}');
      }
    }
    final dt = cleanName(_getExprType(dst).$1);
    final st = cleanName(_getExprType(src).$1);
    if (dt != st) throw CompileError("copyFrom() copies a '$dt' from a '$dt', not from a '$st'");
    if (_holdsReferences(dt)) {
      throw CompileError("a '$dt' holds references, so it cannot be copied: the copy would be a "
          'second owner of what they refer to');
    }
    _checkWritable(dst);
    for (final side in [dst, src]) {
      if (_kindOf(side) == _Kind.reference) {
        _checkExpr(side);
      } else {
        _checkLvalue(side);
      }
    }
  }
}
