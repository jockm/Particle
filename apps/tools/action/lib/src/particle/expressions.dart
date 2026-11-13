part of '../compiler.dart';

extension _Expressions on CodeGen {
  void _emitLvalueAddr(AstNode node, [int targetReg = 14]) {
    if (node is VarAccessNode) {
      final name = node.name;
      final isRef = typeOf(name).isRef;
      if (boundAddrs.containsKey(name)) {
        emitImmediate(targetReg, boundAddrs[name]!);
      } else if (locals.containsKey(name)) {
        final offset = stackOffset - locals[name]!;
        emitImmediate(targetReg, offset);
        emit('ADD     R$targetReg, R15', "Address of local '$name'");
        if (isRef) {
          emit('LD32    R$targetReg, (R$targetReg)', "Dereference ref param '$name'");
        }
      } else {
        emit('LOAD32  R$targetReg, _$name');
        if (isRef) {
          emit('LD32    R$targetReg, (R$targetReg)', "Dereference global reference '$name'");
          if (referenceCheck) backend.genNullTrap(targetReg, "global '$name'");
        }
      }
    } else if (node is MemberAccessNode) {
      final baseExpr = node.expr;
      final member = node.member;
      final (tName, baseIsPtr) = _getExprType(baseExpr);
      final sName = cleanName(tName);
      final f = fieldOf(sName, member);
      _emitLvalueAddr(baseExpr, targetReg);
      if (baseIsPtr) {
        emit('LD32    R$targetReg, (R$targetReg)',
            "Dereference pointer base '${baseExpr.nodeName ?? ''}'");
        _checkStoredRef(baseExpr, targetReg);
      }
      if (f.offset > 0) {
        if (targetReg == 14) {
          emitImmediateKeepR14(2, f.offset);
        } else {
          emitImmediate(2, f.offset);
        }
        emit('ADD     R$targetReg, R2', "Offset ${f.offset} for field '$member'");
      }
    } else if (node is ArrayAccessNode) {
      _emitArrayElemAddr(node, targetReg, 2);
    } else {
      genExpr(node, targetReg);
    }
  }

  (Object, int) _emitArrayElemAddr(ArrayAccessNode node,
      [int addrReg = 14, int idxScratch = 2, bool isWrite = false]) {
    // 1. Flatten nested ArrayAccessNodes from outermost to innermost (for a
    // character of a string in an array of references, the base is the
    // element)
    final (baseNode, idxList) = _splitIndex(node);
    final baseName = baseNode.nodeName;
    final refElems = _isRefArray(baseNode);
    final isOpen = baseName != null && openArrays.contains(baseName);
    if (isOpen && openRanks.containsKey(baseName)) {
      return _emitOpenElemAddr(baseNode, baseName, idxList, addrReg, idxScratch, isWrite);
    }

    var dims = arrayDims[baseName] ?? <int>[];
    if (dims.isEmpty && baseName != null && arrayLens.containsKey(baseName)) {
      dims = [arrayLens[baseName]!];
    } else if (dims.isEmpty && baseNode is MemberAccessNode) {
      final (pT, _) = _getExprType(baseNode.expr);
      final sName = cleanName(pT);
      final mDim = fieldOf(sName, baseNode.member).dim;
      if (mDim is List<int>) {
        dims = mDim;
      } else if (mDim is int) {
        dims = [mDim];
      }
    }

    // 2. Evaluate flat offset across indices
    // We accumulate into R{idx_scratch}
    for (var dimIdx = 0; dimIdx < idxList.length; dimIdx++) {
      final idxExpr = idxList[dimIdx];
      if (dimIdx > 0) {
        emit('PUSH32  R$idxScratch', 'Preserve accumulated flat index');
        stackOffset += 4;
      }

      // Evaluate current index into R3
      genExpr(idxExpr, 3);

      // Runtime Bounds Check with TRAP 15 (use R13 to avoid clobbering)
      if (boundsCheck) {
        final lblInBounds = newLabel('in_bounds');
        if (isOpen && dimIdx == 0) {
          final lenOff = stackOffset - locals['${baseName}__len']!;
          emitImmediate(14, lenOff);
          emit('ADD     R14, R15');
          emit('LD32    R14, (R14)', "Load dynamic length for '$baseName'");
          emit('LD      R13, R3', 'Preserve index for bounds check');
          emit('SLT     R13, R14', 'Check $baseName[i] < dynamic length');
          emit('FBRA.NZ R13, $lblInBounds', 'Branch if within array bounds');
          emit('TRAP    15', 'Open array out-of-bounds trap ($baseName)');
          emitLabel(lblInBounds);
        } else if (dimIdx == 0 && _refField(baseNode)?.isArrayRef == true) {
          // Heap array held in a field: check against its header
          final field = (baseNode as MemberAccessNode).member;
          emit('PUSH32  R3', 'Preserve index');
          stackOffset += 4;
          _emitLvalueAddr(baseNode, 14);
          emit('POP32   R3', 'Restore index');
          stackOffset -= 4;
          emit('LD32    R14, (R14)', "Load heap pointer for field '$field'");
          _checkFieldRef(field, 14);
          emit('SUB     R14, 4', 'Point to prefix header');
          emit('LD32    R14, (R14)', 'Read dynamic bound from prefix header');
          final (baseT, _) = _getExprType(baseNode);
          if (isWrite && !refElems && cleanType(baseT) == 'string') {
            emit('SUB     R14, 1', 'Reserve null terminator for dynamic string write');
          }
          emit('LD      R13, R3', 'Preserve index for bounds check');
          emit('SLT     R13, R14', 'Check dynamic $field[i] < bound');
          emit('FBRA.NZ R13, $lblInBounds', 'Branch if within array bounds');
          emit('TRAP    15', 'Dynamic heap out-of-bounds trap ($field)');
          emitLabel(lblInBounds);
        } else if (baseName != null &&
            (affineState.containsKey(baseName) || _isHeapArrayRef(baseName)) &&
            dimIdx == 0) {
          // Dynamic heap array / string bounds check via prefix header at (base - 4)
          final isGlobal = !locals.containsKey(baseName);
          if (!isGlobal) {
            final lenOff = stackOffset - locals[baseName]!;
            emitImmediate(14, lenOff);
            emit('ADD     R14, R15');
          } else {
            emit('LOAD32  R14, _$baseName', "Address of global '$baseName'");
          }
          emit('LD32    R14, (R14)', "Load heap pointer for '$baseName'");
          if (isGlobal && referenceCheck) {
            backend.genNullTrap(14, "global '$baseName'");
          }
          emit('SUB     R14, 4', 'Point to prefix header');
          emit('LD32    R14, (R14)', 'Read dynamic bound from prefix header');
          final (baseT, _) = _getExprType(baseNode);
          if (isWrite && !refElems && cleanType(baseT) == 'string') {
            emit('SUB     R14, 1', 'Reserve null terminator for dynamic string write');
          }
          emit('LD      R13, R3', 'Preserve index for bounds check');
          emit('SLT     R13, R14', 'Check dynamic $baseName[i] < bound');
          emit('FBRA.NZ R13, $lblInBounds', 'Branch if within array bounds');
          emit('TRAP    15', 'Dynamic heap out-of-bounds trap ($baseName)');
          emitLabel(lblInBounds);
        } else if (dimIdx < dims.length) {
          final arrDim = dims[dimIdx];
          var bnd = arrDim;
          final (baseT, _) = _getExprType(baseNode);
          if (isWrite &&
              !refElems &&
              cleanType(baseT) == 'string' &&
              dimIdx == idxList.length - 1) {
            bnd = arrDim - 1 > 0 ? arrDim - 1 : 0;
          }
          emitImmediate(14, bnd);
          emit('LD      R13, R3', 'Preserve index for bounds check');
          emit('SLT     R13, R14', 'Check index < $bnd');
          emit('FBRA.NZ R13, $lblInBounds', 'Branch if within array bounds');
          emit('TRAP    15', 'Array out-of-bounds trap (${baseName ?? 'None'})');
          emitLabel(lblInBounds);
        }
      }

      if (dimIdx == 0) {
        emit('LD      R$idxScratch, R3', 'Initialize flat index');
      } else {
        emit('POP32   R$idxScratch', 'Restore accumulated flat index');
        stackOffset -= 4;
        final nextDim = dimIdx < dims.length ? dims[dimIdx] : 1;
        emitImmediate(14, nextDim);
        emit('MULL    R$idxScratch, R14', 'Multiply by dimension $nextDim');
        emit('ADD     R$idxScratch, R3', 'Add current dimension index');
      }
    }

    // 4. Scale index by remaining element/slice size. Done before the base
    //    address is computed: a stride of 16 or more needs a LOAD macro,
    //    which would clobber a base held in R14.
    final (baseType, _) = _getExprType(baseNode);
    final leafElemSz = _elemSizeOfBase(baseNode, baseType);
    var remainingStride = 1;
    for (final d in dims.skip(idxList.length)) {
      remainingStride *= d;
    }
    final stride = leafElemSz * remainingStride;

    if (stride == 2) {
      emit('SHIFTL  R$idxScratch, 1', 'Scale index by 2');
    } else if (stride == 4) {
      emit('SHIFTL  R$idxScratch, 2', 'Scale index by 4');
    } else if (stride == 8) {
      emit('SHIFTL  R$idxScratch, 3', 'Scale index by 8');
    } else if (stride != 1) {
      final strideReg = addrReg == 14 ? 13 : 14;
      emitImmediate(strideReg, stride);
      emit('MULL    R$idxScratch, R$strideReg', 'Scale index by stride $stride');
    }

    // Save accumulated index before computing base address (which may clobber scratch registers like R2)
    emit('PUSH32  R$idxScratch', 'Save flat index across base address computation');
    stackOffset += 4;

    // 3. Compute Base Address into addr_reg
    if (isOpen) {
      final offset = stackOffset - locals[baseName]!;
      emitImmediate(addrReg, offset);
      emit('ADD     R$addrReg, R15');
      emit('LD32    R$addrReg, (R$addrReg)', "Dereference open array base '$baseName'");
    } else if (baseName != null && boundAddrs.containsKey(baseName)) {
      emitImmediate(addrReg, boundAddrs[baseName]!);
    } else if (baseName != null && locals.containsKey(baseName)) {
      final offset = stackOffset - locals[baseName]!;
      emitImmediate(addrReg, offset);
      emit('ADD     R$addrReg, R15', "Base of local array '$baseName'");
      final tInfo = typeOf(baseName);
      final isLocalFixed =
          arrayDims.containsKey(baseName) || arrayLens.containsKey(baseName);
      if (tInfo.isRef || tInfo.isPtr || !isLocalFixed) {
        emit('LD32    R$addrReg, (R$addrReg)',
            "Dereference pointer/param base '$baseName'");
      }
    } else if (baseName != null && globals.contains(baseName)) {
      emit('LOAD32  R$addrReg, _$baseName', "Base of global array '$baseName'");
      final tInfo = typeOf(baseName);
      if (tInfo.isPtr && !arrayDims.containsKey(baseName) && !arrayLens.containsKey(baseName)) {
        // A global array reference (`T g[]`) holds the heap address
        emit('LD32    R$addrReg, (R$addrReg)',
            "Dereference global array reference '$baseName'");
        // With bounds checks on, the bounds check above already did this
        if (referenceCheck && !boundsCheck) {
          backend.genNullTrap(addrReg, "global '$baseName'");
        }
      }
    } else if (baseNode is MemberAccessNode) {
      _emitLvalueAddr(baseNode, addrReg);
      if (_refField(baseNode)?.isArrayRef == true) {
        emit('LD32    R$addrReg, (R$addrReg)',
            "Dereference heap array field '${baseNode.member}'");
        // With bounds checks on, the bounds check above already did this
        if (!boundsCheck) _checkFieldRef(baseNode.member, addrReg);
      }
    } else {
      genExpr(baseNode, addrReg);
      // A string an array of references points at
      if (_isRefElement(baseNode)) _checkStoredRef(baseNode, addrReg);
    }

    // Restore accumulated index
    emit('POP32   R$idxScratch', 'Restore flat index');
    stackOffset -= 4;

    // 5. Add offset to base address
    emit('ADD     R$addrReg, R$idxScratch', 'Indexed element address');
    // An element of an array of references is one address
    if (refElems) return (baseType, leafElemSz);
    // A string's elements are bytes
    if (cleanType(baseType) == 'string' && idxList.length >= dims.length) {
      return ('u8', 1);
    }
    return (baseType, leafElemSz);
  }

