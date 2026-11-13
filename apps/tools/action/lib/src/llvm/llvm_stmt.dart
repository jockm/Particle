part of '../compiler.dart';

// ------------------------------------------------------------------------------
// LLVM generator: statements
// ------------------------------------------------------------------------------

extension _LlvmStatements on LlvmGen {
  void _genBlock(BlockNode block) {
    _enterBlock();
    for (final s in block.stmts) {
      _genStmt(s);
    }
    _leaveBlock();
  }

  void _genStmt(AstNode stmt) {
    final saved = _curLoc;
    final savedScope = _scope;
    if (stmt.loc != null) _curLoc = stmt.loc;
    // A block that declares locals has a debug scope of its own
    final block = _blockOf[stmt];
    if (_scope != null && block != null && !block.isCase && block.hasDecls) {
      _scope = _diScopeOf(block);
    }
    _genStmtInner(stmt);
    _curLoc = saved;
    _scope = savedScope;
  }

  void _genStmtInner(AstNode stmt) {
    if (stmt is BlockNode) {
      _genBlock(stmt);
    } else if (stmt is BreakNode) {
      _br(_flows.last.breakTo!);
    } else if (stmt is ContinueNode) {
      final f = _flows.last;
      if (f.isSwitch) {
        final next = f.currentCase + 1;
        _br(next < f.caseBlocks.length ? f.caseBlocks[next] : f.breakTo!);
      } else {
        _br(f.continueTo!);
      }
    } else if (stmt is CaseLabelNode || stmt is DefaultLabelNode) {
      _genCaseLabel(stmt);
    } else if (stmt is SwitchNode) {
      _genSwitch(stmt);
    } else if (stmt is VarDeclNode) {
      _genVarDecl(stmt);
    } else if (stmt is CompoundAssignNode) {
      _genCompound(stmt);
    } else if (stmt is ExprStmtNode) {
      _expr(stmt.expr);
    } else if (stmt is YieldNode) {
      _setTaskStep(_func!, stmt.stepConst);
      _terminator('ret i32 ${_pkStatus('PK_YIELDED')}');
      _startBlock('step.${stmt.stepConst}');
    } else if (stmt is WaitUntilNode) {
      final cont = _newBlock('wait.cont');
      final wait = _newBlock('wait');
      _startBlock('step.${stmt.stepConst}');
      _condBr(stmt.cond, cont, wait);
      _body.add('$wait:');
      _terminated = false;
      _setTaskStep(_func!, stmt.stepConst);
      _terminator('ret i32 ${_pkStatus('PK_WAITING')}');
      _body.add('$cont:');
      _terminated = false;
    } else if (stmt is PkExitNode) {
      _setTaskStep(_func!, 0);
      _terminator('ret i32 ${_pkStatus('PK_EXITED')}');
    } else if (stmt is TupleReturnNode) {
      final rets = currentFuncRet.$1 as List;
      var agg = 'undef';
      for (var i = 0; i < stmt.exprs.length; i++) {
        final rt = rets[i];
        final (Object? name, bool isPtr) = rt is (Object?, bool) ? rt : (rt, false);
        final ty = _regTy(name, isPtr);
        var v = _conv(_expr(stmt.exprs[i]), ty);
        if (cleanName(name) == 'bool' && !isPtr) v = _fromBool(_truth(v));
        agg = _val('insertvalue $_retTy $agg, $ty ${v.v}, $i');
      }
      _terminator('ret $_retTy $agg');
    } else if (stmt is TupleAssignNode) {
      final v = _expr(stmt.expr);
      final elems = _aggElems(v.ty);
      for (var i = 0; i < stmt.targets.length; i++) {
        final target = stmt.targets[i];
        if (target.isWildcard) continue;
        final name = target.name!;
        if (target.typeName != null) {
          types[name] = TypeInfo(target.typeName!, target.isPtr, false);
        }
        final t = typeOf(name);
        final ev = _V(_val('extractvalue ${v.ty} ${v.v}, $i'), elems[i],
            i < elems.length && _isSignedName(cleanName(t.name)));
        final slot = _varAddr(name);
        if (slot != null) _store(slot, ev, t.name, t.isPtr);
      }
    } else if (stmt is ReturnNode) {
      if (currentFuncIsTask) {
        _br('task.end');
        return;
      }
      if (stmt.expr == null) {
        _terminator(_defaultReturn());
        return;
      }
      final v = _expr(stmt.expr!);
      if (_retTy == 'void') {
        _terminator('ret void');
        return;
      }
      var cv = _conv(v, _retTy);
      final (rt, rp) = currentFuncRet;
      if (cleanName(rt) == 'bool' && !rp) cv = _fromBool(_truth(cv));
      _terminator('ret $_retTy ${cv.v}');
    } else if (stmt is IfNode) {
      int? constVal;
      try {
        constVal = _evalConstExpr(stmt.cond);
      } on NotConstantError {
        constVal = null;
      }
      if (constVal != null) {
        if (constVal != 0) {
          _genStmt(stmt.thenBody);
        } else if (stmt.elseBody != null) {
          _genStmt(stmt.elseBody!);
        }
        return;
      }
      final thenB = _newBlock('then');
      final endB = _newBlock('endif');
      final elseB = stmt.elseBody != null ? _newBlock('else') : endB;
      _condBr(stmt.cond, thenB, elseB);
      _body.add('$thenB:');
      _terminated = false;
      _genStmt(stmt.thenBody);
      if (stmt.elseBody != null) {
        if (!_terminated) _br(endB);
        _body.add('$elseB:');
        _terminated = false;
        _genStmt(stmt.elseBody!);
      }
      _startBlock(endB);
    } else if (stmt is WhileNode) {
      final head = _newBlock('while');
      final bodyB = _newBlock('while.body');
      final endB = _newBlock('while.end');
      _startBlock(head);
      _condBr(stmt.cond, bodyB, endB);
      _body.add('$bodyB:');
      _terminated = false;
      _flows.add(_LFlow.loop(endB, head));
      _genStmt(stmt.body);
      _flows.removeLast();
      if (!_terminated) _br(head);
      _body.add('$endB:');
      _terminated = false;
    } else if (stmt is ForRangeNode) {
      final head = _newBlock('for');
      final bodyB = _newBlock('for.body');
      final step = _newBlock('for.step');
      final endB = _newBlock('for.end');
      final vt = typeOf(stmt.varName);
      _store(_slots[stmt.varName]!, _expr(stmt.startExpr), vt.name, false);
      _store(_slots[loopEndName(stmt.varName)]!, _expr(stmt.endExpr), 'u32', false);
      _startBlock(head);
      final i = _load(_slots[stmt.varName]!, vt.name, false);
      final end = _load(_slots[loopEndName(stmt.varName)]!, 'u32', false);
      final ty = i.ty == 'i64' ? 'i64' : 'i32';
      final signed = _isSignedName(cleanName(stmt.varType));
      final c = _val('icmp ${signed ? 'slt' : 'ult'} $ty ${_conv(i, ty).v}, ${_conv(end, ty).v}');
      _terminator('br i1 $c, label %$bodyB, label %$endB');
      _body.add('$bodyB:');
      _terminated = false;
      _flows.add(_LFlow.loop(endB, step));
      _genStmt(stmt.body);
      _flows.removeLast();
      _startBlock(step);
      final cur = _load(_slots[stmt.varName]!, vt.name, false);
      final next = _V(_val('add ${cur.ty} ${cur.v}, 1'), cur.ty, cur.signed);
      _store(_slots[stmt.varName]!, next, vt.name, false);
      _br(head);
      _body.add('$endB:');
      _terminated = false;
    }
    // AsmNode (rejected by the checker), VerifyNode: nothing to generate
  }

