part of 'codegen.dart';

// ------------------------------------------------------------------------------
// Protothread coroutines: task functions
// ------------------------------------------------------------------------------
//
// A task is declared `task name(State t, ...) { ... }`. It returns its status
// (a u16) and is the only kind of function that may pause, with `yield(t)`,
// `waitUntil(t, cond)` and `pkExit(t)`. These are declared as prototypes in
// lib/protokernel.act and look like ordinary calls, but the compiler generates
// them in place: they store into the task's continuation counter `t.lc` and
// return from the task, and a task's entry dispatches on `t.lc` to the point
// it left from (see genFunc). The compiler numbers those resume points 1, 2,
// ... in source order.
//
// A call is generated this way only when the program declares the name as a
// prototype (a declaration without a body), which importing
// lib/protokernel.act does. Without it the name is an ordinary function.
// Status values are taken from the PK_* constants of protokernel.act.
//
// A paused task has no stack frame, so its locals do not survive a pause:
// reading a local after a pause, when it was set before the pause and not
// set again, is an error, and so is a `for` loop whose body pauses.

/// Names of the coroutine operations and their argument counts.
const Map<String, int> _coroutineOps = {'yield': 1, 'waitUntil': 2, 'pkExit': 1};

extension _Coroutines on Checker {
  /// True when [name] is a coroutine operation the program has declared.
  bool _isCoroutineOp(String name) =>
      _coroutineOps.containsKey(name) && _prototypeNames.contains(name);

  /// Rewrites coroutine operation call statements in [funcs] into
  /// [YieldNode], [WaitUntilNode] and [PkExitNode], numbering the resume
  /// points of each task.
  void _lowerCoroutineOps(List<FuncDeclNode> funcs) {
    for (final f in funcs) {
      if (f.body == null) continue;
      _loweringFunc = f;
      _nextStep = 1;
      _lowerIn(f.body!);
    }
    _loweringFunc = null;
  }

  void _lowerIn(AstNode node) {
    if (node is BlockNode) {
      for (var i = 0; i < node.stmts.length; i++) {
        node.stmts[i] = _lowerStmt(node.stmts[i]);
        _lowerIn(node.stmts[i]);
      }
    } else if (node is IfNode) {
      node.thenBody = _lowerStmt(node.thenBody);
      _lowerIn(node.thenBody);
      if (node.elseBody != null) {
        node.elseBody = _lowerStmt(node.elseBody!);
        _lowerIn(node.elseBody!);
      }
    } else if (node is WhileNode) {
      node.body = _lowerStmt(node.body);
      _lowerIn(node.body);
    } else if (node is ForRangeNode) {
      node.body = _lowerStmt(node.body);
      _lowerIn(node.body);
    } else if (node is SwitchNode) {
      node.body = _lowerStmt(node.body);
      _lowerIn(node.body);
    }
  }

  AstNode _lowerStmt(AstNode stmt) {
    try {
      return _lowerStmtInner(stmt)..loc ??= stmt.loc;
    } on CompileError catch (e) {
      throw e.at(stmt.loc);
    }
  }

  AstNode _lowerStmtInner(AstNode stmt) {
    if (stmt is! ExprStmtNode) return stmt;
    final call = stmt.expr;
    if (call is! CallNode || !_isCoroutineOp(call.name)) return stmt;
    final f = _loweringFunc!;
    if (!f.isTask) {
      throw CompileError(
          "'${call.name}' can only be used in a task function; declare '${f.name}' as 'task ${f.name}(...)'");
    }
    final want = _coroutineOps[call.name]!;
    if (call.args.length != want) {
      throw CompileError(
          "'${call.name}' takes $want argument${want == 1 ? '' : 's'}, got ${call.args.length}");
    }
    // The task argument must be the task's own state (its first parameter)
    final state = f.params.first.name;
    final taskArg = call.args[0];
    if (taskArg is! VarAccessNode || taskArg.name != state) {
      throw CompileError(
          "'${call.name}' in task '${f.name}' must name the task's state '$state'");
    }
    switch (call.name) {
      case 'yield':
        return YieldNode(taskArg)..stepConst = _nextStep++;
      case 'waitUntil':
        return WaitUntilNode(taskArg, call.args[1])..stepConst = _nextStep++;
      default:
        return PkExitNode(taskArg);
    }
  }

