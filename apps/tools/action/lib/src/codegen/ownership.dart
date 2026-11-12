part of 'codegen.dart';

// ------------------------------------------------------------------------------
// Reference flow analysis
// ------------------------------------------------------------------------------
//
// The references held in a function's own variables (its record references,
// array references `T x[]`, heap strings, and its record parameters) are
// followed through every path of the function. At each point a reference is
// known to be valid, null (set to 0, destroyed, or never given a value), or
// moved (assigned to another variable), or it may be any mix of these when
// paths with different outcomes meet. Using a reference that is not
// definitely valid is an error: reading a field or element, `.len`, calling a
// method on it, passing it to a function, destroying or resizing it.
//
// `x.exists()` (also `x.exists() != 0`, `x.exists() == 1`, `x != 0`, and
// their negations) makes `x` valid where the test is true and null where it
// is false. Assigning, returning, comparing or testing a reference only needs
// it not to have been moved.
//
// `create()` and `createArray()` results are valid (allocation failure traps
// at run time). A call returns a valid reference when every `return` of the
// function returns a definitely valid one; otherwise its result may be null.
// References kept in fields, globals and array elements are not followed
// here; a variable given one may be null.

const int _refValid = 1;
const int _refNull = 2;
const int _refMoved = 4;
const int _refMaybeNull = _refValid | _refNull;

class _RefFacts extends FlowFacts<_RefFacts> {
  final Map<String, int> states;
  _RefFacts(this.states);

  @override
  _RefFacts copy() => _RefFacts(Map.of(states));

  @override
  _RefFacts join(_RefFacts o) {
    final r = Map.of(states);
    o.states.forEach((k, v) => r[k] = (r[k] ?? 0) | v);
    return _RefFacts(r);
  }

  @override
  bool sameAs(_RefFacts o) {
    if (states.length != o.states.length) return false;
    for (final e in states.entries) {
      if (o.states[e.key] != e.value) return false;
    }
    return true;
  }

  _RefFacts withState(String name, int state) {
    final r = copy();
    r.states[name] = state;
    return r;
  }
}

extension _Ownership on CodeGen {
  /// The field [e] names when it is a reference field (`ref T f` or
  /// `T f[]`), else null.
  FieldInfo? _refField(AstNode e) {
    if (e is! MemberAccessNode) return null;
    final (bt, _) = _getExprType(e.expr);
    final f = structs[cleanName(bt)]?.fields[e.member];
    return (f != null && f.isPtr) ? f : null;
  }

  /// With `-freference-check`, traps if the reference in [reg], read from
  /// field [field], is null.
  void _checkFieldRef(String field, int reg) {
    if (referenceCheck) backend.genNullTrap(reg, "field '$field'");
  }

  /// `n.f = rhs` for a reference field: the value must be a reference.
  void _checkRefFieldAssignment(MemberAccessNode target, FieldInfo f, AstNode rhs) {
    final what = "reference field '${target.member}'";
    if (f.isArrayRef) {
      if (rhs is HeapArrayAllocNode && cleanName(rhs.typeName) != cleanName(f.type)) {
        throw CompileError(
            "Array type mismatch: cannot assign '${cleanName(rhs.typeName)}[]' to '${cleanName(f.type)}[]'");
      }
      return;
    }
    if (rhs is VarAccessNode) {
      final rt = typeOf(rhs.name);
      if (_isRecordTypeName(rt.name) &&
          !rt.isRef &&
          !rt.isPtr &&
          !arrayDims.containsKey(rhs.name)) {
        throw CompileError(
            "cannot assign '${rhs.name}', a '${cleanName(rt.name)}' stored on the stack, to $what");
      }
    } else if (rhs is MemberAccessNode || rhs is ArrayAccessNode) {
      final (rt, isPtr) = _getExprType(rhs);
      if (_isRecordTypeName(rt) && !isPtr) {
        throw CompileError(
            "cannot assign a '${cleanName(rt)}' stored inside another type or an array to $what");
      }
    }
  }