  /// `.len` and `.capacity` of an open array parameter with more than one
  /// dimension, or of one of its rows: the lengths passed in, or for a
  /// string the scan for its terminator. False for anything else.
  bool _genOpenRankMember(AstNode base, String member, int targetReg) {
    final (root, indices) = base is ArrayAccessNode ? _splitIndex(base) : (base, <AstNode>[]);
    final name = root is VarAccessNode ? root.name : null;
    if (name == null || !openRanks.containsKey(name) || !openArrays.contains(name)) return false;
    final rank = openRanks[name]!;
    final isString = cleanType(typeOf(name).name) == 'string';
    final n = indices.length;
    if (member == 'capacity') {
      _emitOpenLen(name, isString ? rank - 1 : n, targetReg);
      return true;
    }
    if (isString && n == rank - 1) {
      // One string of the array: its characters before the terminator
      _emitArrayElemAddr(base as ArrayAccessNode, 14, 2);
      _emitStringScanAt14(null, targetReg);
      return true;
    }
    _emitOpenLen(name, n, targetReg);
    return true;
  }

  /// Loads length [k] of open array parameter [name] (0 is the first
  /// dimension) into [reg].
  void _emitOpenLen(String name, int k, int reg) {
    final off = stackOffset - locals[k == 0 ? '${name}__len' : '${name}__len$k']!;
    emitImmediate(reg, off);
    emit('ADD     R$reg, R15');
    emit('LD32    R$reg, (R$reg)', "Length ${k + 1} of '$name'");
  }

  /// The address of an element (or row) of an open array parameter with
  /// more than one dimension: the flat index is worked out from the
  /// lengths passed in, each index checked against its own.
  (Object, int) _emitOpenElemAddr(AstNode baseNode, String name, List<AstNode> idxList,
      int addrReg, int idxScratch, bool isWrite) {
    final rank = openRanks[name]!;
    final (baseType, _) = _getExprType(baseNode);
    final isString = cleanType(baseType) == 'string';
    for (var dimIdx = 0; dimIdx < idxList.length; dimIdx++) {
      if (dimIdx > 0) {
        emit('PUSH32  R$idxScratch', 'Preserve accumulated flat index');
        stackOffset += 4;
      }
      genExpr(idxList[dimIdx], 3);
      if (boundsCheck) {
        final ok = newLabel('in_bounds');
        _emitOpenLen(name, dimIdx, 14);
        if (isWrite && isString && dimIdx == rank - 1) {
          emit('SUB     R14, 1', 'Reserve the terminator of a string written to');
        }
        emit('LD      R13, R3', 'Preserve index for bounds check');
        emit('SLT     R13, R14', 'Check $name[i] < its length');
        emit('FBRA.NZ R13, $ok', 'Branch if within array bounds');
        emit('TRAP    15', 'Open array out-of-bounds trap ($name)');
        emitLabel(ok);
      }
      if (dimIdx == 0) {
        emit('LD      R$idxScratch, R3', 'Initialize flat index');
      } else {
        emit('POP32   R$idxScratch', 'Restore accumulated flat index');
        stackOffset -= 4;
        _emitOpenLen(name, dimIdx, 14);
        emit('MULL    R$idxScratch, R14', 'Multiply by length ${dimIdx + 1}');
        emit('ADD     R$idxScratch, R3', 'Add current dimension index');
      }
    }
    // A row: skip the elements of the dimensions not indexed
    for (var k = idxList.length; k < rank; k++) {
      _emitOpenLen(name, k, 14);
      emit('MULL    R$idxScratch, R14', 'Times length ${k + 1}');
    }
    final elemSz = isString ? 1 : _getElemSize(baseType, false);
    if (elemSz == 2) {
      emit('SHIFTL  R$idxScratch, 1', 'Scale index by 2');
    } else if (elemSz == 4) {
      emit('SHIFTL  R$idxScratch, 2', 'Scale index by 4');
    } else if (elemSz == 8) {
      emit('SHIFTL  R$idxScratch, 3', 'Scale index by 8');
    } else if (elemSz != 1) {
      final strideReg = addrReg == 14 ? 13 : 14;
      emitImmediate(strideReg, elemSz);
      emit('MULL    R$idxScratch, R$strideReg', 'Scale index by $elemSz');
    }
    emit('PUSH32  R$idxScratch', 'Save flat index across base address computation');
    stackOffset += 4;
    final off = stackOffset - locals[name]!;
    emitImmediate(addrReg, off);
    emit('ADD     R$addrReg, R15');
    emit('LD32    R$addrReg, (R$addrReg)', "Dereference open array base '$name'");
    emit('POP32   R$idxScratch', 'Restore flat index');
    stackOffset -= 4;
    emit('ADD     R$addrReg, R$idxScratch', 'Indexed element address');
    if (isString && idxList.length >= rank) return ('u8', 1);
    return (baseType, elemSz);
  }

