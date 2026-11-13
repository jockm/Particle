part of '../compiler.dart';

// ------------------------------------------------------------------------------
// LLVM generator: expressions, addresses, calls and the heap
// ------------------------------------------------------------------------------

extension _LlvmExpressions on LlvmGen {
  _V _expr(AstNode e) {
    final saved = _curLoc;
    if (e.loc != null) _curLoc = e.loc;
    final v = _exprInner(e);
    _curLoc = saved;
    return v;
  }

  _V _exprInner(AstNode expr) {
    if (expr is UnaryOpNode ||
        expr is ConvertNode ||
        expr is MemberAccessNode ||
        (expr is BinaryOpNode && expr.op != '=')) {
      final c = _tryConst(expr);
      if (c != null) return _constOf(c);
    }
    // A floating-point constant (a literal, a const, or arithmetic on them)
    if (expr is FloatLitNode ||
        expr is UnaryOpNode ||
        expr is ConvertNode ||
        expr is VarAccessNode ||
        (expr is BinaryOpNode && expr.op != '=')) {
      final f = _tryFloatConst(expr);
      if (f != null) {
        final ty = f.$2 == 'f32' ? 'float' : 'double';
        return _V(_fpLit(f.$1, ty), ty);
      }
    }
    if (expr is ConvertNode) return _genConvert(expr);
    if (expr is IntLitNode) return _const(BigInt.from(expr.val));
    if (expr is CallNode && expr.name == '__copyFrom') return _genCopyFrom(expr);
    if (expr is HeapAllocNode) {
      final p = _calloc('i64 ${structSize(cleanName(expr.typeName))}');
      if (expr.args.isNotEmpty) _genCreateValues(expr, p);
      return _V(p, 'ptr');
    }
    if (expr is HeapArrayAllocNode) {
      final n = _conv(_expr(expr.countExpr), 'i32');
      final es = expr.refElems ? target.pointerSize : _getElemSize(cleanName(expr.typeName), false);
      return _V(_newHeapArray(n, es), 'ptr');
    }
    if (expr is HeapStringAllocNode) {
      final cap = _conv(_expr(expr.capExpr), 'i32');
      final n64 = _val('zext i32 ${cap.v} to i64');
      final bytes = _val('add i64 $n64, ${_heapHeader + 1}');
      final base = _calloc('i64 $bytes');
      _ins('store i32 ${cap.v}, ptr $base');
      return _V(_offset(base, '$_heapHeader'), 'ptr');
    }
    if (expr is HeapFreeNode) return _genFree(expr);
    if (expr is HeapArrayResizeNode) return _genResize(expr);
    if (expr is HeapArrayFreeNode) {
      final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
      final p = _expr(expr.expr);
      _globalRefCheck(expr.expr, p.v);
      if (targetVar != null && affineState.containsKey(targetVar)) affineState[targetVar] = 'MOVED';
      _freeHeapArray(p.v);
      if (targetVar != null && locals.containsKey(targetVar)) {
        _ins('store ptr null, ptr ${_slots[targetVar]}');
      }
      return const _V('0', 'i32');
    }
    if (expr is ExistsNode) {
      final inner = expr.expr;
      _V p;
      if (inner is VarAccessNode) {
        final addr = locals.containsKey(inner.name) || globals.contains(inner.name)
            ? _varAddr(inner.name)
            : null;
        p = addr == null ? const _V('null', 'ptr') : _V(_val('load ptr, ptr $addr'), 'ptr');
      } else {
        p = _conv(_expr(inner), 'ptr');
      }
      return _fromBool(_val('icmp ne ptr ${p.v}, null'));
    }
    if (expr is SizeofNode) return _const(BigInt.from(_evalConstExpr(expr)));
    if (expr is MemberAccessNode) return _member(expr);
    if (expr is ArrayAccessNode) {
      final (addr, tName, vol) = _elemAddr(expr);
      // One string of a fixed array of them: its address
      if (_isStringRow(expr)) return _V(addr, 'ptr');
      return _load(addr, tName, _isRefElement(expr), volatile: vol);
    }
    if (expr is VarAccessNode) return _varValue(expr.name);
    if (expr is UnaryOpNode) {
      final v = _expr(expr.operand);
      if (_isFloatTy(v.ty) && expr.op == '-') return _V(_val('fneg ${v.ty} ${v.v}'), v.ty);
      final iv = v.isPtr ? _conv(v, 'i64') : v;
      switch (expr.op) {
        case '-':
          return _V(_val('sub ${iv.ty} 0, ${iv.v}'), iv.ty, _isSignedOperand(expr));
        case '~':
          return _V(_val('xor ${iv.ty} ${iv.v}, -1'), iv.ty, iv.signed);
        default:
          return _fromBool(_val('icmp eq ${iv.ty} ${iv.v}, 0'));
      }
    }
    if (expr is CompoundAssignNode) return _genCompound(expr);
    if (expr is BinaryOpNode) return _binary(expr);
    if (expr is StringLitNode) return _V(_stringConst(expr.val), 'ptr');
    if (expr is TrapNode) return _genTrap(expr.trapNum);
    if (expr is CallNode) return _call(expr);
    return const _V('0', 'i32');
  }

  // ---------------------------------------------------------- variables

  /// The address of variable [name]'s storage (for a reference: the slot
  /// holding it), or null when there is none.
  String? _varAddr(String name) {
    if (boundAddrs.containsKey(name)) return _addrPtr('${boundAddrs[name]}');
    if (locals.containsKey(name)) return _slots[name];
    if (globals.contains(name)) return _globalName(name);
    return null;
  }

  _V _varValue(String name) {
    final c = _constInfo(name);
    if (c != null && constants.containsKey(name)) return _constOf(c);
    if (funcSignatures.containsKey(name) && !_isVariableInScope(name)) {
      final sig = funcSignatures[name]!;
      return _V(sig.isExtern ? '@$name' : _fnName(name), 'ptr');
    }
    final t = typeOf(name);
    final addr = _varAddr(name)!;
    // An array's name is its address
    if (arrayLens.containsKey(name)) return _V(addr, 'ptr');
    return _load(addr, t.name, t.isPtr || t.isRef, volatile: boundAddrs.containsKey(name));
  }

  // ------------------------------------------------------------ addresses

  /// The address [node] denotes, and whether it is a fixed (`@`) address,
  /// which is accessed volatile.
  (String, bool) _lvalue(AstNode node) {
    final saved = _curLoc;
    if (node.loc != null) _curLoc = node.loc;
    final r = _lvalueInner(node);
    _curLoc = saved;
    return r;
  }

