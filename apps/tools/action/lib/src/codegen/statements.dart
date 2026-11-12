part of 'codegen.dart';

extension _Statements on CodeGen {
  void _validateFnTypeAssignment(Object targetType, AstNode rhsExpr, [String? targetName]) {
    final cleanTgt = cleanName(targetType);
    final rhsTObj = _getExprType(rhsExpr).$1;
    final rhsT = rhsTObj is String ? rhsTObj : rhsTObj.toString();
    final cleanRhs = cleanName(rhsTObj);

    // 1. Function pointer targets
    if (targetType is String && fnTypes.containsKey(targetType)) {
      final (expParams, expRet) = fnTypes[targetType]!;
      if (rhsT.startsWith('fn_')) {
        final fnName = rhsT.substring(3);
        final sig = funcSignatures[fnName];
        if (sig == null) {
          throw CompileError(
              "Unknown function '$fnName' in function pointer assignment");
        }
        final actRet = sig.retType;
        final actParams = [for (final p in sig.params) cleanName(p.type)];
        final expParamsClean = [for (final p in expParams) cleanName(p)];
        if (expParamsClean.length != actParams.length ||
            !_listEq(expParamsClean, actParams) ||
            expRet != actRet) {
          final expSig = 'fn(${pyListRepr(expParamsClean)}) -> $expRet';
          final actSig = 'fn(${pyListRepr(actParams)}) -> $actRet';
          throw CompileError(
              "Function signature mismatch: cannot assign '$fnName' ($actSig) to type '$targetType' ($expSig)");
        }
      } else if (fnTypes.containsKey(rhsT)) {
        final a = fnTypes[targetType]!;
        final b = fnTypes[rhsT]!;
        if (!_listEq(a.$1, b.$1) || a.$2 != b.$2) {
          throw CompileError(
              "Function type mismatch: cannot assign '$rhsT' to '$targetType'");
        }
      } else {
        throw CompileError(
            "Cannot assign non-function value of type '$rhsT' to function pointer '$targetType'");
      }
      return;
    }

    // 2. Reject function references assigned to non-function types
    if (rhsT.startsWith('fn_') || fnTypes.containsKey(rhsT)) {
      throw CompileError(
          "Cannot implicitly convert function reference to non-function type '$targetType'");
    }

    // 3. HeapAllocNode (Type.create())
    if (rhsExpr is HeapAllocNode) {
      final allocT = cleanName(rhsExpr.typeName);
      if (cleanTgt != allocT) {
        throw CompileError(
            "Cannot assign instance of type '$allocT' to variable of type '$targetType'");
      }
      return;
    }

    // 4. HeapStringAllocNode (string.create())
    if (rhsExpr is HeapStringAllocNode) {
      if (cleanTgt != 'string') {
        throw CompileError(
            "Cannot assign string allocation to non-string variable of type '$targetType'");
      }
      return;
    }

    // 5. User struct reference targets
    if (structs.containsKey(cleanTgt)) {
      // Allow assigning 0 (null reference)
      if (rhsExpr is IntLitNode && rhsExpr.val == 0) {
        return;
      }
      if (cleanRhs != cleanTgt) {
        throw CompileError(
            "Cannot assign type '$cleanRhs' to reference variable of type '$targetType'");
      }
      return;
    }

    // 6. Primitive scalar target with struct/reference RHS
    const primitives = ['u8', 's8', 'u16', 's16', 'u32', 's32', 'bool'];
    if (primitives.contains(cleanTgt)) {
      if (structs.containsKey(cleanRhs)) {
        throw CompileError(
            "cannot assign a reference to a '$cleanRhs' to ${targetName != null ? "'$targetName'" : 'a variable'} of type '$targetType'");
      }
      if (cleanRhs == 'string' && rhsExpr is! IntLitNode) {
        throw CompileError(
            "Cannot assign string to scalar variable of type '$targetType'");
      }
    }
  }

  void genStmt(AstNode stmt) {
    try {
      _genStmt(stmt);
    } on CompileError catch (e) {
      throw e.at(stmt.loc);
    }
  }

