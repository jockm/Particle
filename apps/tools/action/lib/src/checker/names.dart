part of '../compiler.dart';

// ------------------------------------------------------------------------------
// Names: type constants, static functions, overloads and pub members
// ------------------------------------------------------------------------------
//
// Three steps, before anything else looks at the program's calls:
//
// 1. `Type.NAME`, a constant declared in a type's body, becomes that
//    constant (a top-level constant named `Type.NAME`), wherever it is used,
//    constant expressions included ([_rewriteTypeConstants]).
// 2. A function with more than one version (overloads: the same name with
//    different parameter types) gives each version its own name, its name
//    and parameter types (`Integer.min~~u8.u8`, whose label is
//    `_Integer.min..u8.u8`) ([_nameOverloads]).
// 3. Once types are known, every call is resolved to the function it calls
//    ([_resolveNames]): `Type.name(args)` to a static function, a call of
//    an overloaded name to its version for the arguments, an overloaded
//    function given to a variable, parameter or result of a function type
//    to the version of that type. Members that are not `pub` cannot be used
//    outside their type's package.
//
// Choosing a version: the versions that take every argument (with the
// conversions allowed anywhere) are kept. One whose parameters match the
// arguments' types exactly wins (an integer constant matches any integer
// type it fits). When several match exactly, an integer constant counts as
// s32 (u32 when larger) to choose between them. Otherwise exactly one
// version must take the arguments; anything else is ambiguous.

