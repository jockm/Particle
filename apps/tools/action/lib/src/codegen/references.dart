part of 'codegen.dart';

// ------------------------------------------------------------------------------
// Record references
// ------------------------------------------------------------------------------
//
// Action has no pointers. A record variable is either *storage* (the record
// itself lives in the stack frame or the data section) or a *reference* to a
// record that lives elsewhere: on the heap after `T.create()`, or in the
// caller's frame for a record parameter.
//
// A record variable is a reference when anything in its scope gives it a
// reference value: `T.create()`, `0` (the null reference), another reference
// variable or parameter, or the result of a call returning a record (methods
// that `return this`). Otherwise it is storage. The classification is made
// for the whole function (and, for globals, the whole program) before code is
// generated, so it does not depend on statement order.
//
// A reference occupies one pointer-sized slot; reading a field dereferences
// it, exactly as for record parameters.

extension _References on Checker {
  bool _isRecordTypeName(Object? t) =>
      t is String && structs.containsKey(cleanName(t));

  /// Classifies the record variables of every function and the program's
  /// globals. Records the result in [_functionRefs] and [_globalRefs].
  void _classifyReferences(List<FuncDeclNode> funcs, List<VarDeclNode> globalDecls) {
    final globalRecords = <String>{
      for (final d in globalDecls)
        if (!d.isConst &&
            d.boundAddrExpr == null &&
            d.dimExprs.isEmpty &&
            !d.isPtr &&
            _isRecordTypeName(d.typeName))
          d.name
    };
    for (final d in globalDecls) {
      if (d.isRefDecl) {
        _checkRefDecl(d);
        _globalRefs.add(d.name);
      }
    }
    for (final d in globalDecls) {
      if (globalRecords.contains(d.name) && d.initExpr != null) {
        bool isRef;
        try {
          isRef = _isRefSource(d.initExpr!, const {}, const {});
        } on CompileError catch (e) {
          throw e.at(d.initExpr!.loc ?? d.loc);
        }
        if (isRef) {
          _globalRefs.add(d.name);
        }
      }
    }

    var changed = true;
    while (changed) {
      changed = false;
      for (final f in funcs) {
        if (f.body == null) continue;
        final params = <String>{
          for (final p in f.params)
            if (_isRecordTypeName(p.type) && !p.isOpenArr) p.name
        };
        final localNames = <String>{
          for (final p in f.params) p.name,
          ..._declaredLocalNames(f.body!),
        };
        final localRecords = <String>{
          for (final d in _localRecordDecls(f.body!)) d.name
        };
        final refs = _functionRefs.putIfAbsent(f.name, () => <String>{});
        // `ref T name;` is a reference from its declaration
        for (final d in _localRecordDecls(f.body!)) {
          if (d.isRefDecl) refs.add(d.name);
        }
        // Give this function's parameters and locals their types while its
        // calls are inspected (the caller restores the type table).
        for (final p in f.params) {
          types[p.name] = TypeInfo(p.type, p.isPtr, params.contains(p.name), p.isRefArray);
        }
        for (final d in _localRecordDecls(f.body!)) {
          types[d.name] = TypeInfo(d.typeName, d.isPtr, refs.contains(d.name), d.isRefArray);
        }
        // An element of an array of references is a reference
        final allDecls = <VarDeclNode>[];
        _collectLocalDecls(f.body, allDecls);
        for (final d in allDecls) {
          if (d.isRefArray) types[d.name] = TypeInfo(d.typeName, false, false, true);
        }
        final assignments = <(String, AstNode)>[];
        _collectAssignments(f.body!, assignments);

        var localChanged = true;
        while (localChanged) {
          localChanged = false;
          final known = {...params, ...refs, ..._globalRefs};
          for (final (target, rhs) in assignments) {
            bool isRef;
            try {
              isRef = _isRefSource(rhs, known, localNames);
            } on CompileError catch (e) {
              throw e.at(rhs.loc);
            }
            if (!isRef) continue;
            if (localRecords.contains(target)) {
              if (refs.add(target)) localChanged = true;
            } else if (!localNames.contains(target) &&
                globalRecords.contains(target)) {
              if (_globalRefs.add(target)) changed = true;
            }
          }
        }
      }
    }
  }