  (String, bool) _lvalueInner(AstNode node) {
    if (node is VarAccessNode) {
      final name = node.name;
      final isRef = typeOf(name).isRef;
      if (boundAddrs.containsKey(name)) return (_addrPtr('${boundAddrs[name]}'), true);
      if (locals.containsKey(name)) {
        final slot = _slots[name]!;
        return (isRef ? _val('load ptr, ptr $slot') : slot, false);
      }
      final g = _globalName(name);
      if (!isRef) return (g, false);
      final p = _val('load ptr, ptr $g');
      _nullCheck(p, "global '$name'");
      return (p, false);
    }
    if (node is MemberAccessNode) {
      final baseExpr = node.expr;
      final (tName, baseIsPtr) = _getExprType(baseExpr);
      final f = fieldOf(cleanName(tName), node.member);
      var (base, vol) = _lvalue(baseExpr);
      if (baseIsPtr) {
        base = _val('load ptr, ptr $base');
        final what = _storedRefName(baseExpr);
        if (what != null) _nullCheck(base, what);
      }
      return (_offset(base, '${f.offset}'), vol);
    }
    if (node is ArrayAccessNode) {
      final (a, _, vol) = _elemAddr(node);
      return (a, vol);
    }
    return (_conv(_expr(node), 'ptr').v, false);
  }

  /// The address of an array element, its type and whether it is volatile.
  (String, Object, bool) _elemAddr(ArrayAccessNode node, {bool isWrite = false}) {
    final (baseNode, idxList) = _splitIndex(node);
    final baseName = baseNode.nodeName;
    final refElems = _isRefArray(baseNode);
    final isOpen = baseName != null && openArrays.contains(baseName);
    if (isOpen && openRanks.containsKey(baseName)) {
      return _openElemAddr(baseNode, baseName, idxList, isWrite);
    }
    var dims = arrayDims[baseName] ?? <int>[];
    if (dims.isEmpty && baseName != null && arrayLens.containsKey(baseName)) {
      dims = [arrayLens[baseName]!];
    } else if (dims.isEmpty && baseNode is MemberAccessNode) {
      final (pT, _) = _getExprType(baseNode.expr);
      final mDim = fieldOf(cleanName(pT), baseNode.member).dim;
      if (mDim is List<int>) {
        dims = mDim;
      } else if (mDim is int) {
        dims = [mDim];
      }
    }
    final (baseType, _) = _getExprType(baseNode);
    final isString = cleanType(baseType) == 'string';
    final refField = _refField(baseNode);

    // The base address first: a heap array's length is in its header
    String base;
    var vol = false;
    var heap = false;
    if (isOpen) {
      base = _val('load ptr, ptr ${_slots[baseName]}');
    } else if (baseName != null && boundAddrs.containsKey(baseName)) {
      base = _addrPtr('${boundAddrs[baseName]}');
      vol = true;
    } else if (baseName != null && locals.containsKey(baseName)) {
      final t = typeOf(baseName);
      final fixed = arrayDims.containsKey(baseName) || arrayLens.containsKey(baseName);
      base = _slots[baseName]!;
      if (t.isRef || t.isPtr || !fixed) base = _val('load ptr, ptr $base');
      heap = affineState.containsKey(baseName) || _isHeapArrayRef(baseName);
    } else if (baseName != null && globals.contains(baseName)) {
      final t = typeOf(baseName);
      base = _globalName(baseName);
      if (t.isPtr && !arrayDims.containsKey(baseName) && !arrayLens.containsKey(baseName)) {
        base = _val('load ptr, ptr $base');
        _nullCheck(base, "global '$baseName'");
        heap = true;
      }
    } else if (baseNode is MemberAccessNode) {
      final (a, v) = _lvalue(baseNode);
      base = a;
      vol = v;
      if (refField?.isArrayRef == true) {
        base = _val('load ptr, ptr $base');
        _nullCheck(base, "field '${baseNode.member}'");
        heap = true;
      }
    } else {
      base = _conv(_expr(baseNode), 'ptr').v;
      // A string an array of references points at
      final what = _storedRefName(baseNode);
      if (what != null) _nullCheck(base, what);
    }

    // The flat index, checked dimension by dimension
    String? flat;
    for (var d = 0; d < idxList.length; d++) {
      final iv = _expr(idxList[d]);
      final i64 = _conv(iv.isPtr ? _conv(iv, 'i64') : iv, 'i64').v;
      final what = baseName ?? (baseNode is MemberAccessNode ? baseNode.member : 'array');
      if (d == 0 && (isOpen || heap)) {
        _V len = isOpen
            ? _load(_slots['${baseName}__len']!, 'u32', false)
            : _headerLen(base);
        if (isWrite && isString && !isOpen && !refElems) len = _V(_val('sub i32 ${len.v}, 1'), 'i32');
        _boundsCheck(_V(i64, 'i64'), _conv(len, 'i64'), what);
      } else if (d < dims.length) {
        var bnd = dims[d];
        if (isWrite && isString && !refElems && d == idxList.length - 1) bnd = bnd - 1 > 0 ? bnd - 1 : 0;
        _boundsCheck(_V(i64, 'i64'), _V('$bnd', 'i64'), what);
      }
      if (flat == null) {
        flat = i64;
      } else {
        final next = d < dims.length ? dims[d] : 1;
        final m = _val('mul i64 $flat, $next');
        flat = _val('add i64 $m, $i64');
      }
    }
    final leafSz = _elemSizeOfBase(baseNode, baseType);
    var stride = leafSz;
    for (final d in dims.skip(idxList.length)) {
      stride *= d;
    }
    final bytes = stride == 1 ? flat! : _val('mul i64 $flat, $stride');
    final addr = _val('getelementptr inbounds i8, ptr $base, i64 $bytes');
    if (refElems) return (addr, baseType, vol);
    if (isString && idxList.length >= dims.length) return (addr, 'u8', vol);
    return (addr, baseType, vol);
  }

  /// Length [k] of open array parameter [name] (0 is the first dimension).
  _V _openLen(String name, int k) =>
      _load(_slots[k == 0 ? '${name}__len' : '${name}__len$k']!, 'u32', false);