const _intTypes = {'u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'bool'};

extension _NameRules on Checker {
  // -------------------------------------------------------- type constants

  /// Step 1: `Type.NAME` becomes the constant `Type.NAME`.
  void _rewriteTypeConstants(ProgramNode root) {
    final consts = <String, VarDeclNode>{
      for (final d in root.decls)
        if (d is VarDeclNode && d.isConst && d.name.contains('.')) d.name: d
    };
    if (consts.isEmpty) return;
    for (var i = 0; i < root.decls.length; i++) {
      final d = root.decls[i];
      final where = d is FuncDeclNode ? d.name : (d.nodeName ?? '');
      root.decls[i] = rewriteTree(d, (n) {
        if (n is MemberAccessNode && n.expr is VarAccessNode) {
          final name = typeConstName((n.expr as VarAccessNode).name, n.member);
          final c = consts[name];
          if (c != null) {
            _checkPubMember(name, c.isPub, where, n.loc);
            return VarAccessNode(name)..loc = n.loc;
          }
        }
        return n;
      }, intoLambdas: true);
    }
  }

  // -------------------------------------------------------------- overloads

  /// Step 2: the versions of an overloaded function get their own names.
  void _nameOverloads(List<FuncDeclNode> funcs) {
    final groups = <String, List<FuncDeclNode>>{};
    for (final f in funcs) {
      (groups[f.name] ??= []).add(f);
    }
    for (final e in groups.entries) {
      final byKey = <String, List<FuncDeclNode>>{};
      for (final f in e.value) {
        (byKey[_paramKey(f)] ??= []).add(f);
      }
      if (byKey.length < 2) continue;
      final shown = sourceName(e.key);
      for (final f in e.value) {
        final why = f.isAsm
            ? "an 'asm' routine names one label"
            : f.isExtern
                ? "an 'extern' function names one C function"
                : f.trapExpr != null
                    ? 'a trap handler runs only as a trap'
                    : f.isTask
                        ? 'a task cannot be overloaded'
                        : f.name == 'main'
                            ? "'main' is where the program starts"
                            : null;
        if (why != null) {
          throw CompileError("'$shown' has more than one version, but $why").at(f.loc);
        }
      }
      final kinds = <String, FuncDeclNode>{};
      for (final k in byKey.entries) {
        final defs = k.value.where((f) => f.body != null).toList();
        if (defs.length > 1) {
          throw CompileError("'$shown(${_shownParams(defs[1])})' is defined twice").at(defs[1].loc);
        }
        // A static function and a method with the same parameter types
        // would have the same name
        final f = k.value.first;
        final other = kinds[_paramTypes(f).join(',')];
        if (other != null && other.isStatic != f.isStatic) {
          throw CompileError("a static function and a method of '${shown.substring(0, shown.lastIndexOf('.'))}' "
                  "cannot have the same parameters: '$shown(${_shownParams(f)})'")
              .at(f.loc);
        }
        kinds[_paramTypes(f).join(',')] = f;
      }
      final names = <String>[];
      for (final f in e.value) {
        f.declaredName = f.name;
        f.name = overloadName(f.name, _paramTypes(f));
        if (!names.contains(f.name)) names.add(f.name);
      }
      _overloads[e.key] = names;
    }
    for (final f in funcs) {
      if (f.isStatic) _staticFuncs.add(f.name);
    }
  }

  /// The parameter types of [f] without its `this`, as an overload's name
  /// writes them.
  List<String> _paramTypes(FuncDeclNode f) => [
        for (final p in f.params)
          if (!(p.name == 'this' && !f.isStatic))
            overloadTypeName(cleanName(p.type), open: p.isOpenArr, rank: p.openRank, refArray: p.isRefArray)
      ];

  String _paramKey(FuncDeclNode f) => '${f.isStatic ? 'static ' : ''}${_paramTypes(f).join(',')}';

  String _shownParams(FuncDeclNode f) => [
        for (final p in f.params)
          if (!(p.name == 'this' && !f.isStatic))
            '${p.isRefArray ? 'ref ' : ''}${sourceName(cleanName(p.type))}${p.isOpenArr ? '[]' * p.openRank : ''}'
      ].join(', ');

  /// How messages show the version [name] of an overloaded function:
  /// `Integer.min(u8, u8)`.
  String _shownVersion(String name) {
    final f = _funcDecls.where((d) => d.name == name).firstOrNull;
    return f == null ? sourceName(name) : '${sourceName(f.declaredName)}(${_shownParams(f)})';
  }

  // ------------------------------------------------------------- resolving

  /// Step 3: resolves the calls and function values of every function, and
  /// of the globals' starting values.
  void _resolveNames(ProgramNode root, List<FuncDeclNode> funcs) {
    final savedTypes = Map<String, TypeInfo>.of(types);
    final savedLocals = locals;
    try {
      for (final f in funcs) {
        if (f.body == null) continue;
        types = Map<String, TypeInfo>.of(savedTypes);
        locals = {};
        for (final p in f.params) {
          types[p.name] = TypeInfo(p.type, p.isPtr, false, p.isRefArray);
          locals[p.name] = 0;
          if (p.isOpenArr) openArrays.add(p.name);
        }
        final decls = <VarDeclNode>[];
        _collectLocalDecls(f.body, decls);
        final arrays = <String>[];
        for (final d in decls) {
          if (d.isConst) continue;
          types[d.name] = TypeInfo(d.typeName, d.isPtr, false, d.isRefArray);
          locals[d.name] = 0;
          // Its dimensions tell a row of an array of strings from a character
          if (d.dimExprs.isNotEmpty && !arrayDims.containsKey(d.name)) {
            try {
              final dims = [for (final e in d.dimExprs) _evalConstExpr(e)];
              arrayDims[d.name] = dims;
              arrayLens[d.name] = dims.first;
              arrays.add(d.name);
            } on CompileError {
              // Reported when the function is checked
            }
          }
        }
        _resolveIn(f, f.name, cleanType(f.retType));
        for (final p in f.params) {
          openArrays.remove(p.name);
        }
        for (final a in arrays) {
          arrayDims.remove(a);
          arrayLens.remove(a);
        }
      }
      types = Map<String, TypeInfo>.of(savedTypes);
      locals = {};
      for (final d in root.decls) {
        if (d is VarDeclNode) _resolveIn(d, d.name, null);
      }
    } on CompileError catch (e) {
      types = savedTypes;
      locals = savedLocals;
      throw e;
    }
    types = savedTypes;
    locals = savedLocals;
  }

  /// Resolves the calls and function values in [node], part of [owner] (a
  /// function or a global), which returns [ret].
  void _resolveIn(AstNode node, String owner, Object? ret) {
    final at = node is FuncDeclNode ? node.body! : node;
    rewriteTree(at, (n) {
      try {
        return _resolveNode(n, owner, ret);
      } on CompileError catch (e) {
        throw e.at(n.loc);
      }
    });
    // An overloaded function used as a value where no type picks a version
    rewriteTree(at, (n) {
      if (n is VarAccessNode && n is! LambdaNode && _overloads.containsKey(n.name) && !_isVariableInScope(n.name)) {
        throw CompileError("'${sourceName(n.name)}' has more than one version; give it to a variable, "
                'parameter or result of a function type, which says which one')
            .at(n.loc);
      }
      if (n is MemberAccessNode && n.expr is VarAccessNode) {
        final t = (n.expr as VarAccessNode).name;
        if (!_isVariableInScope(t) && _overloads.containsKey(methodFuncName(t, n.member))) {
          throw CompileError("'${sourceName(t)}.${n.member}' has more than one version; give it to a "
                  'variable, parameter or result of a function type, which says which one')
              .at(n.loc);
        }
      }
      return n;
    });
  }

  AstNode _resolveNode(AstNode n, String owner, Object? ret) {
    if (n is CallNode) {
      _resolveCall(n, owner);
    } else if (n is MemberAccessNode) {
      _checkFieldAccess(n, owner);
    } else if (n is VarDeclNode && n.initExpr != null) {
      n.initExpr = _pickFunctionValue(n.initExpr!, cleanType(n.typeName));
      final init = n.initList;
      if (init is InitListNode) {
        for (var i = 0; i < init.elems.length; i++) {
          init.elems[i] = _pickFunctionValue(init.elems[i], cleanType(n.typeName));
        }
      }
    } else if (n is VarDeclNode && n.initList is InitListNode) {
      final init = n.initList as InitListNode;
      for (var i = 0; i < init.elems.length; i++) {
        init.elems[i] = _pickFunctionValue(init.elems[i], cleanType(n.typeName));
      }
    } else if (n is BinaryOpNode && n.op == '=') {
      n.right = _pickFunctionValue(n.right, _typeOrNull(n.left));
    } else if (n is ReturnNode && n.expr != null && ret != null) {
      n.expr = _pickFunctionValue(n.expr!, ret);
    }
    if (n is HeapAllocNode) _checkFieldNames(n.typeName, [for (final p in n.fieldPaths) p.first as String], owner, n.loc);
    if (n is VarDeclNode && n.initList is RecordInitNode) {
      _checkFieldNames(cleanName(n.typeName), [for (final (f, _) in (n.initList as RecordInitNode).fields) f],
          owner, n.loc);
    }
    return n;
  }

  Object? _typeOrNull(AstNode e) {
    if (e is StringLitNode) return 'string';
    try {
      return cleanType(_getExprType(e).$1);
    } on CompileError {
      return null;
    }
  }

  /// A call: a static function (`Type.name(args)`), a method, or a function
  /// with more than one version.
  void _resolveCall(CallNode call, String owner) {
    if (isMethodCall(call.name) && call.args.isNotEmpty) {
      final m = methodOfCall(call.name);
      final rcv = call.args.first;
      // Type.name(args): a static function
      if (rcv is VarAccessNode && !_isVariableInScope(rcv.name) && _isTypeName(rcv.name)) {
        final t = rcv.name;
        final base = methodFuncName(t, m);
        final versions = _versionsOf(base).where(_staticFuncs.contains).toList();
        if (versions.isEmpty) {
          if (_versionsOf(base).isNotEmpty) {
            throw CompileError("'${sourceName(base)}' is a method: call it on a value, as x.$m(...)");
          }
          throw CompileError("type '${sourceName(t)}' has no static function '$m'");
        }
        final args = call.args.sublist(1);
        final chosen = _choose(base, versions, args, skipThis: false);
        _checkPubMember(base, _pubFuncs.contains(chosen), owner, call.loc);
        call.name = chosen;
        call.args
          ..clear()
          ..addAll(args);
        _pickArgFunctionValues(call, chosen, 0);
        return;
      }
      final sName = _typeOrNull(rcv);
      if (sName is! String || sName.isEmpty) return;
      final (declType, versions) = _methodVersions(sName, m);
      if (versions.isEmpty) return;
      final methods = versions.where((v) => !_staticFuncs.contains(v)).toList();
      if (methods.isEmpty) {
        throw CompileError("'${sourceName(methodFuncName(declType!, m))}' is a static function of "
            "'${sourceName(declType)}': call it as ${sourceName(declType)}.$m(...)");
      }
      final base = methodFuncName(declType!, m);
      final chosen =
          methods.length == 1 && !_overloads.containsKey(base) ? methods.single : _choose(base, methods, call.args.sublist(1), skipThis: true);
      _checkPubMember(base, _pubFuncs.contains(chosen), owner, call.loc);
      if (chosen != base) call.name = methodCallName(chosen.substring(declType.length + 1));
      _pickArgFunctionValues(call, chosen, 1);
      return;
    }
    final versions = _overloads[call.name];
    if (versions != null && !_isVariableInScope(call.name)) {
      final chosen = _choose(call.name, versions, call.args, skipThis: false);
      call.name = chosen;
      _pickArgFunctionValues(call, chosen, 0);
    } else if (funcSignatures.containsKey(call.name) && !_isVariableInScope(call.name)) {
      _pickArgFunctionValues(call, call.name, 0);
    }
  }

  /// The versions of the function [name]: its overloads, or itself.
  List<String> _versionsOf(String name) =>
      _overloads[name] ?? (funcSignatures.containsKey(name) ? [name] : const []);

  /// The type that declares method [m] for a value of type [sName] (itself,
  /// or a type embedded in it) and the versions of the method there.
  (String?, List<String>) _methodVersions(String sName, String m) {
    final own = _versionsOf(methodFuncName(sName, m));
    if (own.isNotEmpty) return (sName, own);
    for (final (embedType, _) in structs[sName]?.embedded ?? const <(String, int)>[]) {
      final r = _methodVersions(embedType, m);
      if (r.$2.isNotEmpty) return r;
    }
    return (null, const []);
  }

  /// An argument given to a parameter of a function type picks the version
  /// of an overloaded function of that type.
  void _pickArgFunctionValues(CallNode call, String callee, int skip) {
    final sig = funcSignatures[callee];
    if (sig == null) return;
    final params = sig.params.skip(skip == 1 ? 1 : 0).toList();
    final args = call.args.skip(skip).toList();
    for (var i = 0; i < args.length && i < params.length; i++) {
      final picked = _pickFunctionValue(args[i], params[i].type);
      if (!identical(picked, args[i])) call.args[i + skip] = picked;
    }
  }

  /// [value] given where a value of type [type] is expected: when it names
  /// an overloaded function and [type] is a function type, the version of
  /// that type.
  AstNode _pickFunctionValue(AstNode value, Object? type) {
    String? base;
    String? methodType;
    if (value is VarAccessNode && value is! LambdaNode && !_isVariableInScope(value.name)) {
      base = value.name;
    } else if (value is MemberAccessNode && value.expr is VarAccessNode) {
      final t = (value.expr as VarAccessNode).name;
      if (!_isVariableInScope(t)) {
        base = methodFuncName(t, value.member);
        methodType = t;
      }
    }
    final versions = base == null ? null : _overloads[base];
    if (versions == null || type is! String) return value;
    final fnType = fnTypes[type];
    if (fnType == null) return value;
    final (paramTypes, retType) = fnType;
    for (final v in versions) {
      final sig = funcSignatures[v]!;
      final ps = [for (final p in sig.params) cleanName(p.type)];
      if (ps.length == paramTypes.length &&
          [for (var i = 0; i < ps.length; i++) ps[i] == cleanName(paramTypes[i])].every((x) => x) &&
          cleanName(sig.retType) == cleanName(retType)) {
        if (methodType != null) {
          (value as MemberAccessNode).member = v.substring(methodType.length + 1);
          return value;
        }
        return VarAccessNode(v)..loc = value.loc;
      }
    }
    throw CompileError("no version of '${sourceName(base!)}' is a '${sourceName(type)}'; the versions are "
        '${versions.map(_shownVersion).join(', ')}');
  }

  /// The version of [base] (one of [versions]) the arguments [args] call.
  String _choose(String base, List<String> versions, List<AstNode> args, {required bool skipThis}) {
    if (versions.length == 1 && !_overloads.containsKey(base)) return versions.single;
    final taking = <String>[];
    final exact = <String>[];
    final scores = <String, int>{};
    for (final v in versions) {
      final params = funcSignatures[v]!.params.skip(skipThis ? 1 : 0).toList();
      if (params.length != args.length) continue;
      var all = true, allExact = true, score = 0;
      for (var i = 0; i < args.length; i++) {
        final (m, preferred) = _argMatch(args[i], params[i]);
        if (m == 0) all = false;
        if (m < 2) allExact = false;
        if (preferred) score++;
      }
      if (!all) continue;
      taking.add(v);
      if (allExact) exact.add(v);
      scores[v] = score;
    }
    String? pick(List<String> c) {
      if (c.length == 1) return c.single;
      if (c.isEmpty) return null;
      final best = c.map((v) => scores[v]!).reduce((a, b) => a > b ? a : b);
      final top = c.where((v) => scores[v] == best).toList();
      return top.length == 1 ? top.single : null;
    }

    final chosen = exact.isNotEmpty ? pick(exact) : (taking.length == 1 ? taking.single : null);
    if (chosen != null) return chosen;
    final shown = sourceName(base);
    final given = args.map(_shownArgType).join(', ');
    if (taking.isEmpty) {
      throw CompileError("no version of '$shown' takes ($given); the versions are "
          '${versions.map(_shownVersion).join(', ')}');
    }
    final which = exact.length > 1 ? exact : taking;
    throw CompileError("the call of '$shown' with ($given) could be "
        '${which.map(_shownVersion).join(' or ')}; convert an argument, as in u8(x), to say which');
  }

  String _shownArgType(AstNode a) {
    try {
      final c = _constExact(a, arrayNames: false);
      if (c.type == null) return 'constant ${c.value}';
      return c.type!;
    } on CompileError {
      // Not a constant
    }
    final t = _typeOrNull(a);
    return t is String && t.isNotEmpty ? sourceName(t) : '?';
  }

  /// How well [arg] fits parameter [p]: 0 not at all, 1 with a conversion,
  /// 2 exactly; and whether it is an integer constant whose type (s32, or
  /// u32 when larger) is the parameter's.
  (int, bool) _argMatch(AstNode arg, ParamSig p) {
    final pt = cleanName(p.type);
    // An overloaded function as a value: any function type may take it
    if (arg is VarAccessNode && _overloads.containsKey(arg.name) && !_isVariableInScope(arg.name)) {
      return (fnTypes.containsKey(pt) ? 1 : 0, false);
    }
    String? constType;
    if (!p.isOpen) {
      try {
        final c = _constExact(arg, arrayNames: false);
        constType = c.type;
        if (c.type == null) {
          if (_intTypes.contains(pt)) {
            final preferred = pt == (c.value > BigInt.from(0x7FFFFFFF) ? 'u32' : 's32');
            return (_fitsType(c.value, pt) ? 2 : 0, preferred);
          }
          if (pt == 'f32' || pt == 'f64') return (1, false);
          return (0, false);
        }
      } on CompileError {
        // Not a constant: its type decides
      }
    }
    final at = constType ?? _typeOrNull(arg);
    if (at is! String || at.isEmpty) return (1, false);
    if (p.isOpen) {
      return (at == pt || (pt == 'u8' && at == 'string') ? 2 : 0, false);
    }
    if (_intTypes.contains(pt)) {
      if (at == pt) return (2, false);
      return (_intTypes.contains(at) ? 1 : 0, false);
    }
    if (pt == 'f32' || pt == 'f64') return (at == pt ? 2 : 0, false);
    if (fnTypes.containsKey(pt)) return (at == pt ? 2 : (at.startsWith('fn_') || fnTypes.containsKey(at) ? 1 : 0), false);
    return (at == pt ? 2 : 0, false);
  }

  // ------------------------------------------------------------ pub members

  /// The package of [name] (a type, a function or a constant): its prefix,
  /// or '' outside packages.
  String _packageOfName(String name) {
    final i = name.lastIndexOf(packageMark);
    return i < 0 ? '' : name.substring(0, i);
  }

  /// A member of a type that is not `pub` cannot be used outside the
  /// type's package. [member] is the member's full name (`geo..Point.x`)
  /// and [owner] the function or global using it.
  void _checkPubMember(String member, bool isPub, String owner, String? loc) {
    if (isPub) return;
    final pkg = _packageOfName(member);
    if (pkg.isEmpty || pkg == _packageOfName(owner)) return;
    final dot = member.lastIndexOf('.');
    throw CompileError("'${member.substring(dot + 1)}' of '${sourceName(member.substring(0, dot))}' is not "
            "pub: only its own package can use it")
        .at(loc);
  }

  /// `x.field` for a field of another package's type.
  void _checkFieldAccess(MemberAccessNode n, String owner) {
    final t = _typeOrNull(n.expr);
    if (t is! String || !t.contains(packageMark)) return;
    final declType = _fieldOwner(t, n.member);
    if (declType == null) return;
    _checkPubMember(methodFuncName(declType, n.member), _pubFields.contains(methodFuncName(declType, n.member)),
        owner, n.loc);
  }

  /// The fields given values by name in `T.create(...)` or `{...}`.
  void _checkFieldNames(String type, List<String> fields, String owner, String? loc) {
    if (!type.contains(packageMark)) return;
    for (final f in fields) {
      final declType = _fieldOwner(type, f);
      if (declType == null) continue;
      _checkPubMember(methodFuncName(declType, f), _pubFields.contains(methodFuncName(declType, f)), owner, loc);
    }
  }

  /// The type that declares field [f] of type [t] (itself or one embedded
  /// in it).
  String? _fieldOwner(String t, String f) {
    final td = _typeDefs[t];
    if (td == null) return null;
    if (td.fields.any((x) => x.name == f && !x.isEmbedded)) return t;
    for (final x in td.fields.where((x) => x.isEmbedded)) {
      final r = _fieldOwner(cleanName(x.type), f);
      if (r != null) return r;
    }
    return null;
  }
}
