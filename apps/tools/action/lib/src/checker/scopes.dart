part of '../compiler.dart';

// ------------------------------------------------------------------------------
// Scopes of functions, inline functions and local constants
// ------------------------------------------------------------------------------
//
// Every function starts from the program's global scope: the types,
// arrays and constants of the globals, as they were after the program-level
// checks. Nothing a function declares is seen by the functions after it.
//
// A local `const` follows Go's rule: it can be used from its declaration to
// the end of the `{ }` block it is declared in, and a constant declared in
// an inner block hides one of the same name from an enclosing block until
// the inner block ends. Its name must not be that of a global (constant,
// enum member, variable, function or type), of another constant in the same
// block, or of a parameter or local variable of the function. A `-D` value
// of the same name still overrides it, as for a global `const`.
//
// The dimensions of local arrays are worked out before the function's frame
// is laid out, by walking its blocks with the same scopes ([_resolveLocalDims]).
//
// An inline function's body has a scope of its own: the globals, its
// parameters and its own locals and constants. The variables and constants
// of the function it is expanded into are hidden ([_enterInlineBody]).

/// What a block's constant hid when it was declared: the value, type and
/// exact value of the constant of the same name in an enclosing block, or
/// nulls when there was none.
typedef _Hidden = (int?, String?, _ConstVal?);

/// Local constant scopes in force, saved while an inline function's body is
/// walked.
class _LocalConstState {
  final List<Map<String, _Hidden>> scopes;
  final Set<String> varNames;
  final Map<String, _Hidden> values;
  _LocalConstState(this.scopes, this.varNames, this.values);
}

/// The scope of the function an inline function is expanded into, saved
/// while the inline body is walked.
class _CallerScope {
  final Map<String, int> locals;
  final Map<String, TypeInfo> types;
  final Map<String, List<int>> arrayDims;
  final Map<String, int> arrayLens;
  final Map<String, int> boundAddrs;
  final Set<String> openArrays;
  final Set<String> dynamicArrays;
  final Set<String> borrowedParams;
  final Map<String, String> affineState;
  final Set<String> hiddenNames;
  final _LocalConstState consts;
  _CallerScope(this.locals, this.types, this.arrayDims, this.arrayLens, this.boundAddrs,
      this.openArrays, this.dynamicArrays, this.borrowedParams, this.affineState,
      this.hiddenNames, this.consts);
}

extension _Scopes on Checker {
  /// Sets up the local constant scopes of function [func] (which has been
  /// started from the program's global scope) and works out the dimensions
  /// of its local arrays.
  void _enterFunctionScope(FuncDeclNode func) {
    _constScopes.clear();
    _hiddenCallerNames = {};
    _localVarNames = _functionVarNames(func);
    _resolveLocalDims(func.body);
  }

  /// The names of [func]'s parameters and local variables.
  Set<String> _functionVarNames(FuncDeclNode func) {
    final names = <String>{for (final p in func.params) p.name};
    if (func.body != null) _collectLocalNames(func.body!, names);
    return names;
  }

  void _enterBlock() => _constScopes.add({});

  void _leaveBlock() {
    _constScopes.removeLast().forEach((name, hidden) {
      constants.remove(name);
      _constTypes.remove(name);
      _constExactValues.remove(name);
      _putConst(name, hidden);
    });
  }

  /// The constant [name] as it is now (nulls when there is none).
  _Hidden _currentConst(String name) =>
      (constants[name], _constTypes[name], _constExactValues[name]);

  /// Makes [name] the constant [v] again (or no constant, for nulls).
  void _putConst(String name, _Hidden v) {
    final (value, type, exact) = v;
    if (value == null) return;
    constants[name] = value;
    _constTypes[name] = type;
    if (exact != null) _constExactValues[name] = exact;
  }

  /// Declares local constant [d] in the innermost block.
  void _declareLocalConst(VarDeclNode d) {
    final name = d.name;
    if (predefinedConstants.containsKey(name)) {
      // A -D value overrides it, as it does a global const
      _defineLocalConst(d);
      return;
    }
    final kind = _globalKind(name);
    if (kind != null) {
      throw CompileError(
          "local constant '$name' has the same name as $kind; give it another name");
    }
    if (_constScopes.isNotEmpty && _constScopes.last.containsKey(name)) {
      throw CompileError("constant '$name' is already declared in this block");
    }
    if (_localVarNames.contains(name)) {
      throw CompileError(
          "local constant '$name' has the same name as a parameter or variable of '$currentFuncName'");
    }
    // A constant of an enclosing block is hidden until this block ends
    final _Hidden hidden =
        _constScopes.any((s) => s.containsKey(name)) ? _currentConst(name) : (null, null, null);
    _defineLocalConst(d);
    if (_constScopes.isNotEmpty) _constScopes.last[name] = hidden;
  }

