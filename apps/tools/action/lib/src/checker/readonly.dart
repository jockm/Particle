part of '../compiler.dart';

// ------------------------------------------------------------------------------
// Parameters a function writes through
// ------------------------------------------------------------------------------
//
// Arrays, strings and records are passed by reference, so a function can
// change its caller's value through a parameter. A value that must not
// change (a constant table, a string literal, `main`'s command line) can
// only be passed to a parameter the function never writes through:
// directly (an assignment, a compound assignment, `tryReadFifo` into it) or
// by passing it on to a parameter that is written. The compiler works this
// out for every function; it cannot see into `extern` and `asm` functions,
// which are taken not to write, nor know which function a function value
// calls, which is taken to write.

extension _ReadOnlyParams on Checker {
  /// Finds, for every function with a body, the indexes of the parameters
  /// it writes through (`this` is index 0 of a method).
  void _findWrittenParams(List<FuncDeclNode> funcs) {
    final bodies = {for (final f in funcs) if (f.body != null) f.name: f};
    for (final f in bodies.values) {
      final names = [for (final p in f.params) _byReference(p) ? p.name : null];
      final written = <int>{};
      void target(AstNode t) {
        final root = _writeRoot(t);
        if (root != null) {
          final i = names.indexOf(root);
          if (i >= 0) written.add(i);
        }
      }

      _walkWrites(f.body!, target, f);
      _writtenParams[f.name] = written;
    }
    // Passing a parameter on to one that is written writes it too
    var changed = true;
    while (changed) {
      changed = false;
      for (final f in bodies.values) {
        final names = [for (final p in f.params) _byReference(p) ? p.name : null];
        final written = _writtenParams[f.name]!;
        _walkCalls(f.body!, (call) {
          for (final (argIndex, j) in _argParamPairs(call)) {
            if (!_calleeWrites(call, j)) continue;
            final root = _valueRoot(call.args[argIndex]);
            final i = root == null ? -1 : names.indexOf(root);
            if (i >= 0 && written.add(i)) changed = true;
          }
        });
      }
    }
  }

  /// True for a parameter that refers to its caller's value: an open
  /// array, a string or a record.
  bool _byReference(Param p) =>
      p.isOpenArr ||
      (!p.isPtr && (cleanName(p.type) == 'string' || structs.containsKey(cleanName(p.type))));

  /// Pairs of (argument index, parameter index) of [call].
  List<(int, int)> _argParamPairs(CallNode call) =>
      [for (var i = 0; i < call.args.length; i++) (i, i)];

  /// True when [call] may write through its parameter [j]: the callee
  /// writes it, or it is called through a function value (unknown).
  bool _calleeWrites(CallNode call, int j) {
    final n = call.name;
    if (n.startsWith('__METHOD__')) {
      // The receiver's type is not known here: any method of that name
      final m = n.substring(10);
      for (final e in _writtenParams.entries) {
        if (e.key.endsWith('_$m') && e.value.contains(j)) return true;
        if (e.key.startsWith('string') &&
            e.key.length > 6 &&
            e.key.substring(6).toLowerCase() == m.toLowerCase() &&
            e.value.contains(j)) {
          return true;
        }
      }
      return false;
    }
    final w = _writtenParams[n];
    if (w != null) return w.contains(j);
    if (funcSignatures.containsKey(n) || inlineFuncs.containsKey(n)) return false;
    // A function value: which function it calls is not known
    return !_memoryBuiltins.containsKey(n) && !const {'trap', 'readFifo', 'writeFifo'}.contains(n);
  }

  /// The variable a write to [t] changes the value of, when [t] goes
  /// through an element, field or (for a string) the variable itself.
  String? _writeRoot(AstNode t) {
    if (t is VarAccessNode) return t.name;
    return _valueRoot(t);
  }

  /// The variable whose storage [e] is part of: `a`, `a[i]`, `a.f`,
  /// `a[1..2]`.
  String? _valueRoot(AstNode e) {
    var cur = e;
    while (true) {
      if (cur is ArrayAccessNode) {
        cur = cur.base;
      } else if (cur is MemberAccessNode) {
        cur = cur.expr;
      } else if (cur is SliceNode) {
        cur = cur.base;
      } else {
        break;
      }
    }
    return cur is VarAccessNode ? cur.name : null;
  }

