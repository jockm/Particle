part of 'codegen.dart';

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
      } else if (globals.contains(name)) {
        emit('LOAD32  R$targetReg, _$name');
        if (isRef) {
          emit('LD32    R$targetReg, (R$targetReg)', "Dereference global reference '$name'");
          if (referenceCheck) backend.genNullTrap(targetReg, "global '$name'");
        }
      } else {
        _undefinedName(name);
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
        if (baseExpr is MemberAccessNode) _checkFieldRef(baseExpr.member, targetReg);
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

  /// True for a variable holding a heap array reference (`T x[]`), as
  /// opposed to a fixed array or an open array parameter.
  bool _isHeapArrayRef(String name) =>
      (locals.containsKey(name) || globals.contains(name)) &&
      typeOf(name).isPtr &&
      !openArrays.contains(name) &&
      !arrayDims.containsKey(name) &&
      !arrayLens.containsKey(name);

  (Object, int) _emitArrayElemAddr(ArrayAccessNode node,
      [int addrReg = 14, int idxScratch = 2, bool isWrite = false]) {
    // 1. Flatten nested ArrayAccessNodes from outermost to innermost
    final indices = <AstNode>[];
    AstNode curr = node;
    while (curr is ArrayAccessNode) {
      indices.add(curr.index);
      curr = curr.base;
    }
    final idxList = indices.reversed.toList();
    final baseNode = curr;
    final baseName = baseNode.nodeName;
    final isOpen = baseName != null && openArrays.contains(baseName);

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
          if (isWrite && cleanType(baseT) == 'string') {
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
          if (isWrite && cleanType(baseT) == 'string') {
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
    final leafElemSz = _getElemSize(baseType, false);
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
    }

    // Restore accumulated index
    emit('POP32   R$idxScratch', 'Restore flat index');
    stackOffset -= 4;

    // 5. Add offset to base address
    emit('ADD     R$addrReg, R$idxScratch', 'Indexed element address');
    // A string's elements are bytes
    if (cleanType(baseType) == 'string' && idxList.length >= dims.length) {
      return ('u8', 1);
    }
    return (baseType, leafElemSz);
  }

  void genExpr(AstNode expr, [int targetReg = 1]) {
    try {
      _genExpr(expr, targetReg);
    } on CompileError catch (e) {
      throw e.at(expr.loc);
    }
  }

  void _genExpr(AstNode expr, int targetReg) {
    // An operation on constants is evaluated exactly at compile time
    if (_emitFoldedConst(expr, targetReg)) return;
    if (expr is HeapAllocNode) {
      final cleanT = cleanName(expr.typeName);
      final sz = structSize(cleanT);
      backend.genHeapAlloc(targetReg, sz);
      return;
    } else if (expr is HeapArrayAllocNode) {
      final cleanT = cleanName(expr.typeName);
      final elemSz = _getElemSize(cleanT, false);
      genExpr(expr.countExpr, 2);
      backend.genArrayAlloc(targetReg, elemSz, 2);
      return;
    } else if (expr is HeapStringAllocNode) {
      genExpr(expr.capExpr, 2);
      backend.genStringAlloc(targetReg, 2);
      return;
    } else if (expr is HeapFreeNode) {
      final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
      if (targetVar != null && borrowedParams.contains(targetVar)) {
        throw CompileError(
            "cannot destroy borrowed reference parameter '$targetVar'");
      }
      if (targetVar != null &&
          _isRecordTypeName(typeOf(targetVar).name) &&
          !typeOf(targetVar).isRef &&
          !typeOf(targetVar).isPtr &&
          !arrayDims.containsKey(targetVar)) {
        throw CompileError(
            "cannot destroy '$targetVar': it is a '${cleanName(typeOf(targetVar).name)}' stored on the stack; only references from .create() can be destroyed");
      }
      final field = _refField(expr.expr);
      genExpr(expr.expr, 1);
      _checkGlobalRef(expr.expr, 1);
      if (field != null) _checkFieldRef((expr.expr as MemberAccessNode).member, 1);
      if (targetVar != null && affineState.containsKey(targetVar)) {
        affineState[targetVar] = 'MOVED';
      }
      // Arrays and heap strings carry a 4-byte header below the address
      final isArr = (field != null && field.isArrayRef) ||
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
      final elemSize = _getElemSize(elemT, false);

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
      backend.genArrayResize(1, 1, elemSize, 2);

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
      _emitLoadTyped(targetReg, 14, tName, false);
    } else if (expr is VarAccessNode) {
      final name = expr.name;
      if (constants.containsKey(name)) {
        emitImmediate(targetReg, constants[name]!);
        return;
      }
      if (funcSignatures.containsKey(name)) {
        if (_trapHandlerNames.contains(name)) {
          throw CompileError(
              "'$name' is a trap handler; it runs only when its trap is taken");
        }
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
      } else if (globals.contains(name)) {
        emit('LOAD32  R14, _$name', "Address of global '$name'");
        if (arrayLens.containsKey(name)) {
          emit('LD      R$targetReg, R14', "Address of global array '$name'");
        } else {
          _emitLoadTyped(targetReg, 14, t.name, t.isPtr);
        }
      } else {
        _undefinedName(name);
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
      _checkCompoundConst(expr, opChar);
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
        } else if (globals.contains(name)) {
          emit('LOAD32  R14, _$name');
        } else {
          _undefinedName(name);
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

  void _genMemberAccess(MemberAccessNode expr, int targetReg) {
    final baseExpr = expr.expr;
    final member = expr.member;
    // An open array parameter carries its length in a hidden slot. Its type
    // is also marked as a pointer, so this must be checked before the
    // dynamic (heap header) cases below. For an open string the slot is the
    // capacity; its .len is still the scan for the terminator.
    if ((member == 'capacity' ||
            (member == 'len' &&
                !(baseExpr is VarAccessNode &&
                    cleanType(typeOf(baseExpr.name).name) == 'string'))) &&
        baseExpr is VarAccessNode &&
        openArrays.contains(baseExpr.name)) {
      final lenOff = stackOffset - locals['${baseExpr.name}__len']!;
      emitImmediate(14, lenOff);
      emit('ADD     R14, R15');
      emit('LD32    R$targetReg, (R14)',
          "Dynamic .$member for open array '${baseExpr.name}'");
      return;
    }
    final arrField = _refField(baseExpr);
    if (arrField != null && arrField.isArrayRef && (member == 'len' || member == 'capacity')) {
      // A heap array or string held in a field
      final field = (baseExpr as MemberAccessNode).member;
      genExpr(baseExpr, 14);
      _checkFieldRef(field, 14);
      if (cleanName(arrField.type) == 'string' && member == 'len') {
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
      if (isDynamic && tName != 'string') {
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
      if (funcSignatures.containsKey(mangledFunc)) {
        emit('LOAD32  R$targetReg, _$mangledFunc', "Method function address '$mangledFunc'");
        return;
      }
      throw CompileError("Type '${baseExpr.name}' has no method '$member'");
    }

    final (tN, _) = _getExprType(baseExpr);
    final possibleType = cleanName(tN);
    final mangledFunc = '${possibleType}_$member';
    if (funcSignatures.containsKey(mangledFunc)) {
      final baseName = baseExpr.nodeName ?? 'instance';
      throw CompileError(
          "Cannot extract unbound method reference from instance '$baseName'. "
          "Use '$possibleType.$member' with signature fn($possibleType, ...) instead.");
    }

    final (tName, _) = _getExprType(baseExpr);
    final sName = cleanName(tName);
    final f = fieldOf(sName, member);
    _emitLvalueAddr(expr, 14);
    _emitLoadTyped(targetReg, 14, f.type, f.isPtr);
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
      Object? targetType;
      if (left is VarAccessNode || left is MemberAccessNode || left is ArrayAccessNode) {
        final (lt, lp) = _getExprType(left);
        _checkConstFits(right, lt, lp, 'assignment to ${_targetName(left)}');
        if (!lp) targetType = lt;
      }
      // A field's address is computed first and the RHS evaluated once
      // after it; every other target evaluates the RHS first.
      if (left is! MemberAccessNode) {
        genExpr(right, 1);
        _normalizeBool(targetType, right, 1);
      }
      if (left is MemberAccessNode) {
        final rf = _refField(left);
        if (rf != null) _checkRefFieldAssignment(left, rf, right);
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
            final allocElemT = cleanName(right.typeName);
            final varInfo = typeOf(name);
            final varElemT = cleanName(varInfo.name);
            final isArrTarget = dynamicArrays.contains(name) ||
                arrayDims.containsKey(name) ||
                arrayLens.containsKey(name) ||
                varInfo.isPtr;
            if (!isArrTarget) {
              throw CompileError(
                  "Cannot assign array allocation to non-array variable '$name'");
            }
            if (!varInfo.isPtr) {
              throw CompileError(
                  "Cannot assign array allocation to fixed-size array '$name'; declare it as '$varElemT $name[]'");
            }
            if (allocElemT != varElemT) {
              throw CompileError(
                  "Array type mismatch: cannot assign '$allocElemT[]' to '$varElemT[]'");
            }
            dynamicArrays.add(name);
          }
        }
        // Affine move semantics
        if (right is VarAccessNode) {
          final rhsName = right.name;
          if (borrowedParams.contains(rhsName) && affineState.containsKey(name)) {
            // Borrowed reference cannot be moved into an owning handle
            throw CompileError(
                "cannot take ownership of borrowed parameter '$rhsName'");
          }
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
        _validateFnTypeAssignment(t.name, right, name);
        _checkRecordAssignment(name, right);
        if (boundAddrs.containsKey(name)) {
          emitImmediate(14, boundAddrs[name]!);
          _emitStoreTyped(14, 1, t.name, t.isPtr);
        } else if (locals.containsKey(name)) {
          final offset = stackOffset - locals[name]!;
          emitImmediate(14, offset);
          emit('ADD     R14, R15');
          _emitStoreTyped(14, 1, t.name, t.isPtr);
        } else if (globals.contains(name)) {
          emit('LOAD32  R14, _$name');
          _emitStoreTyped(14, 1, t.name, t.isPtr);
        } else {
          _undefinedName(name);
        }
      }
      return;
    }

    _checkBinaryConsts(expr);
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
    if (_trapHandlerNames.contains(expr.name)) {
      throw CompileError(
          "'${expr.name}' is a trap handler; it runs only when its trap is taken");
    }
    // trap(N) whose number is a constant other than a literal (a const)
    if (expr.name == 'trap' && expr.args.length == 1 && !funcSignatures.containsKey('trap')) {
      int n;
      try {
        n = _evalConstExpr(expr.args[0]);
      } on NotConstantError {
        throw CompileError('trap: the trap number must be a constant');
      }
      if (n < 0 || n >= backend.vectorCount) {
        // Constants are evaluated modulo 2^32; show a negative one as such
        final shown = n > 0x7FFFFFFF ? n - 0x100000000 : n;
        throw CompileError(
            'trap number $shown is out of range (0-${backend.vectorCount - 1})');
      }
      emit('TRAP    $n', 'Trigger Trap #$n');
      emit('LD      R$targetReg, 0');
      return;
    }
    if (_isCoroutineOp(expr.name)) {
      throw CompileError(
          "'${expr.name}' returns from the task; use it as a statement, not in an expression");
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
      } else if (_refField(rcvNode) != null) {
        // A reference field holds the receiver's address
        genExpr(rcvNode, 1);
        _checkFieldRef((rcvNode as MemberAccessNode).member, 1);
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

    if (expr.name == 'readfifo') {
      final chan = _fifoChannel(expr);
      emit('FIFO.R  R$targetReg, $chan');
      return;
    } else if (expr.name == 'writefifo') {
      final chan = _fifoChannel(expr);
      genExpr(expr.args[1], 1);
      emit('FIFO.W  R1, $chan');
      return;
    } else if (expr.name == 'tryreadfifo') {
      // tryreadfifo(chan, x): if channel `chan` has data, x = data and the
      // result is 1; otherwise x is unchanged and the result is 0.
      // FIFO.TRYR takes the channel in a register and reports in R14.
      final chan = _fifoChannel(expr);
      if (expr.args.length != 2) {
        throw CompileError(
            "tryreadfifo takes 2 arguments (channel, variable), got ${expr.args.length}");
      }
      final dest = expr.args[1];
      final (tName, isPtr) = _getExprType(dest);
      _emitLvalueAddr(dest, 3);
      _emitLoadTyped(1, 3, tName, isPtr);
      emitImmediate(2, chan);
      emit('FIFO.TRYR R1, R2', 'Non-blocking read; R14 = 1 if data');
      _emitStoreTyped(3, 1, tName, isPtr);
      emit('LD      R$targetReg, R14', 'tryreadfifo status');
      return;
    }

    if (inlineFuncs.containsKey(expr.name)) {
      final func = inlineFuncs[expr.name]!;
      final lblInlineEnd = newLabel('inline_end_${expr.name}');
      final savedLocals = Map<String, int>.of(locals);
      final savedTypes = Map<String, TypeInfo>.of(types);
      final savedDims = Map<String, List<int>>.of(arrayDims);
      final savedLens = Map<String, int>.of(arrayLens);
      final initialOffset = stackOffset;

      // Evaluate parameters and spill onto caller stack frame
      for (var i = 0; i < func.params.length; i++) {
        final p = func.params[i];
        final argExpr = expr.args[i];
        _checkConstFits(argExpr, p.type, p.isPtr || p.isOpenArr,
            "argument ${i + 1} of '${expr.name}'");
        final cleanPt = cleanName(p.type);
        final isRef = structs.containsKey(cleanPt) && !p.isPtr;
        types[p.name] = TypeInfo(p.type, p.isPtr, isRef);
        if (isRef) {
          _emitLvalueAddr(argExpr, 1);
        } else {
          genExpr(argExpr, 1);
          if (!p.isPtr) _normalizeBool(p.type, argExpr, 1);
        }
        emit('PUSH32  R1', "Spill inline param '${p.name}'");
        stackOffset += 4;
        locals[p.name] = stackOffset;
      }

      // The inline body's own locals get a frame below its parameters
      _preRegisterLocalConsts(func.body);
      final inlineDecls = <VarDeclNode>[];
      _collectLocalDecls(func.body, inlineDecls);
      final frameBytes = _allocateLocalFrame(func.name, inlineDecls);

      inlineReturnStack.add((lblInlineEnd, stackOffset));
      genBlock(func.body!);
      emitLabel(lblInlineEnd);
      inlineReturnStack.removeLast();

      // Deallocate pushed inline params and locals
      final paramBytes = func.params.length * 4 + frameBytes;
      if (paramBytes > 0) {
        emitImmediate(14, paramBytes);
        emit('ADD     R15, R14', "Deallocate inline '${expr.name}' parameters");
      }
      stackOffset = initialOffset;
      locals = savedLocals;
      types = savedTypes;
      arrayDims
        ..clear()
        ..addAll(savedDims);
      arrayLens
        ..clear()
        ..addAll(savedLens);

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
      final sigInfo = funcSignatures[expr.name];
      final paramSigs = sigInfo?.params ?? <ParamSig>[];
      final area = _beginStackArgs(expr.args, paramSigs, 1);
      _genCallArgList(expr.args, paramSigs, 1, area);
      emit('RCALL   _${expr.name}');
      _endStackArgs(area);
      if (targetReg != 1) {
        emit('LD      R$targetReg, R1');
      }
    }
  }

  /// Reports a name that is not a variable, constant or function in scope.
  Never _undefinedName(String name) =>
      throw CompileError("undefined identifier '$name'");

  /// The channel of a FIFO built-in: its first argument, a constant.
  int _fifoChannel(CallNode expr) {
    if (expr.args.isEmpty) {
      throw CompileError("${expr.name} needs a channel number");
    }
    try {
      return _evalConstExpr(expr.args[0]);
    } on NotConstantError {
      throw CompileError("${expr.name}: the channel must be a constant");
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

  /// Number of call slots the arguments take: one each, two for an open
  /// array (pointer and length).
  int _argSlotCount(List<AstNode> args, List<ParamSig> paramSigs) {
    var n = 0;
    for (var i = 0; i < args.length; i++) {
      final open = i < paramSigs.length && paramSigs[i].isOpen;
      n += open ? 2 : 1;
    }
    return n;
  }

  /// True for an argument whose code only touches its own register (and
  /// R13/R14), so it can be loaded straight into its argument register
  /// without disturbing those already loaded.
  bool _isLeafArg(AstNode arg) {
    if (arg is IntLitNode || arg is StringLitNode || arg is VarAccessNode || arg is SizeofNode) {
      return true;
    }
    if (arg is UnaryOpNode && (arg.op == '-' || arg.op == '~')) {
      return _isLeafArg(arg.operand);
    }
    return false;
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
    for (var i = 0; i < args.length && i < paramSigs.length; i++) {
      final p = paramSigs[i];
      if (!p.isOpen) _checkConstFits(args[i], p.type, p.isPtr, 'argument ${i + 1}');
    }
    final lastSlot = startReg - 1 + _argSlotCount(args, paramSigs);
    if (lastSlot <= 4 && args.every(_isLeafArg)) {
      var curReg = startReg;
      for (var i = 0; i < args.length; i++) {
        final pSig = i < paramSigs.length ? paramSigs[i] : const ParamSig(null, false, false);
        _emitArgValue(args[i], pSig, curReg);
        curReg += pSig.isOpen ? 2 : 1;
      }
      return;
    }

    var slot = startReg;
    var pushed = 0;
    for (var i = 0; i < args.length; i++) {
      final pSig = i < paramSigs.length ? paramSigs[i] : const ParamSig(null, false, false);
      _emitArgValue(args[i], pSig, 1);
      final values = pSig.isOpen ? 2 : 1;
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
        } else {
          _emitLvalueAddr(arg, curReg);
          final (argT, _) = _getExprType(arg);
          if (cleanType(argT) == 'string') {
            _emitStringScanLen(argName, curReg + 1);
          } else {
            final arrSz = arrayLens[argName] ?? 0;
            emitImmediate(curReg + 1, arrSz);
          }
        }
      }
    } else if (pType != null && pType.isNotEmpty && structs.containsKey(pType) && !pIsPtr) {
      if (_refField(arg) != null) {
        // A reference field holds the address to pass
        genExpr(arg, curReg);
        _checkFieldRef((arg as MemberAccessNode).member, curReg);
      } else {
        _emitLvalueAddr(arg, curReg);
      }
    } else {
      genExpr(arg, curReg);
      if (!pIsPtr) _normalizeBool(pType, arg, curReg);
    }
  }

  /// True when either operand of [expr] has a signed type; signed division,
  /// remainder and right shift are then used (as comparisons already did).
  bool _isSignedBinary(BinaryOpNode expr) =>
      _isSignedOperand(expr.left) || _isSignedOperand(expr.right);

  /// True when [expr] yields a signed value: its type is signed, or it is
  /// arithmetic (or a negation) over a signed operand. _getExprType types
  /// every operator result as u32, so `(a - b) / 2` needs this look inside.
  bool _isSignedOperand(AstNode expr) {
    if (expr is BinaryOpNode &&
        const ['+', '-', '*', '/', '%', '&', '|', '^', '<<', '>>'].contains(expr.op)) {
      return _isSignedOperand(expr.left) || _isSignedOperand(expr.right);
    }
    if (expr is UnaryOpNode && expr.op == '-') {
      return _isSignedOperand(expr.operand);
    }
    final (t, _) = _getExprType(expr);
    return _isSignedName(t);
  }

  /// True when a compound assignment to a [lhsType] target with [rhs] is
  /// signed arithmetic.
  bool _isSignedCompound(Object lhsType, AstNode rhs) =>
      _isSignedName(lhsType) || _isSignedOperand(rhs);

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

  bool _isWordType(Object tName) =>
      ['u32', 's32', 'string'].contains(tName) ||
      fnTypes.containsKey(tName) ||
      structs.containsKey(tName);

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