  /// What kind of global [name] is ('a global constant', ...), or null.
  String? _globalKind(String name) {
    if (_globalConstNames.contains(name)) return 'a global constant';
    if (globals.contains(name) || _globalBoundNames.contains(name)) return 'a global variable';
    if (funcSignatures.containsKey(name)) return 'a function';
    if (_declaredTypes.contains(name) || fnTypes.containsKey(name)) return 'a type';
    return null;
  }

  /// Hides the local constants in force; [_restoreLocalConsts] puts them
  /// back.
  _LocalConstState _hideLocalConsts() {
    final values = <String, _Hidden>{};
    for (final scope in _constScopes) {
      for (final name in scope.keys) {
        values[name] ??= _currentConst(name);
        constants.remove(name);
        _constTypes.remove(name);
        _constExactValues.remove(name);
      }
    }
    final saved = _LocalConstState(
        [for (final s in _constScopes) Map.of(s)], _localVarNames, values);
    _constScopes.clear();
    return saved;
  }

  void _restoreLocalConsts(_LocalConstState saved) {
    _constScopes
      ..clear()
      ..addAll(saved.scopes);
    _localVarNames = saved.varNames;
    saved.values.forEach(_putConst);
  }

  /// Starts the body of inline function [func], expanded into the current
  /// function: from now on only the globals are in scope, and the caller
  /// binds the parameters. [_leaveInlineBody] returns to the caller's scope.
  _CallerScope _enterInlineBody(FuncDeclNode func) {
    final global = _globalScope!;
    final saved = _CallerScope(
        locals,
        types,
        Map.of(arrayDims),
        Map.of(arrayLens),
        Map.of(boundAddrs),
        Set.of(openArrays),
        Set.of(dynamicArrays),
        Set.of(borrowedParams),
        affineState,
        _hiddenCallerNames,
        _hideLocalConsts());
    // The caller's names, which the inline body may not use
    _hiddenCallerNames = {..._hiddenCallerNames, ...locals.keys, ...saved.consts.values.keys}
      ..removeWhere((n) => n.contains(RegExp(r'~(len\d*|end)$')));
    locals = {};
    types = Map.of(global.types);
    arrayDims
      ..clear()
      ..addAll(global.arrayDims);
    arrayLens
      ..clear()
      ..addAll(global.arrayLens);
    boundAddrs
      ..clear()
      ..addAll(global.boundAddrs);
    openArrays.clear();
    dynamicArrays.clear();
    borrowedParams.clear();
    affineState = {};
    _localVarNames = _functionVarNames(func);
    _resolveLocalDims(func.body);
    return saved;
  }

  void _leaveInlineBody(_CallerScope s) {
    locals = s.locals;
    types = s.types;
    arrayDims
      ..clear()
      ..addAll(s.arrayDims);
    arrayLens
      ..clear()
      ..addAll(s.arrayLens);
    boundAddrs
      ..clear()
      ..addAll(s.boundAddrs);
    openArrays
      ..clear()
      ..addAll(s.openArrays);
    dynamicArrays
      ..clear()
      ..addAll(s.dynamicArrays);
    borrowedParams
      ..clear()
      ..addAll(s.borrowedParams);
    affineState = s.affineState;
    _hiddenCallerNames = s.hiddenNames;
    _restoreLocalConsts(s.consts);
  }

  /// Evaluates the dimensions and `@` addresses of the local variables in
  /// [node], with each block's constants in scope.
  void _resolveLocalDims(AstNode? node) {
    if (node is BlockNode) {
      _enterBlock();
      for (final s in node.stmts) {
        try {
          _resolveLocalDims(s);
        } on CompileError catch (e) {
          throw e.at(s.loc);
        }
      }
      _leaveBlock();
    } else if (node is IfNode) {
      _resolveLocalDims(node.thenBody);
      _resolveLocalDims(node.elseBody);
    } else if (node is WhileNode) {
      _resolveLocalDims(node.body);
    } else if (node is ForRangeNode) {
      _resolveLocalDims(node.body);
    } else if (node is SwitchNode) {
      _resolveLocalDims(node.body);
    } else if (node is VarDeclNode) {
      if (node.isConst) {
        _declareLocalConst(node);
      } else {
        _resolveVarDecl(node);
      }
    }
  }
}