  /// With `-freference-check`, traps if [base], a reference held in a
  /// global (which the flow analysis does not follow), is null; its value
  /// is in [reg].
  void _checkGlobalRef(AstNode base, int reg) {
    if (!referenceCheck) return;
    if (base is VarAccessNode &&
        globals.contains(base.name) &&
        !locals.containsKey(base.name)) {
      backend.genNullTrap(reg, "global '${base.name}'");
    }
  }

  /// True when [sig] returns a single reference (record, array or string).
  bool _returnsReference(FuncSig sig) {
    final t = sig.retType;
    if (t is List) return false;
    return sig.retPtr || _isRecordTypeName(t) || cleanName(t) == 'string';
  }

  /// Name of the function a call runs, or null for a call through a
  /// function value.
  String? _calleeName(CallNode call) {
    if (call.name.startsWith('__METHOD__')) {
      final mName = call.name.replaceAll('__METHOD__', '');
      final (rcvT, _) = _getExprType(call.args[0]);
      final sName = cleanName(rcvT);
      final (resolved, _) = _resolveMethod(sName, mName);
      return resolved ?? '${sName}_$mName';
    }
    return funcSignatures.containsKey(call.name) ? call.name : null;
  }

  /// Runs the reference flow analysis over every function. Functions
  /// returning references are first summarised (does every `return` give a
  /// valid reference?), starting from "yes" and settling on the answers that
  /// hold together, so recursive functions are handled; then each function
  /// is checked and the first error is reported.
  void _checkReferenceFlow(List<FuncDeclNode> funcs) {
    final bodies = [for (final f in funcs) if (f.body != null) f];
    final summaries = <String, bool>{
      for (final f in bodies)
        if (funcSignatures[f.name] != null && _returnsReference(funcSignatures[f.name]!))
          f.name: true
    };
    final saved = Map<String, TypeInfo>.of(types);
    try {
      var changed = true;
      while (changed) {
        changed = false;
        for (final f in bodies) {
          if (summaries[f.name] != true) continue;
          final a = _analyzeReferences(f, summaries);
          if (!a.returnsValid) {
            summaries[f.name] = false;
            changed = true;
          }
        }
      }
      for (final f in bodies) {
        final a = _analyzeReferences(f, summaries);
        if (a.errors.isNotEmpty) throw CompileError(a.errors.first);
      }
    } finally {
      types = saved;
    }
  }

  _RefAnalysis _analyzeReferences(FuncDeclNode f, Map<String, bool> summaries) {
    final refs = _functionRefs[f.name] ?? const <String>{};
    final tracked = <String>{};
    final start = <String, int>{};
    final params = <String>{};
    for (final p in f.params) {
      final isRecordRef = _isRecordTypeName(p.type) && !p.isPtr && !p.isOpenArr;
      types[p.name] = TypeInfo(p.type, p.isPtr, isRecordRef || p.isOpenArr);
      params.add(p.name);
      if (isRecordRef) {
        tracked.add(p.name);
        start[p.name] = _refValid;
      }
    }
    final decls = <VarDeclNode>[];
    _collectLocalDecls(f.body, decls);
    for (final d in decls) {
      final isRecordRef = _isRecordTypeName(d.typeName) && refs.contains(d.name);
      types[d.name] = TypeInfo(d.typeName, d.isPtr, isRecordRef);
      if (d.dimExprs.isNotEmpty) continue;
      if (isRecordRef || d.isPtr || (cleanName(d.typeName) == 'string')) {
        tracked.add(d.name);
        // Locals have no value until their declaration runs
        start[d.name] = _refNull;
      }
    }
    final sig = funcSignatures[f.name];
    final a = _RefAnalysis(this, f, tracked, params, summaries,
        sig != null && _returnsReference(sig));
    FlowWalker<_RefFacts>(a).stmt(f.body!, _RefFacts(start));
    return a;
  }
}

class _RefAnalysis extends FlowAnalysis<_RefFacts> {
  final CodeGen g;
  final FuncDeclNode func;
  final Set<String> tracked;
  final Set<String> params;
  final Map<String, bool> summaries;
  final bool returnsRef;
  final List<String> errors = [];

