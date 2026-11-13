part of 'codegen.dart';

// ------------------------------------------------------------------------------
// Checking functions
// ------------------------------------------------------------------------------
//
// The checker walks every function the way code generation does: the same
// statements and expressions, in the same order, with the same scopes (the
// parameters and locals of the function, those of each inline function
// expanded into it, constant `if` branches that are left out). Everything
// that can be wrong with a program is found here, and the type of each
// expression is recorded in [Checker.exprTypes]. Code generation then only
// emits code.
//
// The walk must stay in step with codegen.dart, statements.dart and
// expressions.dart: each function here is named after the one it mirrors.

extension _CheckWalk on Checker {
  /// Mirrors [CodeGen.genFunc].
  void _checkFunc(FuncDeclNode func) {
    try {
      _checkFuncInner(func);
    } on CompileError catch (e) {
      throw e.at(func.loc);
    }
  }

  void _checkFuncInner(FuncDeclNode func) {
    _globalScope?.restore(this);
    currentFuncName = func.name;
    _readOnly
      ..clear()
      ..addAll([if (func.name == 'main') for (final p in func.params) p.name]);
    currentFuncRet = (cleanType(func.retType), func.retPtr);
    locals = {};
    openArrays.clear();
    dynamicArrays.clear();
    borrowedParams.clear();
    openRanks.clear();
    affineState = {};
    for (final p in func.params) {
      final cleanPt = cleanName(p.type);
      final isRef = (structs.containsKey(cleanPt) && !p.isPtr) || p.isOpenArr;
      types[p.name] = TypeInfo(p.type, p.isPtr, isRef, p.isRefArray);
      borrowedParams.add(p.name);
      locals[p.name] = 0;
      if (p.isOpenArr) {
        openArrays.add(p.name);
        locals['${p.name}__len'] = 0;
        if (p.openRank > 1) openRanks[p.name] = p.openRank;
        for (var k = 1; k < p.openRank; k++) {
          locals['${p.name}__len$k'] = 0;
        }
      }
    }
    _enterFunctionScope(func);
    _checkLocalDecls(func.name, func.body);

    currentFuncIsTask = func.isTask;
    if (func.isTask) {
      _checkTask(func);
      _checkLvalue(VarAccessNode(func.params.first.name));
    }
    _checkBlock(func.body!);
    if (func.isTask) {
      _checkLvalue(VarAccessNode(func.params.first.name));
      _pkStatus('PK_ENDED');
    }
  }

  /// Declares the locals of [body] (a function's, or an inline function's),
  /// as [CodeGen._allocateLocalFrame] does.
  void _checkLocalDecls(String funcName, AstNode? body) {
    final decls = <VarDeclNode>[];
    _collectLocalDecls(body, decls);
    final funcRefs = _functionRefs[funcName] ?? const <String>{};
    for (final d in decls) {
      _declareLocal(funcRefs, d);
      locals[d.name] = 0;
    }
  }

  void _checkBlock(BlockNode block) {
    _enterBlock();
    for (final stmt in block.stmts) {
      _checkStmt(stmt);
    }
    _leaveBlock();
  }

  /// Mirrors [CodeGen.genStmt].
  void _checkStmt(AstNode stmt) {
    try {
      _checkStmtInner(stmt);
    } on CompileError catch (e) {
      throw e.at(stmt.loc);
    }
  }

  void _checkStmtInner(AstNode stmt) {
    if (stmt is BlockNode) {
      _checkBlock(stmt);
    } else if (stmt is AsmNode) {
      if (target.isHosted) {
        throw CompileError(
            "inline assembly is Particle assembly, which the LLVM compiler cannot use; call a C function declared 'extern' instead");
      }
    } else if (stmt is BreakNode) {
      if (_breakDepth == 0) {
        throw CompileError("'break' outside of loop or switch block");
      }
    } else if (stmt is ContinueNode) {
      if (_flowDepth == 0) {
        throw CompileError("'continue' outside of loop or switch block");
      }
    } else if (stmt is SwitchNode) {
      _breakDepth++;
      _checkCaseLabels(stmt.body);
      _checkCaseConsts(stmt);
      _checkExpr(stmt.expr);
      _flowDepth++;
      _checkStmt(stmt.body);
      _flowDepth--;
      _breakDepth--;
    } else if (stmt is VarDeclNode) {
      _checkVarDecl(stmt);
    } else if (stmt is CompoundAssignNode) {
      _checkWritable(stmt.lhs);
      _checkExpr(stmt.rhs);
      final lhs = stmt.lhs;
      if (lhs is VarAccessNode) {
        _checkDefined(lhs.name);
      } else if (lhs is ArrayAccessNode) {
        _checkArrayElem(lhs, isWrite: true);
      } else if (lhs is MemberAccessNode) {
        _getExprType(lhs.expr);
        _checkLvalue(lhs.expr);
      }
    } else if (stmt is ExprStmtNode) {
      final e = stmt.expr;
      _statementExpr = e;
      try {
        _checkExpr(e);
      } finally {
        _statementExpr = null;
      }
    } else if (stmt is YieldNode) {
      _checkLvalue(stmt.taskRef);
      _pkStatus('PK_YIELDED');
    } else if (stmt is WaitUntilNode) {
      _checkExpr(stmt.cond);
      _checkLvalue(stmt.taskRef);
      _pkStatus('PK_WAITING');
    } else if (stmt is PkExitNode) {
      _checkLvalue(stmt.taskRef);
      _pkStatus('PK_EXITED');
    } else if (stmt is VerifyNode) {
      final res = _evalConstExpr(stmt.cond);
      if (res == 0) {
        final tok = stmt.token;
        final loc = tok != null ? tok.loc : 'verify';
        throw CompileError("$loc: Compile-time verification failed: '${stmt.msg}'");
      }
    } else if (stmt is TupleReturnNode) {
      final retTypeInfo = currentFuncRet;
      if (retTypeInfo.$1 is! List) {
        throw CompileError(
            "Function ${_shownFunc(currentFuncName)} has scalar return type '${retTypeInfo.$1}', cannot return tuple");
      }
      final retTypes = retTypeInfo.$1 as List;
      if (stmt.exprs.length != retTypes.length) {
        throw CompileError(
            "Tuple return arity mismatch in ${_shownFunc(currentFuncName)}: expected ${retTypes.length}, got ${stmt.exprs.length}");
      }
      for (var i = 0; i < stmt.exprs.length; i++) {
        final rt = retTypes[i];
        final (Object? rtName, bool rtPtr) = rt is (Object?, bool) ? rt : (rt, false);
        _rejectZeroReference(rtName, rtPtr, stmt.exprs[i],
            _zeroResultMessage("result ${i + 1} of ${_shownFunc(currentFuncName)}", rtName, rtPtr));
        _checkResultKind(stmt.exprs[i], rtName, rtPtr, "result ${i + 1} of ${_shownFunc(currentFuncName)}");
        _checkConstFits(stmt.exprs[i], rtName, rtPtr,
            "return value ${i + 1} of ${_shownFunc(currentFuncName)}");
      }
      for (final e in stmt.exprs) {
        _checkExpr(e);
      }
    } else if (stmt is TupleAssignNode) {
      _checkExpr(stmt.expr);
      for (final target in stmt.targets) {
        if (target.isWildcard) continue;
        if (target.typeName != null) {
          types[target.name!] = TypeInfo(target.typeName!, target.isPtr, false);
        }
      }
    } else if (stmt is ReturnNode) {
      final retTypeInfo = currentFuncRet;
      if (retTypeInfo.$1 is List) {
        throw CompileError(
            "Function ${_shownFunc(currentFuncName)} declared with tuple return of arity ${(retTypeInfo.$1 as List).length}, cannot return scalar or void");
      }
      if (currentFuncIsTask && _inlineDepth == 0) {
        if (stmt.expr != null) {
          throw CompileError(
              "task ${_shownFunc(currentFuncName)} cannot return a value; 'return;' ends the task");
        }
        return;
      }
      if (stmt.expr != null) {
        _rejectZeroReference(retTypeInfo.$1, retTypeInfo.$2, stmt.expr!,
            _zeroResultMessage("the result of ${_shownFunc(currentFuncName)}", retTypeInfo.$1, retTypeInfo.$2));
        _checkResultKind(stmt.expr!, retTypeInfo.$1, retTypeInfo.$2, "the result of ${_shownFunc(currentFuncName)}");
        _checkConstFits(stmt.expr, retTypeInfo.$1, retTypeInfo.$2,
            "return value of ${_shownFunc(currentFuncName)}");
        _checkExpr(stmt.expr!);
      }
    } else if (stmt is IfNode) {
      // A constant condition selects one branch; the other is left out
      // entirely, as code generation does
      int? constVal;
      try {
        _checkConditionKinds(stmt.cond);
      } on CompileError catch (e) {
        throw e.at(stmt.cond.loc);
      }
      try {
        constVal = _evalConstExpr(stmt.cond);
      } on NotConstantError {
        constVal = null;
      }
      if (constVal != null) {
        if (constVal != 0) {
          _checkStmt(stmt.thenBody);
        } else if (stmt.elseBody != null) {
          _checkStmt(stmt.elseBody!);
        }
        return;
      }
      _checkCond(stmt.cond);
      _checkStmt(stmt.thenBody);
      if (stmt.elseBody != null) _checkStmt(stmt.elseBody!);
    } else if (stmt is WhileNode) {
      _breakDepth++;
      _checkCond(stmt.cond);
      _flowDepth++;
      _checkStmt(stmt.body);
      _flowDepth--;
      _breakDepth--;
    } else if (stmt is ForRangeNode) {
      _breakDepth++;
      _checkExpr(stmt.startExpr);
      _checkExpr(stmt.endExpr);
      _flowDepth++;
      _checkStmt(stmt.body);
      _flowDepth--;
      _breakDepth--;
    }
  }