  /// `ref T name;` needs a user-defined type: a heap string or array that
  /// starts empty is declared `string s[];` or `T a[];`.
  void _checkRefDecl(VarDeclNode d) {
    if (_isRecordTypeName(d.typeName)) return;
    final t = cleanName(d.typeName);
    throw CompileError("'ref $t ${d.name};': a reference needs a user-defined type; "
            "a heap ${t == 'string' ? 'string' : 'array'} that starts empty is declared "
            "'${t == 'string' ? 'string' : t} ${d.name}[];'")
        .at(d.loc);
  }

  /// True if [rhs] produces a record reference.
  bool _isRefSource(AstNode rhs, Set<String> knownRefs, Set<String> localNames) {
    if (rhs is HeapAllocNode) return true;
    if (rhs is IntLitNode && rhs.val == 0) return true;
    if (rhs is VarAccessNode) return knownRefs.contains(rhs.name);
    if (rhs is MemberAccessNode || rhs is ArrayAccessNode) {
      // A 'ref' field, or an element of an array of references, holds a
      // reference
      final (t, isPtr) = _getExprType(rhs);
      return isPtr && _isRecordTypeName(t);
    }
    if (rhs is CallNode) {
      final (t, _) = _getExprType(rhs);
      return _isRecordTypeName(t);
    }
    return false;
  }

  /// Every `name = value` and `T name = value` in [node].
  void _collectAssignments(AstNode? node, List<(String, AstNode)> out) {
    if (node == null) return;
    if (node is BlockNode) {
      for (final s in node.stmts) {
        _collectAssignments(s, out);
      }
    } else if (node is IfNode) {
      _collectAssignments(node.thenBody, out);
      _collectAssignments(node.elseBody, out);
    } else if (node is WhileNode) {
      _collectAssignments(node.body, out);
    } else if (node is ForRangeNode) {
      _collectAssignments(node.body, out);
    } else if (node is SwitchNode) {
      _collectAssignments(node.body, out);
    } else if (node is VarDeclNode) {
      if (node.initExpr != null) out.add((node.name, node.initExpr!));
    } else if (node is ExprStmtNode) {
      _collectAssignments(node.expr, out);
    } else if (node is BinaryOpNode && node.op == '=') {
      final left = node.left;
      if (left is VarAccessNode) out.add((left.name, node.right));
      _collectAssignments(node.right, out);
    }
  }

  /// Names declared by local declarations, for-loop variables and tuple
  /// declarations in [node].
  Set<String> _declaredLocalNames(AstNode node) {
    final decls = <VarDeclNode>[];
    _collectLocalDecls(node, decls);
    return {for (final d in decls) d.name};
  }

  /// Local declarations in [node] that declare a single record variable.
  List<VarDeclNode> _localRecordDecls(AstNode node) {
    final decls = <VarDeclNode>[];
    _collectLocalDecls(node, decls);
    return [
      for (final d in decls)
        if (d.dimExprs.isEmpty && !d.isPtr && _isRecordTypeName(d.typeName)) d
    ];
  }

  /// Checks an assignment of [rhs] to the record variable [name]: references
  /// accept only reference values, and records stored on the stack cannot be
  /// assigned at all (Action does not copy records).
  void _checkRecordAssignment(String name, AstNode rhs) {
    final t = typeOf(name);
    // Arrays of records (fixed, or dynamic `T x[]`) are not record variables
    if (!_isRecordTypeName(t.name) || arrayDims.containsKey(name) || t.isPtr) return;
    final isRef = t.isRef;
    if (!isRef) {
      throw CompileError(
          "cannot assign to '$name': it is a '${cleanName(t.name)}' stored on the stack, and values of user-defined types are not copied. "
          "Declare it with a reference value (for example '= ${cleanName(t.name)}.create()') to make it a reference");
    }
    if (rhs is VarAccessNode) {
      final rt = typeOf(rhs.name);
      if (_isRecordTypeName(rt.name) &&
          !rt.isRef &&
          !rt.isPtr &&
          !arrayDims.containsKey(rhs.name)) {
        throw CompileError(
            "cannot assign '${rhs.name}', a '${cleanName(rt.name)}' stored on the stack, to reference '$name'");
      }
    } else if (rhs is MemberAccessNode || rhs is ArrayAccessNode) {
      final (rt, rIsPtr) = _getExprType(rhs);
      if (_isRecordTypeName(rt) && !rIsPtr) {
        throw CompileError(
            "cannot assign a '${cleanName(rt)}' stored inside another type or an array to reference '$name'");
      }
    }
  }
}