  /// False once a `return` gives a reference that may not be valid.
  bool returnsValid = true;

  _RefAnalysis(this.g, this.func, this.tracked, this.params, this.summaries,
      this.returnsRef);

  /// Location of the node being looked at, for error messages.
  String? _here;

  void _error(String msg) =>
      errors.add(CompileError("in '${func.name}': $msg").at(_here ?? func.loc).message);

  void _visit(AstNode n) {
    if (n.loc != null) _here = n.loc;
  }

  /// A use that reads the reference itself (assigning, returning, testing
  /// or comparing it): it must not have been moved.
  void _valueUse(String name, _RefFacts s) {
    final st = s.states[name] ?? _refValid;
    if (st == _refMoved) {
      _error("'$name' was moved to another variable or field and can no longer be used");
    } else if (st & _refMoved != 0) {
      _error("'$name' may have been moved to another variable or field and can no longer be used");
    }
  }

  /// A use that goes through the reference: it must be definitely valid.
  void _derefUse(String name, _RefFacts s) {
    final st = s.states[name] ?? _refValid;
    if (st == _refValid) return;
    if (st & _refMoved != 0) {
      _valueUse(name, s);
      return;
    }
    if (st == _refNull) {
      _error("'$name' is null here (it was set to 0, destroyed, or never given a value)");
    } else {
      _error("'$name' may be null here; check it with '$name.exists()' first");
    }
  }

  bool _isTracked(AstNode e) => e is VarAccessNode && tracked.contains(e.name);

  @override
  _RefFacts? simpleStmt(AstNode stmt, _RefFacts s) {
    _visit(stmt);
    if (stmt is VarDeclNode) {
      if (stmt.isConst) return s;
      final init = stmt.initExpr;
      if (tracked.contains(stmt.name)) {
        if (init == null) return s.withState(stmt.name, _refNull);
        return _assignVar(stmt.name, init, s);
      }
      return init == null ? s : _ev(init, s);
    }
    if (stmt is TupleAssignNode) {
      var cur = _ev(stmt.expr, s);
      for (final t in stmt.targets) {
        if (!t.isWildcard && t.name != null && tracked.contains(t.name)) {
          cur = cur.withState(t.name!, _refMaybeNull);
        }
      }
      return cur;
    }
    if (stmt is WaitUntilNode) return _ev(stmt.cond, s);
    if (stmt is YieldNode ||
        stmt is PkExitNode ||
        stmt is AsmNode ||
        stmt is VerifyNode ||
        stmt is TrapNode) {
      return s;
    }
    return _ev(stmt, s);
  }

  @override
  _RefFacts expr(AstNode expr, _RefFacts s) => _ev(expr, s);

  @override
  _RefFacts forInit(ForRangeNode loop, _RefFacts s) => s;

  @override
  void onReturn(ReturnNode ret, _RefFacts s) {
    _visit(ret);
    final e = ret.expr;
    if (e == null) return;
    if (returnsRef) {
      final (st, _) = _refValue(e, s);
      if (st != _refValid) returnsValid = false;
    } else {
      _ev(e, s);
    }
  }

  @override
  void onTupleReturn(TupleReturnNode ret, _RefFacts s) {
    var cur = s;
    for (final e in ret.exprs) {
      if (_isTracked(e)) {
        _valueUse((e as VarAccessNode).name, cur);
      } else {
        cur = _ev(e, cur);
      }
    }
  }