  /// An element (or row) of an open array parameter with more than one
  /// dimension: the flat index from the lengths passed in, each index
  /// checked against its own.
  (String, Object, bool) _openElemAddr(
      AstNode baseNode, String name, List<AstNode> idxList, bool isWrite) {
    final rank = openRanks[name]!;
    final (baseType, _) = _getExprType(baseNode);
    final isString = cleanType(baseType) == 'string';
    final base = _val('load ptr, ptr ${_slots[name]}');
    String? flat;
    for (var d = 0; d < idxList.length; d++) {
      final iv = _expr(idxList[d]);
      final i64 = _conv(iv.isPtr ? _conv(iv, 'i64') : iv, 'i64').v;
      var len = _openLen(name, d);
      if (isWrite && isString && d == rank - 1) len = _V(_val('sub i32 ${len.v}, 1'), 'i32');
      _boundsCheck(_V(i64, 'i64'), _conv(len, 'i64'), name);
      if (flat == null) {
        flat = i64;
      } else {
        final n = _conv(_openLen(name, d), 'i64').v;
        flat = _val('add i64 ${_val('mul i64 $flat, $n')}, $i64');
      }
    }
    for (var k = idxList.length; k < rank; k++) {
      final n = _conv(_openLen(name, k), 'i64').v;
      flat = _val('mul i64 $flat, $n');
    }
    final sz = isString ? 1 : _getElemSize(baseType, false);
    final bytes = sz == 1 ? flat! : _val('mul i64 $flat, $sz');
    final addr = _val('getelementptr inbounds i8, ptr $base, i64 $bytes');
    if (isString && idxList.length >= rank) return (addr, 'u8', false);
    return (addr, baseType, false);
  }

  /// The length (or capacity) in the header of the heap array or string
  /// whose elements start at [payload].
  _V _headerLen(String payload) {
    final h = _val('getelementptr inbounds i8, ptr $payload, i64 -$_heapHeader');
    return _V(_val('load i32, ptr $h'), 'i32');
  }

  /// A reference held in a global is not followed by the flow analysis:
  /// with reference checks on, it is checked when used.
  void _globalRefCheck(AstNode base, String ptr) {
    if (base is VarAccessNode && globals.contains(base.name) && !locals.containsKey(base.name)) {
      _nullCheck(ptr, "global '${base.name}'");
    }
  }

  // ------------------------------------------------------------- members

  _V _member(MemberAccessNode expr) {
    final baseExpr = expr.expr;
    final member = expr.member;
    if (member == 'len' || member == 'capacity') {
      final (root, indices) =
          baseExpr is ArrayAccessNode ? _splitIndex(baseExpr) : (baseExpr, <AstNode>[]);
      final name = root is VarAccessNode ? root.name : null;
      if (name != null && openRanks.containsKey(name) && openArrays.contains(name)) {
        final rank = openRanks[name]!;
        final isString = cleanType(typeOf(name).name) == 'string';
        final n = indices.length;
        if (member == 'capacity') return _openLen(name, isString ? rank - 1 : n);
        if (isString && n == rank - 1) return _strlen(_elemAddr(baseExpr as ArrayAccessNode).$1);
        return _openLen(name, n);
      }
    }
    if ((member == 'capacity' ||
            (member == 'len' &&
                !(baseExpr is VarAccessNode &&
                    cleanType(typeOf(baseExpr.name).name) == 'string' &&
                    !typeOf(baseExpr.name).refElems))) &&
        baseExpr is VarAccessNode &&
        openArrays.contains(baseExpr.name)) {
      return _load(_slots['${baseExpr.name}__len']!, 'u32', false);
    }
    if (member == 'len' || member == 'capacity') {
      if (baseExpr is ArrayAccessNode && _isRefElement(baseExpr) &&
          cleanType(_getExprType(baseExpr).$1) == 'string') {
        final p = _conv(_expr(baseExpr), 'ptr').v;
        _nullCheck(p, _storedRefName(baseExpr)!);
        return member == 'capacity' ? _headerLen(p) : _strlen(p);
      }
      if (baseExpr is ArrayAccessNode && _isStringRow(baseExpr)) {
        if (member == 'capacity') return _i32(_rowCapacity(baseExpr) ?? 0);
        return _strlen(_elemAddr(baseExpr).$1);
      }
      if (baseExpr is MemberAccessNode && member == 'len' && _fixedStringCap(baseExpr) != null) {
        return _strlen(_lvalue(baseExpr).$1);
      }
      if (baseExpr is VarAccessNode && member == 'len' && !openArrays.contains(baseExpr.name)) {
        final t = typeOf(baseExpr.name);
        final dims = arrayDims[baseExpr.name];
        if ((t.refElems && !t.isPtr) || (cleanType(t.name) == 'string' && dims != null && dims.length > 1)) {
          return _i32(dims?.first ?? arrayLens[baseExpr.name] ?? 0);
        }
      }
    }
    final arrField = _refField(baseExpr);
    if (arrField != null && arrField.isArrayRef && (member == 'len' || member == 'capacity')) {
      final p = _conv(_expr(baseExpr), 'ptr');
      _nullCheck(p.v, "field '${(baseExpr as MemberAccessNode).member}'");
      if (cleanName(arrField.type) == 'string' && member == 'len' && !arrField.refElems) {
        return _strlen(p.v);
      }
      return _headerLen(p.v);
    }
    if (member == 'capacity') {
      if (baseExpr is VarAccessNode &&
          (affineState.containsKey(baseExpr.name) ||
              typeOf(baseExpr.name, const TypeInfo('', false)).isPtr)) {
        final p = _conv(_expr(baseExpr), 'ptr');
        _globalRefCheck(baseExpr, p.v);
        return _headerLen(p.v);
      }
      if (baseExpr is MemberAccessNode) {
        final (pT, _) = _getExprType(baseExpr.expr);
        final fDim = fieldOf(cleanName(pT), baseExpr.member).dim;
        return _i32(fDim is List<int> ? fDim.last : ((fDim as int?) ?? 0));
      }
      final arrName = baseExpr.nodeName ?? '';
      if (arrayDims.containsKey(arrName)) return _i32(arrayDims[arrName]!.last);
      return _i32(arrayLens[arrName] ?? 0);
    }
    if (member == 'len') {
      final arrName = baseExpr.nodeName ?? '';
      final t = typeOf(arrName, const TypeInfo('', false));
      final isDynamic = t.isPtr || affineState.containsKey(arrName);
      if (isDynamic && (t.name != 'string' || t.refElems)) {
        final p = _conv(_expr(baseExpr), 'ptr');
        _globalRefCheck(baseExpr, p.v);
        return _headerLen(p.v);
      }
      if (t.name == 'string') return _strlen(_stringAddr(arrName));
      if (baseExpr is VarAccessNode) return _i32(arrayLens[baseExpr.name] ?? 0);
      if (baseExpr is MemberAccessNode) {
        final (parentT, _) = _getExprType(baseExpr.expr);
        final fDim = fieldOf(cleanName(parentT), baseExpr.member).dim;
        return _i32(fDim is List<int> ? fDim.first : ((fDim as int?) ?? 0));
      }
    }
    // A method of a type, named through the type: its address
    if (baseExpr is VarAccessNode &&
        structs.containsKey(baseExpr.name) &&
        !locals.containsKey(baseExpr.name) &&
        !globals.contains(baseExpr.name) &&
        !boundAddrs.containsKey(baseExpr.name)) {
      return _V(_fnName('${baseExpr.name}_$member'), 'ptr');
    }
    final (tName, _) = _getExprType(baseExpr);
    final f = fieldOf(cleanName(tName), member);
    final (addr, vol) = _lvalue(expr);
    return _load(addr, f.type, f.isPtr, volatile: vol);
  }