  void _genStmt(AstNode stmt) {
    if (stmt is BlockNode) {
      genBlock(stmt);
      return;
    } else if (stmt is AsmNode) {
      for (final l in _splitLines(stmt.asmText)) {
        if (l.trim().isNotEmpty) {
          asm.add('    ${l.trim()}');
        }
      }
      return;
    } else if (stmt is BreakNode) {
      if (breakStack.isEmpty) {
        throw CompileError("'break' outside of loop or switch block");
      }
      emit('FBRA    ${breakStack.last}', 'Break jump');
      return;
    } else if (stmt is ContinueNode) {
      if (flowStack.isEmpty) {
        throw CompileError("'continue' outside of loop or switch block");
      }
      final ctx = flowStack.last;
      if (ctx.isSwitch) {
        // Fall through into the next case (or leave the switch after the last)
        final next = ctx.currentCase + 1;
        final target =
            next < ctx.caseLabels.length ? ctx.caseLabels[next] : ctx.endLabel!;
        emit('FBRA    $target', 'Continue: fall through to next case');
      } else {
        // A while loop re-tests its condition above; a for loop steps below.
        final op = ctx.continueBackward ? 'BBRA' : 'FBRA';
        emit('$op    ${ctx.loopTarget}', 'Continue: next loop iteration');
      }
      return;
    } else if (stmt is CaseLabelNode) {
      if (stmt.label != null) {
        _emitCaseLabel(stmt.label!);
      }
      return;
    } else if (stmt is DefaultLabelNode) {
      if (stmt.label != null) {
        _emitCaseLabel(stmt.label!);
      }
      return;
    } else if (stmt is SwitchNode) {
      final lblEnd = newLabel('switch_end');
      breakStack.add(lblEnd);

      final cases = <(int, String)>[];
      final defaultHolder = <String?>[null];
      final orderedLabels = <String>[];
      _collectSwitchLabels(stmt.body, cases, defaultHolder, orderedLabels);
      _checkCaseConsts(stmt);

      // Evaluate switch discriminant into R1
      genExpr(stmt.expr, 1);

      // Generate dispatch checks without modifying stack
      for (final (val, cLbl) in cases) {
        final lblMatch = newLabel('case_match');
        final lblSkip = newLabel('case_skip');
        emit('LD      R3, R1', 'Copy discriminant for comparison');
        emitImmediate(2, val);
        emit('SUB     R3, R2');
        emit('FBRA.Z  R3, $lblMatch', 'Hop if matched (1 instruction)');
        emit('FBRA    $lblSkip', 'Skip to next case check (8-bit)');
        emitLabel(lblMatch);
        emit('FBRA    $cLbl', 'Wide dispatch to case $val (8-bit)');
        emitLabel(lblSkip);
      }

      // Default or exit branch
      final targetDefault = defaultHolder[0] ?? lblEnd;
      emit('FBRA    $targetDefault', 'Dispatch default or exit');

      // Emit nested body (which contains the CaseLabelNodes and code).
      // Each case ends with an implicit break; 'continue' falls through.
      flowStack.add(_FlowContext.switchBlock(orderedLabels, lblEnd));
      genStmt(stmt.body);
      flowStack.removeLast();

      emitLabel(lblEnd);
      breakStack.removeLast();
      return;
    } else if (stmt is VarDeclNode) {
      _validateBackendType(stmt.typeName, "local variable '${stmt.name}'");
      if (stmt.isConst) {
        _defineLocalConst(stmt);
        return;
      }
      _resolveVarDecl(stmt);
      if (stmt.boundAddr != null) {
        boundAddrs[stmt.name] = stmt.boundAddr!;
        return;
      }

      final init = stmt.initExpr;
      if (init != null) {
        if (stmt.typeName == 'string' && init is StringLitNode) {
          final cap = stmt.arrayDim;
          _emitStringInit(stmt.name, init, cap);
          return;
        }
        if (stmt.dimExprs.isEmpty) {
          _checkConstFits(init, cleanName(stmt.typeName), stmt.isPtr, "variable '${stmt.name}'");
        }
        _validateFnTypeAssignment(stmt.typeName, init, stmt.name);
        _checkRecordAssignment(stmt.name, init);
        genExpr(init, 1);
        if (!stmt.isPtr && stmt.dimExprs.isEmpty) _normalizeBool(stmt.typeName, init, 1);
        final name = stmt.name;
        if (init is HeapAllocNode ||
            init is HeapArrayAllocNode ||
            init is HeapStringAllocNode) {
          affineState[name] = 'VALID';
        }
        if (init is HeapArrayAllocNode) {
          final allocElemT = cleanName(init.typeName);
          final varElemT = cleanName(stmt.typeName);
          // Enforce array target: must have array_dims, array_dim, or is_ptr/open-arr
          final isArrTarget = (stmt.arrayDims != null && stmt.arrayDims!.isNotEmpty) ||
              stmt.arrayDim != null ||
              stmt.isPtr;
          if (!isArrTarget) {
            throw CompileError(
                "Cannot assign array allocation to non-array variable '$name'");
          }
          if (!stmt.isPtr) {
            throw CompileError(
                "Cannot assign array allocation to fixed-size array '$name'; declare it as '$varElemT $name[]'");
          }
          if (allocElemT != varElemT) {
            throw CompileError(
                "Array type mismatch: cannot assign '$allocElemT[]' to '$varElemT[]'");
          }
          dynamicArrays.add(name);
        }
        final t = typeOf(name);
        final offset = stackOffset - locals[name]!;
        emitImmediate(14, offset);
        emit('ADD     R14, R15');
        _emitStoreTyped(14, 1, t.name, t.isPtr);
      }
    } else if (stmt is CompoundAssignNode) {
      // Compound assignment: lhs op= rhs
      final opChar = stmt.op.substring(0, stmt.op.length - 1); // Remove trailing '='
      genExpr(stmt.rhs, 2);
      emit('PUSH32  R2', 'Save compound RHS');
      stackOffset += 4;

      // Evaluate LHS address
      final lhs = stmt.lhs;
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
        _emitBinaryCalc(opChar, 1, 2, signed: _isSignedCompound(t.name, stmt.rhs));
        _normalizeBoolResult(t.isPtr ? null : t.name, 1);
        _emitStoreTyped(14, 1, t.name, t.isPtr);
      } else if (lhs is ArrayAccessNode) {
        final (tName, _) = _emitArrayElemAddr(lhs, 14, 3, true);
        _emitLoadTyped(1, 14, tName, false);
        emit('POP32   R2', 'Restore compound RHS');
        stackOffset -= 4;
        _emitBinaryCalc(opChar, 1, 2, signed: _isSignedCompound(tName, stmt.rhs));
        _normalizeBoolResult(tName, 1);
        _emitStoreTyped(14, 1, tName, false);
        return;
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
        _emitBinaryCalc(opChar, 1, 2, signed: _isSignedCompound(f.type, stmt.rhs));
        _normalizeBoolResult(f.isPtr ? null : f.type, 1);
        _emitStoreTyped(14, 1, f.type, f.isPtr);
      }
      return;
    } else if (stmt is ExprStmtNode) {
      genExpr(stmt.expr, 1);
    } else if (stmt is YieldNode) {
      // yield(task, step): task.lc = step; return PK_YIELDED; case step:
      // Step value first: loading it may need R14 (LOAD macro)
      emitImmediate(1, stmt.stepConst);
      _emitLvalueAddr(stmt.taskRef, 14);
      emit('LD16     (R14), R1', 'Set continuation counter');
      final yielded = _pkStatus('PK_YIELDED');
      emitImmediate(1, yielded);
      emit('FBRA     ._epilogue_$currentFuncName');
      emitLabel('._step_${currentFuncName}_${stmt.stepConst}');
      return;
    } else if (stmt is WaitUntilNode) {
      // wait_until(task, step, cond): case step: if (!cond) { task.lc = step; return PK_WAITING; }
      emitLabel('._step_${currentFuncName}_${stmt.stepConst}');
      final lblContinue = newLabel('wait_cont');
      genExpr(stmt.cond, 1);
      emit('FBRA.NZ  R1, $lblContinue', 'Condition satisfied, proceed');
      // Step value first: loading it may need R14 (LOAD macro)
      emitImmediate(1, stmt.stepConst);
      _emitLvalueAddr(stmt.taskRef, 14);
      emit('LD16     (R14), R1', 'Set continuation counter');
      final waiting = _pkStatus('PK_WAITING');
      emitImmediate(1, waiting);
      emit('FBRA     ._epilogue_$currentFuncName');
      emitLabel(lblContinue);
      return;
    } else if (stmt is PkExitNode) {
      // pk_exit(task): task.lc = 0; return PK_EXITED;
      _emitLvalueAddr(stmt.taskRef, 14);
      emit('LD16     (R14), R0', 'Reset continuation counter (lc = 0)');
      final exited = _pkStatus('PK_EXITED');
      emitImmediate(1, exited);
      emit('FBRA     ._epilogue_$currentFuncName', 'Exit coroutine');
      return;
    } else if (stmt is VerifyNode) {
      final res = _evalConstExpr(stmt.cond);
      if (res == 0) {
        final tok = stmt.token;
        final loc = tok != null ? tok.loc : 'verify';
        throw CompileError("$loc: Compile-time verification failed: '${stmt.msg}'");
      }
      return;
    } else if (stmt is TupleReturnNode) {
      // Strict callee return validation
      final retTypeInfo = currentFuncRet;
      if (retTypeInfo.$1 is! List) {
        throw CompileError(
            "Function '$currentFuncName' has scalar return type '${retTypeInfo.$1}', cannot return tuple");
      }
      final expectedArity = (retTypeInfo.$1 as List).length;
      if (stmt.exprs.length != expectedArity) {
        throw CompileError(
            "Tuple return arity mismatch in '$currentFuncName': expected $expectedArity, got ${stmt.exprs.length}");
      }

      final retTypes = retTypeInfo.$1 as List;
      for (var i = 0; i < stmt.exprs.length; i++) {
        final rt = retTypes[i];
        final (Object? rtName, bool rtPtr) = rt is (Object?, bool) ? rt : (rt, false);
        _checkConstFits(stmt.exprs[i], rtName, rtPtr,
            "return value ${i + 1} of '$currentFuncName'");
      }
      final numReturns = stmt.exprs.length;
      // Check if all return expressions are simple leaves (IntLitNode or VarAccessNode)
      // which can safely be placed directly into R1..Rn without evaluation clobbering
      final allSimple =
          stmt.exprs.every((e) => e is IntLitNode || e is VarAccessNode);
      if (allSimple) {
        for (var i = 0; i < stmt.exprs.length; i++) {
          genExpr(stmt.exprs[i], i + 1);
        }
      } else {
        for (var i = 0; i < stmt.exprs.length; i++) {
          genExpr(stmt.exprs[i], 1);
          emit('PUSH32  R1', 'Save tuple return elem ${i + 1}');
          stackOffset += 4;
        }
        for (var i = numReturns - 1; i >= 0; i--) {
          final targetR = i + 1;
          emit('POP32   R$targetR', 'Restore tuple return into R$targetR');
          stackOffset -= 4;
        }
      }
      emit('FBRA    ._epilogue_$currentFuncName');
    } else if (stmt is TupleAssignNode) {
      // Save return registers if RHS is evaluated
      genExpr(stmt.expr, 1);
      for (var i = 0; i < stmt.targets.length; i++) {
        final target = stmt.targets[i];
        if (target.isWildcard) continue;
        final regSrc = i + 1;
        final name = target.name!;
        if (target.typeName != null) {
          types[name] = TypeInfo(target.typeName!, target.isPtr, false);
        }
        final t = typeOf(name);
        if (locals.containsKey(name)) {
          final offset = stackOffset - locals[name]!;
          if (offset > 0) {
            emitImmediate(14, offset);
            emit('ADD     R14, R15');
          } else {
            emit('LD      R14, R15');
          }
          _emitStoreTyped(14, regSrc, t.name, t.isPtr);
        } else if (globals.contains(name)) {
          emit('LOAD32  R14, _$name');
          _emitStoreTyped(14, regSrc, t.name, t.isPtr);
        }
      }
    } else if (stmt is ReturnNode) {
      final retTypeInfo = currentFuncRet;
      if (retTypeInfo.$1 is List) {
        throw CompileError(
            "Function '$currentFuncName' declared with tuple return of arity ${(retTypeInfo.$1 as List).length}, cannot return scalar or void");
      }
      if (currentFuncIsTask && inlineReturnStack.isEmpty) {
        // A task's result is always its status: 'return;' ends the task
        if (stmt.expr != null) {
          throw CompileError(
              "task '$currentFuncName' cannot return a value; 'return;' ends the task");
        }
        emit('FBRA    ._task_end_$currentFuncName', 'End the task');
        return;
      }
      if (stmt.expr != null) {
        _checkConstFits(stmt.expr, retTypeInfo.$1, retTypeInfo.$2,
            "return value of '$currentFuncName'");
        genExpr(stmt.expr!, 1);
        if (!retTypeInfo.$2) _normalizeBool(retTypeInfo.$1, stmt.expr!, 1);
      }
      if (inlineReturnStack.isNotEmpty) {
        final (lblInlineEnd, initialOffset) = inlineReturnStack.last;
        final frameExtra = stackOffset - initialOffset;
        if (frameExtra > 0) {
          emitImmediate(14, frameExtra);
          emit('ADD     R15, R14', 'Unwind inline stack frame on return');
        }
        emit('FBRA    $lblInlineEnd', 'Return from inline function');
      } else {
        emit('FBRA    ._epilogue_$currentFuncName');
      }
    } else if (stmt is IfNode) {
      // Attempt compile-time constant branch pruning (replaces preprocessor #if/#ifdef)
      var isConstCond = false;
      var constVal = 0;
      try {
        constVal = _evalConstExpr(stmt.cond);
        isConstCond = true;
      } on NotConstantError {
        isConstCond = false;
      }

      if (isConstCond) {
        if (constVal != 0) {
          genStmt(stmt.thenBody);
        } else if (stmt.elseBody != null) {
          genStmt(stmt.elseBody!);
        }
        return;
      }

      final lblElse = newLabel('else');
      final lblEnd = newLabel('endif');
      final target = stmt.elseBody != null ? lblElse : lblEnd;

      _genCondJump(stmt.cond, target);

      genStmt(stmt.thenBody);
      if (stmt.elseBody != null) {
        emit('FBRA     $lblEnd');
        emitLabel(lblElse);
        genStmt(stmt.elseBody!);
      }
      emitLabel(lblEnd);
    } else if (stmt is WhileNode) {
      final lblLoop = newLabel('while_start');
      final lblEnd = newLabel('while_end');
      breakStack.add(lblEnd);

      emitLabel(lblLoop);
      _genCondJump(stmt.cond, lblEnd);

      flowStack.add(_FlowContext.loop(lblLoop));
      genStmt(stmt.body);
      flowStack.removeLast();
      emit('BBRA     $lblLoop', 'Loop back');
      emitLabel(lblEnd);
      breakStack.removeLast();
    } else if (stmt is ForRangeNode) {
      final lblLoop = newLabel('for_start');
      final lblBody = newLabel('for_body');
      final lblEnd = newLabel('for_end');
      breakStack.add(lblEnd);

      final endVarName = '${stmt.varName}__end';

      // 1. Initialize induction variable
      genExpr(stmt.startExpr, 1);
      var varOff = stackOffset - locals[stmt.varName]!;
      emitImmediate(14, varOff);
      emit('ADD     R14, R15');
      emit('ST32    (R14), R1', "Init for-loop var '${stmt.varName}'");

      // 2. Evaluate upper bound once and store into pre-allocated slot
      genExpr(stmt.endExpr, 1);
      var endOff = stackOffset - locals[endVarName]!;
      emitImmediate(14, endOff);
      emit('ADD     R14, R15');
      emit('ST32    (R14), R1', "Cache upper bound for loop '${stmt.varName}'");

      // 3. Trampoline condition check
      emitLabel(lblLoop);
      varOff = stackOffset - locals[stmt.varName]!;
      emitImmediate(14, varOff);
      emit('ADD     R14, R15');
      emit('LD32    R1, (R14)', "Load induction var '${stmt.varName}'");

      endOff = stackOffset - locals[endVarName]!;
      emitImmediate(14, endOff);
      emit('ADD     R14, R15');
      emit('LD32    R2, (R14)', "Load cached upper bound for '${stmt.varName}'");

      if (_isSignedName(cleanName(stmt.varType))) {
        emit('SSLT    R1, R2', 'Loop condition i < end (signed)');
      } else {
        emit('SLT     R1, R2', 'Loop condition i < end');
      }
      emit('FBRA.NZ R1, $lblBody', 'Enter for body if true');
      emit('FBRA    $lblEnd', 'Exit for loop if false');

      // 4. Body
      emitLabel(lblBody);
      final loopCtx = _FlowContext.lazyLoop(() => newLabel('for_step'));
      flowStack.add(loopCtx);
      genStmt(stmt.body);
      flowStack.removeLast();

      // 5. Unit stride step (+1)
      if (loopCtx.continueLabel != null) {
        emitLabel(loopCtx.continueLabel!);
      }
      varOff = stackOffset - locals[stmt.varName]!;
      emitImmediate(14, varOff);
      emit('ADD     R14, R15');
      emit('LD32    R1, (R14)');
      emit('ADD     R1, 1', "Step '${stmt.varName}' +1");
      emit('ST32    (R14), R1');

      // 6. Branch back
      emit('BBRA    $lblLoop', 'Loop back');

      // 7. Epilogue
      emitLabel(lblEnd);
      breakStack.removeLast();
    }
  }

  /// Emits a case or default label of the innermost switch. Reaching a label
  /// from the case above ends that case: an implicit break is emitted first.
  void _emitCaseLabel(String label) {
    _FlowContext? ctx;
    for (final c in flowStack.reversed) {
      if (c.isSwitch) {
        ctx = c;
        break;
      }
    }
    if (ctx != null) {
      final idx = ctx.caseLabels.indexOf(label);
      if (idx > 0 || (idx == 0 && ctx.currentCase >= 0)) {
        emit('FBRA    ${ctx.endLabel}', 'Implicit break at end of case');
      }
      if (idx >= 0) ctx.currentCase = idx;
    }
    emitLabel(label);
  }

  void _genCondJump(AstNode condExpr, String falseTarget) {
    try {
      _genCondJumpInner(condExpr, falseTarget);
    } on CompileError catch (e) {
      throw e.at(condExpr.loc);
    }
  }

  void _genCondJumpInner(AstNode condExpr, String falseTarget) {
    // A condition that is an operation on constants is decided now
    final folded = _foldedCondition(condExpr);
    if (folded != null) {
      if (!folded) emit('FBRA     $falseTarget', 'Constant condition is false');
      return;
    }
    // Optimized control-flow branch fusion for relational comparisons and short-circuiting
    if (condExpr is BinaryOpNode && condExpr.op == '&&') {
      _genCondJump(condExpr.left, falseTarget);
      _genCondJump(condExpr.right, falseTarget);
      return;
    } else if (condExpr is BinaryOpNode && condExpr.op == '||') {
      final lblBody = newLabel('or_body');
      _genCondJumpTrue(condExpr.left, lblBody);
      _genCondJump(condExpr.right, falseTarget);
      emitLabel(lblBody);
      return;
    }

    final lblHop = newLabel('hop_false');
    final lblCont = newLabel('hop_cont');

    if (condExpr is BinaryOpNode &&
        ['==', '!=', '<=', '>=', '<', '>'].contains(condExpr.op)) {
      _checkBinaryConsts(condExpr);
      genExpr(condExpr.left, 1);
      emit('PUSH32  R1', 'Save LHS for comparison branch');
      stackOffset += 4;
      genExpr(condExpr.right, 2);
      emit('POP32   R1', 'Restore LHS for comparison branch');
      stackOffset -= 4;

      final op = condExpr.op;
      final isSigned = _isSignedBinary(condExpr);
      final sleOp = isSigned ? 'SSLE' : 'SLE';
      final kind = isSigned ? 'signed' : 'unsigned';

      if (op == '==') {
        emit('SEQ      R1, R2', 'Single-cycle equal');
        emit('FBRA.Z   R1, $lblHop', 'Hop if condition false (not equal)');
      } else if (op == '!=') {
        emit('SNE      R1, R2', 'Single-cycle not-equal');
        emit('FBRA.Z   R1, $lblHop', 'Hop if condition false (equal)');
      } else if (op == '<=') {
        emit('${sleOp.padRight(8)} R1, R2', 'Single-cycle $kind less-equal');
        emit('FBRA.Z   R1, $lblHop', 'Hop if condition false (!(L <= R))');
      } else if (op == '>=') {
        emit('${sleOp.padRight(8)} R2, R1',
            'Single-cycle $kind greater-equal (swapped <=)');
        emit('FBRA.Z   R2, $lblHop', 'Hop if condition false (!(R <= L))');
      } else if (op == '<') {
        emit('${sleOp.padRight(8)} R2, R1',
            'Single-cycle $kind less check via inverted SLE');
        emit('FBRA.NZ  R2, $lblHop', 'Hop if condition false (R <= L)');
      } else if (op == '>') {
        emit('${sleOp.padRight(8)} R1, R2',
            'Single-cycle $kind greater check via inverted SLE');
        emit('FBRA.NZ  R1, $lblHop', 'Hop if condition false (L <= R)');
      }
    } else {
      genExpr(condExpr, 1);
      emit('FBRA.Z   R1, $lblHop', 'Hop if condition false');
    }

    emit('FBRA     $lblCont', 'Enter body');
    emitLabel(lblHop);
    emit('FBRA     $falseTarget', 'Wide branch to target (8-bit)');
    emitLabel(lblCont);
  }

  void _genCondJumpTrue(AstNode condExpr, String trueTarget) {
    try {
      _genCondJumpTrueInner(condExpr, trueTarget);
    } on CompileError catch (e) {
      throw e.at(condExpr.loc);
    }
  }

  void _genCondJumpTrueInner(AstNode condExpr, String trueTarget) {
    final folded = _foldedCondition(condExpr);
    if (folded != null) {
      if (folded) emit('FBRA    $trueTarget', 'Constant condition is true');
      return;
    }
    // Jump to true_target if cond_expr evaluates to TRUE (!= 0)
    if (condExpr is BinaryOpNode && condExpr.op == '||') {
      _genCondJumpTrue(condExpr.left, trueTarget);
      _genCondJumpTrue(condExpr.right, trueTarget);
    } else if (condExpr is BinaryOpNode && condExpr.op == '&&') {
      final lblSkip = newLabel('and_skip');
      _genCondJump(condExpr.left, lblSkip);
      _genCondJumpTrue(condExpr.right, trueTarget);
      emitLabel(lblSkip);
    } else {
      genExpr(condExpr, 1);
      final lblCont = newLabel('hop_cont');
      final lblHop = newLabel('hop_true');
      emit('FBRA.NZ R1, $lblHop', 'Hop if condition true (!= 0)');
      emit('FBRA    $lblCont', 'Fall through');
      emitLabel(lblHop);
      emit('FBRA    $trueTarget', 'Wide branch to true target (8-bit)');
      emitLabel(lblCont);
    }
  }
}

bool _listEq(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Python `str.splitlines()`.
List<String> _splitLines(String s) {
  final lines = s.split(RegExp(r'\r\n|\r|\n'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}