  /// A local declaration statement.
  void _checkVarDecl(VarDeclNode stmt) {
    _validateBackendType(stmt.typeName, "local variable '${stmt.name}'");
    if (stmt.isConst) {
      _declareLocalConst(stmt);
      return;
    }
    _resolveVarDecl(stmt);
    _checkInitializer(stmt, isGlobal: false);
    if (stmt.isRefDecl) _checkRefDecl(stmt);
    if (stmt.isRefArray) _checkRefArrayElem(stmt.name, stmt.typeName, stmt.loc);
    _rejectZeroInit(stmt);
    if (stmt.boundAddr != null) {
      boundAddrs[stmt.name] = stmt.boundAddr!;
      return;
    }
    final init = stmt.initExpr;
    if (init == null) return;
    if (stmt.typeName == 'string' && init is StringLitNode) {
      final capacity = stmt.arrayDim;
      if (capacity == null) {
        throw CompileError(
            "'>' not supported between instances of 'int' and 'NoneType'");
      }
      if (init.val.length >= capacity) {
        throw CompileError(
            'String literal length (${init.val.length}) exceeds capacity ($capacity) of string ${stmt.name}[$capacity]: '
            'it holds ${capacity - 1} characters and the terminator');
      }
      stringLens[stmt.name] = init.val.length;
      return;
    }
    final cap = _fixedStringCap(VarAccessNode(stmt.name));
    if (cap != null) {
      _checkStringSource(init, cap, "string '${stmt.name}'");
      _checkExpr(init);
      return;
    }
    if (stmt.dimExprs.isEmpty) {
      _checkConstFits(init, cleanName(stmt.typeName), stmt.isPtr, "variable '${stmt.name}'");
    }
    _checkArrayKinds(typeOf(stmt.name).refElems, init, stmt.name);
    _validateFnTypeAssignment(stmt.typeName, init, stmt.name);
    _checkRecordAssignment(stmt.name, init);
    _checkExpr(init);
    final name = stmt.name;
    if (init is HeapAllocNode || init is HeapArrayAllocNode || init is HeapStringAllocNode) {
      affineState[name] = 'VALID';
    }
    if (init is HeapArrayAllocNode) {
      init.refElems = stmt.isRefArray;
      final allocElemT = cleanName(init.typeName);
      final varElemT = cleanName(stmt.typeName);
      final isArrTarget = (stmt.arrayDims != null && stmt.arrayDims!.isNotEmpty) ||
          stmt.arrayDim != null ||
          stmt.isPtr;
      if (!isArrTarget) {
        throw CompileError("Cannot assign array allocation to non-array variable '$name'");
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
  }

  /// Evaluates the case labels of a switch body, as
  /// [CodeGen._collectSwitchLabels] does (it does not look inside `for`
  /// loops or nested switches).
  void _checkCaseLabels(AstNode node) {
    if (node is CaseLabelNode) {
      final e = node.expr;
      node.val = e is IntLitNode ? e.val : _evalConstExpr(e);
    } else if (node is BlockNode) {
      for (final s in node.stmts) {
        _checkCaseLabels(s);
      }
    } else if (node is IfNode) {
      _checkCaseLabels(node.thenBody);
      if (node.elseBody != null) _checkCaseLabels(node.elseBody!);
    } else if (node is WhileNode) {
      _checkCaseLabels(node.body);
    }
  }

  /// Mirrors [CodeGen._genCondJump]: a condition that branches when false.
  void _checkCond(AstNode cond) {
    try {
      _checkConditionKinds(cond);
      if (_foldedCondition(cond) != null) return;
      if (cond is BinaryOpNode && cond.op == '&&') {
        _checkCond(cond.left);
        _checkCond(cond.right);
      } else if (cond is BinaryOpNode && cond.op == '||') {
        _checkCondTrue(cond.left);
        _checkCond(cond.right);
      } else if (cond is BinaryOpNode &&
          ['==', '!=', '<=', '>=', '<', '>'].contains(cond.op)) {
        _checkBinaryConsts(cond);
        _checkExpr(cond.left);
        _checkExpr(cond.right);
      } else {
        _checkExpr(cond);
      }
    } on CompileError catch (e) {
      throw e.at(cond.loc);
    }
  }

  /// Mirrors [CodeGen._genCondJumpTrue]: a condition that branches when true.
  void _checkCondTrue(AstNode cond) {
    try {
      _checkConditionKinds(cond);
      if (_foldedCondition(cond) != null) return;
      if (cond is BinaryOpNode && cond.op == '||') {
        _checkCondTrue(cond.left);
        _checkCondTrue(cond.right);
      } else if (cond is BinaryOpNode && cond.op == '&&') {
        _checkCond(cond.left);
        _checkCondTrue(cond.right);
      } else {
        _checkExpr(cond);
      }
    } on CompileError catch (e) {
      throw e.at(cond.loc);
    }
  }

  // ------------------------------------------------------- operand kinds

  /// `T name = 0;` for a reference: an empty one is declared without a value.
  void _rejectZeroInit(VarDeclNode d) {
    final init = d.initExpr;
    if (init == null) return;
    final c = _tryConst(init);
    if (c == null || c.value != BigInt.zero) return;
    final t = cleanName(d.typeName);
    if (_isRecordTypeName(d.typeName) && d.dimExprs.isEmpty && !d.isPtr) {
      throw CompileError("'${d.name}': a reference cannot be 0; declare one that starts empty "
          "as 'ref $t ${d.name};'");
    }
    if (d.isPtr && d.dimExprs.isEmpty) {
      throw CompileError("'${d.name}': a reference cannot be 0; a heap "
          "${t == 'string' ? 'string' : 'array'} declared without a value starts empty: "
          "'$t ${d.name}[];'");
    }
  }

  /// The error for `return 0` from a function whose result ([what], of
  /// type [t]) is a reference.
  String _zeroResultMessage(String what, Object? t, bool isPtr) {
    final ct = cleanName(t);
    if (isPtr) {
      final kind = ct == 'string' ? 'heap string' : 'heap array';
      return "$what is a $kind, so it cannot be 0; return a variable declared "
          "'${ct == 'string' ? 'string' : ct} name[];', which starts empty";
    }
    return "$what is a reference, so it cannot be 0; return a reference variable instead "
        "(one declared 'ref $ct r;' starts empty)";
  }

  /// A returned value [v] is of the kind the result ([what], of type [t])
  /// is: a heap array or string when [isPtr], and never an array stored in
  /// the frame or a parameter borrowed from the caller.
  void _checkResultKind(AstNode v, Object? t, bool isPtr, String what) {
    if (t is List) return;
    final ct = cleanName(t);
    final k = _kindOf(v);
    final c = _tryConst(v);
    if (c != null) return;
    if (isPtr) {
      final wantString = ct == 'string';
      final kindOk = wantString ? k == _Kind.string : k == _Kind.array;
      if (kindOk && v is VarAccessNode && openArrays.contains(v.name)) {
        throw CompileError("'${v.name}' is borrowed from the caller, so it cannot be returned");
      }
      if (kindOk && v is VarAccessNode && borrowedParams.contains(v.name) && wantString) {
        throw CompileError("'${v.name}' is borrowed from the caller, so it cannot be returned");
      }
      final want = wantString ? 'a heap string' : "a heap array of '$ct'";
      if (!kindOk) throw CompileError("$what is $want, not the ${_kindWords(k, v)}");
      if (!_isHeapValue(v)) {
        throw CompileError("$what is $want; the ${_kindWords(k, v)} is stored in place, "
            'so it cannot be returned');
      }
      final vt = cleanName(_getExprType(v).$1);
      if (!wantString && vt != ct) {
        throw CompileError("$what is a heap array of '$ct', not of '$vt'");
      }
      return;
    }
    if (k == _Kind.array || k == _Kind.string) {
      throw CompileError("$what is a $ct, not the ${_kindWords(k, v)}");
    }
  }

  /// [e] as source text, for messages (indexes are shown as `[…]`).
  String _exprText(AstNode e) {
    if (e is VarAccessNode) return e.name;
    if (e is MemberAccessNode) return '${_exprText(e.expr)}.${e.member}';
    if (e is ArrayAccessNode) return '${_exprText(e.base)}[…]';
    return '…';
  }

  /// A value of type [t] (a reference when [isPtr], or a user-defined type,
  /// which is returned and stored as one) cannot be the constant 0.
  void _rejectZeroReference(Object? t, bool isPtr, AstNode value, String message) {
    if (t is List) return;
    if (!isPtr && !structs.containsKey(cleanName(t))) return;
    final c = _tryConst(value);
    if (c != null && c.value == BigInt.zero) throw CompileError(message);
  }

  /// How [k] is described in messages.
  String _kindWords(_Kind k, AstNode e) {
    final name = e is VarAccessNode
        ? " '${e.name}'"
        : e is MemberAccessNode
            ? " '${e.member}'"
            : '';
    switch (k) {
      case _Kind.string:
        return 'string$name';
      case _Kind.array:
        return 'array$name';
      case _Kind.record:
        final (t, _) = _getExprType(e);
        return "'${cleanName(t)}' value$name";
      case _Kind.reference:
        return 'reference$name';
      case _Kind.function:
        return 'function value$name';
      case _Kind.scalar:
        return name.isEmpty && _tryConst(e) != null ? 'number ${_tryConst(e)!.value}' : 'value$name';
    }
  }

  /// True when [e] (a string or array) is a reference to one on the heap.
  bool _isHeapValue(AstNode e) {
    if (e is HeapArrayAllocNode || e is HeapStringAllocNode) return true;
    if (e is VarAccessNode) {
      if (openArrays.contains(e.name) || arrayDims.containsKey(e.name)) return false;
      return dynamicArrays.contains(e.name) || typeOf(e.name).isPtr;
    }
    if (e is MemberAccessNode) {
      final f = _refField(e);
      return f != null && f.isArrayRef;
    }
    if (e is ArrayAccessNode) return _isRefElement(e);
    if (e is CallNode) return _getExprType(e).$2;
    return false;
  }

  /// The operands of binary operator [e] (other than `=`): numbers, except
  /// that `==` and `!=` also compare function values, and `a.sameAs(b)`
  /// compares references.
  void _checkOperands(BinaryOpNode e) {
    final lk = _kindOf(e.left);
    final rk = _kindOf(e.right);
    if (e.identity) {
      for (final (side, k) in [(e.left, lk), (e.right, rk)]) {
        final ok = k == _Kind.reference ||
            ((k == _Kind.array || k == _Kind.string) && _isHeapValue(side));
        if (!ok) {
          throw CompileError('sameAs() tells whether two references are to the same value; '
              'the ${_kindWords(k, side)} is not a reference');
        }
      }
      final lt = cleanName(_getExprType(e.left).$1);
      final rt = cleanName(_getExprType(e.right).$1);
      if (lt != rt || lk != rk) {
        throw CompileError("sameAs() compares references of the same type, not '$lt' and '$rt'");
      }
      return;
    }
    final op = e.op;
    if (lk == _Kind.scalar && rk == _Kind.scalar) _checkFloatOperands(op, e.left, e.right);
    final isEquality = op == '==' || op == '!=';
    final isCompare = isEquality || const ['<', '<=', '>', '>='].contains(op);
    for (final (side, k, other, ok) in [(e.left, lk, e.right, rk), (e.right, rk, e.left, lk)]) {
      switch (k) {
        case _Kind.scalar:
          continue;
        case _Kind.function:
          if (isEquality && ok == _Kind.function) continue;
          throw CompileError("'$op' cannot be used on the ${_kindWords(k, side)}");
        case _Kind.string:
          if (isCompare) {
            throw CompileError("strings cannot be compared with '$op'; use stringEquals(a, b) "
                'or stringCompare(a, b) from lib/string.act');
          }
          throw CompileError("'$op' cannot be used on the ${_kindWords(k, side)}");
        case _Kind.array:
          if (isCompare) {
            throw CompileError("arrays cannot be compared with '$op'; compare their elements"
                "${_isHeapValue(side) ? ', or use a.sameAs(b) to tell whether two heap arrays are the same one' : ''}");
          }
          throw CompileError("'$op' cannot be used on the ${_kindWords(k, side)}");
        case _Kind.record:
          if (isCompare) {
            throw CompileError("values of user-defined types cannot be compared with '$op'; "
                'compare their fields');
          }
          throw CompileError("'$op' cannot be used on the ${_kindWords(k, side)}");
        case _Kind.reference:
          final c = ok == _Kind.scalar ? _tryConst(other) : null;
          if (isEquality && c != null && c.value == BigInt.zero) {
            throw CompileError('a reference is not compared with 0; use r.exists() to tell '
                'whether it has a value');
          }
          if (isEquality) {
            throw CompileError("references are compared with a.sameAs(b), not '$op'");
          }
          throw CompileError("'$op' cannot be used on the ${_kindWords(k, side)}");
      }
    }
  }

  /// `T(x)`: [x] is a number, and a constant must fit `T`.
  void _checkConvert(ConvertNode e) {
    _validateBackendType(e.typeName, '${e.typeName}(...)');
    final k = _kindOf(e.expr);
    if (k != _Kind.scalar) {
      throw CompileError('${e.typeName}(...) converts a number, not the ${_kindWords(k, e.expr)}');
    }
    final c = _tryConst(e);
    if (c != null) {
      _requireRegisterValue(c.value);
      return;
    }
    _checkExpr(e.expr);
  }

  /// The operand of unary [e] is a number.
  void _checkUnaryOperand(UnaryOpNode e) {
    final k = _kindOf(e.operand);
    if (k == _Kind.scalar) {
      final f = _floatTypeOf(e.operand);
      if (f != null && e.op != '-') {
        throw CompileError(e.op == '!'
            ? "'!' is for integers and bools; compare the ${f == 'float' ? 'floating-point' : f} value, as in x == 0.0"
            : "'${e.op}' is for integers, not ${f == 'float' ? 'floating-point' : f} values");
      }
      return;
    }
    if (k == _Kind.reference && e.op == '!') {
      throw CompileError('a reference is not a condition; use !r.exists()');
    }
    throw CompileError("'${e.op}' cannot be used on the ${_kindWords(k, e.operand)}");
  }

  /// A condition (and each side of its `&&` and `||`) is a number.
  void _checkConditionKinds(AstNode cond) {
    if (cond is BinaryOpNode && (cond.op == '&&' || cond.op == '||')) {
      _checkConditionKinds(cond.left);
      _checkConditionKinds(cond.right);
      return;
    }
    if (cond is BinaryOpNode && cond.op != '=') {
      _checkOperands(cond);
      return;
    }
    if (cond is UnaryOpNode) {
      _checkUnaryOperand(cond);
      return;
    }
    final k = _kindOf(cond);
    if (k == _Kind.scalar) {
      final f = _floatTypeOf(cond);
      if (f != null) {
        throw CompileError('a condition is an integer or bool; compare the '
            "${f == 'float' ? 'floating-point' : f} value, as in x != 0.0");
      }
      return;
    }
    if (k == _Kind.reference) {
      throw CompileError('a reference is not a condition; use r.exists()');
    }
    throw CompileError('a condition is a number or bool, not the ${_kindWords(k, cond)}');
  }

  /// A name used as a variable must be a parameter, local or global.
  void _checkDefined(String name) {
    if (!boundAddrs.containsKey(name) &&
        !locals.containsKey(name) &&
        !globals.contains(name)) {
      _checkNotCallerName(name);
      _undefinedName(name);
    }
  }

  /// In an inline function's body, a name of the function it is expanded
  /// into is out of scope.
  void _checkNotCallerName(String name) {
    if (_inlineDepth > 0 && _hiddenCallerNames.contains(name)) {
      throw CompileError(
          "'$name' belongs to '$currentFuncName', which inline function '${_inlineExpanding.last}' "
          "is expanded into; an inline function can use only its parameters, its own "
          "variables and constants, and globals, so pass it as a parameter");
    }
  }

  /// Mirrors [CodeGen._emitLvalueAddr].
  void _checkLvalue(AstNode node) {
    if (node is VarAccessNode) {
      _checkDefined(node.name);
    } else if (node is MemberAccessNode) {
      _getExprType(node.expr);
      _checkLvalue(node.expr);
    } else if (node is ArrayAccessNode) {
      _checkArrayElem(node);
    } else {
      _checkExpr(node);
    }
  }

  /// Mirrors [CodeGen._emitArrayElemAddr].
  void _checkArrayElem(ArrayAccessNode node, {bool isWrite = false}) {
    final (baseNode, idxList) = _splitIndex(node);
    final indices = idxList.reversed.toList();
    final baseName = baseNode.nodeName;
    final isOpen = baseName != null && openArrays.contains(baseName);
    final dims = arrayDims[baseName] ?? <int>[];
    if (dims.isEmpty &&
        !(baseName != null && arrayLens.containsKey(baseName)) &&
        baseNode is MemberAccessNode) {
      _getExprType(baseNode.expr);
    }
    var first = true;
    for (final idx in indices.reversed) {
      _checkExpr(idx);
      if (first && !isOpen && _refField(baseNode)?.isArrayRef == true) {
        // The bounds check of a heap array field reads the field first
        _checkLvalue(baseNode);
      }
      first = false;
    }
    _getExprType(baseNode);
    if (isOpen ||
        (baseName != null &&
            (boundAddrs.containsKey(baseName) ||
                locals.containsKey(baseName) ||
                globals.contains(baseName)))) {
      return;
    }
    if (baseNode is MemberAccessNode) {
      _checkLvalue(baseNode);
      _refField(baseNode);
    } else {
      _checkExpr(baseNode);
    }
  }

  /// Mirrors [CodeGen.genExpr], and records the expression's type.
  void _checkExpr(AstNode expr) {
    try {
      _checkExprInner(expr);
    } on CompileError catch (e) {
      throw e.at(expr.loc);
    }
    try {
      exprTypes[expr] = _getExprType(expr);
    } on CompileError {
      // An expression that has no type of its own (a type name)
    }
  }

  void _checkExprInner(AstNode expr) {
    if (expr is ConvertNode) {
      _checkConvert(expr);
      return;
    }
    if (expr is BinaryOpNode && expr.op != '=') _checkOperands(expr);
    if (expr is UnaryOpNode) _checkUnaryOperand(expr);
    if (expr is BinaryOpNode && expr.isUnset && !identical(expr, _statementExpr)) {
      throw CompileError('unset() is a statement; it has no value');
    }
    // An operation on constants is evaluated at compile time
    if (expr is UnaryOpNode || (expr is BinaryOpNode && expr.op != '=')) {
      final c = _tryConst(expr);
      if (c != null) {
        _requireRegisterValue(c.value);
        return;
      }
    }
    if (expr is HeapAllocNode) {
      _checkCreateValues(expr);
    } else if (expr is HeapArrayAllocNode) {
      _checkExpr(expr.countExpr);
    } else if (expr is HeapStringAllocNode) {
      _checkExpr(expr.capExpr);
    } else if (expr is HeapFreeNode) {
      _checkWritable(expr.expr);
      final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
      if (targetVar != null && borrowedParams.contains(targetVar)) {
        throw CompileError("cannot destroy borrowed reference parameter '$targetVar'");
      }
      if (targetVar != null &&
          _isRecordTypeName(typeOf(targetVar).name) &&
          !typeOf(targetVar).isRef &&
          !typeOf(targetVar).isPtr &&
          !arrayDims.containsKey(targetVar)) {
        throw CompileError(
            "cannot destroy '$targetVar': it is a '${cleanName(typeOf(targetVar).name)}' stored on the stack; only references from .create() can be destroyed");
      }
      _refField(expr.expr);
      _checkExpr(expr.expr);
      if (targetVar != null && affineState.containsKey(targetVar)) {
        affineState[targetVar] = 'MOVED';
      }
    } else if (expr is HeapArrayResizeNode) {
      _checkWritable(expr.expr);
      if (_refField(expr.expr) != null) {
        _checkExpr(expr.expr);
        _checkExpr(expr.newLenExpr);
      } else {
        _checkExpr(expr.newLenExpr);
        _checkExpr(expr.expr);
      }
    } else if (expr is HeapArrayFreeNode) {
      _checkWritable(expr.expr);
      final targetVar = expr.expr is VarAccessNode ? (expr.expr as VarAccessNode).name : null;
      _checkExpr(expr.expr);
      if (targetVar != null && affineState.containsKey(targetVar)) {
        affineState[targetVar] = 'MOVED';
      }
    } else if (expr is ExistsNode) {
      if (expr.expr is! VarAccessNode) _checkExpr(expr.expr);
    } else if (expr is SizeofNode) {
      _evalConstExpr(expr);
    } else if (expr is MemberAccessNode) {
      _checkMemberAccess(expr);
    } else if (expr is ArrayAccessNode) {
      _checkArrayElem(expr);
    } else if (expr is VarAccessNode) {
      final name = expr.name;
      if (constants.containsKey(name)) return;
      if (_floatConsts.containsKey(name) && !_isVariableInScope(name)) return;
      if (funcSignatures.containsKey(name)) {
        if (_trapHandlerNames.contains(name)) {
          throw CompileError("'$name' is a trap handler; it runs only when its trap is taken");
        }
        return;
      }
      _checkDefined(name);
    } else if (expr is UnaryOpNode) {
      _checkExpr(expr.operand);
    } else if (expr is CompoundAssignNode) {
      final opChar = expr.op.substring(0, expr.op.length - 1);
      _checkWritable(expr.lhs);
      _checkFloatOperands(opChar, expr.lhs, expr.rhs);
      _checkCompoundConst(expr, opChar);
      _checkExpr(expr.rhs);
      final lhs = expr.lhs;
      if (lhs is VarAccessNode) {
        _checkDefined(lhs.name);
      } else if (lhs is ArrayAccessNode) {
        _checkArrayElem(lhs, isWrite: true);
      } else if (lhs is MemberAccessNode) {
        _getExprType(lhs.expr);
        _checkLvalue(lhs.expr);
      }
    } else if (expr is BinaryOpNode) {
      _checkBinaryOp(expr);
    } else if (expr is CallNode) {
      _checkCall(expr);
    }
  }

  /// Mirrors [CodeGen._genMemberAccess].
  void _checkMemberAccess(MemberAccessNode expr) {
    final baseExpr = expr.expr;
    final member = expr.member;
    if ((member == 'capacity' ||
            (member == 'len' &&
                !(baseExpr is VarAccessNode &&
                    cleanType(typeOf(baseExpr.name).name) == 'string' &&
                    !typeOf(baseExpr.name).refElems))) &&
        baseExpr is VarAccessNode &&
        openArrays.contains(baseExpr.name)) {
      return;
    }
    if (member == 'len' || member == 'capacity') {
      if (baseExpr is ArrayAccessNode && _isRefElement(baseExpr) &&
          cleanType(_getExprType(baseExpr).$1) == 'string') {
        if (member == 'capacity') {
          var root = baseExpr as AstNode;
          while (root is ArrayAccessNode) {
            root = root.base;
          }
          if (root is VarAccessNode && _readOnly.contains(root.name)) {
            throw CompileError(
                "the command line's strings have no capacity; use .len, or copy one into a string buffer");
          }
        }
        _checkExpr(baseExpr);
        return;
      }
      if (baseExpr is ArrayAccessNode && _isStringRow(baseExpr)) {
        if (member == 'len') _checkArrayElem(baseExpr);
        return;
      }
      if (baseExpr is MemberAccessNode && member == 'len' && _fixedStringCap(baseExpr) != null) {
        _checkLvalue(baseExpr);
        return;
      }
      if (baseExpr is VarAccessNode && member == 'len' && !openArrays.contains(baseExpr.name)) {
        final t = typeOf(baseExpr.name);
        final dims = arrayDims[baseExpr.name];
        if ((t.refElems && !t.isPtr) || (cleanType(t.name) == 'string' && dims != null && dims.length > 1)) {
          return;
        }
      }
    }
    final arrField = _refField(baseExpr);
    if (arrField != null && arrField.isArrayRef && (member == 'len' || member == 'capacity')) {
      _checkExpr(baseExpr);
      return;
    }
    if (member == 'capacity') {
      if (baseExpr is VarAccessNode &&
          (affineState.containsKey(baseExpr.name) ||
              typeOf(baseExpr.name, const TypeInfo('', false)).isPtr)) {
        _checkExpr(baseExpr);
      } else if (baseExpr is MemberAccessNode) {
        _getExprType(baseExpr.expr);
      }
      return;
    } else if (member == 'len') {
      final arrName = baseExpr.nodeName ?? '';
      final t = typeOf(arrName, const TypeInfo('', false));
      final isDynamic = t.isPtr || affineState.containsKey(arrName);
      if (isDynamic && (t.name != 'string' || t.refElems)) {
        _checkExpr(baseExpr);
        return;
      }
      if (t.name == 'string' || baseExpr is VarAccessNode) return;
      if (baseExpr is MemberAccessNode) {
        _getExprType(baseExpr.expr);
        return;
      }
    }

    // A method of a type, named through the type: its address
    if (baseExpr is VarAccessNode &&
        structs.containsKey(baseExpr.name) &&
        !locals.containsKey(baseExpr.name) &&
        !globals.contains(baseExpr.name) &&
        !boundAddrs.containsKey(baseExpr.name)) {
      if (funcSignatures.containsKey('${baseExpr.name}_$member')) return;
      throw CompileError("Type '${baseExpr.name}' has no method '$member'");
    }

    final (tN, _) = _getExprType(baseExpr);
    final possibleType = cleanName(tN);
    if (funcSignatures.containsKey('${possibleType}_$member')) {
      final baseName = baseExpr.nodeName ?? 'instance';
      throw CompileError(
          "Cannot extract unbound method reference from instance '$baseName'. "
          "Use '$possibleType.$member' with signature fn($possibleType, ...) instead.");
    }
    _checkLvalue(expr);
  }

  /// Mirrors [CodeGen._genBinaryOp].
  void _checkBinaryOp(BinaryOpNode expr) {
    if (expr.op == '&&' || expr.op == '||') {
      _checkExpr(expr.left);
      _checkExpr(expr.right);
      return;
    }
    if (expr.op != '=') {
      _checkBinaryConsts(expr);
      _checkExpr(expr.left);
      _checkExpr(expr.right);
      return;
    }
    final left = expr.left;
    final right = expr.right;
    _checkWritable(left);
    final lk = _kindOf(left);
    final leftIsRef = lk == _Kind.reference ||
        ((lk == _Kind.array || lk == _Kind.string) && _isHeapValue(left));
    if (expr.isUnset) {
      if (!leftIsRef) {
        throw CompileError('unset() empties a reference; the ${_kindWords(lk, left)} is not one');
      }
      _checkLvalue(left);
      return;
    }
    if (lk == _Kind.array && !leftIsRef) {
      throw CompileError("arrays cannot be assigned; '${_exprText(left)}' is an array, so copy its elements");
    }
    if (leftIsRef) {
      final c = _tryConst(right);
      if (c != null && c.value == BigInt.zero) {
        final text = _exprText(left);
        throw CompileError("'$text' is a reference, so it cannot be given 0; empty it with $text.unset()");
      }
    }
    final cap = _fixedStringCap(left);
    if (cap != null) {
      // Copied into the buffer
      _checkStringSource(right, cap, _targetName(left));
      _checkLvalue(left);
      _checkExpr(right);
      return;
    }
    if (_isRefElement(left)) _checkRefElementAssignment(left as ArrayAccessNode, right);
    if (left is VarAccessNode || left is MemberAccessNode || left is ArrayAccessNode) {
      final (lt, lp) = _getExprType(left);
      _checkConstFits(right, lt, lp, 'assignment to ${_targetName(left)}');
    }
    if (left is MemberAccessNode) {
      final rf = _refField(left);
      if (rf != null) _checkRefFieldAssignment(left, rf, right);
      if (rf != null && rf.isArrayRef) _checkArrayKinds(rf.refElems, right, left.member);
      _checkLvalue(left);
      _checkExpr(right);
      return;
    }
    _checkExpr(right);
    if (left is ArrayAccessNode) {
      _checkArrayElem(left, isWrite: true);
    } else if (left is VarAccessNode) {
      final name = left.name;
      _checkArrayKinds(typeOf(name).refElems, right, name);
      if (right is HeapAllocNode || right is HeapArrayAllocNode || right is HeapStringAllocNode) {
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
            throw CompileError("Cannot assign array allocation to non-array variable '$name'");
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
          throw CompileError("cannot take ownership of borrowed parameter '$rhsName'");
        }
        if (affineState.containsKey(rhsName)) {
          affineState[rhsName] = 'MOVED';
          affineState[name] = 'VALID';
          if (dynamicArrays.contains(rhsName)) dynamicArrays.add(name);
        }
      }
      _validateFnTypeAssignment(typeOf(name).name, right, name);
      _checkRecordAssignment(name, right);
      _checkDefined(name);
    }
  }

  /// Mirrors [CodeGen._genCall].
  void _checkCall(CallNode expr) {
    if (expr.name == '__copyFrom') {
      _checkCopyFrom(expr);
      return;
    }
    final cv = _callValue(expr);
    if (cv != null) {
      final (callee, fnT, args) = cv;
      final fn = fnTypes[fnT];
      if (fn == null) {
        throw CompileError("'${_exprText(callee)}' is not a function value, so it cannot be called");
      }
      if (!identical(expr, _statementExpr) && cleanName(fn.$2) == 'void') {
        throw CompileError("'${_exprText(callee)}' returns nothing, so its call has no value to use");
      }
      _checkArgCount(_exprText(callee), args.length, fn.$1.length);
      _checkCallArgList(args, [for (final p in fn.$1) ParamSig(cleanName(p), false, false)]);
      _checkExpr(callee);
      return;
    }
    if (!identical(expr, _statementExpr) && _callReturnsNothing(expr)) {
      final name = expr.name.replaceFirst('__METHOD__', '');
      throw CompileError("'$name' returns nothing, so its call has no value to use");
    }
    if (_trapHandlerNames.contains(expr.name)) {
      throw CompileError(
          "'${expr.name}' is a trap handler; it runs only when its trap is taken");
    }
    if (expr.name == 'trap' && expr.args.length == 1 && !funcSignatures.containsKey('trap')) {
      int n;
      try {
        n = _evalConstExpr(expr.args[0]);
      } on NotConstantError {
        throw CompileError('trap: the trap number must be a constant');
      }
      if (n < 0 || n >= target.vectorCount) {
        // Constants are evaluated modulo 2^32; show a negative one as such
        final shown = n > 0x7FFFFFFF ? n - 0x100000000 : n;
        throw CompileError('trap number $shown is out of range (0-${target.vectorCount - 1})');
      }
      return;
    }
    if (_isCoroutineOp(expr.name)) {
      throw CompileError(
          "'${expr.name}' returns from the task; use it as a statement, not in an expression");
    }
    if (expr.name.startsWith('__METHOD__')) {
      final mName = expr.name.replaceAll('__METHOD__', '');
      final rcvNode = expr.args[0];
      final sName = cleanName(_getExprType(rcvNode).$1);
      final (resolved, _) = _resolveMethod(sName, mName);
      final targetFunc = resolved ?? '${sName}_$mName';
      if (rcvNode is CallNode) {
        _checkExpr(rcvNode);
      } else if (_refField(rcvNode) != null) {
        _checkExpr(rcvNode);
      } else {
        _checkLvalue(rcvNode);
      }
      final paramSigs = funcSignatures[targetFunc]?.params ?? <ParamSig>[];
      if (funcSignatures.containsKey(targetFunc)) {
        _checkArgCount('$sName.$mName', expr.args.length - 1, paramSigs.length - 1);
        _checkReadOnlyArgs(expr, targetFunc, '$sName.$mName');
      }
      if (expr.args.length > 1) {
        _checkCallArgList(
            expr.args.sublist(1), paramSigs.length > 1 ? paramSigs.sublist(1) : <ParamSig>[]);
      }
      return;
    }

    if (target.isHosted && const ['readFifo', 'writeFifo', 'tryReadFifo'].contains(expr.name) &&
        !funcSignatures.containsKey(expr.name)) {
      throw CompileError(
          "'${expr.name}': FIFOs are Particle hardware, which the LLVM compiler does not have");
    }
    if (expr.name == 'readFifo') {
      _fifoChannel(expr);
      return;
    } else if (expr.name == 'writeFifo') {
      _fifoChannel(expr);
      _checkExpr(expr.args[1]);
      return;
    } else if (expr.name == 'tryReadFifo') {
      _fifoChannel(expr);
      if (expr.args.length != 2) {
        throw CompileError(
            "tryReadFifo takes 2 arguments (channel, variable), got ${expr.args.length}");
      }
      _checkWritable(expr.args[1]);
      _getExprType(expr.args[1]);
      _checkLvalue(expr.args[1]);
      return;
    }

    if (_isMemoryBuiltin(expr)) {
      final (want, _) = _memoryBuiltins[expr.name]!;
      if (expr.args.length != want) {
        final what = want == 1 ? '1 argument (address)' : '2 arguments (address, value)';
        throw CompileError("${expr.name} takes $what, got ${expr.args.length}");
      }
      _checkConstFits(expr.args[0], 'u32', false, 'address of ${expr.name}');
      if (want == 2) {
        _checkConstFits(
            expr.args[1],
            const {'poke8': 'u8', 'poke16': 'u16'}[expr.name] ?? 'u32',
            false,
            'value of ${expr.name}');
      }
      for (final a in expr.args) {
        _checkExpr(a);
      }
      return;
    }

    if (inlineFuncs.containsKey(expr.name)) {
      _checkInlineCall(expr, inlineFuncs[expr.name]!);
      return;
    }

    final isFnVar = locals.containsKey(expr.name) ||
        globals.contains(expr.name) ||
        boundAddrs.containsKey(expr.name);
    if (isFnVar) {
      final fnT = typeOf(expr.name).name;
      if (fnTypes.containsKey(fnT)) {
        final (pTypes, _) = fnTypes[fnT]!;
        _checkArgCount(expr.name, expr.args.length, pTypes.length);
        _checkCallArgList(expr.args, [for (final p in pTypes) ParamSig(p, false, false)]);
      } else {
        for (var i = 0; i < expr.args.length && i < 4; i++) {
          _checkExpr(expr.args[i]);
        }
      }
      _checkExpr(VarAccessNode(expr.name));
      return;
    }
    final sigInfo = funcSignatures[expr.name];
    if (sigInfo == null) {
      // Every Action file of the program is here; anything else must be
      // promised by a prototype ('asm' for an assembly routine)
      throw CompileError(
          "'${expr.name}' is not declared; import the file that defines it, or declare it "
          "with a prototype ('asm u32 ${expr.name}(...);' if it is written in assembly)");
    }
    _checkArgCount(expr.name, expr.args.length, sigInfo.params.length, variadic: sigInfo.isVariadic);
    _checkReadOnlyArgs(expr, expr.name, expr.name);
    _checkCallArgList(expr.args, sigInfo.params);
  }

  /// An inline function's body, checked in place with its parameters and
  /// locals added to the caller's scope (see [CodeGen._genCall]).
  void _checkInlineCall(CallNode expr, FuncDeclNode func) {
    if (_inlineExpanding.contains(func.name)) {
      final through = _inlineExpanding.skipWhile((n) => n != func.name).skip(1).toList();
      final via = through.isEmpty ? '' : " (through ${through.map((n) => "'$n'").join(', ')})";
      throw CompileError(
          "'${func.name}' is inline and calls itself$via; inline functions cannot be recursive");
    }
    _checkArgCount(func.name, expr.args.length, func.params.length);
    _checkReadOnlyArgs(expr, func.name, func.name);
    // The arguments are evaluated in the caller's scope, then the body in
    // its own (see scopes.dart)
    final paramTypes = <TypeInfo>[];
    for (var i = 0; i < func.params.length; i++) {
      final p = func.params[i];
      final argExpr = expr.args[i];
      _checkConstFits(argExpr, p.type, p.isPtr || p.isOpenArr,
          "argument ${i + 1} of '${expr.name}'");
      final isRef = structs.containsKey(cleanName(p.type)) && !p.isPtr;
      paramTypes.add(TypeInfo(p.type, p.isPtr, isRef, p.isRefArray));
      if (isRef) {
        _checkLvalue(argExpr);
      } else {
        _checkExpr(argExpr);
      }
    }
    _inlineExpanding.add(func.name);
    final caller = _enterInlineBody(func);
    for (var i = 0; i < func.params.length; i++) {
      types[func.params[i].name] = paramTypes[i];
      locals[func.params[i].name] = 0;
    }
    _checkLocalDecls(func.name, func.body);
    _inlineDepth++;
    _checkBlock(func.body!);
    _inlineDepth--;
    _leaveInlineBody(caller);
    _inlineExpanding.remove(func.name);
  }

  /// Mirrors [CodeGen._genCallArgList].
  /// True when [call] is to a function, method or function value that
  /// returns nothing.
  bool _callReturnsNothing(CallNode call) {
    Object? ret;
    final n = call.name;
    if (n.startsWith('__METHOD__')) {
      try {
        final sName = cleanName(_getExprType(call.args[0]).$1);
        final (resolved, _) = _resolveMethod(sName, n.substring(10));
        ret = funcSignatures[resolved ?? '${sName}_${n.substring(10)}']?.retType;
      } on CompileError {
        return false;
      }
    } else if (locals.containsKey(n) || globals.contains(n) || boundAddrs.containsKey(n)) {
      ret = fnTypes[typeOf(n).name]?.$2;
    } else {
      ret = funcSignatures[n]?.retType;
    }
    return ret is String && cleanName(ret) == 'void';
  }

  /// A call to [callee] gives one argument per parameter (or more, after
  /// the `...` of a variadic C function).
  void _checkArgCount(String callee, int given, int expected, {bool variadic = false}) {
    if (given == expected || (variadic && given > expected)) return;
    final what = expected == 1 ? '1 argument' : '$expected arguments';
    throw CompileError("'$callee' takes ${variadic ? 'at least ' : ''}$what, not $given");
  }

  void _checkCallArgList(List<AstNode> args, List<ParamSig> paramSigs) {
    for (var i = 0; i < args.length && i < paramSigs.length; i++) {
      final p = paramSigs[i];
      if (!p.isOpen) _checkConstFits(args[i], p.type, p.isPtr, 'argument ${i + 1}');
    }
    for (var i = 0; i < args.length; i++) {
      _checkArgValue(
          args[i], i < paramSigs.length ? paramSigs[i] : const ParamSig(null, false, false));
    }
  }

  /// An argument for an open array parameter of more than one dimension:
  /// a whole array of the same element type and number of dimensions.
  void _checkMultiArg(AstNode arg, ParamSig pSig) {
    final want = pSig.openRank;
    final name = arg is VarAccessNode ? arg.name : null;
    final int? rank = name != null && openRanks.containsKey(name)
        ? openRanks[name]
        : _fixedDimsOf(arg)?.length;
    final shown = _exprText(arg);
    if (rank == null) {
      throw CompileError("an array of $want dimensions is expected here; '$shown' is "
          "${_kindOf(arg) == _Kind.array ? 'a heap array, which has one' : 'not an array'}");
    }
    if (rank != want) {
      throw CompileError("an array of $want dimensions is expected here; '$shown' has $rank");
    }
    final at = cleanName(_getExprType(arg).$1);
    final pt = cleanName(pSig.type);
    if (at != pt) {
      throw CompileError("an array of '$pt' is expected here; '$shown' is an array of '$at'");
    }
    if (arg is MemberAccessNode) {
      _checkLvalue(arg);
    } else {
      _checkExpr(arg);
    }
  }

  static const _sliceNotString = 'a slice of a string is an array of u8 characters with no '
      "terminator, not a string; pass it to a 'u8 s[]' parameter, or copy it into a string buffer";

  /// Mirrors [CodeGen._emitArgValue].
  void _checkArgValue(AstNode arg, ParamSig pSig) {
    final pType = pSig.type;
    if (!pSig.isOpen && arg is SliceNode && cleanName(pType) == 'string') {
      throw CompileError(_sliceNotString);
    }
    if (pSig.isOpen && pSig.openRank > 1) {
      _checkMultiArg(arg, pSig);
      return;
    }
    if (pSig.isOpen) {
      final argBase = arg is SliceNode ? arg.base : arg;
      final argRefs = _isRefArray(argBase);
      if (argRefs != pSig.isRefArray) {
        throw CompileError(pSig.isRefArray
            ? "an array of references ('ref ${pSig.type} ...[]') is expected here, not an array of values"
            : "an array of values is expected here, not an array of references");
      }
      if (arg is SliceNode) {
        final baseExpr = arg.base;
        final baseName = baseExpr.nodeName;
        _getExprType(baseExpr);
        if (!(baseName != null && openArrays.contains(baseName))) {
          _checkLvalue(baseExpr);
        }
        final startExpr = arg.startExpr;
        final endExpr = arg.endExpr;
        if (startExpr != null && startExpr is! IntLitNode) _checkExpr(startExpr);
        if (endExpr == null) {
          _checkArrayLen(baseExpr);
          if (startExpr != null && startExpr is! IntLitNode) _checkExpr(startExpr);
        } else if (startExpr == null) {
          if (endExpr is! IntLitNode) _checkExpr(endExpr);
        } else if (!(startExpr is IntLitNode && endExpr is IntLitNode)) {
          _checkExpr(endExpr);
          _checkExpr(startExpr);
        }
        return;
      }
      final argName = arg.nodeName;
      if (argName != null && openArrays.contains(argName)) return;
      if (argName != null &&
          arg is VarAccessNode &&
          typeOf(argName).isPtr &&
          !arrayDims.containsKey(argName) &&
          !arrayLens.containsKey(argName) &&
          (locals.containsKey(argName) || globals.contains(argName))) {
        _checkExpr(arg);
      } else if (_refField(arg)?.isArrayRef == true) {
        _checkExpr(arg);
      } else {
        _checkLvalue(arg);
        _getExprType(arg);
      }
    } else if (pType != null && pType.isNotEmpty && structs.containsKey(pType) && !pSig.isPtr) {
      if (_refField(arg) != null) {
        _checkExpr(arg);
      } else {
        _checkLvalue(arg);
      }
    } else {
      _checkExpr(arg);
    }
  }

  /// Mirrors [CodeGen._emitArrayLen].
  void _checkArrayLen(AstNode baseExpr) {
    final baseName = baseExpr.nodeName ?? '';
    if (baseName.isNotEmpty && openArrays.contains(baseName)) return;
    if (baseExpr is MemberAccessNode) {
      _getExprType(baseExpr.expr);
    } else {
      _getExprType(baseExpr);
    }
  }

  /// A heap array given to [name] (an array of references when
  /// [refElems]) must be of the same kind; `T.createArray(n)` makes the
  /// kind the target needs.
  void _checkArrayKinds(bool refElems, AstNode right, String name) {
    if (right is HeapArrayAllocNode) {
      right.refElems = refElems;
      return;
    }
    if (right is VarAccessNode && typeOf(right.name).isPtr && !openArrays.contains(right.name)) {
      final r = typeOf(right.name).refElems;
      if (r != refElems) {
        throw CompileError(refElems
            ? "Array type mismatch: '${right.name}' is an array of values, and '$name' an array of references"
            : "Array type mismatch: '${right.name}' is an array of references, and '$name' an array of values");
      }
    }
  }

  /// `main`'s command line cannot be written to.
  void _checkWritable(AstNode target) {
    var t = target;
    while (t is ArrayAccessNode || t is MemberAccessNode) {
      t = t is ArrayAccessNode ? t.base : (t as MemberAccessNode).expr;
    }
    if (t is VarAccessNode &&
        _readOnlyGlobals.contains(t.name) &&
        !locals.containsKey(t.name) &&
        !boundAddrs.containsKey(t.name)) {
      throw CompileError("'${t.name}' is a constant; its values cannot be changed");
    }
    if (t is VarAccessNode && _readOnly.contains(t.name) && locals.containsKey(t.name)) {
      throw CompileError(
          "'${t.name}' is read-only; copy a string into a buffer of its own to change it, as in 'string s[64] = ${t.name}[1];'");
    }
  }

  /// [src], copied into a string buffer of [cap] bytes named [what], must be
  /// a string; a literal must fit with its terminator.
  void _checkStringSource(AstNode src, int cap, String what) {
    if (src is SliceNode) throw CompileError(_sliceNotString);
    if (src is StringLitNode) {
      if (src.val.length >= cap) {
        throw CompileError(
            'String literal length (${src.val.length}) does not fit in $what, which holds ${cap - 1} characters and the terminator');
      }
      return;
    }
    final (t, _) = _getExprType(src);
    if (cleanType(t) != 'string') {
      throw CompileError("cannot assign a '${cleanName(t)}' to $what; only a string can be copied into it");
    }
  }

  /// `nodes[i] = rhs` for an array of references: the value must be a
  /// reference of the element type (or 0, the null reference).
  void _checkRefElementAssignment(ArrayAccessNode left, AstNode right) {
    final (base, _) = _splitIndex(left);
    final name = base is VarAccessNode ? base.name : (base as MemberAccessNode).member;
    final elemT = cleanName(base is VarAccessNode ? typeOf(name).name : _refArrayField(base)!.type);
    final what = "an element of '$name'";
    if (right is IntLitNode && right.val == 0) return;
    if (elemT == 'string') {
      if (right is StringLitNode || right is HeapStringAllocNode) return;
      final (t, _) = _getExprType(right);
      if (cleanType(t) != 'string') {
        throw CompileError("cannot assign a '${cleanName(t)}' to $what, a reference to a string");
      }
      return;
    }
    if (right is HeapAllocNode) {
      if (cleanName(right.typeName) != elemT) {
        throw CompileError(
            "Cannot assign instance of type '${cleanName(right.typeName)}' to $what, a reference to '$elemT'");
      }
      return;
    }
    if (right is VarAccessNode) {
      final rt = typeOf(right.name);
      if (_isRecordTypeName(rt.name) && !rt.isRef && !rt.isPtr && !arrayDims.containsKey(right.name)) {
        throw CompileError(
            "cannot assign '${right.name}', a '${cleanName(rt.name)}' stored on the stack, to $what");
      }
    } else if (right is MemberAccessNode || right is ArrayAccessNode) {
      final (rt, isPtr) = _getExprType(right);
      if (_isRecordTypeName(rt) && !isPtr) {
        throw CompileError(
            "cannot assign a '${cleanName(rt)}' stored inside another type or an array to $what");
      }
    }
    final (rt, _) = _getExprType(right);
    if (cleanName(rt) != elemT) {
      throw CompileError("Cannot assign type '${cleanName(rt)}' to $what, a reference to '$elemT'");
    }
  }

  /// The initial values of the globals, checked in the order code
  /// generation lays them out.
  void _checkGlobalData(List<VarDeclNode> dataDecls) {
    for (final d in dataDecls) {
      if (d.isConst || d.boundAddr != null) continue;
      try {
        var dims = d.arrayDims;
        if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
          dims = [d.arrayDim!];
        }
        final init = d.initExpr;
        _rejectZeroInit(d);
        _checkInitializer(d, isGlobal: true);
        if (dims != null && dims.isNotEmpty) {
          if (init != null) {
            // string s[N] = "text": the buffer starts with the literal
            if (cleanName(d.typeName) == 'string' && dims.length == 1) {
              _checkInitValue(d.typeName, dims, init, d.name, isGlobal: true);
              continue;
            }
            throw CompileError(
                "global array '${d.name}' is given its values in braces: = {a, b, ...}");
          }
          continue;
        }
        final cleanT = cleanName(d.typeName);
        if (structs.containsKey(cleanT) && !d.isPtr && !_globalRefs.contains(d.name)) {
          if (init != null) {
            throw CompileError(
                "global '${d.name}' of type '$cleanT' is given its values as {field: value, ...}, "
                'or is a reference');
          }
          continue;
        }
        if (_isFloatName(cleanT) && init != null) {
          _checkConstFits(init, cleanT, d.isPtr, "global variable '${d.name}'");
          if (_tryFloatConst(init) == null && _tryConst(init) == null) {
            throw CompileError(
                "The initializer of global variable '${d.name}' must be a constant expression");
          }
        } else if (init is IntLitNode) {
          _checkConstFits(init, cleanT, d.isPtr, "global variable '${d.name}'");
        } else if (init != null) {
          _globalInitValue(d);
        }
      } on CompileError catch (e) {
        throw e.at(d.loc);
      }
    }
  }
}