  /// The address of the characters of string variable [name].
  String _stringAddr(String name) {
    if (boundAddrs.containsKey(name)) return _addrPtr('${boundAddrs[name]}');
    final t = typeOf(name);
    final fixed = arrayDims.containsKey(name) || arrayLens.containsKey(name);
    final addr = locals.containsKey(name) ? _slots[name]! : _globalName(name);
    if (t.isRef || t.isPtr || !fixed) return _val('load ptr, ptr $addr');
    return addr;
  }

  _V _strlen(String ptr) {
    _declare('declare i64 @strlen(ptr)');
    final n = _val('call i64 @strlen(ptr $ptr)');
    return _V(_val('trunc i64 $n to i32'), 'i32');
  }

  /// Length of [baseExpr] as an open array argument without an end.
  _V _arrayLen(AstNode baseExpr) {
    final baseName = baseExpr.nodeName ?? '';
    if (baseName.isNotEmpty && openArrays.contains(baseName)) {
      return _load(_slots['${baseName}__len']!, 'u32', false);
    }
    if (baseExpr is MemberAccessNode) {
      final (parentT, _) = _getExprType(baseExpr.expr);
      final fDim = fieldOf(cleanName(parentT), baseExpr.member).dim;
      return _i32(fDim is List<int> ? fDim.first : ((fDim as int?) ?? 0));
    }
    if (cleanType(_getExprType(baseExpr).$1) == 'string') return _strlen(_stringAddr(baseName));
    return _i32(arrayLens[baseName] ?? 0);
  }

  // ------------------------------------------------------------ operators

  _V _binary(BinaryOpNode expr) {
    if (expr.op == '&&' || expr.op == '||') {
      final isAnd = expr.op == '&&';
      final rhsB = _newBlock(isAnd ? 'and.rhs' : 'or.rhs');
      final endB = _newBlock(isAnd ? 'and.end' : 'or.end');
      final l = _truth(_expr(expr.left));
      final from = _currentBlock();
      _terminator(isAnd
          ? 'br i1 $l, label %$rhsB, label %$endB'
          : 'br i1 $l, label %$endB, label %$rhsB');
      _body.add('$rhsB:');
      _terminated = false;
      final r = _truth(_expr(expr.right));
      final rFrom = _currentBlock();
      _br(endB);
      _body.add('$endB:');
      _terminated = false;
      final phi = _val('phi i1 [ ${isAnd ? 'false' : 'true'}, %$from ], [ $r, %$rFrom ]');
      return _fromBool(phi);
    }
    if (expr.op == '=') return _assign(expr);
    final l = _expr(expr.left);
    final r = _expr(expr.right);
    // Floating point: done in the operands' type (an untyped constant takes
    // the other side's)
    final lf = _floatTypeOf(expr.left);
    final rf = _floatTypeOf(expr.right);
    if (lf != null || rf != null) {
      final t = lf != null && lf != 'float' ? lf : (rf != null && rf != 'float' ? rf : 'f64');
      return _arith(expr.op, l, r, false, fty: t == 'f32' ? 'float' : 'double');
    }
    return _arith(expr.op, l, r, _isSignedBinary(expr));
  }

  /// The label of the block being generated.
  String _currentBlock() {
    for (var i = _body.length - 1; i >= 0; i--) {
      final s = _body[i];
      if (!s.startsWith(' ') && s.endsWith(':')) return s.substring(0, s.length - 1);
    }
    return 'entry';
  }

  /// `l op r` for an arithmetic, bitwise, shift or comparison operator.
  _V _arith(String op, _V l, _V r, bool signed, {String? fty}) {
    if (fty == null && (_isFloatTy(l.ty) || _isFloatTy(r.ty))) {
      fty = _isFloatTy(l.ty) ? l.ty : r.ty;
    }
    if (fty != null) {
      final a = _conv(l, fty).v;
      final b = _conv(r, fty).v;
      const fcmp = {'==': 'oeq', '!=': 'une', '<': 'olt', '<=': 'ole', '>': 'ogt', '>=': 'oge'};
      if (fcmp.containsKey(op)) return _fromBool(_val('fcmp ${fcmp[op]} $fty $a, $b'));
      const inst = {'+': 'fadd', '-': 'fsub', '*': 'fmul', '/': 'fdiv'};
      return _V(_val('${inst[op]} $fty $a, $b'), fty);
    }
    const cmp = {
      '==': ('eq', 'eq'),
      '!=': ('ne', 'ne'),
      '<': ('ult', 'slt'),
      '<=': ('ule', 'sle'),
      '>': ('ugt', 'sgt'),
      '>=': ('uge', 'sge'),
    };
    if (cmp.containsKey(op) && (l.isPtr || r.isPtr)) {
      final c = _val('icmp ${cmp[op]!.$1} ptr ${_conv(l, 'ptr').v}, ${_conv(r, 'ptr').v}');
      return _fromBool(c);
    }
    if (l.isPtr) l = _conv(l, 'i64');
    if (r.isPtr) r = _conv(r, 'i64');
    if (op == '<<' || op == '>>') {
      final ty = l.ty;
      final count = _conv(r, ty);
      final masked = _val('and $ty ${count.v}, ${ty == 'i64' ? 63 : 31}');
      final inst = op == '<<' ? 'shl' : (signed ? 'ashr' : 'lshr');
      return _V(_val('$inst $ty ${l.v}, $masked'), ty, l.signed);
    }
    final ty = (l.ty == 'i64' || r.ty == 'i64') ? 'i64' : 'i32';
    final a = _conv(l, ty).v;
    final b = _conv(r, ty).v;
    if (cmp.containsKey(op)) {
      final (u, s) = cmp[op]!;
      return _fromBool(_val('icmp ${signed ? s : u} $ty $a, $b'));
    }
    switch (op) {
      case '+':
        return _V(_val('add $ty $a, $b'), ty, signed);
      case '-':
        return _V(_val('sub $ty $a, $b'), ty, signed);
      case '*':
        return _V(_val('mul $ty $a, $b'), ty, signed);
      case '/':
      case '%':
        return _divide(op == '/', ty, a, b, signed);
      case '&':
        return _V(_val('and $ty $a, $b'), ty, signed);
      case '|':
        return _V(_val('or $ty $a, $b'), ty, signed);
      case '^':
        return _V(_val('xor $ty $a, $b'), ty, signed);
    }
    return _V(a, ty, signed);
  }

