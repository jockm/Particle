part of '../compiler.dart';

/// Raised when an expression is not a compile-time constant. Constant `if`
/// pruning catches it and falls back to a runtime branch; anywhere else it
/// is reported as a normal compile error (Python raised `ValueError`).
class NotConstantError extends CompileError {
  NotConstantError(super.message);

  @override
  CompileError withMessage(String msg) => NotConstantError(msg);
}

/// What kind of value an operand is, for the rules on what operators and
/// comparisons accept (see [_TypeRules._kindOf]).
enum _Kind { scalar, string, array, record, reference, function }

extension _TypeRules on Checker {
  /// The kind of value [e] is.
  _Kind _kindOf(AstNode e) {
    if (e is StringLitNode || e is HeapStringAllocNode) return _Kind.string;
    if (e is HeapArrayAllocNode) return _Kind.array;
    if (e is HeapAllocNode) return _Kind.reference;
    if (e is BinaryOpNode && e.op == '=') return _kindOf(e.left);
    if (e is SliceNode) return _Kind.array;
    if (e is VarAccessNode) {
      final n = e.name;
      if (!_isVariableInScope(n) && !types.containsKey(n)) {
        return funcSignatures.containsKey(n) ? _Kind.function : _Kind.scalar;
      }
      final t = typeOf(n, const TypeInfo('u32', false));
      final ct = _ctName(t.name);
      if (ct == 'string') {
        return t.refElems || (arrayDims[n]?.length ?? 1) > 1 ? _Kind.array : _Kind.string;
      }
      if (t.refElems ||
          arrayDims.containsKey(n) ||
          openArrays.contains(n) ||
          arrayLens.containsKey(n) ||
          dynamicArrays.contains(n)) {
        return _Kind.array;
      }
      return _kindOfType(ct, t.isRef || t.isPtr);
    }
    if (e is MemberAccessNode) {
      if (e.member == 'len' || e.member == 'capacity') return _Kind.scalar;
      final FieldInfo f;
      try {
        final (bT, _) = _getExprType(e.expr);
        f = fieldOf(cleanName(bT), e.member);
      } on CompileError {
        return _Kind.function;
      }
      final ct = _ctName(f.type);
      if (ct == 'string') {
        return f.refElems || (f.dim is List<int> && (f.dim as List<int>).length > 1)
            ? _Kind.array
            : _Kind.string;
      }
      if (f.refElems || f.isArrayRef || f.dim != null) return _Kind.array;
      return _kindOfType(ct, f.isPtr);
    }
    if (e is ArrayAccessNode) {
      final (t, isPtr) = _getExprType(e);
      final ct = _ctName(t);
      if (ct == 'string') return _Kind.string;
      final (base, indices) = _splitIndex(e);
      var rank = 1;
      if (base is VarAccessNode) {
        rank = _rankOf(base.name);
      } else if (base is MemberAccessNode) {
        try {
          final (bT, _) = _getExprType(base.expr);
          final f = fieldOf(cleanName(bT), base.member);
          if (f.dim is List<int>) rank = (f.dim as List<int>).length;
        } on CompileError {
          // not a field
        }
      }
      if (base is! ArrayAccessNode && indices.length < rank) return _Kind.array;
      return _kindOfType(ct, isPtr);
    }
    if (e is CallNode) {
      final (t, isPtr) = _getExprType(e);
      final ct = _ctName(t);
      if (ct == 'string' && isPtr) return _Kind.string;
      if (structs.containsKey(ct)) return _Kind.reference;
      if (isPtr) return _Kind.array;
      return _kindOfType(ct, false);
    }
    return _Kind.scalar;
  }

  /// [t] without qualifiers, as a plain type name ('' for a tuple).
  String _ctName(Object? t) {
    final c = cleanType(t);
    return c is String ? c : '';
  }

  _Kind _kindOfType(String ct, bool isRef) {
    if (fnTypes.containsKey(ct) || ct.startsWith('fn_')) return _Kind.function;
    if (structs.containsKey(ct)) return isRef ? _Kind.reference : _Kind.record;
    if (isRef) return ct == 'string' ? _Kind.string : _Kind.array;
    return _Kind.scalar;
  }