  /// The value of protokernel status constant [name].
  int _pkStatus(String name) {
    final v = constants[name];
    if (v == null) {
      throw CompileError(
          "coroutine status '$name' is not defined; import \"lib/protokernel.act\"");
    }
    return v;
  }

  /// Checks a task [f] before code generation: its state type, `for` loops
  /// that pause, and locals read after a pause.
  void _checkTask(FuncDeclNode f) {
    // The state's first field holds the continuation counter
    final stateType = cleanName(f.params.first.type);
    final info = structs[stateType];
    final first = info?.fields.values.where((fi) => fi.offset == 0).toList() ?? const [];
    final okFirst = first.isNotEmpty &&
        first.any((fi) => cleanName(fi.type) == 'u16' && fi.dim == null && !fi.isPtr);
    if (info == null || !okFirst) {
      throw CompileError(
          "task '${f.name}': its state '${f.params.first.name}' must be of a type whose first field is a u16 (the continuation counter), such as 'pt'");
    }
    _checkForLoopsDoNotPause(f, f.body!);

    final locals = <String>{};
    _collectLocalNames(f.body!, locals);
    final analysis = _TaskLocals(f, locals);
    FlowWalker<_TaskFacts>(analysis).stmt(f.body!, _TaskFacts({}, {}));
  }

  void _checkForLoopsDoNotPause(FuncDeclNode f, AstNode node) {
    if (node is ForRangeNode) {
      if (_pauses(node.body)) {
        throw CompileError(
                "task '${f.name}': the 'for' loop over '${node.varName}' pauses, but its counter does not survive a pause; use a 'while' loop with the counter in the task's state")
            .at(node.loc);
      }
      _checkForLoopsDoNotPause(f, node.body);
    } else if (node is BlockNode) {
      for (final s in node.stmts) {
        _checkForLoopsDoNotPause(f, s);
      }
    } else if (node is IfNode) {
      _checkForLoopsDoNotPause(f, node.thenBody);
      if (node.elseBody != null) _checkForLoopsDoNotPause(f, node.elseBody!);
    } else if (node is WhileNode) {
      _checkForLoopsDoNotPause(f, node.body);
    } else if (node is SwitchNode) {
      _checkForLoopsDoNotPause(f, node.body);
    }
  }

  bool _pauses(AstNode node) {
    if (node is YieldNode || node is WaitUntilNode) return true;
    if (node is BlockNode) return node.stmts.any(_pauses);
    if (node is IfNode) {
      return _pauses(node.thenBody) || (node.elseBody != null && _pauses(node.elseBody!));
    }
    if (node is WhileNode) return _pauses(node.body);
    if (node is ForRangeNode) return _pauses(node.body);
    if (node is SwitchNode) return _pauses(node.body);
    return false;
  }

  void _collectLocalNames(AstNode node, Set<String> names) {
    if (node is VarDeclNode) {
      if (!node.isConst) names.add(node.name);
    } else if (node is BlockNode) {
      for (final s in node.stmts) {
        _collectLocalNames(s, names);
      }
    } else if (node is IfNode) {
      _collectLocalNames(node.thenBody, names);
      if (node.elseBody != null) _collectLocalNames(node.elseBody!, names);
    } else if (node is WhileNode) {
      _collectLocalNames(node.body, names);
    } else if (node is ForRangeNode) {
      names.add(node.varName);
      _collectLocalNames(node.body, names);
    } else if (node is SwitchNode) {
      _collectLocalNames(node.body, names);
    } else if (node is TupleAssignNode) {
      for (final t in node.targets) {
        if (t.typeName != null && t.name != null) names.add(t.name!);
      }
    }
  }
}