  /// Division and remainder as on RISC-V (and Particle): by zero, the
  /// quotient is all ones and the remainder the dividend; the most negative
  /// value divided by -1 is itself, with remainder 0.
  _V _divide(bool quotient, String ty, String a, String b, bool signed) {
    final zero = _val('icmp eq $ty $b, 0');
    var bad = zero;
    if (signed) {
      final minV = ty == 'i64' ? '-9223372036854775808' : '-2147483648';
      final isMin = _val('icmp eq $ty $a, $minV');
      final isM1 = _val('icmp eq $ty $b, -1');
      final ovf = _val('and i1 $isMin, $isM1');
      bad = _val('or i1 $zero, $ovf');
    }
    final safe = _val('select i1 $bad, $ty 1, $ty $b');
    final inst = quotient ? (signed ? 'sdiv' : 'udiv') : (signed ? 'srem' : 'urem');
    final q = _val('$inst $ty $a, $safe');
    // A safe divisor of 1 already gives the overflow case its result
    final onZero = quotient ? '-1' : a;
    return _V(_val('select i1 $zero, $ty $onZero, $ty $q'), ty, signed);
  }

  _V _assign(BinaryOpNode expr) {
    final left = expr.left;
    final right = expr.right;
    final cap = _fixedStringCap(left);
    if (cap != null) {
      final dst = _lvalue(left).$1;
      return _V(_stringCopy(dst, right, cap), 'ptr');
    }
    if (left is MemberAccessNode) {
      final (addr, vol) = _lvalue(left);
      final v = _expr(right);
      final (tName, isPtr) = _getExprType(left);
      _store(addr, v, tName, isPtr, volatile: vol);
      return v;
    }
    var v = _expr(right);
    if (left is ArrayAccessNode) {
      if (_copiesIntoHeapString(left, right)) {
        final what = _storedRefName(right);
        if (what != null) _nullCheck(_conv(v, 'ptr').v, what);
        v = _V(_heapStringCopy(_conv(v, 'ptr').v), 'ptr');
      }
      final (addr, tName, vol) = _elemAddr(left, isWrite: true);
      _store(addr, v, tName, _isRefElement(left), volatile: vol);
      return v;
    }
    if (left is VarAccessNode) {
      final name = left.name;
      if (right is HeapAllocNode || right is HeapArrayAllocNode || right is HeapStringAllocNode) {
        affineState[name] = 'VALID';
        if (right is HeapArrayAllocNode) dynamicArrays.add(name);
      }
      if (right is VarAccessNode && affineState.containsKey(right.name)) {
        affineState[right.name] = 'MOVED';
        affineState[name] = 'VALID';
        if (dynamicArrays.contains(right.name)) dynamicArrays.add(name);
      }
      final t = typeOf(name);
      _store(_varAddr(name)!, v, t.name, t.isPtr || t.isRef, volatile: boundAddrs.containsKey(name));
    }
    return v;
  }

  /// Copies string [src] into the buffer at [dst] of [cap] bytes: at most
  /// cap - 1 characters, then a terminator. Gives [dst].
  String _stringCopy(String dst, AstNode src, int cap) {
    var p = _conv(_expr(src), 'ptr').v;
    final what = _storedRefName(src);
    if (what != null) _nullCheck(p, what);
    _strCopyUsed = true;
    _ins('call void @act.strcopy(ptr $dst, ptr $p, i32 $cap)');
    return dst;
  }

  /// A new heap string holding a copy of the string at [src].
  String _heapStringCopy(String src) {
    final n = _strlen(src);
    final n64 = _val('zext i32 ${n.v} to i64');
    final bytes = _val('add i64 $n64, ${_heapHeader + 1}');
    final base = _calloc('i64 $bytes');
    final cap = _val('add i32 ${n.v}, 1');
    _ins('store i32 $cap, ptr $base');
    final payload = _offset(base, '$_heapHeader');
    _declare('declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)');
    _ins('call void @llvm.memcpy.p0.p0.i64(ptr $payload, ptr $src, i64 $n64, i1 false)');
    return payload;
  }

  // ---------------------------------------------------------------- heap

  String _calloc(String bytes) {
    _declare('declare ptr @calloc(i64, i64)');
    final p = _val('call ptr @calloc(i64 1, $bytes)');
    _allocCheck(p);
    return p;
  }

  void _free(String ptr) {
    _declare('declare void @free(ptr)');
    _ins('call void @free(ptr $ptr)');
  }

  /// A zeroed heap array of [n] elements of [es] bytes; gives the address
  /// of its first element.
  String _newHeapArray(_V n, int es) {
    final n64 = _val('zext i32 ${n.v} to i64');
    final data = _val('mul i64 $n64, $es');
    final bytes = _val('add i64 $data, $_heapHeader');
    final base = _calloc('i64 $bytes');
    _ins('store i32 ${n.v}, ptr $base');
    return _offset(base, '$_heapHeader');
  }

  void _freeHeapArray(String payload) {
    final skip = _val('icmp eq ptr $payload, null');
    final doB = _newBlock('free');
    final endB = _newBlock('free.end');
    _terminator('br i1 $skip, label %$endB, label %$doB');
    _body.add('$doB:');
    _terminated = false;
    _free(_val('getelementptr inbounds i8, ptr $payload, i64 -$_heapHeader'));
    _startBlock(endB);
  }