  /// The element types of an aggregate type `{ a, b }`.
  List<String> _aggElems(String ty) {
    final inner = ty.trim();
    if (!inner.startsWith('{')) return [ty];
    return inner.substring(1, inner.length - 1).split(',').map((s) => s.trim()).toList();
  }

  // ------------------------------------------------------------- switch

  void _genSwitch(SwitchNode stmt) {
    final endB = _newBlock('switch.end');
    final labels = <AstNode>[];
    _collectCases(stmt.body, labels);
    final blocks = <String>[];
    String? defaultB;
    final cases = <String>[];
    final seen = <int>{};
    final d = _expr(stmt.expr);
    final dv = d.isPtr ? _conv(d, 'i64') : d;
    for (final l in labels) {
      final b = _newBlock(l is CaseLabelNode ? 'case' : 'default');
      _caseBlocks[l] = b;
      blocks.add(b);
      if (l is CaseLabelNode) {
        final e = l.expr;
        final val = e is IntLitNode ? e.val : _evalConstExpr(e);
        if (seen.add(val)) cases.add('${dv.ty} ${_intText(BigInt.from(val), dv.ty == 'i64' ? 64 : 32)}, label %$b');
      } else {
        defaultB = b;
      }
    }
    _terminator('switch ${dv.ty} ${dv.v}, label %${defaultB ?? endB} [ ${cases.join(' ')} ]');
    _flows.add(_LFlow.switchBlock(endB, blocks));
    _genStmt(stmt.body);
    _flows.removeLast();
    _startBlock(endB);
  }

  /// The case and default labels of a switch body, in order (as
  /// [CodeGen._collectSwitchLabels] finds them).
  void _collectCases(AstNode node, List<AstNode> out) {
    if (node is CaseLabelNode || node is DefaultLabelNode) {
      out.add(node);
    } else if (node is BlockNode) {
      for (final s in node.stmts) {
        _collectCases(s, out);
      }
    } else if (node is IfNode) {
      _collectCases(node.thenBody, out);
      if (node.elseBody != null) _collectCases(node.elseBody!, out);
    } else if (node is WhileNode) {
      _collectCases(node.body, out);
    }
  }