/// Facts for the task locals rule: locals that may have been set since the
/// task was entered, and those set before a pause and not set since.
class _TaskFacts extends FlowFacts<_TaskFacts> {
  final Set<String> assigned;
  final Set<String> stale;
  _TaskFacts(this.assigned, this.stale);

  @override
  _TaskFacts copy() => _TaskFacts({...assigned}, {...stale});
  @override
  _TaskFacts join(_TaskFacts o) =>
      _TaskFacts({...assigned, ...o.assigned}, {...stale, ...o.stale});
  @override
  bool sameAs(_TaskFacts o) =>
      assigned.length == o.assigned.length &&
      assigned.containsAll(o.assigned) &&
      stale.length == o.stale.length &&
      stale.containsAll(o.stale);
}

/// Reports a local read after a pause when its value was set before it.
class _TaskLocals extends FlowAnalysis<_TaskFacts> {
  final FuncDeclNode task;
  final Set<String> locals;
  _TaskLocals(this.task, this.locals);

  _TaskFacts _set(String name, _TaskFacts s) {
    if (!locals.contains(name)) return s;
    final n = s.copy();
    n.assigned.add(name);
    n.stale.remove(name);
    return n;
  }

  _TaskFacts _pause(_TaskFacts s) =>
      _TaskFacts({...s.assigned}, {...s.stale, ...s.assigned});

  /// The local variable an assignment target writes, if any (a whole local,
  /// or an element or field of one).
  String? _targetLocal(AstNode target) {
    var t = target;
    while (true) {
      if (t is VarAccessNode) return locals.contains(t.name) ? t.name : null;
      if (t is MemberAccessNode) {
        t = t.expr;
      } else if (t is ArrayAccessNode) {
        t = t.base;
      } else {
        return null;
      }
    }
  }

  _TaskFacts _leaf(AstNode node, _TaskFacts s) {
    if (node is VarAccessNode && s.stale.contains(node.name)) {
      throw CompileError(
              "task '${task.name}': '${node.name}' is read after a pause but was set before it; locals do not survive a pause, so keep it in the task's state or set it again after the pause")
          .at(node.loc);
    }
    if (node is BinaryOpNode && node.op == '=') {
      final name = _targetLocal(node.left);
      if (name != null) return _set(name, s);
    }
    if (node is CompoundAssignNode) {
      final name = _targetLocal(node.lhs);
      if (name != null) {
        // A compound assignment reads its target first
        if (node.lhs is VarAccessNode && s.stale.contains(name)) {
          _leaf(node.lhs, s);
        }
        return _set(name, s);
      }
    }
    return s;
  }

  @override
  _TaskFacts expr(AstNode e, _TaskFacts s) => walkExpr<_TaskFacts>(e, s, _leaf);

  @override
  _TaskFacts forInit(ForRangeNode loop, _TaskFacts s) => _set(loop.varName, s);

  @override
  _TaskFacts? simpleStmt(AstNode stmt, _TaskFacts s) {
    if (stmt is VarDeclNode) {
      if (stmt.initExpr == null) return s;
      return _set(stmt.name, expr(stmt.initExpr!, s));
    }
    if (stmt is ExprStmtNode) return expr(stmt.expr, s);
    if (stmt is CompoundAssignNode) return expr(stmt, s);
    if (stmt is YieldNode) return _pause(s);
    if (stmt is WaitUntilNode) {
      // The condition is tested before pausing, and again on every resume
      final before = expr(stmt.cond, s);
      final resumed = expr(stmt.cond, _pause(before));
      return before.join(resumed);
    }
    if (stmt is PkExitNode) return null;
    if (stmt is TupleAssignNode) {
      var cur = expr(stmt.expr, s);
      for (final t in stmt.targets) {
        if (t.name != null) cur = _set(t.name!, cur);
      }
      return cur;
    }
    if (stmt is VerifyNode) return s;
    return s;
  }

  @override
  void onReturn(ReturnNode ret, _TaskFacts s) {
    if (ret.expr != null) expr(ret.expr!, s);
  }
}