  _V _genFree(HeapFreeNode expr) {
    final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
    final field = _refField(expr.expr);
    final element = _isRefElement(expr.expr);
    final p = _conv(_expr(expr.expr), 'ptr');
    _globalRefCheck(expr.expr, p.v);
    final stored = _storedRefName(expr.expr);
    if (stored != null) _nullCheck(p.v, stored);
    if (targetVar != null && affineState.containsKey(targetVar)) affineState[targetVar] = 'MOVED';
    final isArr = (field != null && field.isArrayRef) ||
        (element && cleanType(_getExprType(expr.expr).$1) == 'string') ||
        (targetVar != null &&
            (dynamicArrays.contains(targetVar) ||
                arrayDims.containsKey(targetVar) ||
                arrayLens.containsKey(targetVar) ||
                openArrays.contains(targetVar) ||
                cleanType(typeOf(targetVar).name) == 'string'));
    if (isArr) {
      _freeHeapArray(p.v);
    } else {
      _free(p.v);
    }
    if (targetVar != null && (locals.containsKey(targetVar) || globals.contains(targetVar))) {
      _ins('store ptr null, ptr ${_varAddr(targetVar)}');
    } else if (field != null || element) {
      final (addr, _) = _lvalue(expr.expr);
      _ins('store ptr null, ptr $addr');
    }
    return const _V('0', 'i32');
  }

  _V _genResize(HeapArrayResizeNode expr) {
    final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
    final field = _refField(expr.expr);
    Object elemT = 'u32';
    if (targetVar != null) {
      elemT = typeOf(targetVar).name;
    } else if (field != null) {
      elemT = field.type;
    }
    final refElems = targetVar != null ? typeOf(targetVar).refElems : (field?.refElems ?? false);
    final es = refElems ? target.pointerSize : _getElemSize(elemT, false);
    final p = _conv(_expr(expr.expr), 'ptr');
    if (field != null) {
      _nullCheck(p.v, "field '${(expr.expr as MemberAccessNode).member}'");
    } else {
      _globalRefCheck(expr.expr, p.v);
    }
    final n = _conv(_expr(expr.newLenExpr), 'i32');
    final old = _headerLen(p.v);
    final base = _val('getelementptr inbounds i8, ptr ${p.v}, i64 -$_heapHeader');
    final n64 = _val('zext i32 ${n.v} to i64');
    final data = _val('mul i64 $n64, $es');
    final bytes = _val('add i64 $data, $_heapHeader');
    _declare('declare ptr @realloc(ptr, i64)');
    final nb = _val('call ptr @realloc(ptr $base, i64 $bytes)');
    _allocCheck(nb);
    _ins('store i32 ${n.v}, ptr $nb');
    final payload = _offset(nb, '$_heapHeader');
    // New elements start at zero, as allocated ones do
    final grows = _val('icmp ugt i32 ${n.v}, ${old.v}');
    final old64 = _val('zext i32 ${old.v} to i64');
    final oldBytes = _val('mul i64 $old64, $es');
    final tail = _val('getelementptr inbounds i8, ptr $payload, i64 $oldBytes');
    final extra = _val('sub i64 $data, $oldBytes');
    final len = _val('select i1 $grows, i64 $extra, i64 0');
    _declare('declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)');
    _ins('call void @llvm.memset.p0.i64(ptr align 1 $tail, i8 0, i64 $len, i1 false)');
    if (targetVar != null && (locals.containsKey(targetVar) || globals.contains(targetVar))) {
      _ins('store ptr $payload, ptr ${_varAddr(targetVar)}');
    } else if (field != null) {
      final (addr, _) = _lvalue(expr.expr);
      _ins('store ptr $payload, ptr $addr');
    }
    return _V(payload, 'ptr');
  }

  // --------------------------------------------------------------- calls

  _V _genTrap(int n) {
    _declare('declare void @exit(i32) #2');
    _ins('call void @exit(i32 $n)');
    _terminator('unreachable');
    return const _V('0', 'i32');
  }

  _V _call(CallNode expr) {
    if (expr.name == 'trap' && expr.args.length == 1 && !funcSignatures.containsKey('trap')) {
      return _genTrap(_evalConstExpr(expr.args[0]));
    }
    if (_isMemoryBuiltin(expr)) return _memoryBuiltin(expr);
    final cv = _callValue(expr);
    if (cv != null) {
      final (callee, fnT, args) = cv;
      final (pTypes, rt) = fnTypes[fnT]!;
      final fp = _conv(_expr(callee), 'ptr');
      final sigs = [for (final p in pTypes) ParamSig(cleanName(p), false, false)];
      final ret = _retType(cleanName(rt), false);
      final argv = _argList(args, sigs);
      return _callResult(ret, 'call $ret ${fp.v}(${argv.join(', ')})', rt, false);
    }
    if (expr.name.startsWith('__METHOD__')) return _methodCall(expr);

    final isFnVar = locals.containsKey(expr.name) ||
        globals.contains(expr.name) ||
        boundAddrs.containsKey(expr.name);
    if (isFnVar) {
      final fnT = typeOf(expr.name).name;
      final List<ParamSig> sigs;
      String ret;
      if (fnTypes.containsKey(fnT)) {
        final (pTypes, rt) = fnTypes[fnT]!;
        sigs = [for (final p in pTypes) ParamSig(cleanName(p), false, false)];
        ret = _retType(cleanName(rt), false);
      } else {
        sigs = [for (final _ in expr.args) const ParamSig('u32', false, false)];
        ret = 'i32';
      }
      final args = _argList(expr.args, sigs);
      final fp = _varValue(expr.name);
      return _callResult(ret, 'call $ret ${fp.v}(${args.join(', ')})',
          fnTypes.containsKey(fnT) ? fnTypes[fnT]!.$2 : 'u32', false);
    }
    final sig = funcSignatures[expr.name]!;
    if (sig.isExtern) return _externCall(expr, sig);
    final ret = _retType(sig.retType, sig.retPtr);
    final args = _argList(expr.args, sig.params);
    return _callResult(ret, 'call $ret ${_fnName(expr.name)}(${args.join(', ')})', sig.retType, sig.retPtr);
  }

  _V _callResult(String ret, String call, Object retType, bool retPtr) {
    if (ret == 'void') {
      _ins(call);
      return const _V('0', 'i32');
    }
    final v = _val(call);
    return _V(v, ret, ret.startsWith('i') && _isSignedName(cleanName(retType)) && !retPtr);
  }