  void genExpr(AstNode expr, [int targetReg = 1]) {
    // An operation on constants is evaluated exactly at compile time
    if (_emitFoldedConst(expr, targetReg)) return;
    if (expr is ConvertNode) {
      _genConvert(expr, targetReg);
      return;
    }
    if (expr is CallNode && expr.name == '__copyFrom') {
      _genCopyFrom(expr);
      return;
    }
    if (expr is HeapAllocNode) {
      final cleanT = cleanName(expr.typeName);
      final sz = structSize(cleanT);
      backend.genHeapAlloc(targetReg, sz);
      if (expr.args.isNotEmpty) _genCreateValues(expr, targetReg);
      return;
    } else if (expr is HeapArrayAllocNode) {
      final cleanT = cleanName(expr.typeName);
      final elemSz = expr.refElems ? backend.pointerSize : _getElemSize(cleanT, false);
      genExpr(expr.countExpr, 2);
      backend.genArrayAlloc(targetReg, elemSz, 2);
      return;
    } else if (expr is HeapStringAllocNode) {
      genExpr(expr.capExpr, 2);
      backend.genStringAlloc(targetReg, 2);
      return;
    } else if (expr is HeapFreeNode) {
      final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
      final field = _refField(expr.expr);
      final element = _isRefElement(expr.expr);
      genExpr(expr.expr, 1);
      _checkGlobalRef(expr.expr, 1);
      _checkStoredRef(expr.expr, 1);
      if (targetVar != null && affineState.containsKey(targetVar)) {
        affineState[targetVar] = 'MOVED';
      }
      // Arrays and heap strings carry a 4-byte header below the address
      final isArr = (field != null && field.isArrayRef) ||
          (element && cleanType(_getExprType(expr.expr).$1) == 'string') ||
          (targetVar != null &&
              (dynamicArrays.contains(targetVar) ||
                  arrayDims.containsKey(targetVar) ||
                  arrayLens.containsKey(targetVar) ||
                  openArrays.contains(targetVar) ||
                  cleanType(typeOf(targetVar).name) == 'string'));
      if (isArr) {
        backend.genArrayFree(1);
      } else {
        backend.genHeapFree(1);
      }
      if (targetVar != null && locals.containsKey(targetVar)) {
        final off = stackOffset - locals[targetVar]!;
        emitImmediate(14, off);
        emit('ADD     R14, R15');
        emit('ST32    (R14), R0', "Zero out destroyed affine reference '$targetVar'");
      } else if (targetVar != null && globals.contains(targetVar)) {
        emit('LOAD32  R14, _$targetVar');
        emit('ST32    (R14), R0', "Zero out destroyed global reference '$targetVar'");
      } else if (field != null) {
        _emitLvalueAddr(expr.expr, 14);
        emit('ST32    (R14), R0', "Zero out destroyed reference field '${(expr.expr as MemberAccessNode).member}'");
      } else if (element) {
        _emitLvalueAddr(expr.expr, 14);
        emit('ST32    (R14), R0', 'Zero out destroyed reference element');
      }
      return;
    } else if (expr is HeapArrayResizeNode) {
      final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
      final field = _refField(expr.expr);
      // 1. Determine element size
      Object elemT = 'u32';
      if (targetVar != null) {
        elemT = typeOf(targetVar).name;
      } else if (field != null) {
        elemT = field.type;
      }
      final refElems = targetVar != null ? typeOf(targetVar).refElems : (field?.refElems ?? false);
      final elemSize = refElems ? backend.pointerSize : _getElemSize(elemT, false);

      if (field != null) {
        // The field's address computation may use R2, so load the array
        // pointer first and keep it while the count is evaluated
        genExpr(expr.expr, 1);
        _checkFieldRef((expr.expr as MemberAccessNode).member, 1);
        emit('PUSH32  R1', 'Preserve array pointer');
        stackOffset += 4;
        genExpr(expr.newLenExpr, 2);
        emit('POP32   R1', 'Restore array pointer');
        stackOffset -= 4;
      } else {
        // 2. Evaluate new count into R2
        genExpr(expr.newLenExpr, 2);

        // 3. Load current array pointer into R1
        genExpr(expr.expr, 1);
        _checkGlobalRef(expr.expr, 1);
      }

      // 4. Invoke backend resize (returns updated payload in R1)
      if (refElems) {
        emit('LD      R3, R1');
        emit('SUB     R3, 4', 'Point to prefix header');
        emit('LD32    R3, (R3)', 'Old length');
        emit('PUSH32  R3', 'Keep old length');
        stackOffset += 4;
      }
      backend.genArrayResize(1, 1, elemSize, 2);
      if (refElems) {
        // New references start null: clear elements old length .. new length
        emit('POP32   R3', 'Old length');
        stackOffset -= 4;
        final lblLoop = newLabel('ref_clr');
        final lblDone = newLabel('ref_clr_done');
        emitLabel(lblLoop);
        emit('LD      R13, R3');
        emit('SLT     R13, R2', 'Element below the new length?');
        emit('FBRA.Z  R13, $lblDone');
        emit('LD      R14, R3');
        emit('SHIFTL  R14, 2', 'Element offset');
        emit('ADD     R14, R1');
        emit('ST32    (R14), R0', 'Null reference');
        emit('ADD     R3, 1');
        emit('BBRA    $lblLoop');
        emitLabel(lblDone);
      }

      // 5. Rebind local variable stack slot to new pointer
      if (targetVar != null && locals.containsKey(targetVar)) {
        final off = stackOffset - locals[targetVar]!;
        emitImmediate(14, off);
        emit('ADD     R14, R15');
        emit('ST32    (R14), R1', "Update local reference '$targetVar' after resize");
      } else if (targetVar != null && globals.contains(targetVar)) {
        emit('LOAD32  R14, _$targetVar');
        emit('ST32    (R14), R1', "Update global reference '$targetVar' after resize");
      } else if (field != null) {
        emit('PUSH32  R1', 'Preserve resized pointer');
        stackOffset += 4;
        _emitLvalueAddr(expr.expr, 14);
        emit('POP32   R1', 'Restore resized pointer');
        stackOffset -= 4;
        emit('ST32    (R14), R1',
            "Update reference field '${(expr.expr as MemberAccessNode).member}' after resize");
      }

      if (targetReg != 1) {
        emit('LD      R$targetReg, R1');
      }
      return;
    } else if (expr is HeapArrayFreeNode) {
      final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
      genExpr(expr.expr, 1);
      _checkGlobalRef(expr.expr, 1);
      if (targetVar != null && affineState.containsKey(targetVar)) {
        affineState[targetVar] = 'MOVED';
      }
      backend.genArrayFree(1);
      if (targetVar != null && locals.containsKey(targetVar)) {
        final off = stackOffset - locals[targetVar]!;
        emitImmediate(14, off);
        emit('ADD     R14, R15');
        emit('ST32    (R14), R0', "Zero out destroyed affine array reference '$targetVar'");
      }
      return;
    } else if (expr is ExistsNode) {
      // Check liveness: if VarAccessNode and currently MOVED, we know it was destroyed -> evaluate to 0
      // Otherwise, read value from stack slot and check NEZ
      final inner = expr.expr;
      if (inner is VarAccessNode) {
        final varName = inner.name;
        if (locals.containsKey(varName)) {
          final offset = stackOffset - locals[varName]!;
          emitImmediate(14, offset);
          emit('ADD     R14, R15');
          emit('LD32    R$targetReg, (R14)', "Read reference for .exists() ('$varName')");
        } else if (globals.contains(varName)) {
          emit('LOAD32  R14, _$varName');
          emit('LD32    R$targetReg, (R14)',
              "Read global reference for .exists() ('$varName')");
        } else {
          emitImmediate(targetReg, 0);
        }
      } else {
        genExpr(inner, targetReg);
      }
      emit('NEZ     R$targetReg', 'Check reference != 0 (.exists())');
      return;
    } else if (expr is SizeofNode) {
      final szVal = _evalConstExpr(expr);
      emitImmediate(targetReg, szVal);
      return;
    } else if (expr is IntLitNode) {
      emitImmediate(targetReg, expr.val);
    } else if (expr is MemberAccessNode) {
      _genMemberAccess(expr, targetReg);
    } else if (expr is ArrayAccessNode) {
      final (tName, _) = _emitArrayElemAddr(expr, 14, 2);
      if (_isStringRow(expr)) {
        // One string of a fixed array of them: its address
        if (targetReg != 14) emit('LD      R$targetReg, R14', 'Address of the string');
        return;
      }
      _emitLoadTyped(targetReg, 14, tName, false);
    } else if (expr is VarAccessNode) {
      final name = expr.name;
      if (constants.containsKey(name)) {
        emitImmediate(targetReg, constants[name]!);
        return;
      }
      if (funcSignatures.containsKey(name)) {
        emit('LOAD32  R$targetReg, _$name', "Function address '$name'");
        return;
      }
      final t = typeOf(name);
      if (boundAddrs.containsKey(name)) {
        emitImmediate(14, boundAddrs[name]!);
        if (arrayLens.containsKey(name)) {
          emit('LD      R$targetReg, R14', "Address of bound array '$name'");
        } else {
          _emitLoadTyped(targetReg, 14, t.name, t.isPtr);
        }
      } else if (locals.containsKey(name)) {
        final offset = stackOffset - locals[name]!;
        emitImmediate(14, offset);
        emit('ADD     R14, R15', 'Compute local address');
        if (arrayLens.containsKey(name)) {
          emit('LD      R$targetReg, R14', "Address of local array '$name'");
        } else {
          _emitLoadTyped(targetReg, 14, t.name, t.isPtr);
        }
      } else {
        emit('LOAD32  R14, _$name', "Address of global '$name'");
        if (arrayLens.containsKey(name)) {
          emit('LD      R$targetReg, R14', "Address of global array '$name'");
        } else {
          _emitLoadTyped(targetReg, 14, t.name, t.isPtr);
        }
      }
    } else if (expr is UnaryOpNode) {
      if (expr.op == '-') {
        genExpr(expr.operand, targetReg);
        emit('NEG     R$targetReg');
      } else if (expr.op == '~') {
        genExpr(expr.operand, targetReg);
        emit('NOT     R$targetReg');
      } else if (expr.op == '!') {
        final lblTrue = newLabel('not_true');
        final lblDone = newLabel('not_done');
        genExpr(expr.operand, 1);
        emit('FBRA.Z  R1, $lblTrue');
        emit('LD      R$targetReg, 0');
        emit('FBRA    $lblDone');
        emitLabel(lblTrue);
        emit('LD      R$targetReg, 1');
        emitLabel(lblDone);
      }
    } else if (expr is CompoundAssignNode) {
      // Compound assignment: lhs op= rhs
      final opChar = expr.op.substring(0, expr.op.length - 1); // Strip trailing '='
      genExpr(expr.rhs, 2);
      emit('PUSH32  R2', 'Save compound RHS');
      stackOffset += 4;

      final lhs = expr.lhs;
      if (lhs is VarAccessNode) {
        final name = lhs.name;
        final t = typeOf(name);
        if (boundAddrs.containsKey(name)) {
          emitImmediate(14, boundAddrs[name]!);
        } else if (locals.containsKey(name)) {
          final offset = stackOffset - locals[name]!;
          emitImmediate(14, offset);
          emit('ADD     R14, R15');
        } else {
          emit('LOAD32  R14, _$name');
        }
        _emitLoadTyped(1, 14, t.name, t.isPtr);
        emit('POP32   R2', 'Restore compound RHS');
        stackOffset -= 4;
        _emitBinaryCalc(opChar, 1, 2, signed: _isSignedCompound(t.name, expr.rhs));
        _normalizeBoolResult(t.isPtr ? null : t.name, 1);
        _emitStoreTyped(14, 1, t.name, t.isPtr);
        if (targetReg != 1) {
          emit('LD      R$targetReg, R1');
        }
      } else if (lhs is ArrayAccessNode) {
        final (tName, _) = _emitArrayElemAddr(lhs, 14, 3, true);
        _emitLoadTyped(1, 14, tName, false);
        emit('POP32   R2', 'Restore compound RHS');
        stackOffset -= 4;
        _emitBinaryCalc(opChar, 1, 2, signed: _isSignedCompound(tName, expr.rhs));
        _normalizeBoolResult(tName, 1);
        _emitStoreTyped(14, 1, tName, false);
        if (targetReg != 1) {
          emit('LD      R$targetReg, R1');
        }
      } else if (lhs is MemberAccessNode) {
        final baseExpr = lhs.expr;
        final member = lhs.member;
        final (tName, _) = _getExprType(baseExpr);
        final sName = cleanName(tName);
        final f = fieldOf(sName, member);
        _emitLvalueAddr(baseExpr, 14);
        if (f.offset > 0) {
          emitImmediateKeepR14(3, f.offset);
          emit('ADD     R14, R3');
        }
        _emitLoadTyped(1, 14, f.type, f.isPtr);
        emit('POP32   R2', 'Restore compound RHS');
        stackOffset -= 4;
        _emitBinaryCalc(opChar, 1, 2, signed: _isSignedCompound(f.type, expr.rhs));
        _normalizeBoolResult(f.isPtr ? null : f.type, 1);
        _emitStoreTyped(14, 1, f.type, f.isPtr);
        if (targetReg != 1) {
          emit('LD      R$targetReg, R1');
        }
      }
    } else if (expr is BinaryOpNode) {
      _genBinaryOp(expr, targetReg);
    } else if (expr is StringLitNode) {
      final lbl = newLabel('str');
      strings.add((lbl, expr.val));
      emit('LOAD32  R$targetReg, $lbl', 'Load string address');
    } else if (expr is TrapNode) {
      emit('TRAP    ${expr.trapNum}', 'Trigger Trap #${expr.trapNum}');
      emit('LD      R$targetReg, 0');
    } else if (expr is CallNode) {
      _genCall(expr, targetReg);
    }
  }