/// The program-level state that checking the functions changes, saved so
/// that code generation can start from the same state.
class _ScopeSnapshot {
  final Map<String, TypeInfo> types;
  final Map<String, int> locals;
  final Map<String, String> affineState;
  final Map<String, List<int>> arrayDims;
  final Map<String, int> arrayLens;
  final Map<String, int> stringLens;
  final Map<String, int> boundAddrs;
  final Set<String> dynamicArrays;
  final Set<String> borrowedParams;
  final Set<String> openArrays;
  final Map<String, int> constants;
  final Map<String, String?> constTypes;
  final Map<String, _ConstVal> constExactValues;
  final Map<String, FuncDeclNode> inlineFuncs;
  final String currentFuncName;
  final (Object?, bool) currentFuncRet;
  final bool currentFuncIsTask;

  _ScopeSnapshot(Checker c)
      : types = Map.of(c.types),
        locals = Map.of(c.locals),
        affineState = Map.of(c.affineState),
        arrayDims = Map.of(c.arrayDims),
        arrayLens = Map.of(c.arrayLens),
        stringLens = Map.of(c.stringLens),
        boundAddrs = Map.of(c.boundAddrs),
        dynamicArrays = Set.of(c.dynamicArrays),
        borrowedParams = Set.of(c.borrowedParams),
        openArrays = Set.of(c.openArrays),
        constants = Map.of(c.constants),
        constTypes = Map.of(c._constTypes),
        constExactValues = Map.of(c._constExactValues),
        inlineFuncs = Map.of(c.inlineFuncs),
        currentFuncName = c.currentFuncName,
        currentFuncRet = c.currentFuncRet,
        currentFuncIsTask = c.currentFuncIsTask;

  void restore(Checker c) {
    void put<K, V>(Map<K, V> m, Map<K, V> from) => m
      ..clear()
      ..addAll(from);
    void putSet<T>(Set<T> s, Set<T> from) => s
      ..clear()
      ..addAll(from);
    c.types = Map.of(types);
    c.locals = Map.of(locals);
    c.affineState = Map.of(affineState);
    put(c.arrayDims, arrayDims);
    put(c.arrayLens, arrayLens);
    put(c.stringLens, stringLens);
    put(c.boundAddrs, boundAddrs);
    putSet(c.dynamicArrays, dynamicArrays);
    putSet(c.borrowedParams, borrowedParams);
    putSet(c.openArrays, openArrays);
    put(c.constants, constants);
    put(c._constTypes, constTypes);
    put(c._constExactValues, constExactValues);
    put(c.inlineFuncs, inlineFuncs);
    c.currentFuncName = currentFuncName;
    c.currentFuncRet = currentFuncRet;
    c.currentFuncIsTask = currentFuncIsTask;
  }
}