  void _walkWrites(AstNode? n, void Function(AstNode target) target, FuncDeclNode f) {
    if (n == null) return;
    if (n is BinaryOpNode && n.op == '=' && !n.isUnset) {
      // Giving a whole record or array parameter a new reference does not
      // change the caller's value; a string's is copied into
      final l = n.left;
      if (l is! VarAccessNode ||
          f.params.any((p) => p.name == l.name && !p.isOpenArr && cleanName(p.type) == 'string')) {
        target(l);
      }
    } else if (n is CompoundAssignNode) {
      target(n.lhs);
    } else if (n is CallNode && n.name == 'tryReadFifo' && n.args.length == 2) {
      target(n.args[1]);
    }
    for (final c in _children(n)) {
      _walkWrites(c, target, f);
    }
  }

  void _walkCalls(AstNode? n, void Function(CallNode call) visit) {
    if (n == null) return;
    if (n is CallNode) visit(n);
    for (final c in _children(n)) {
      _walkCalls(c, visit);
    }
  }

  /// The child nodes of [n] that are statements or expressions.
  List<AstNode> _children(AstNode n) {
    if (n is BlockNode) return n.stmts;
    if (n is IfNode) return [n.cond, n.thenBody, if (n.elseBody != null) n.elseBody!];
    if (n is WhileNode) return [n.cond, n.body];
    if (n is ForRangeNode) return [n.startExpr, n.endExpr, n.body];
    if (n is SwitchNode) return [n.expr, n.body];
    if (n is VarDeclNode) return [if (n.initExpr != null) n.initExpr!];
    if (n is ExprStmtNode) return [n.expr];
    if (n is ReturnNode) return [if (n.expr != null) n.expr!];
    if (n is TupleReturnNode) return n.exprs;
    if (n is TupleAssignNode) return [n.expr];
    if (n is BinaryOpNode) return [n.left, n.right];
    if (n is UnaryOpNode) return [n.operand];
    if (n is CompoundAssignNode) return [n.lhs, n.rhs];
    if (n is CallNode) return n.args;
    if (n is ArrayAccessNode) return [n.base, n.index];
    if (n is SliceNode) {
      return [n.base, if (n.startExpr != null) n.startExpr!, if (n.endExpr != null) n.endExpr!];
    }
    if (n is MemberAccessNode) return [n.expr];
    if (n is ConvertNode) return [n.expr];
    if (n is HeapAllocNode) return n.args;
    if (n is HeapArrayAllocNode) return [n.countExpr];
    if (n is HeapStringAllocNode) return [n.capExpr];
    if (n is HeapFreeNode) return [n.expr];
    if (n is HeapArrayFreeNode) return [n.expr];
    if (n is HeapArrayResizeNode) return [n.expr, n.newLenExpr];
    if (n is ExistsNode) return [n.expr];
    if (n is WaitUntilNode) return [n.cond];
    return const [];
  }

  /// At a call: a value that must not change (a constant table, a string
  /// literal, `main`'s command line) is not passed to a parameter the
  /// callee writes through.
  void _checkReadOnlyArgs(CallNode call, String callee, String shown) {
    final written = _writtenParams[callee];
    if (written == null || written.isEmpty) return;
    final f = _funcDecls.where((x) => x.name == callee).firstOrNull;
    for (var i = 0; i < call.args.length; i++) {
      if (!written.contains(i)) continue;
      final what = _readOnlyValue(call.args[i]);
      if (what == null) continue;
      final pName = f != null && i < f.params.length ? f.params[i].name : '${i + 1}';
      throw CompileError("$what cannot be passed to '$shown': it changes its parameter '$pName'")
          .at(call.args[i].loc ?? call.loc);
    }
  }

  /// How [e] is described when it is a value that must not change, else
  /// null.
  String? _readOnlyValue(AstNode e) {
    if (e is StringLitNode) return 'a string literal';
    final root = _valueRoot(e) ?? (e is VarAccessNode ? e.name : null);
    if (root == null) return null;
    if (_readOnlyGlobals.contains(root) && !locals.containsKey(root)) {
      return "constant '$root'";
    }
    if (_readOnly.contains(root) && locals.containsKey(root)) return "the command line '$root'";
    return null;
  }
}