  /// The named values of `T.create(...)`, stored into the new value whose
  /// address is in [reg] (kept on the stack while they are computed).
  void _genCreateValues(HeapAllocNode expr, int reg) {
    final t = cleanName(expr.typeName);
    emit('PUSH32  R$reg', 'Keep the new value while its fields are set');
    stackOffset += 4;
    void addressInR14(int off) {
      emit('LD32    R14, (R15)', 'The new value');
      if (off > 0) {
        emitImmediateKeepR14(13, off);
        emit('ADD     R14, R13');
      }
    }

    for (var i = 0; i < expr.args.length; i++) {
      final v = expr.args[i];
      final path = expr.fieldPaths[i];
      final slot = _fieldSlot(t, path);
      if (slot.stringCap != null) {
        // The value is zeroed, so the terminator is already there
        final text = (v as StringLitNode).val;
        for (var c = 0; c < text.length; c++) {
          emitImmediate(1, text.codeUnitAt(c) & 0xFF);
          addressInR14(slot.offset + c);
          emit('ST8     (R14), R1', "'${path.join('.')}'[$c]");
        }
        continue;
      }
      genExpr(v, 1);
      if (!slot.isRef) _normalizeBool(slot.type, v, 1);
      addressInR14(slot.offset);
      _emitStoreTyped(14, 1, slot.type, slot.isRef);
    }
    emit('POP32   R$reg', 'The new value');
    stackOffset -= 4;
  }

  /// `dst.copyFrom(src)`: copies the bytes of a record.
  void _genCopyFrom(CallNode expr) {
    final t = cleanName(_getExprType(expr.args[0]).$1);
    final info = structs[t]!;
    final sig = ParamSig(t, false, false);
    _emitArgValue(expr.args[1], sig, 1);
    emit('PUSH32  R1', 'Source of copyFrom');
    stackOffset += 4;
    _emitArgValue(expr.args[0], sig, 1);
    emit('POP32   R2', 'Source of copyFrom');
    stackOffset -= 4;
    final words = info.size % 4 == 0 && info.align >= 4;
    final count = words ? info.size ~/ 4 : info.size;
    if (count == 0) return;
    final lbl = newLabel('copy');
    emitImmediate(13, count);
    emitLabel(lbl);
    emit(words ? 'LD32    R12, (R2)' : 'LD8     R12, (R2)', "copyFrom: a '$t'");
    emit(words ? 'ST32    (R1), R12' : 'ST8     (R1), R12');
    emit('ADD     R1, ${words ? 4 : 1}');
    emit('ADD     R2, ${words ? 4 : 1}');
    emit('SUB     R13, 1');
    emit('BBRA.NZ R13, $lbl');
  }

  /// `T(x)`: truncates to the width of `T` and extends by its signedness
  /// (from 32 bits, the width of every value in a register).
  void _genConvert(ConvertNode expr, int targetReg) {
    genExpr(expr.expr, targetReg);
    final scratch = targetReg == 14 ? 13 : 14;
    switch (expr.typeName) {
      case 'u8':
        emitImmediate(scratch, 0xFF);
        emit('AND     R$targetReg, R$scratch', 'u8(...): keep the low byte');
      case 'u16':
        emitImmediate(scratch, 0xFFFF);
        emit('AND     R$targetReg, R$scratch', 'u16(...): keep the low halfword');
      case 's8':
        emit('SEXT8   R$targetReg', 's8(...): sign-extend the low byte');
      case 's16':
        emit('SEXT16  R$targetReg', 's16(...): sign-extend the low halfword');
      case 'bool':
        if (!_isBoolValued(expr.expr)) emit('NEZ     R$targetReg', 'bool(...): 0 or 1');
      default:
        // u32 and s32 keep the bits; only the type changes
        break;
    }
  }

  /// `peek8/16/32(a)`, `poke8/16/32(a, v)` and `callAddr(a)`.
  void _genMemoryBuiltin(CallNode expr, int targetReg) {
    const widths = {'8': ('8', 'byte'), '16': ('16', 'halfword'), '32': ('32', 'word')};
    switch (expr.name) {
      case 'peek8' || 'peek16' || 'peek32':
        final (w, what) = widths[expr.name.substring(4)]!;
        genExpr(expr.args[0], targetReg);
        emit('LD$w${' ' * (4 - w.length)}  R$targetReg, (R$targetReg)', '${expr.name}: read the $what at the address');
      case 'poke8' || 'poke16' || 'poke32':
        final (w, what) = widths[expr.name.substring(4)]!;
        genExpr(expr.args[0], 1);
        _genExprKeeping(expr.args[1], 2, [1]);
        emit('ST$w${' ' * (4 - w.length)}  (R1), R2', '${expr.name}: write the $what at the address');
      case 'callAddr':
        genExpr(expr.args[0], 13);
        emit('JMP     R13, R14', 'callAddr: call the code at the address');
        if (targetReg != 1) emit('LD      R$targetReg, R1');
    }
  }

  void _genMemberAccess(MemberAccessNode expr, int targetReg) {
    final baseExpr = expr.expr;
    final member = expr.member;
    if ((member == 'len' || member == 'capacity') && _genOpenRankMember(baseExpr, member, targetReg)) {
      return;
    }
    // An open array parameter carries its length in a hidden slot. Its type
    // is also marked as a pointer, so this must be checked before the
    // dynamic (heap header) cases below. For an open string the slot is the
    // capacity; its .len is still the scan for the terminator.
    if ((member == 'capacity' ||
            (member == 'len' &&
                !(baseExpr is VarAccessNode &&
                    cleanType(typeOf(baseExpr.name).name) == 'string' &&
                    !typeOf(baseExpr.name).refElems))) &&
        baseExpr is VarAccessNode &&
        openArrays.contains(baseExpr.name)) {
      final lenOff = stackOffset - locals['${baseExpr.name}__len']!;
      emitImmediate(14, lenOff);
      emit('ADD     R14, R15');
      emit('LD32    R$targetReg, (R14)',
          "Dynamic .$member for open array '${baseExpr.name}'");
      return;
    }
    if ((member == 'len' || member == 'capacity') && _genStringArrayMember(baseExpr, member, targetReg)) {
      return;
    }
    final arrField = _refField(baseExpr);
    if (arrField != null && arrField.isArrayRef && (member == 'len' || member == 'capacity')) {
      // A heap array or string held in a field
      final field = (baseExpr as MemberAccessNode).member;
      genExpr(baseExpr, 14);
      _checkFieldRef(field, 14);
      if (cleanName(arrField.type) == 'string' && member == 'len' && !arrField.refElems) {
        _emitStringScanAt14(field, targetReg);
      } else {
        emit('SUB     R14, 4', 'Point to prefix header');
        emit('LD32    R$targetReg, (R14)', "Read .$member of field '$field' from its header");
      }
      return;
    }
    if (member == 'capacity') {
      if (baseExpr is VarAccessNode &&
          (affineState.containsKey(baseExpr.name) ||
              typeOf(baseExpr.name, const TypeInfo('', false)).isPtr)) {
        // Dynamic heap capacity header at base[-4]
        genExpr(baseExpr, 14);
        _checkGlobalRef(baseExpr, 14);
        emit('SUB     R14, 4', 'Point to prefix header');
        emit('LD32    R$targetReg, (R14)', 'Read dynamic capacity header');
        return;
      }
      if (baseExpr is MemberAccessNode) {
        final (pT, _) = _getExprType(baseExpr.expr);
        final sName = cleanName(pT);
        final fDim = fieldOf(sName, baseExpr.member).dim;
        final arrCap = fDim is List<int> ? fDim.last : ((fDim as int?) ?? 0);
        emitImmediate(targetReg, arrCap);
        return;
      }
      final arrName = baseExpr.nodeName ?? '';
      int arrCap;
      if (openArrays.contains(arrName)) {
        final lenOff = stackOffset - locals['${arrName}__len']!;
        emitImmediate(14, lenOff);
        emit('ADD     R14, R15');
        emit('LD32    R$targetReg, (R14)', "Dynamic .capacity for open array '$arrName'");
        return;
      } else if (arrayDims.containsKey(arrName)) {
        arrCap = arrayDims[arrName]!.last;
      } else {
        arrCap = arrayLens[arrName] ?? 0;
      }
      emitImmediate(targetReg, arrCap);
      return;
    } else if (member == 'len' || member == 'capacity') {
      var arrName = baseExpr.nodeName ?? '';
      var tName = typeOf(arrName, const TypeInfo('', false)).name;
      final isP = typeOf(arrName, const TypeInfo('', false)).isPtr;
      final isDynamic = isP || affineState.containsKey(arrName);
      final refElems = typeOf(arrName, const TypeInfo('', false)).refElems;
      if (isDynamic && (tName != 'string' || refElems)) {
        // Dynamic heap array length header at base[-4]
        genExpr(baseExpr, 14);
        _checkGlobalRef(baseExpr, 14);
        emit('SUB     R14, 4', 'Point to prefix header');
        emit('LD32    R$targetReg, (R14)', 'Read dynamic array length header');
        return;
      } else if (isDynamic && tName == 'string' && member == 'capacity') {
        // Dynamic heap string capacity header at base[-4]
        genExpr(baseExpr, 14);
        _checkGlobalRef(baseExpr, 14);
        emit('SUB     R14, 4', 'Point to prefix header');
        emit('LD32    R$targetReg, (R14)', 'Read dynamic string capacity header');
        return;
      }
      arrName = baseExpr.nodeName ?? '';
      tName = typeOf(arrName, const TypeInfo('', false)).name;
      if (tName == 'string') {
        _emitStringScanLen(arrName, targetReg);
        return;
      }
      if (baseExpr is VarAccessNode) {
        final arrName2 = baseExpr.name;
        if (openArrays.contains(arrName2)) {
          final lenOff = stackOffset - locals['${arrName2}__len']!;
          emitImmediate(14, lenOff);
          emit('ADD     R14, R15');
          emit('LD32    R$targetReg, (R14)', "Dynamic .len for open array '$arrName2'");
        } else {
          final arrLen = arrayLens[arrName2] ?? 0;
          emitImmediate(targetReg, arrLen);
        }
        return;
      } else if (baseExpr is MemberAccessNode) {
        final (parentT, _) = _getExprType(baseExpr.expr);
        final sName = cleanName(parentT);
        final fDim = fieldOf(sName, baseExpr.member).dim;
        final arrLen = fDim is List<int> ? fDim.first : ((fDim as int?) ?? 0);
        emitImmediate(targetReg, arrLen);
        return;
      }
    }

    // Method function pointer introspection (unbound Type.method only)
    if (baseExpr is VarAccessNode &&
        structs.containsKey(baseExpr.name) &&
        !locals.containsKey(baseExpr.name) &&
        !globals.contains(baseExpr.name) &&
        !boundAddrs.containsKey(baseExpr.name)) {
      final mangledFunc = '${baseExpr.name}_$member';
      emit('LOAD32  R$targetReg, _$mangledFunc', "Method function address '$mangledFunc'");
      return;
    }

    final (tName, _) = _getExprType(baseExpr);
    final sName = cleanName(tName);
    final f = fieldOf(sName, member);
    _emitLvalueAddr(expr, 14);
    _emitLoadTyped(targetReg, 14, f.type, f.isPtr);
  }