  /// Infers `(type name, is pointer)` for an expression.
  (Object, bool) _getExprType(AstNode? expr) {
    if (expr is ConvertNode) return (expr.typeName, false);
    if (expr is FloatLitNode) return ('f64', false);
    if (expr is VarAccessNode && !_isVariableInScope(expr.name) && _floatConsts.containsKey(expr.name)) {
      return (_floatConsts[expr.name]!.$2, false);
    }
    if (expr is ExistsNode) {
      return ('u32', false);
    } else if (expr is HeapAllocNode) {
      return (expr.typeName, true);
    } else if (expr is HeapArrayAllocNode) {
      return (expr.typeName, true);
    } else if (expr is HeapStringAllocNode) {
      return ('string', true);
    }
    while (expr != null &&
        expr.innerExpr != null &&
        expr is! MemberAccessNode &&
        expr is! UnaryOpNode) {
      expr = expr.innerExpr;
    }
    if (expr is VarAccessNode) {
      if (funcSignatures.containsKey(expr.name)) {
        return ('fn_${expr.name}', false);
      }
      final info = typeOf(expr.name);
      return (info.name, info.isPtr);
    } else if (expr is MemberAccessNode && expr.member == 'len') {
      return ('u32', false);
    } else if (expr is MemberAccessNode) {
      final base = expr.expr;
      if (base is VarAccessNode &&
          structs.containsKey(base.name) &&
          !locals.containsKey(base.name) &&
          !globals.contains(base.name) &&
          !boundAddrs.containsKey(base.name)) {
        final mangled = '${base.name}_${expr.member}';
        if (funcSignatures.containsKey(mangled)) {
          return ('fn_$mangled', false);
        }
        throw CompileError("Type '${base.name}' has no method '${expr.member}'");
      }

      final (pT, _) = _getExprType(expr.expr);
      final possibleType = cleanName(pT);
      final mangled = '${possibleType}_${expr.member}';
      if (funcSignatures.containsKey(mangled)) {
        final baseName = expr.expr.nodeName ?? 'instance';
        throw CompileError(
            "Cannot extract unbound method reference from instance '$baseName'. "
            "Use '$possibleType.${expr.member}' with signature fn($possibleType, ...) instead.");
      }

      final f = fieldOf(possibleType, expr.member);
      return (f.type, f.isPtr);
    } else if (expr is ArrayAccessNode) {
      final (curr, indices) = _splitIndex(expr);
      if (curr is ArrayAccessNode) {
        // A character of a string an array of references points at
        return ('u8', false);
      }
      if (curr is VarAccessNode) {
        final t = typeOf(curr.name);
        final cleanT = cleanType(t.name);
        if (t.refElems) return cleanT == 'string' ? ('string', false) : (t.name, true);
        if (cleanT == 'string') {
          // Fewer indices than dimensions: one string of an array of them
          return indices.length < _rankOf(curr.name) ? ('string', false) : ('u8', false);
        }
        return (t.name, false);
      } else if (curr is MemberAccessNode) {
        final (baseT, _) = _getExprType(curr.expr);
        final sName = cleanName(baseT);
        final f = fieldOf(sName, curr.member);
        if (f.refElems) return cleanType(f.type) == 'string' ? ('string', false) : (f.type, true);
        if (cleanType(f.type) == 'string') {
          final rank = f.dim is List<int> ? (f.dim as List<int>).length : 1;
          return indices.length < rank ? ('string', false) : ('u8', false);
        }
        return (f.type, false);
      }
      return ('u32', false);
    } else if (expr is CallNode) {
      final cv = _callValue(expr);
      if (cv != null) {
        final fn = fnTypes[cv.$2];
        return (fn?.$2 ?? 'u32', false);
      }
      String fname;
      if (expr.name.startsWith('__METHOD__')) {
        final mName = expr.name.replaceAll('__METHOD__', '');
        final (rcvT, _) = _getExprType(expr.args[0]);
        final sName = cleanName(rcvT);
        final (resolved, _) = _resolveMethod(sName, mName);
        fname = resolved ?? '${sName}_$mName';
      } else {
        fname = expr.name;
      }
      final sig = funcSignatures[fname];
      if (sig != null) {
        return (sig.retType, sig.retPtr);
      }
      if (_isMemoryBuiltin(expr)) return (_memoryBuiltins[expr.name]!.$2, false);
      return ('u32', false);
    }
    return ('u32', false);
  }

  bool _isSignedName(Object t) => t is String && _signedTypes.contains(t);