  @override
  (_RefFacts?, _RefFacts?) cond(AstNode c, _RefFacts s) {
    _visit(c);
    if (c is UnaryOpNode && c.op == '!') {
      final (t, f) = cond(c.operand, s);
      return (f, t);
    }
    if (c is BinaryOpNode && c.op == '&&') {
      final (lt, lf) = cond(c.left, s);
      if (lt == null) return (null, lf);
      final (rt, rf) = cond(c.right, lt);
      return (rt, joinFacts(lf, rf));
    }
    if (c is BinaryOpNode && c.op == '||') {
      final (lt, lf) = cond(c.left, s);
      if (lf == null) return (lt, null);
      final (rt, rf) = cond(c.right, lf);
      return (joinFacts(lt, rt), rf);
    }
    final tested = _existsTest(c);
    if (tested != null) {
      final (name, positive) = tested;
      _valueUse(name, s);
      // Narrow what is already known; an outcome the known state rules out
      // is not reached (null facts)
      final st = s.states[name] ?? _refValid;
      _RefFacts? narrow(int to) =>
          st & to != 0 ? s.withState(name, st & to) : (st & _refMoved != 0 ? s : null);
      final valid = narrow(_refValid);
      final isNull = narrow(_refNull);
      return positive ? (valid, isNull) : (isNull, valid);
    }
    final after = _ev(c, s);
    return (after, after.copy());
  }

  /// When [c] tests whether a tracked reference exists, its name and
  /// whether the condition is true when it does.
  (String, bool)? _existsTest(AstNode c) {
    String? existsName(AstNode e) {
      if (e is ExistsNode && _isTracked(e.expr)) return (e.expr as VarAccessNode).name;
      return null;
    }

    final direct = existsName(c);
    if (direct != null) return (direct, true);
    if (c is BinaryOpNode && (c.op == '==' || c.op == '!=')) {
      for (final (side, other) in [(c.left, c.right), (c.right, c.left)]) {
        final k = g._tryConst(other);
        if (k == null) continue;
        final isZero = k.value == BigInt.zero;
        final name = existsName(side);
        if (name != null && (isZero || k.value == BigInt.one)) {
          // exists() == 1, exists() != 0: true when it exists
          final whenExists = (c.op == '==') != isZero;
          return (name, whenExists);
        }
        if (_isTracked(side) && isZero) {
          // x != 0: true when it exists
          return ((side as VarAccessNode).name, c.op == '!=');
        }
      }
    }
    return null;
  }

  /// `name = rhs` for a tracked variable: the variable takes the value's
  /// state; a reference moved out of another variable leaves that one moved.
  _RefFacts _assignVar(String name, AstNode rhs, _RefFacts s) {
    final (st, after) = _refValue(rhs, s);
    var r = after.withState(name, st);
    if (_isTracked(rhs) && (rhs as VarAccessNode).name != name) {
      r = r.withState(rhs.name, _refMoved);
    }
    return r;
  }

  /// State of the reference [e] produces, and the facts after evaluating it.
  (int, _RefFacts) _refValue(AstNode e, _RefFacts s) {
    if (e is HeapAllocNode || e is HeapArrayAllocNode || e is HeapStringAllocNode) {
      return (_refValid, _ev(e, s));
    }
    if (e is StringLitNode) return (_refValid, s);
    if (e is VarAccessNode) {
      if (tracked.contains(e.name)) {
        _valueUse(e.name, s);
        final st = s.states[e.name] ?? _refValid;
        return (st & ~_refMoved == 0 ? _refMaybeNull : st & ~_refMoved, s);
      }
      final c = g._tryConst(e);
      if (c != null) return (c.value == BigInt.zero ? _refNull : _refMaybeNull, s);
      // Other parameters (strings, open arrays) are valid; globals may be null
      if (params.contains(e.name)) return (_refValid, s);
      return (_refMaybeNull, s);
    }
    final c = g._tryConst(e);
    if (c != null) return (c.value == BigInt.zero ? _refNull : _refMaybeNull, s);
    if (e is CallNode) {
      final after = _ev(e, s);
      final callee = g._calleeName(e);
      final valid = callee != null && summaries[callee] == true;
      return (valid ? _refValid : _refMaybeNull, after);
    }
    return (_refMaybeNull, _ev(e, s));
  }