  /// `.len` and `.capacity` of an array of references or of strings, of
  /// one string of a fixed array of them, and of a string an array of
  /// references points at. False when [baseExpr] is none of these.
  bool _genStringArrayMember(AstNode baseExpr, String member, int targetReg) {
    if (baseExpr is ArrayAccessNode && _isRefElement(baseExpr)) {
      if (cleanType(_getExprType(baseExpr).$1) != 'string') return false;
      // Every element owns a heap string, with its capacity in its header
      // (the checker rejects .capacity of the command line's strings)
      genExpr(baseExpr, 14);
      _checkStoredRef(baseExpr, 14);
      if (member == 'capacity') {
        emit('SUB     R14, 4', 'Point to prefix header');
        emit('LD32    R$targetReg, (R14)', 'Read string capacity header');
      } else {
        _emitStringScanAt14(null, targetReg);
      }
      return true;
    }
    if (baseExpr is ArrayAccessNode && _isStringRow(baseExpr)) {
      if (member == 'capacity') {
        emitImmediate(targetReg, _rowCapacity(baseExpr) ?? 0);
      } else {
        _emitArrayElemAddr(baseExpr, 14, 2);
        _emitStringScanAt14(null, targetReg);
      }
      return true;
    }
    if (baseExpr is MemberAccessNode && member == 'len' && _fixedStringCap(baseExpr) != null) {
      // A string field: the characters before the terminator
      _emitLvalueAddr(baseExpr, 14);
      _emitStringScanAt14(baseExpr.member, targetReg);
      return true;
    }
    if (baseExpr is VarAccessNode && member == 'len' && !openArrays.contains(baseExpr.name)) {
      final t = typeOf(baseExpr.name);
      final dims = arrayDims[baseExpr.name];
      final isStrings = cleanType(t.name) == 'string' && dims != null && dims.length > 1;
      if ((t.refElems && !t.isPtr) || isStrings) {
        emitImmediate(targetReg, dims?.first ?? arrayLens[baseExpr.name] ?? 0);
        return true;
      }
    }
    return false;
  }

  /// Replaces the string whose address is in R1 by a new heap string
  /// holding a copy of it (capacity: its length and the terminator).
  void _emitHeapStringCopy() {
    emit('PUSH32  R1', 'Keep source string');
    stackOffset += 4;
    emit('LD      R14, R1');
    _emitStringScanAt14(null, 2);
    emit('ADD     R2, 1', 'Capacity: length and terminator');
    backend.genStringAlloc(1, 2);
    emit('POP32   R13', 'Source string');
    stackOffset -= 4;
    emit('LD      R14, R1', 'New heap string');
    final lblLoop = newLabel('str_dup');
    final lblDone = newLabel('str_dup_done');
    emitLabel(lblLoop);
    emit('LD8     R12, (R13)', 'Fetch source byte');
    emit('FBRA.Z  R12, $lblDone', 'End of source string (the copy is already terminated)');
    emit('LD8     (R14), R12', 'Store byte');
    emit('ADD     R13, 1');
    emit('ADD     R14, 1');
    emit('BBRA    $lblLoop');
    emitLabel(lblDone);
  }

  /// `dst = src` for a fixed string buffer [left] of [cap] bytes: copies
  /// the characters of string [right] up to the terminator, at most
  /// cap - 1 of them, and ends the buffer with a terminator.
  void _genStringCopy(AstNode left, AstNode right, int cap) {
    _emitLvalueAddr(left, 13);
    emit('PUSH32  R13', 'Preserve string buffer address');
    stackOffset += 4;
    genExpr(right, 1);
    if (_isRefElement(right)) _checkStoredRef(right, 1);
    emit('POP32   R13', 'Restore string buffer address');
    stackOffset -= 4;
    emitImmediate(3, cap > 0 ? cap - 1 : 0);
    final lblLoop = newLabel('str_copy');
    final lblDone = newLabel('str_copy_done');
    emitLabel(lblLoop);
    emit('FBRA.Z  R3, $lblDone', 'Buffer full');
    emit('LD8     R12, (R1)', 'Fetch source byte');
    emit('FBRA.Z  R12, $lblDone', 'End of source string');
    emit('LD8     (R13), R12', 'Store byte into string buffer');
    emit('ADD     R1, 1', 'src++');
    emit('ADD     R13, 1', 'dst++');
    emit('SUB     R3, 1', 'room--');
    emit('BBRA    $lblLoop', 'Copy next byte');
    emitLabel(lblDone);
    emit('LD8     (R13), R0', 'Store null terminator');
  }