  /// True for a 64-bit integer type name.
  bool _is64Name(Object? t) => t is String && (cleanName(t) == 'u64' || cleanName(t) == 's64');

  /// True when [expr] is computed in 64 bits: its type is 64-bit, or it is
  /// arithmetic over a 64-bit operand (the widest operand decides).
  bool _is64Operand(AstNode expr) {
    if (expr is BinaryOpNode &&
        const ['+', '-', '*', '/', '%', '&', '|', '^'].contains(expr.op)) {
      return _is64Operand(expr.left) || _is64Operand(expr.right);
    }
    if (expr is BinaryOpNode && (expr.op == '<<' || expr.op == '>>')) {
      return _is64Operand(expr.left);
    }
    if (expr is UnaryOpNode && (expr.op == '-' || expr.op == '~')) {
      return _is64Operand(expr.operand);
    }
    final c = _tryConst(expr);
    if (c != null) {
      return _is64Name(c.type) || c.value < _min32 || c.value > _mask32;
    }
    final (t, isPtr) = _getExprType(expr);
    return !isPtr && _is64Name(t);
  }

  /// Byte size of a scalar or record type name (the `sizeof` rules).
  int _sizeOfTypeName(String tClean) {
    if (['u8', 's8', 'bool', 'string'].contains(tClean)) return 1;
    if (['u16', 's16'].contains(tClean)) return 2;
    if (['u32', 's32', 'void'].contains(tClean)) return 4;
    if (fnTypes.containsKey(tClean)) return target.pointerSize;
    if (['u64', 's64', 'f64'].contains(tClean)) return 8;
    if (tClean == 'f32') return 4;
    if (structs.containsKey(tClean)) return structs[tClean]!.size;
    if (_declaredTypes.contains(tClean)) throw _LayoutDeferred();
    return 4;
  }

  /// Total byte size of a fixed array variable, or null if [vName] is not one.
  int? _arrayByteSize(String vName) {
    if (arrayDims.containsKey(vName)) {
      final elemSz = _varElemSize(vName);
      var tot = 1;
      for (final dm in arrayDims[vName]!) {
        tot *= dm;
      }
      return elemSz * tot;
    } else if (arrayLens.containsKey(vName)) {
      final elemSz = _varElemSize(vName);
      return elemSz * arrayLens[vName]!;
    }
    return null;
  }

  /// Value of constant expression [expr] as a 32-bit pattern (its exact
  /// value modulo 2^32). See [_constExact] for the rules.
  int _evalConstExpr(AstNode? expr) => _bits32(_constExact(expr).value);

  /// Value of `sizeof(...)`.
  int _sizeofValue(SizeofNode expr) {
    Object target = expr.target;
    // If target is a variable name, resolve to its type
    if (target is String) {
      final vName = target;
      // (The reference analysis types a function's locals before they
      // are in scope)
      if (_isVariableInScope(vName) || types.containsKey(vName)) {
        final sz = _arrayByteSize(vName);
        if (sz != null) return sz;
        final tInfo = typeOf(vName);
        if (tInfo.isPtr) {
          // a reference
          return this.target.pointerSize;
        }
        return _sizeOfTypeName(cleanName(tInfo.name));
      }
      if (_isTypeName(vName)) return _sizeOfTypeName(vName);
      final c = _constInfo(vName);
      if (c != null) return _sizeOfTypeName(cleanName(c.type ?? 'u32'));
      _undefinedName(vName);
    }
    _checkSizeofOperand(target as AstNode);
    if (target is VarAccessNode) {
      final sz = _arrayByteSize(target.name);
      if (sz != null) return sz;
      final (tName, isP) = _getExprType(target);
      if (isP) return this.target.pointerSize;
      return _sizeOfTypeName(cleanName(tName));
    } else {
      final (tName, isP) = _getExprType(target);
      if (isP) return this.target.pointerSize;
      return _sizeOfTypeName(cleanName(tName));
    }
  }

  /// True when [name] is a variable in scope: a parameter, local or global.
  bool _isVariableInScope(String name) =>
      locals.containsKey(name) || globals.contains(name) || boundAddrs.containsKey(name);