  /// Evaluates [e] for its uses of tracked references. A tracked variable
  /// met here is used through (it must be valid) unless an enclosing node
  /// says otherwise.
  _RefFacts _ev(AstNode? e, _RefFacts s) {
    if (e == null) return s;
    _visit(e);
    if (e is VarAccessNode) {
      if (tracked.contains(e.name)) _derefUse(e.name, s);
      return s;
    }
    if (e is ExprStmtNode) return _ev(e.expr, s);
    if (e is BinaryOpNode) {
      switch (e.op) {
        case '=':
          return _assign(e.left, e.right, s);
        case '&&' || '||':
          final (t, f) = cond(e, s);
          return joinFacts(t, f) ?? s;
        case '==' || '!=':
          var cur = s;
          for (final side in [e.left, e.right]) {
            if (_isTracked(side)) {
              _valueUse((side as VarAccessNode).name, cur);
            } else {
              cur = _ev(side, cur);
            }
          }
          return cur;
      }
      return _ev(e.right, _ev(e.left, s));
    }
    if (e is CompoundAssignNode) return _lvalue(e.lhs, _ev(e.rhs, s));
    if (e is UnaryOpNode) return _ev(e.operand, s);
    if (e is CallNode) return _call(e, s);
    if (e is MemberAccessNode) return _ev(e.expr, s);
    if (e is ArrayAccessNode) return _ev(e.index, _ev(e.base, s));
    if (e is SliceNode) return _ev(e.endExpr, _ev(e.startExpr, _ev(e.base, s)));
    if (e is HeapArrayAllocNode) return _ev(e.countExpr, s);
    if (e is HeapStringAllocNode) return _ev(e.capExpr, s);
    if (e is HeapAllocNode) {
      var cur = s;
      for (final a in e.args) {
        cur = _ev(a, cur);
      }
      return cur;
    }
    if (e is HeapFreeNode || e is HeapArrayFreeNode) {
      final target = e is HeapFreeNode ? e.expr : (e as HeapArrayFreeNode).expr;
      final after = _ev(target, s);
      if (_isTracked(target)) {
        // The variable is cleared to 0 when its reference is destroyed
        return after.withState((target as VarAccessNode).name, _refNull);
      }
      return after;
    }
    if (e is HeapArrayResizeNode) return _ev(e.newLenExpr, _ev(e.expr, s));
    if (e is ExistsNode) {
      if (_isTracked(e.expr)) {
        _valueUse((e.expr as VarAccessNode).name, s);
        return s;
      }
      return _ev(e.expr, s);
    }
    return s;
  }

  /// `left = right`.
  _RefFacts _assign(AstNode left, AstNode right, _RefFacts s) {
    if (left is VarAccessNode && tracked.contains(left.name)) {
      return _assignVar(left.name, right, s);
    }
    // Storing a variable's reference elsewhere reads it.
    var cur = s;
    if (_isTracked(right)) {
      final name = (right as VarAccessNode).name;
      _valueUse(name, cur);
      // A whole variable (a global) or a reference field takes it over
      if (left is VarAccessNode || g._refField(left) != null) {
        cur = cur.withState(name, _refMoved);
      }
    } else {
      cur = _ev(right, cur);
    }
    return _lvalue(left, cur);
  }

  /// The parts of an assignment target that are evaluated: the record whose
  /// field is written and the array and index of an element.
  _RefFacts _lvalue(AstNode target, _RefFacts s) {
    if (target is VarAccessNode) return s;
    if (target is MemberAccessNode) return _ev(target.expr, s);
    if (target is ArrayAccessNode) return _ev(target.index, _ev(target.base, s));
    return _ev(target, s);
  }

  _RefFacts _call(CallNode call, _RefFacts s) {
    final callee = g._calleeName(call);
    final sig = callee != null ? g.funcSignatures[callee] : null;
    var cur = s;
    for (var i = 0; i < call.args.length; i++) {
      final arg = call.args[i];
      if (sig != null && i < sig.params.length) {
        final p = sig.params[i];
        final takesRecord = g._isRecordTypeName(p.type) && !p.isPtr && !p.isOpen;
        final k = g._tryConst(arg);
        if (takesRecord && k != null && k.value == BigInt.zero) {
          _error("argument ${i + 1} of '$callee' is null; an argument of a user-defined type must be a valid reference");
        }
      }
      cur = _ev(arg, cur);
    }
    return cur;
  }
}