  void _genBinaryOp(BinaryOpNode expr, int targetReg) {
    // The right operand can be longer than an Imm4 branch reaches, so the
    // register test hops over a wide (8-bit) branch, as _genCondJump does.
    if (expr.op == '&&') {
      genExpr(expr.left, targetReg);
      final lblEnd = newLabel('sc_and_end');
      final lblRhs = newLabel('sc_and_rhs');
      emit('FBRA.NZ R$targetReg, $lblRhs', 'Hop to RHS if LHS true');
      emit('FBRA    $lblEnd', 'Short-circuit AND: exit with 0');
      emitLabel(lblRhs);
      genExpr(expr.right, targetReg);
      emit('NEZ     R$targetReg', 'Normalize boolean result');
      emitLabel(lblEnd);
      return;
    } else if (expr.op == '||') {
      genExpr(expr.left, targetReg);
      final lblTrue = newLabel('sc_or_true');
      final lblEnd = newLabel('sc_or_end');
      final lblRhs = newLabel('sc_or_rhs');
      emit('FBRA.Z  R$targetReg, $lblRhs', 'Hop to RHS if LHS false');
      emit('FBRA    $lblTrue', 'Short-circuit OR: exit with 1');
      emitLabel(lblRhs);
      genExpr(expr.right, targetReg);
      emit('NEZ     R$targetReg', 'Normalize boolean result');
      emit('FBRA    $lblEnd');
      emitLabel(lblTrue);
      emitImmediate(targetReg, 1);
      emitLabel(lblEnd);
      return;
    }
    if (expr.op == '=') {
      final left = expr.left;
      final right = expr.right;
      final cap = _fixedStringCap(left);
      if (cap != null) {
        _genStringCopy(left, right, cap);
        return;
      }
      Object? targetType;
      if (left is VarAccessNode || left is MemberAccessNode || left is ArrayAccessNode) {
        final (lt, lp) = _getExprType(left);
        if (!lp) targetType = lt;
      }
      // A field's address is computed first and the RHS evaluated once
      // after it; every other target evaluates the RHS first.
      if (left is! MemberAccessNode) {
        genExpr(right, 1);
        _normalizeBool(targetType, right, 1);
      }
      if (left is MemberAccessNode) {
        // Compute lvalue address into R13 BEFORE evaluating RHS or altering stack offset
        _emitLvalueAddr(left, 13);
        emit('PUSH32  R13', 'Preserve lvalue address');
        stackOffset += 4;
        genExpr(right, 1);
        _normalizeBool(targetType, right, 1);
        emit('POP32   R13', 'Restore lvalue address');
        stackOffset -= 4;
        final (tName, isPtr) = _getExprType(left);
        _emitStoreTyped(13, 1, tName, isPtr);
        return;
      } else if (left is ArrayAccessNode) {
        if (_copiesIntoHeapString(left, right)) {
          _checkStoredRef(right, 1);
          _emitHeapStringCopy();
        }
        emit('PUSH32  R1', 'Preserve RHS');
        stackOffset += 4;
        final (tName, _) = _emitArrayElemAddr(left, 14, 2, true);
        emit('POP32   R1', 'Restore RHS');
        stackOffset -= 4;
        _emitStoreTyped(14, 1, tName, false);
        return;
      } else if (left is VarAccessNode) {
        final name = left.name;
        if (right is HeapAllocNode ||
            right is HeapArrayAllocNode ||
            right is HeapStringAllocNode) {
          affineState[name] = 'VALID';
          if (right is HeapArrayAllocNode) {
            dynamicArrays.add(name);
          }
        }
        // Affine move semantics
        if (right is VarAccessNode) {
          final rhsName = right.name;
          if (affineState.containsKey(rhsName)) {
            affineState[rhsName] = 'MOVED';
            affineState[name] = 'VALID';
            if (dynamicArrays.contains(rhsName)) {
              dynamicArrays.add(name);
            }
          }
        } else if (right is HeapAllocNode ||
            right is HeapArrayAllocNode ||
            right is HeapStringAllocNode) {
          affineState[name] = 'VALID';
        }
        final t = typeOf(name);
        if (boundAddrs.containsKey(name)) {
          emitImmediate(14, boundAddrs[name]!);
          _emitStoreTyped(14, 1, t.name, t.isPtr);
        } else if (locals.containsKey(name)) {
          final offset = stackOffset - locals[name]!;
          emitImmediate(14, offset);
          emit('ADD     R14, R15');
          _emitStoreTyped(14, 1, t.name, t.isPtr);
        } else {
          emit('LOAD32  R14, _$name');
          _emitStoreTyped(14, 1, t.name, t.isPtr);
        }
      }
      return;
    }

    genExpr(expr.left, 1);
    emit('PUSH32  R1', 'Save LHS');
    stackOffset += 4;
    genExpr(expr.right, 2);
    emit('POP32   R1', 'Restore LHS');
    stackOffset -= 4;

    switch (expr.op) {
      case '+':
        emit('ADD     R1, R2');
      case '-':
        emit('SUB     R1, R2');
      case '*':
        emit('MULL    R1, R2');
      case '/':
        emit(_isSignedBinary(expr) ? 'SDIV    R1, R2' : 'DIV     R1, R2');
      case '%':
        emit(_isSignedBinary(expr) ? 'SMOD    R1, R2' : 'MOD     R1, R2');
      case '&':
        emit('AND     R1, R2');
      case '|':
        emit('OR      R1, R2');
      case '^':
        emit('XOR     R1, R2');
      case '<<':
        emit('SHIFTL  R1, R2');
      case '>>':
        emit(_isSignedBinary(expr)
            ? 'ASHIFTR R1, R2'
            : 'SHIFTR  R1, R2');
      case '==' || '!=' || '<' || '<=' || '>' || '>=':
        _genRelational(expr.op, targetReg, _isSignedBinary(expr));
        return;
    }
    // The LHS was restored into R1, so the result is in R1
    if (targetReg != 1) {
      emit('LD      R$targetReg, R1');
    }
  }

  void _genCall(CallNode expr, int targetReg) {
    // trap(N) whose number is a constant other than a literal (a const)
    if (expr.name == 'trap' && expr.args.length == 1 && !funcSignatures.containsKey('trap')) {
      final n = _evalConstExpr(expr.args[0]);
      emit('TRAP    $n', 'Trigger Trap #$n');
      emit('LD      R$targetReg, 0');
      return;
    }
    final cv = _callValue(expr);
    if (cv != null) {
      _genCallValue(cv.$1, cv.$2, cv.$3, targetReg);
      return;
    }
    if (expr.name.startsWith('__METHOD__')) {
      final mName = expr.name.replaceAll('__METHOD__', '');
      var rcvNode = expr.args[0];
      final (tName, _) = _getExprType(rcvNode);
      final sName = cleanName(tName);
      var (targetFunc, embedOffset) = _resolveMethod(sName, mName);
      targetFunc ??= '${sName}_$mName';

      // Reserve any stack-argument area before the receiver is evaluated and
      // held on the stack. The receiver counts as the first slot(s).
      final stackArea = _beginStackArgs(
          expr.args, funcSignatures[targetFunc]?.params ?? <ParamSig>[], 1);

      if (rcvNode is CallNode) {
        // Evaluated receiver returned pointer in R1
        genExpr(rcvNode, 1);
      } else if (_storedRefName(rcvNode) != null) {
        // A reference field or element holds the receiver's address
        genExpr(rcvNode, 1);
        _checkStoredRef(rcvNode, 1);
        if (embedOffset > 0) {
          emitImmediate(2, embedOffset);
          emit('ADD     R1, R2', 'Adjust receiver for embedded type (+$embedOffset)');
        }
      } else {
        // Pass receiver by reference into R1
        _emitLvalueAddr(rcvNode, 1);
        if (embedOffset > 0) {
          emitImmediate(2, embedOffset);
          emit('ADD     R1, R2', 'Adjust receiver for embedded type (+$embedOffset)');
        }
      }

      // Check if receiver parameter expects an open array (companion capacity register in R2)
      final sigInfo = funcSignatures[targetFunc];
      final paramSigs = sigInfo?.params ?? <ParamSig>[];
      final rcvPSig = paramSigs.isNotEmpty ? paramSigs[0] : const ParamSig(null, false, false);
      final rcvIsOpen = rcvPSig.isOpen;

      if (rcvIsOpen) {
        final rcvName = rcvNode.nodeName;
        if (rcvName != null && openArrays.contains(rcvName)) {
          final lenOff = stackOffset - locals['${rcvName}__len']!;
          emitImmediate(2, lenOff);
          emit('ADD     R2, R15');
          emit('LD32    R2, (R2)', "Dynamic capacity for open array receiver '$rcvName'");
        } else if (rcvName != null && arrayDims.containsKey(rcvName)) {
          emitImmediate(2, arrayDims[rcvName]!.last);
        } else {
          final arrSz = arrayLens[rcvName] ?? 0;
          emitImmediate(2, arrSz);
        }

        final methodParamSigs = paramSigs.length > 1 ? paramSigs.sublist(1) : <ParamSig>[];
        final hasArgs = expr.args.length > 1;
        if (hasArgs) {
          emit('PUSH32   R1', 'Preserve receiver pointer');
          emit('PUSH32   R2', 'Preserve receiver capacity');
          stackOffset += 8;
          _genCallArgList(expr.args.sublist(1), methodParamSigs, 3, stackArea);
          emit('POP32    R2', 'Restore receiver capacity');
          emit('POP32    R1', 'Restore receiver pointer');
          stackOffset -= 8;
        }
      } else {
        final methodParamSigs = paramSigs.length > 1 ? paramSigs.sublist(1) : <ParamSig>[];
        final hasArgs = expr.args.length > 1;
        if (hasArgs) {
          emit('PUSH32   R1', 'Preserve receiver pointer');
          stackOffset += 4;
          _genCallArgList(expr.args.sublist(1), methodParamSigs, 2, stackArea);
          emit('POP32    R1', 'Restore receiver pointer');
          stackOffset -= 4;
        }
      }

      emit('RCALL   _$targetFunc');
      _endStackArgs(stackArea);
      if (targetReg != 1) {
        emit('LD      R$targetReg, R1');
      }
      return;
    }

    if (expr.name == 'readFifo') {
      final chan = _fifoChannel(expr);
      emit('FIFO.R  R$targetReg, $chan');
      return;
    } else if (expr.name == 'writeFifo') {
      final chan = _fifoChannel(expr);
      genExpr(expr.args[1], 1);
      emit('FIFO.W  R1, $chan');
      return;
    } else if (expr.name == 'tryReadFifo') {
      // tryReadFifo(chan, x): if channel `chan` has data, x = data and the
      // result is 1; otherwise x is unchanged and the result is 0.
      // FIFO.TRYR takes the channel in a register and reports in R14.
      final chan = _fifoChannel(expr);
      final dest = expr.args[1];
      final (tName, isPtr) = _getExprType(dest);
      _emitLvalueAddr(dest, 3);
      _emitLoadTyped(1, 3, tName, isPtr);
      emitImmediate(2, chan);
      emit('FIFO.TRYR R1, R2', 'Non-blocking read; R14 = 1 if data');
      _emitStoreTyped(3, 1, tName, isPtr);
      emit('LD      R$targetReg, R14', 'tryReadFifo status');
      return;
    }

    if (_isMemoryBuiltin(expr)) {
      _genMemoryBuiltin(expr, targetReg);
      return;
    }

    if (inlineFuncs.containsKey(expr.name)) {
      final func = inlineFuncs[expr.name]!;
      final lblInlineEnd = newLabel('inline_end_${expr.name}');
      final initialOffset = stackOffset;

      // Evaluate the arguments in the caller's scope and spill them onto
      // the caller's stack frame
      final paramTypes = <TypeInfo>[];
      final paramSlots = <int>[];
      for (var i = 0; i < func.params.length; i++) {
        final p = func.params[i];
        final argExpr = expr.args[i];
        final cleanPt = cleanName(p.type);
        final isRef = structs.containsKey(cleanPt) && !p.isPtr;
        paramTypes.add(TypeInfo(p.type, p.isPtr, isRef, p.isRefArray));
        if (isRef) {
          _emitLvalueAddr(argExpr, 1);
        } else {
          genExpr(argExpr, 1);
          if (!p.isPtr) _normalizeBool(p.type, argExpr, 1);
        }
        emit('PUSH32  R1', "Spill inline param '${p.name}'");
        stackOffset += 4;
        paramSlots.add(stackOffset);
      }

      // The body has a scope of its own (see scopes.dart): its parameters,
      // and its own locals in a frame below them
      final caller = _enterInlineBody(func);
      for (var i = 0; i < func.params.length; i++) {
        types[func.params[i].name] = paramTypes[i];
        locals[func.params[i].name] = paramSlots[i];
      }
      final frameBytes = _allocateLocalFrame(func.name, func.scopes);

      inlineReturnStack.add((lblInlineEnd, stackOffset));
      genBlock(func.body!);
      emitLabel(lblInlineEnd);
      inlineReturnStack.removeLast();
      _leaveInlineBody(caller);

      // Deallocate pushed inline params and locals
      final paramBytes = func.params.length * 4 + frameBytes;
      if (paramBytes > 0) {
        emitImmediate(14, paramBytes);
        emit('ADD     R15, R14', "Deallocate inline '${expr.name}' parameters");
      }
      stackOffset = initialOffset;

      if (targetReg != 1) {
        emit('LD      R$targetReg, R1');
      }
      return;
    }

    final isFnVar = locals.containsKey(expr.name) ||
        globals.contains(expr.name) ||
        boundAddrs.containsKey(expr.name);
    if (isFnVar) {
      _StackArgs? stackArea;
      final fnT = typeOf(expr.name).name;
      if (fnTypes.containsKey(fnT)) {
        final (pTypes, _) = fnTypes[fnT]!;
        final paramSigs = [for (final p in pTypes) ParamSig(p, false, false)];
        stackArea = _beginStackArgs(expr.args, paramSigs, 1);
        _genCallArgList(expr.args, paramSigs, 1, stackArea);
      } else {
        for (var i = 0; i < expr.args.length && i < 4; i++) {
          genExpr(expr.args[i], i + 1);
        }
      }
      // Load indirect target into R13 (uses only R14 for address calc, preserving R1-R4)
      genExpr(VarAccessNode(expr.name), 13);
      emit('JMP     R13, R14', "Indirect call through '${expr.name}'");
      _endStackArgs(stackArea);
      if (targetReg != 1) {
        emit('LD      R$targetReg, R1');
      }
    } else {
      final paramSigs = funcSignatures[expr.name]!.params;
      final area = _beginStackArgs(expr.args, paramSigs, 1);
      _genCallArgList(expr.args, paramSigs, 1, area);
      emit('RCALL   _${expr.name}');
      _endStackArgs(area);
      if (targetReg != 1) {
        emit('LD      R$targetReg, R1');
      }
    }
  }