  _V _methodCall(CallNode expr) {
    final mName = expr.name.replaceAll('__METHOD__', '');
    final rcvNode = expr.args[0];
    final sName = cleanName(_getExprType(rcvNode).$1);
    var (targetFunc, embedOffset) = _resolveMethod(sName, mName);
    targetFunc ??= '${sName}_$mName';
    String rcv;
    if (rcvNode is CallNode) {
      rcv = _conv(_expr(rcvNode), 'ptr').v;
    } else if (_storedRefName(rcvNode) != null) {
      rcv = _conv(_expr(rcvNode), 'ptr').v;
      _nullCheck(rcv, _storedRefName(rcvNode)!);
      rcv = _offset(rcv, '$embedOffset');
    } else {
      rcv = _offset(_lvalue(rcvNode).$1, '$embedOffset');
    }
    final sig = funcSignatures[targetFunc]!;
    final args = <String>['ptr $rcv'];
    if (sig.params.isNotEmpty && sig.params.first.isOpen) {
      final rcvName = rcvNode.nodeName;
      _V len;
      if (rcvName != null && openArrays.contains(rcvName)) {
        len = _load(_slots['${rcvName}__len']!, 'u32', false);
      } else if (rcvName != null && arrayDims.containsKey(rcvName)) {
        len = _i32(arrayDims[rcvName]!.last);
      } else {
        len = _i32(arrayLens[rcvName] ?? 0);
      }
      args.add('i32 ${_conv(len, 'i32').v}');
    }
    args.addAll(_argList(expr.args.sublist(1), sig.params.length > 1 ? sig.params.sublist(1) : const []));
    final ret = _retType(sig.retType, sig.retPtr);
    return _callResult(ret, 'call $ret ${_fnName(targetFunc)}(${args.join(', ')})', sig.retType, sig.retPtr);
  }

  /// The named values of `T.create(...)`, stored into the new value [p].
  void _genCreateValues(HeapAllocNode expr, String p) {
    final t = cleanName(expr.typeName);
    for (var i = 0; i < expr.args.length; i++) {
      final v = expr.args[i];
      final slot = _fieldSlot(t, expr.fieldPaths[i]);
      final at = slot.offset == 0 ? p : _offset(p, '${slot.offset}');
      if (slot.stringCap != null) {
        // The value is zeroed, so the terminator is already there
        final text = (v as StringLitNode).val;
        _declare('declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)');
        _ins('call void @llvm.memcpy.p0.p0.i64(ptr $at, ptr ${_stringConst(text)}, '
            'i64 ${text.length}, i1 false)');
        continue;
      }
      var val = _expr(v);
      if (cleanName(slot.type) == 'bool' && !slot.isRef) val = _fromBool(_truth(val));
      _store(at, val, slot.type, slot.isRef);
    }
  }

  /// `dst.copyFrom(src)`: copies the bytes of a record.
  _V _genCopyFrom(CallNode expr) {
    final t = cleanName(_getExprType(expr.args[0]).$1);
    final sig = ParamSig(t, false, false);
    final src = _argValues(expr.args[1], sig).single.substring(4);
    final dst = _argValues(expr.args[0], sig).single.substring(4);
    _declare('declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)');
    _ins('call void @llvm.memmove.p0.p0.i64(ptr $dst, ptr $src, i64 ${structs[t]!.size}, i1 false)');
    return const _V('0', 'i32');
  }

  /// `T(x)`: truncates to the width of `T` and extends by its signedness;
  /// a wider result extends by the operand's signedness.
  _V _genConvert(ConvertNode e) {
    final v = _expr(e.expr);
    final t = e.typeName;
    final signed = _isSignedName(t);
    if (t == 'f32' || t == 'f64') return _conv(v, t == 'f32' ? 'float' : 'double');
    if (_isFloatTy(v.ty)) {
      // To an integer: toward zero (through 64 bits, so that every u32 and
      // negative value fits), then to the width of T
      if (t == 'bool') return _fromBool(_val('fcmp une ${v.ty} ${v.v}, 0.0'));
      final wide = _V(_val('${t == 'u64' ? 'fptoui' : 'fptosi'} ${v.ty} ${v.v} to i64'), 'i64', signed);
      if (t == 'u64' || t == 's64') return _V(wide.v, 'i64', signed);
      final w32 = _V(_val('trunc i64 ${wide.v} to i32'), 'i32', signed);
      if (t == 'u32' || t == 's32') return w32;
      final small = t.endsWith('8') ? 'i8' : 'i16';
      final tr = _val('trunc i32 ${w32.v} to $small');
      return _V(_val('${signed ? 'sext' : 'zext'} $small $tr to i32'), 'i32', signed);
    }
    switch (t) {
      case 'bool':
        final w = v.isPtr ? _conv(v, 'i64') : v;
        final b = _val('icmp ne ${w.ty} ${w.v}, 0');
        return _V(_val('zext i1 $b to i32'), 'i32');
      case 'u8' || 's8' || 'u16' || 's16':
        final small = t.endsWith('8') ? 'i8' : 'i16';
        final w = _conv(v, 'i32');
        final tr = _val('trunc i32 ${w.v} to $small');
        return _V(_val('${signed ? 'sext' : 'zext'} $small $tr to i32'), 'i32', signed);
      case 'u64' || 's64':
        return _V(_conv(v, 'i64').v, 'i64', signed);
      default:
        return _V(_conv(v, 'i32').v, 'i32', signed);
    }
  }

  _V _memoryBuiltin(CallNode expr) {
    final addr = _conv(_expr(expr.args[0]), 'i64');
    final p = _addrPtr(addr.v);
    switch (expr.name) {
      case 'peek8':
      case 'peek16':
      case 'peek32':
        final ty = 'i${expr.name.substring(4)}';
        final v = _val('load volatile $ty, ptr $p');
        return ty == 'i32' ? _V(v, 'i32') : _V(_val('zext $ty $v to i32'), 'i32');
      case 'poke8':
      case 'poke16':
      case 'poke32':
        final v = _expr(expr.args[1]);
        final ty = 'i${expr.name.substring(4)}';
        final cv = _conv(v.isPtr ? _conv(v, 'i64') : v, ty);
        _ins('store volatile $ty ${cv.v}, ptr $p');
        return const _V('0', 'i32');
      default:
        return _V(_val('call i32 $p()'), 'i32');
    }
  }

  /// The LLVM arguments for [args] passed to parameters [sigs].
  List<String> _argList(List<AstNode> args, List<ParamSig> sigs) => [
        for (var i = 0; i < args.length; i++)
          ..._argValues(args[i], i < sigs.length ? sigs[i] : const ParamSig('u32', false, false))
      ];