  void _genCaseLabel(AstNode label) {
    final b = _caseBlocks[label];
    if (b == null) return;
    _LFlow? f;
    for (final c in _flows.reversed) {
      if (c.isSwitch) {
        f = c;
        break;
      }
    }
    if (f != null) {
      // Reaching a label from the case above ends that case
      if (!_terminated && f.currentCase >= 0) _br(f.breakTo!);
      f.currentCase = f.caseBlocks.indexOf(b);
    }
    _startBlock(b);
  }

  // ------------------------------------------------------------ declarations

  void _genVarDecl(VarDeclNode stmt) {
    if (stmt.isConst) {
      _declareLocalConst(stmt);
      return;
    }
    _resolveVarDecl(stmt);
    if (stmt.boundAddr != null) {
      boundAddrs[stmt.name] = stmt.boundAddr!;
      return;
    }
    if (_declClearsFirst(stmt)) _clearSlot(stmt.name);
    final init = stmt.initExpr;
    if (init == null) return;
    final name = stmt.name;
    if (stmt.typeName == 'string' && init is StringLitNode) {
      stringLens[name] = init.val.length;
      _declare('declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)');
      final lit = _stringConst(init.val);
      _ins('call void @llvm.memcpy.p0.p0.i64(ptr ${_slots[name]}, ptr $lit, i64 ${init.val.length + 1}, i1 false)');
      return;
    }
    final cap = _fixedStringCap(VarAccessNode(name));
    if (cap != null) {
      // A string buffer starts as a copy of another string
      _stringCopy(_slots[name]!, init, cap);
      return;
    }
    final v = _expr(init);
    if (init is HeapAllocNode || init is HeapArrayAllocNode || init is HeapStringAllocNode) {
      affineState[name] = 'VALID';
    }
    if (init is HeapArrayAllocNode) dynamicArrays.add(name);
    final t = typeOf(name);
    _store(_slots[name]!, v, t.name, t.isPtr || t.isRef);
  }

  /// Clears local [name] (a declaration in an inner block).
  void _clearSlot(String name) {
    final slot = _slots[name]!;
    final (ty, size) = _slotInfo[name]!;
    if (ty == '[') {
      _declare('declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)');
      _ins('call void @llvm.memset.p0.i64(ptr align 1 $slot, i8 0, i64 $size, i1 false)');
    } else {
      _ins('store $ty ${_zeroOf(ty)}, ptr $slot');
    }
  }

  // -------------------------------------------------- compound assignment

  /// `lhs op= rhs`, as a statement or an expression; gives the new value.
  _V _genCompound(CompoundAssignNode e) {
    final op = e.op.substring(0, e.op.length - 1);
    final rhs = _expr(e.rhs);
    final lhs = e.lhs;
    String addr;
    Object tName;
    bool isPtr;
    var volatile = false;
    if (lhs is VarAccessNode) {
      final t = typeOf(lhs.name);
      tName = t.name;
      isPtr = t.isPtr;
      volatile = boundAddrs.containsKey(lhs.name);
      addr = _varAddr(lhs.name)!;
    } else if (lhs is ArrayAccessNode) {
      final el = _elemAddr(lhs, isWrite: true);
      addr = el.$1;
      tName = el.$2;
      isPtr = false;
      volatile = el.$3;
    } else {
      final m = lhs as MemberAccessNode;
      final (bt, _) = _getExprType(m.expr);
      final f = fieldOf(cleanName(bt), m.member);
      final (base, vol) = _lvalue(m.expr);
      addr = _offset(base, '${f.offset}');
      tName = f.type;
      isPtr = f.isPtr;
      volatile = vol;
    }
    final old = _load(addr, tName, isPtr, volatile: volatile);
    final signed = _isSignedCompound(tName, e.rhs);
    final r = _arith(op, old, rhs, signed);
    _store(addr, r, tName, isPtr, volatile: volatile);
    return r;
  }

  // ---------------------------------------------------------- conditions

  /// Branches to [t] when [cond] is true, else to [f].
  void _condBr(AstNode cond, String t, String f) {
    final saved = _curLoc;
    if (cond.loc != null) _curLoc = cond.loc;
    final folded = _foldedCondition(cond);
    if (folded != null) {
      _br(folded ? t : f);
    } else if (cond is BinaryOpNode && cond.op == '&&') {
      final mid = _newBlock('and');
      _condBr(cond.left, mid, f);
      _body.add('$mid:');
      _terminated = false;
      _condBr(cond.right, t, f);
    } else if (cond is BinaryOpNode && cond.op == '||') {
      final mid = _newBlock('or');
      _condBr(cond.left, t, mid);
      _body.add('$mid:');
      _terminated = false;
      _condBr(cond.right, t, f);
    } else {
      final v = _expr(cond);
      final c = _truth(v);
      _terminator('br i1 $c, label %$t, label %$f');
    }
    _curLoc = saved;
  }
}