  void _emitArrayLen(AstNode baseExpr, [int targetReg = 14]) {
    final baseName = baseExpr.nodeName ?? '';
    if (baseName.isNotEmpty && openArrays.contains(baseName)) {
      final lenOff = stackOffset - locals['${baseName}__len']!;
      emitImmediate(targetReg, lenOff);
      emit('ADD     R$targetReg, R15');
      emit('LD32    R$targetReg, (R$targetReg)', "Dynamic len for open array '$baseName'");
    } else if (baseExpr is MemberAccessNode) {
      final (parentT, _) = _getExprType(baseExpr.expr);
      final sName = cleanName(parentT);
      final fDim = fieldOf(sName, baseExpr.member).dim;
      final arrLen = fDim is List<int> ? fDim.first : ((fDim as int?) ?? 0);
      emitImmediate(targetReg, arrLen);
    } else if (cleanType(_getExprType(baseExpr).$1) == 'string') {
      _emitStringScanLen(baseName, targetReg);
    } else {
      final arrLen = arrayLens[baseName] ?? 0;
      emitImmediate(targetReg, arrLen);
    }
  }

  /// A call through the function value [callee] (of function type [fnT]):
  /// the value is computed first and kept on the stack while the arguments
  /// are, then called.
  void _genCallValue(AstNode callee, String fnT, List<AstNode> args, int targetReg) {
    genExpr(callee, 1);
    emit('PUSH32  R1', "Function value '${callee is MemberAccessNode ? callee.member : 'called'}'");
    stackOffset += 4;
    final slot = stackOffset;
    final (pTypes, _) = fnTypes[fnT]!;
    final paramSigs = [for (final p in pTypes) ParamSig(cleanName(p), false, false)];
    final area = _beginStackArgs(args, paramSigs, 1);
    _genCallArgList(args, paramSigs, 1, area);
    // Load the function into R13 (using only R14, so R1-R4 keep the arguments)
    final off = stackOffset - slot;
    if (off == 0) {
      emit('LD32    R13, (R15)');
    } else {
      emitImmediate(14, off);
      emit('ADD     R14, R15');
      emit('LD32    R13, (R14)');
    }
    emit('JMP     R13, R14', 'Indirect call through a function value');
    _endStackArgs(area);
    emit('ADD     R15, 4', 'Drop the function value');
    stackOffset -= 4;
    if (targetReg != 1) emit('LD      R$targetReg, R1');
  }

  /// Arguments in call slots 5 and up go in an area the caller reserves
  /// below its frame before evaluating any argument. Slot 5 is at the lowest
  /// address. [base] is the stackOffset position of that lowest word.
  /// Returns null when every argument fits in R1..R4.
  _StackArgs? _beginStackArgs(
      List<AstNode> args, List<ParamSig> paramSigs, int startReg) {
    final lastSlot = startReg - 1 + _argSlotCount(args, paramSigs);
    if (lastSlot <= 4) return null;
    final bytes = (lastSlot - 4) * 4;
    emitImmediate(14, bytes);
    emit('SUB     R15, R14', 'Reserve $bytes bytes for stack arguments');
    stackOffset += bytes;
    return _StackArgs(bytes, stackOffset);
  }

  /// Releases the area of [_beginStackArgs] after the call returns.
  void _endStackArgs(_StackArgs? area) {
    if (area == null) return;
    emitImmediate(14, area.bytes);
    emit('ADD     R15, R14', 'Release stack arguments');
    stackOffset -= area.bytes;
  }

  /// Loads call arguments. Slot k (counting the receiver of a method call)
  /// is register Rk for k <= 4 and the k-5th word of [area] above that.
  ///
  /// When every argument is a leaf and all fit in registers they are loaded
  /// directly, as before. Otherwise each argument is evaluated in turn
  /// into R1 (R1/R2 for an open array) and pushed, or stored into [area],
  /// and the register slots are popped at the end, so evaluating one
  /// argument cannot clobber another. The last argument, if it goes in
  /// registers, is moved into place instead of pushed.
  void _genCallArgList(List<AstNode> args, List<ParamSig> paramSigs,
      [int startReg = 1, _StackArgs? area]) {
    final lastSlot = startReg - 1 + _argSlotCount(args, paramSigs);
    if (lastSlot <= 4 && args.every(_isLeafArg)) {
      var curReg = startReg;
      for (var i = 0; i < args.length; i++) {
        final pSig = i < paramSigs.length ? paramSigs[i] : const ParamSig(null, false, false);
        _emitArgValue(args[i], pSig, curReg);
        curReg += pSig.slots;
      }
      return;
    }

    var slot = startReg;
    var pushed = 0;
    for (var i = 0; i < args.length; i++) {
      final pSig = i < paramSigs.length ? paramSigs[i] : const ParamSig(null, false, false);
      _emitArgValue(args[i], pSig, 1);
      final values = pSig.slots;
      final isLast = i == args.length - 1;
      // Highest value first so R1 -> R2 never overwrites a pending R2
      if (isLast && slot + values - 1 <= 4) {
        for (var v = values; v >= 1; v--) {
          final dst = slot + v - 1;
          if (dst != v) emit('LD      R$dst, R$v', 'Argument slot $dst');
        }
        break;
      }
      for (var v = 1; v <= values; v++, slot++) {
        if (slot <= 4) {
          emit('PUSH32  R$v', 'Hold argument slot $slot');
          stackOffset += 4;
          pushed++;
        } else {
          final pos = area!.base - (slot - 5) * 4;
          emitImmediate(14, stackOffset - pos);
          emit('ADD     R14, R15');
          emit('ST32    (R14), R$v', 'Stack argument slot $slot');
        }
      }
    }
    for (var r = startReg + pushed - 1; r >= startReg; r--) {
      emit('POP32   R$r', 'Argument slot $r');
      stackOffset -= 4;
    }
  }

  /// [genExpr] while registers in [live] hold values: unless [expr] is a
  /// leaf (see [_isLeafArg]) they are saved around it, since operators and
  /// calls use R1/R2 as scratch. [target] must not be one of [live].
  void _genExprKeeping(AstNode expr, int target, List<int> live) {
    if (_isLeafArg(expr)) {
      genExpr(expr, target);
      return;
    }
    for (final r in live) {
      emit('PUSH32  R$r', 'Keep R$r');
      stackOffset += 4;
    }
    genExpr(expr, target);
    for (final r in live.reversed) {
      emit('POP32   R$r');
      stackOffset -= 4;
    }
  }