  List<String> _argValues(AstNode arg, ParamSig p) {
    if (p.isOpen && p.openRank > 1) {
      // An array of more dimensions: its address, then each length
      final name = arg.nodeName;
      if (arg is VarAccessNode && openRanks.containsKey(name)) {
        return [
          'ptr ${_val('load ptr, ptr ${_slots[name]}')}',
          for (var k = 0; k < p.openRank; k++) 'i32 ${_openLen(name!, k).v}'
        ];
      }
      final dims = _fixedDimsOf(arg)!;
      return ['ptr ${_lvalue(arg).$1}', for (final d in dims) 'i32 $d'];
    }
    if (p.isOpen) {
      final (ptr, len) = _openArg(arg);
      return ['ptr $ptr', 'i32 ${_conv(len, 'i32').v}'];
    }
    if (p.type != null && p.type!.isNotEmpty && structs.containsKey(p.type) && !p.isPtr) {
      if (_storedRefName(arg) != null) {
        final v = _conv(_expr(arg), 'ptr').v;
        _nullCheck(v, _storedRefName(arg)!);
        return ['ptr $v'];
      }
      return ['ptr ${_lvalue(arg).$1}'];
    }
    final ty = _regTy(p.type, p.isPtr);
    var v = _conv(_expr(arg), ty);
    if (cleanName(p.type) == 'bool' && !p.isPtr) v = _fromBool(_truth(v));
    return ['$ty ${v.v}'];
  }

  /// An open array argument: the address of its first element and its
  /// length.
  (String, _V) _openArg(AstNode arg) {
    if (arg is SliceNode) {
      final baseExpr = arg.base;
      final baseName = baseExpr.nodeName;
      final (elemT, _) = _getExprType(baseExpr);
      final es = _getElemSize(elemT, false);
      var ptr = baseName != null && openArrays.contains(baseName)
          ? _val('load ptr, ptr ${_slots[baseName]}')
          : _lvalue(baseExpr).$1;
      final s = arg.startExpr;
      final e = arg.endExpr;
      _V? start;
      if (s != null) {
        start = _conv(_expr(s), 'i32');
        final s64 = _val('zext i32 ${start.v} to i64');
        ptr = _val('getelementptr inbounds i8, ptr $ptr, i64 ${es == 1 ? s64 : _val('mul i64 $s64, $es')}');
      }
      _V len;
      if (e == null) {
        len = _conv(_arrayLen(baseExpr), 'i32');
        if (start != null) len = _V(_val('sub i32 ${len.v}, ${start.v}'), 'i32');
      } else {
        len = _conv(_expr(e), 'i32');
        if (start != null) {
          final d = _val('sub i32 ${len.v}, ${start.v}');
          final neg = _val('icmp slt i32 $d, 0');
          len = _V(_val('select i1 $neg, i32 0, i32 $d'), 'i32');
        }
      }
      return (ptr, len);
    }
    final argName = arg.nodeName;
    if (argName != null && openArrays.contains(argName)) {
      return (
        _val('load ptr, ptr ${_slots[argName]}'),
        _load(_slots['${argName}__len']!, 'u32', false)
      );
    }
    if (argName != null &&
        arg is VarAccessNode &&
        typeOf(argName).isPtr &&
        !arrayDims.containsKey(argName) &&
        !arrayLens.containsKey(argName) &&
        (locals.containsKey(argName) || globals.contains(argName))) {
      final p = _conv(_expr(arg), 'ptr').v;
      _globalRefCheck(arg, p);
      return (p, _headerLen(p));
    }
    if (_refField(arg)?.isArrayRef == true) {
      final p = _conv(_expr(arg), 'ptr').v;
      _nullCheck(p, "field '${(arg as MemberAccessNode).member}'");
      return (p, _headerLen(p));
    }
    if (arg is ArrayAccessNode && cleanType(_getExprType(arg).$1) == 'string') {
      // One string of an array: its address and its length
      final p = _isRefElement(arg) ? _conv(_expr(arg), 'ptr').v : _lvalue(arg).$1;
      if (_isRefElement(arg)) _nullCheck(p, _storedRefName(arg)!);
      return (p, _strlen(p));
    }
    final addr = arg is StringLitNode ? _stringConst(arg.val) : _lvalue(arg).$1;
    final (argT, _) = _getExprType(arg);
    final refElems = _isRefArray(arg);
    final row = _openRow(arg);
    if (row != null) return (addr, _openLen(row.$1, row.$2));
    if (cleanType(argT) == 'string' && !refElems) return (addr, _strlen(addr));
    return (addr, _i32(_fixedArgLength(arg)));
  }

  /// A call to a C function, with C's argument promotions after `...`.
  _V _externCall(CallNode expr, FuncSig sig) {
    final f = _funcDecls.firstWhere((d) => d.name == expr.name && d.isExtern);
    final args = <String>[];
    for (var i = 0; i < expr.args.length; i++) {
      final arg = expr.args[i];
      if (i < f.params.length) {
        final p = f.params[i];
        final cty = _cType(p.type, p.isPtr, withAttr: false);
        final c = cleanName(p.type);
        if (structs.containsKey(c) && !p.isPtr) {
          args.add('ptr ${_lvalue(arg).$1}');
          continue;
        }
        var v = _expr(arg);
        if (cty == 'i1') {
          args.add('i1 ${_truth(v)}');
          continue;
        }
        v = _conv(v.isPtr && cty != 'ptr' ? _conv(v, 'i64') : v, cty);
        args.add('${_cType(p.type, p.isPtr)} ${v.v}');
      } else {
        // After '...': narrower integers are already int; a bool is 0 or 1;
        // an f32 is passed as a double, as C does
        var v = _expr(arg);
        if (v.ty == 'float') v = _conv(v, 'double');
        args.add('${v.ty} ${v.v}');
      }
    }
    final ret = _cType(f.retType, f.retPtr, withAttr: false);
    final fnTy = f.isVariadic
        ? '$ret (${[for (final p in f.params) _cType(p.type, p.isPtr, withAttr: false), '...'].join(', ')})'
        : ret;
    final call = 'call $fnTy @${f.name}(${args.join(', ')})';
    if (ret == 'void') {
      _ins(call);
      return const _V('0', 'i32');
    }
    final r = _val(call);
    final rc = cleanName(f.retType);
    if (ret == 'i1') return _fromBool(r);
    if (ret == 'i8' || ret == 'i16') {
      final s = _isSignedName(rc);
      return _V(_val('${s ? 'sext' : 'zext'} $ret $r to i32'), 'i32', s);
    }
    return _V(r, ret, _isSignedName(rc));
  }
}