  /// True when [name] names a type.
  bool _isTypeName(String name) =>
      const ['u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'f32', 'f64', 'bool', 'string', 'void']
          .contains(name) ||
      structs.containsKey(name) ||
      _declaredTypes.contains(name) ||
      fnTypes.containsKey(name);

  /// The variable an expression in `sizeof(...)` starts from must exist:
  /// `sizeof(a[0])`, `sizeof(p.x)`.
  void _checkSizeofOperand(AstNode e) {
    var root = e;
    while (true) {
      if (root is ArrayAccessNode) {
        root = root.base;
      } else if (root is MemberAccessNode) {
        root = root.expr;
      } else {
        break;
      }
    }
    if (root is VarAccessNode &&
        !_isVariableInScope(root.name) &&
        !_isTypeName(root.name) &&
        !funcSignatures.containsKey(root.name) &&
        _constInfo(root.name) == null) {
      _undefinedName(root.name);
    }
  }

  /// Size of one element of array variable [name]: a reference for an
  /// array of references.
  int _varElemSize(String name) {
    final t = typeOf(name);
    return t.refElems ? target.pointerSize : _getElemSize(t.name, false);
  }

  /// Number of dimensions of array variable [name] (1 for an open or heap
  /// array).
  int _rankOf(String name) => openRanks[name] ?? arrayDims[name]?.length ?? 1;

  /// Splits an element access into what it indexes and the indices, outer
  /// dimension first. Usually that is the array variable or field and all
  /// the indices; for `names[i][j]` with `ref string names[N]` it is the
  /// element `names[i]` (a string) and `[j]`.
  (AstNode, List<AstNode>) _splitIndex(ArrayAccessNode node) {
    final chain = <ArrayAccessNode>[];
    AstNode curr = node;
    while (curr is ArrayAccessNode) {
      chain.add(curr);
      curr = curr.base;
    }
    final k = _refArrayRank(curr);
    if (k != null) {
      if (chain.length > k) {
        final outer = chain.sublist(0, chain.length - k);
        return (outer.last.base, [for (final c in outer.reversed) c.index]);
      }
    }
    return (curr, [for (final c in chain.reversed) c.index]);
  }

  /// True when [e] is an element of an array of references: a stored
  /// reference that may be null.
  bool _isRefElement(AstNode e) {
    if (e is! ArrayAccessNode) return false;
    final (base, indices) = _splitIndex(e);
    return indices.length == _refArrayRank(base);
  }

  /// The number of dimensions of [base] when it is an array of references
  /// (a variable or a field), else null.
  int? _refArrayRank(AstNode base) {
    if (base is VarAccessNode && typeOf(base.name).refElems) return _rankOf(base.name);
    final f = _refArrayField(base);
    if (f == null) return null;
    return f.dim is List<int> ? (f.dim as List<int>).length : 1;
  }

  /// The field [e] names when it is an array of references, else null.
  FieldInfo? _refArrayField(AstNode e) {
    if (e is! MemberAccessNode) return null;
    final (bt, _) = _getExprType(e.expr);
    final f = structs[cleanName(bt)]?.fields[e.member];
    return f != null && f.refElems ? f : null;
  }

  /// True when [e] (a variable or a field) is an array of references.
  bool _isRefArray(AstNode e) =>
      (e is VarAccessNode && typeOf(e.name).refElems) || _refArrayField(e) != null;

  /// Size of one element of the array [base] (a variable, field or other
  /// expression) of element type [elemType].
  int _elemSizeOfBase(AstNode base, Object elemType) {
    if (base is VarAccessNode) return _varElemSize(base.name);
    if (_refArrayField(base) != null) return target.pointerSize;
    return _getElemSize(elemType, false);
  }

  /// True when [e] is one string of a fixed array of strings
  /// (`names[i]` with `string names[3][8]`): its value is its address.
  bool _isStringRow(AstNode e) =>
      e is ArrayAccessNode && !_isRefElement(e) && cleanType(_getExprType(e).$1) == 'string';

  /// The capacity (bytes, the terminator included) of the fixed string
  /// buffer [e] names, or null when it is not one. Assigning a string to
  /// one copies it.
  int? _fixedStringCap(AstNode e) {
    if (e is VarAccessNode) {
      final t = typeOf(e.name);
      if (cleanType(t.name) != 'string' || t.isPtr || t.refElems) return null;
      final dims = arrayDims[e.name] ?? (arrayLens.containsKey(e.name) ? [arrayLens[e.name]!] : null);
      return dims != null && dims.length == 1 ? dims[0] : null;
    }
    if (e is MemberAccessNode) {
      final (bt, _) = _getExprType(e.expr);
      final f = structs[cleanName(bt)]?.fields[e.member];
      if (f == null || f.isPtr || cleanType(f.type) != 'string') return null;
      final d = f.dim;
      if (d is int) return d;
      return d is List<int> && d.length == 1 ? d[0] : null;
    }
    if (e is ArrayAccessNode && _isStringRow(e)) return _rowCapacity(e);
    return null;
  }

  /// The capacity of string row [row] of a fixed array of strings: its
  /// array's last dimension.
  int? _rowCapacity(ArrayAccessNode row) {
    final (base, indices) = _splitIndex(row);
    List<int>? dims;
    if (base is VarAccessNode) {
      dims = arrayDims[base.name];
    } else if (base is MemberAccessNode) {
      final (bt, _) = _getExprType(base.expr);
      final d = fieldOf(cleanName(bt), base.member).dim;
      dims = d is List<int> ? d : null;
    }
    if (dims == null || indices.length != dims.length - 1) return null;
    return dims.last;
  }

  /// `elem = value` for an element of an array of references to strings:
  /// every element owns a heap string, so a value that is not one (a
  /// literal, a buffer, a parameter, another element...) is copied into a
  /// new heap string. A heap string variable is moved in instead.
  bool _copiesIntoHeapString(AstNode left, AstNode right) {
    if (!_isRefElement(left) || cleanType(_getExprType(left).$1) != 'string') return false;
    if (right is HeapStringAllocNode) return false;
    if (right is IntLitNode && right.val == 0) return false;
    if (right is VarAccessNode && _isHeapArrayRef(right.name) && !typeOf(right.name).refElems) {
      return false;
    }
    return true;
  }

  /// The length an array passed as an open-array argument has when it is
  /// a fixed array variable or field: its first dimension (0 otherwise).
  int _fixedArgLength(AstNode arg) {
    if (arg is ArrayAccessNode) {
      // A row of an array of more dimensions: the length of the next one
      final (base, indices) = _splitIndex(arg);
      final dims = _fixedDimsOf(base);
      return dims != null && indices.length < dims.length ? dims[indices.length] : 0;
    }
    if (arg is MemberAccessNode) {
      final (bt, _) = _getExprType(arg.expr);
      final d = fieldOf(cleanName(bt), arg.member).dim;
      return d is List<int> ? d.first : ((d as int?) ?? 0);
    }
    final name = arg.nodeName;
    return name == null ? 0 : (arrayDims[name]?.first ?? arrayLens[name] ?? 0);
  }

  /// For a row of an open array parameter of more dimensions (`m[i]`): the
  /// parameter and which of its lengths is the row's. Null otherwise.
  (String, int)? _openRow(AstNode arg) {
    if (arg is! ArrayAccessNode) return null;
    final (base, indices) = _splitIndex(arg);
    if (base is! VarAccessNode || !openRanks.containsKey(base.name)) return null;
    if (indices.length >= openRanks[base.name]!) return null;
    return (base.name, indices.length);
  }

  /// How a run-time message names the stored reference [e] (a `ref` field
  /// or an element of an array of references), or null when it is not one.
  String? _storedRefName(AstNode e) {
    if (e is MemberAccessNode && _refField(e) != null) return "field '${e.member}'";
    if (_isRefElement(e)) {
      final (base, _) = _splitIndex(e as ArrayAccessNode);
      return "an element of '${base is VarAccessNode ? base.name : (base as MemberAccessNode).member}'";
    }
    return null;
  }

  int _getElemSize(Object? tName, bool isPtr) {
    if (isPtr) return target.pointerSize;
    final clean = cleanName(tName);
    if (['u8', 's8', 'bool', 'string'].contains(clean)) {
      return 1;
    } else if (['u16', 's16'].contains(clean)) {
      return 2;
    } else if (['u64', 's64', 'f64'].contains(clean)) {
      return 8;
    } else if (fnTypes.containsKey(clean)) {
      return target.pointerSize;
    } else if (structs.containsKey(clean)) {
      return structs[clean]!.size;
    }
    return 4;
  }
}

/// Python class name of a node, for diagnostics (`BinaryOpNode`, ...).
String _pyClassName(AstNode node) => node.runtimeType.toString();