  /// Emits one argument's value into [curReg] (and its length into
  /// curReg+1 for an open array parameter).
  void _emitArgValue(AstNode arg, ParamSig pSig, int curReg) {
    if (pSig.isOpen && pSig.openRank > 1) {
      // An array of more dimensions: its address, then each length
      final name = arg.nodeName;
      if (arg is VarAccessNode && openRanks.containsKey(name)) {
        final off = stackOffset - locals[name]!;
        emitImmediate(curReg, off);
        emit('ADD     R$curReg, R15');
        emit('LD32    R$curReg, (R$curReg)', "Open array '$name'");
        for (var k = 0; k < pSig.openRank; k++) {
          _emitOpenLen(name!, k, curReg + 1 + k);
        }
        return;
      }
      _emitLvalueAddr(arg, curReg);
      final dims = _fixedDimsOf(arg)!;
      for (var k = 0; k < dims.length; k++) {
        emitImmediate(curReg + 1 + k, dims[k]);
      }
      return;
    }
    final pType = pSig.type;
    final pIsPtr = pSig.isPtr;
    final pOpen = pSig.isOpen;
    if (pOpen) {
      if (arg is SliceNode) {
        final baseExpr = arg.base;
        final baseName = baseExpr.nodeName;
        final (elemT, _) = _getExprType(baseExpr);
        final elemSz = _getElemSize(elemT, false);
        if (baseName != null && openArrays.contains(baseName)) {
          final off = stackOffset - locals[baseName]!;
          emitImmediate(curReg, off);
          emit('ADD     R$curReg, R15');
          emit('LD32    R$curReg, (R$curReg)', "Base of open array slice '$baseName'");
        } else {
          _emitLvalueAddr(baseExpr, curReg);
        }
        final startExpr = arg.startExpr;
        final endExpr = arg.endExpr;
        if (startExpr != null) {
          if (startExpr is IntLitNode) {
            final startVal = startExpr.val;
            if (startVal > 0) {
              emitImmediate(14, startVal * elemSz);
              emit('ADD     R$curReg, R14', 'Add slice start offset');
            }
          } else {
            _genExprKeeping(startExpr, 14, [curReg]);
            if (elemSz == 2) {
              emit('SHIFTL  R14, 1');
            } else if (elemSz == 4) {
              emit('SHIFTL  R14, 2');
            } else if (elemSz == 8) {
              emit('SHIFTL  R14, 3');
            } else if (elemSz != 1) {
              emitImmediateKeepR14(13, elemSz);
              emit('MULL    R14, R13');
            }
            emit('ADD     R$curReg, R14', 'Add dynamic slice start offset');
          }
        }
        final lenReg = curReg + 1;
        if (endExpr == null) {
          _emitArrayLen(baseExpr, lenReg);
          if (startExpr != null) {
            if (startExpr is IntLitNode) {
              if (startExpr.val > 0) {
                emitImmediate(14, startExpr.val);
                emit('SUB     R$lenReg, R14', 'Slice len = total_len - const_start');
              }
            } else {
              _genExprKeeping(startExpr, 14, [curReg, lenReg]);
              emit('SUB     R$lenReg, R14', 'Slice len = total_len - dynamic_start');
            }
          }
        } else if (startExpr == null) {
          if (endExpr is IntLitNode) {
            emitImmediate(lenReg, endExpr.val);
          } else {
            _genExprKeeping(endExpr, lenReg, [curReg]);
          }
        } else {
          if (startExpr is IntLitNode && endExpr is IntLitNode) {
            final d = endExpr.val - startExpr.val;
            final sliceLen = d > 0 ? d : 0;
            emitImmediate(lenReg, sliceLen);
          } else {
            _genExprKeeping(endExpr, lenReg, [curReg]);
            _genExprKeeping(startExpr, 14, [curReg, lenReg]);
            emit('SUB     R$lenReg, R14', 'Slice length = end - start');
          }
        }
      } else {
        final argName = arg.nodeName;
        if (argName != null && openArrays.contains(argName)) {
          final off = stackOffset - locals[argName]!;
          emitImmediate(curReg, off);
          emit('ADD     R$curReg, R15');
          emit('LD32    R$curReg, (R$curReg)', "Forward open array ptr '$argName'");
          final lenOff = stackOffset - locals['${argName}__len']!;
          emitImmediate(curReg + 1, lenOff);
          emit('ADD     R${curReg + 1}, R15');
          emit('LD32    R${curReg + 1}, (R${curReg + 1})', "Forward open array len '$argName'");
        } else if (argName != null &&
            arg is VarAccessNode &&
            typeOf(argName).isPtr &&
            !arrayDims.containsKey(argName) &&
            !arrayLens.containsKey(argName) &&
            (locals.containsKey(argName) || globals.contains(argName))) {
          // A heap array reference: pass its address, and the count from
          // the heap header just below it
          genExpr(arg, curReg);
          _checkGlobalRef(arg, curReg);
          emit('LD      R${curReg + 1}, R$curReg');
          emit('SUB     R${curReg + 1}, 4', 'Point to prefix header');
          emit('LD32    R${curReg + 1}, (R${curReg + 1})',
              "Heap array length for '$argName'");
        } else if (_refField(arg)?.isArrayRef == true) {
          // A heap array held in a field: its address, and the count from
          // the heap header just below it
          genExpr(arg, curReg);
          _checkFieldRef((arg as MemberAccessNode).member, curReg);
          emit('LD      R${curReg + 1}, R$curReg');
          emit('SUB     R${curReg + 1}, 4', 'Point to prefix header');
          emit('LD32    R${curReg + 1}, (R${curReg + 1})',
              "Heap array length for field '${arg.member}'");
        } else if (arg is ArrayAccessNode && cleanType(_getExprType(arg).$1) == 'string') {
          // One string of an array: its address, and the length up to its
          // terminator
          if (_isRefElement(arg)) {
            genExpr(arg, curReg);
            _checkStoredRef(arg, curReg);
          } else {
            _emitLvalueAddr(arg, curReg);
          }
          emit('LD      R14, R$curReg');
          _emitStringScanAt14(null, curReg + 1);
        } else {
          _emitLvalueAddr(arg, curReg);
          final (argT, _) = _getExprType(arg);
          final refElems = _isRefArray(arg);
          final row = _openRow(arg);
          if (row != null) {
            _emitOpenLen(row.$1, row.$2, curReg + 1);
          } else if (cleanType(argT) == 'string' && !refElems) {
            _emitStringScanLen(argName, curReg + 1);
          } else {
            emitImmediate(curReg + 1, _fixedArgLength(arg));
          }
        }
      }
    } else if (pType != null && pType.isNotEmpty && structs.containsKey(pType) && !pIsPtr) {
      if (_storedRefName(arg) != null) {
        // A reference field or element holds the address to pass
        genExpr(arg, curReg);
        _checkStoredRef(arg, curReg);
      } else {
        _emitLvalueAddr(arg, curReg);
      }
    } else {
      genExpr(arg, curReg);
      if (!pIsPtr) _normalizeBool(pType, arg, curReg);
    }
  }

  /// Emits `rDst = rDst op rSrc` for a compound assignment. [signed] selects
  /// SDIV, SMOD and ASHIFTR for '/', '%' and '>>'.
  void _emitBinaryCalc(String op, int rDst, int rSrc, {bool signed = false}) {
    switch (op) {
      case '+':
        emit('ADD     R$rDst, R$rSrc');
      case '-':
        emit('SUB     R$rDst, R$rSrc');
      case '*':
        emit('MULL    R$rDst, R$rSrc');
      case '/':
        emit(signed ? 'SDIV    R$rDst, R$rSrc' : 'DIV     R$rDst, R$rSrc');
      case '%':
        emit(signed ? 'SMOD    R$rDst, R$rSrc' : 'MOD     R$rDst, R$rSrc');
      case '&':
        emit('AND     R$rDst, R$rSrc');
      case '|':
        emit('OR      R$rDst, R$rSrc');
      case '^':
        emit('XOR     R$rDst, R$rSrc');
      case '<<':
        emit('SHIFTL  R$rDst, R$rSrc');
      case '>>':
        emit(signed ? 'ASHIFTR R$rDst, R$rSrc' : 'SHIFTR  R$rDst, R$rSrc');
    }
  }

  void _emitLoadTyped(int dst, int addrReg, Object tName, bool isPtr) {
    if (isPtr || _isWordType(tName)) {
      emit('LD32     R$dst, (R$addrReg)');
    } else if (tName == 'u8' || tName == 'bool') {
      emit('LD8      R$dst, (R$addrReg)');
    } else if (tName == 's8') {
      emit('LD8      R$dst, (R$addrReg)');
      emit('SEXT8   R$dst');
    } else if (tName == 'u16') {
      emit('LD16     R$dst, (R$addrReg)');
    } else if (tName == 's16') {
      emit('LD16     R$dst, (R$addrReg)');
      emit('SEXT16  R$dst');
    } else {
      emit('LD32     R$dst, (R$addrReg)');
    }
  }

  void _emitStoreTyped(int addrReg, int src, Object tName, bool isPtr) {
    if (isPtr || _isWordType(tName)) {
      emit('ST32     (R$addrReg), R$src');
    } else if (tName == 'u8' || tName == 's8' || tName == 'bool') {
      emit('ST8      (R$addrReg), R$src');
    } else if (tName == 'u16' || tName == 's16') {
      emit('ST16     (R$addrReg), R$src');
    } else {
      emit('ST32     (R$addrReg), R$src');
    }
  }

  void _genRelational(String op, int targetReg, [bool isSigned = false]) {
    // Native single-cycle Particle comparisons (SEQ, SNE, SLE, SSLE)
    // R1 is LHS, R2 is RHS
    final sleOp = isSigned ? 'SSLE' : 'SLE';
    final kind = isSigned ? 'signed' : 'unsigned';
    if (op == '==') {
      emit('SEQ     R1, R2', 'Single-cycle equal');
    } else if (op == '!=') {
      emit('SNE     R1, R2', 'Single-cycle not-equal');
    } else if (op == '<=') {
      emit('${sleOp.padRight(7)} R1, R2', 'Single-cycle $kind less-equal');
    } else if (op == '>=') {
      emit('${sleOp.padRight(7)} R2, R1', 'Single-cycle $kind greater-equal (swapped)');
      emit('LD      R1, R2');
    } else if (op == '<') {
      emit('${sleOp.padRight(7)} R2, R1', 'Single-cycle $kind less (< <=> !(R2 <= R1))');
      emit('XOR     R2, 1');
      emit('LD      R1, R2');
    } else if (op == '>') {
      emit('${sleOp.padRight(7)} R1, R2', 'Single-cycle $kind greater (> <=> !(R1 <= R2))');
      emit('XOR     R1, 1');
    }
    if (targetReg != 1) {
      emit('LD      R$targetReg, R1');
    }
  }
}

/// The stack-argument area of one call, see `_beginStackArgs`.
class _StackArgs {
  final int bytes;
  final int base;
  const _StackArgs(this.bytes, this.base);
}
