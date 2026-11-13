part of '../compiler.dart';

// ------------------------------------------------------------------------------
// Checker: the meaning of a program
// ------------------------------------------------------------------------------
//
// The checker finds every error in a program before any code is generated:
// it lays out the user-defined types, evaluates the constants, records the
// signatures of the functions, classifies references and follows them, and
// then walks every function as code generation would (see check_walk.dart),
// recording the type of each expression. A code generator (CodeGen for
// Particle) extends it and only emits code for a program that has passed.

/// Type information recorded for a variable or parameter:
/// `(type name, is pointer, is reference)`.
class TypeInfo {
  /// Usually a type name; for tuple-typed declarations a list of
  /// [TupleElemType].
  final Object name;
  final bool isPtr;
  final bool isRef;

  /// `ref T a[N]` or `ref T a[]`: the elements are references to [name]
  /// values (one address each).
  final bool refElems;
  const TypeInfo(this.name, this.isPtr, [this.isRef = false, this.refElems = false]);
}

/// Layout of one field of a record type.
class FieldInfo {
  final int offset;
  final String type;
  final bool isPtr;

  /// `null`, an int dimension or a `List<int>` of dimensions.
  final Object? dim;

  /// `T name[]`: a reference to a heap array. A field with [isPtr] alone is
  /// `ref T name`.
  final bool isArrayRef;

  /// `ref T name[N]` or `ref T name[]`: the elements are references.
  final bool refElems;
  const FieldInfo(this.offset, this.type, this.isPtr, this.dim,
      {this.isArrayRef = false, this.refElems = false});
}

/// Layout of a record type: its fields (including promoted fields of
/// embedded types), total size and embedded types with their offsets.
class StructInfo {
  final Map<String, FieldInfo> fields;

  /// Size in bytes, padded to a multiple of [align].
  final int size;
  final List<(String, int)> embedded;

  /// Alignment in bytes: that of the most-aligned field.
  final int align;
  StructInfo(this.fields, this.size, this.embedded, [this.align = 1]);
}

/// Parameter signature: `(type, is pointer, is open array)`.
class ParamSig {
  final String? type;
  final bool isPtr;
  final bool isOpen;

  /// `ref T name[]`: an open array of references.
  final bool isRefArray;

  /// The dimensions of an open array (`T m[][]` is 2).
  final int openRank;
  const ParamSig(this.type, this.isPtr, this.isOpen, [this.isRefArray = false, this.openRank = 1]);

  /// The call slots the argument takes: an open array's address and one
  /// length per dimension.
  int get slots => isOpen ? 1 + openRank : 1;
}

/// Function signature: return type (a name or a tuple list), whether it
/// returns a pointer, and the parameter signatures.
class FuncSig {
  final Object retType;
  final bool retPtr;
  final List<ParamSig> params;

  /// A C function (`extern`), and whether it takes `...` after [params].
  final bool isExtern;
  final bool isVariadic;

  /// Returns a heap array of references (`ref T[] f()`).
  final bool retRefArray;
  const FuncSig(this.retType, this.retPtr, this.params,
      {this.isExtern = false, this.isVariadic = false, this.retRefArray = false});
}

const _defaultField = FieldInfo(0, 'u32', false, null);

/// Thrown while laying out record types when a constant needs the size of a
/// type that has not been laid out yet; the type is retried on the next pass.
class _LayoutDeferred implements Exception {}
const _signedTypes = ['s8', 's16', 's32', 's64'];

/// Built-in memory access: name, argument count and result type. `peek8`,
/// `peek16` and `peek32` read a byte, halfword or word at an address (zero-
/// extended), `poke8`, `poke16` and `poke32` write one, and `callAddr` calls
/// the code at an address and gives what it returns in R1. The address is
/// any value computed at run time. A program that declares a function of the
/// same name uses that instead.
const Map<String, (int, String)> _memoryBuiltins = {
  'peek8': (1, 'u8'),
  'peek16': (1, 'u16'),
  'peek32': (1, 'u32'),
  'poke8': (2, 'void'),
  'poke16': (2, 'void'),
  'poke32': (2, 'void'),
  'callAddr': (1, 'u32'),
};

class Checker {
  /// The target the program is checked for: its pointer size, alignment
  /// rules, trap vectors and supported types.
  final Target target;

  Map<String, String> affineState = {};
  final Set<String> dynamicArrays = {};
  final Set<String> borrowedParams = {};
  Map<String, int> locals = {};
  final Set<String> globals = {};
  Map<String, TypeInfo> types = {};
  final Map<String, StructInfo> structs = {};
  final Map<String, int> arrayLens = {};
  final Map<String, int> stringLens = {};
  final Map<String, List<int>> arrayDims = {};
  final Map<String, int> boundAddrs = {};
  final Set<String> volatiles = {};
  final Map<String, FuncSig> funcSignatures = {};
  final Map<String, (List<String>, String)> fnTypes = {};
  String currentFuncName = '';
  (Object?, bool) currentFuncRet = (null, false);

  /// Trap handlers (`trap(N) name() { ... }`): they run only as traps.
  final Set<String> _trapHandlerNames = {};

  /// True while generating a task function.
  bool currentFuncIsTask = false;

  /// While lowering coroutine operations: the function being lowered, and
  /// the next resume point number.
  FuncDeclNode? _loweringFunc;
  int _nextStep = 1;

  /// Functions declared without a body (prototypes).
  final Set<String> _prototypeNames = {};
  final List<_FlowContext> flowStack = [];
  final Map<String, int> constants = {};

  /// The expression of the expression statement being checked: `unset()`
  /// and calls to functions that return nothing are allowed only there.
  AstNode? _statementExpr;

  /// Warnings and information found while generating code, in order.
  final List<CompileNote> notes = [];

  /// Records a warning or information about the program, located at [at]
  /// when it has a location.
  void note(NoteSeverity severity, String message, [AstNode? at]) {
    final located = CompileError(message).at(at?.loc).message;
    notes.add(CompileNote(severity, located));
  }

  /// Declared type of constant [name], or null when it is untyped (an enum
  /// member, a `-D` value) or not a constant.
  String? constTypeOf(String name) => _constTypes[name];

  /// Global `const` declarations and enum members not evaluated yet, keyed
  /// by name. They are evaluated on first use, so constants may refer to
  /// each other (and to `sizeof`) regardless of declaration order.
  final Map<String, AstNode> _pendingConsts = {};
  final Set<String> _constsInProgress = {};

  /// Declared type of each `const` (absent for enum members and `-D`
  /// values, which are untyped).
  final Map<String, String?> _constTypes = {};

  /// Exact value and type of each evaluated constant; [constants] holds
  /// the same values as 32-bit patterns.
  final Map<String, _ConstVal> _constExactValues = {};

  /// Constants defined on the command line with `-D`. They take precedence
  /// over a `const` of the same name in the source, which therefore acts as
  /// a default value.
  final Map<String, int> predefinedConstants;

  /// Names of all record types declared in the program, laid out or not.
  final Set<String> _declaredTypes = {};

  /// Record variables that are references, per function, and globally.
  final Map<String, Set<String>> _functionRefs = {};
  final Set<String> _globalRefs = {};
  final Map<String, FuncDeclNode> inlineFuncs = {};
  final List<(String, int)> inlineReturnStack = [];
  final Set<String> openArrays = {};

  Checker(this.target, {Map<String, int> predefinedConstants = const {}})
      : predefinedConstants = Map.of(predefinedConstants);

  /// The program's global declarations and functions, in source order, and
  /// the handler bound to each trap number; set by [_prepare].
  List<VarDeclNode> _dataDecls = const [];
  List<FuncDeclNode> _funcDecls = const [];
  Map<int, String> _trapHandlers = const {};

  /// While checking a function: the number of enclosing loops and switches
  /// (for `break`), of those `continue` may name, and of inline functions
  /// being expanded.
  int _breakDepth = 0;
  int _flowDepth = 0;
  int _inlineDepth = 0;

  /// The program's global scope, which every function starts from (see
  /// scopes.dart); the names of the global constants and enum members,
  /// and of the globals at fixed addresses.
  _ScopeSnapshot? _globalScope;
  final Set<String> _globalConstNames = {};
  final Set<String> _globalBoundNames = {};

  /// The local constants of each enclosing block, innermost last, and the
  /// names of the parameters and local variables of the function (or
  /// inline function) being walked.
  final List<Map<String, _Hidden>> _constScopes = [];
  Set<String> _localVarNames = {};

  /// While an inline function's body is walked: the variables and
  /// constants of the functions it is expanded into, which it may not use.
  Set<String> _hiddenCallerNames = {};

  /// Variables that cannot be written: `main`'s command line.
  final Set<String> _readOnly = {};

  /// The parameters (by index) each function writes through (see
  /// readonly.dart).
  final Map<String, Set<int>> _writtenParams = {};

  /// Floating-point constants (`const f64 PI = 3.14159;`): value and type.
  final Map<String, _FloatConst> _floatConsts = {};

  /// String constants (`const string NAME = "text";`) and their text, so
  /// that `.len` is a constant.
  final Map<String, String> _stringConsts = {};

  /// The open array parameters of the function being compiled that have
  /// more than one dimension, and how many; their lengths are in the locals
  /// `name__len` (the first), `name__len1`, ...
  final Map<String, int> openRanks = {};

  /// Constant tables (`const T name[N] = {...}`): globals that cannot be
  /// written.
  final Set<String> _readOnlyGlobals = {};

  /// The inline functions being expanded, innermost last.
  final Set<String> _inlineExpanding = {};

  /// The type of each expression checked, as `(type name, is pointer)`.
  /// An inline function's body is checked at every call; the last call
  /// checked is recorded.
  final Map<AstNode, (Object, bool)> exprTypes = Map.identity();

  /// Checks [root] and throws the first error found. The program-level
  /// state (types, constants, signatures, the types of locals...) is left
  /// as checking left it.
  void check(ProgramNode root) {
    _prepare(root);
    _checkProgramBody();
  }

  /// The checks of the whole program: constants, types, signatures, trap
  /// handlers, globals, coroutine operations, prototypes and references.
  void _prepare(ProgramNode root) {
    // Locals are block-scoped: give each its own name first
    resolveBlockScopes(root, {
      for (final d in root.decls)
        if (d is VarDeclNode && !d.isConst) d.name
    }, {
      ...predefinedConstants.keys,
      for (final d in root.decls)
        if (d is VarDeclNode && d.isConst) d.name
        else if (d is FuncDeclNode) d.name
        else if (d is EnumDeclNode) ...d.members.map((m) => m.$1),
    });
    // Constants: -D definitions first, then the program's enum members and
    // global consts, evaluated lazily in any order.
    constants.addAll(predefinedConstants);
    for (final d in root.decls) {
      if (d is EnumDeclNode) {
        // Process Enum declarations into compile-time constants (zero memory allocated)
        AstNode next = IntLitNode(0);
        for (final (mName, mExpr) in d.members) {
          final valueExpr = mExpr ?? next;
          if (!predefinedConstants.containsKey(mName)) {
            _pendingConsts[mName] = valueExpr;
          }
          next = BinaryOpNode('+', VarAccessNode(mName), IntLitNode(1));
        }
      } else if (d is VarDeclNode && d.isConst && _isFloatName(d.typeName)) {
        _validateBackendType(d.typeName, "constant '${d.name}'");
        _defineFloatConst(d);
      } else if (d is VarDeclNode && d.isConst) {
        // Register global constants upfront (before verify evaluation)
        if (!predefinedConstants.containsKey(d.name)) {
          _pendingConsts[d.name] = d.initExpr ?? IntLitNode(0);
          _constTypes[d.name] = cleanName(d.typeName);
        } else {
          _typePredefinedConst(d.name, cleanName(d.typeName));
        }
      }
    }

    // Function types first: a record's field may have one
    for (final d in root.decls) {
      try {
        if (d is FnTypeNode) {
          fnTypes[d.name] = (d.paramTypes, d.retType);
        }
      } on CompileError catch (e) {
        throw e.at(d.loc);
      }
    }

    final typeDefs = root.decls.whereType<TypeDefNode>().toList();
    _declaredTypes.addAll(typeDefs.map((t) => t.name));
    _layoutStructs(typeDefs);
    _dataDecls = root.decls.whereType<VarDeclNode>().toList();
    _readOnlyGlobals.addAll([for (final d in _dataDecls) if (d.isReadOnly) d.name]);
    for (final d in _dataDecls) {
      final init = d.initExpr;
      if (d.isReadOnly && cleanName(d.typeName) == 'string' && init is StringLitNode) {
        _stringConsts[d.name] = init.val;
      }
    }
    final rawFuncDecls = root.decls.whereType<FuncDeclNode>().toList();
    for (final f in rawFuncDecls) {
      try {
        _validateBackendType(f.retType, "return type of function '${f.name}'");
      } on CompileError catch (e) {
        throw e.at(f.loc);
      }
      for (final p in f.params) {
        try {
          _validateBackendType(p.type, "parameter '${p.name}' of function '${f.name}'");
        } on CompileError catch (e) {
          throw e.at(p.loc ?? f.loc);
        }
      }
      funcSignatures[f.name] = FuncSig(
          cleanType(f.retType),
          f.retPtr,
          [
            for (final p in f.params)
              ParamSig(cleanName(p.type), p.isPtr, p.isOpenArr, p.isRefArray, p.openRank)
          ],
          isExtern: f.isExtern,
          isVariadic: f.isVariadic,
          retRefArray: f.retRefArray);
    }
    _checkTargetDecls(rawFuncDecls);
    for (final f in rawFuncDecls) {
      if (!f.isInline) continue;
      for (final p in f.params) {
        if (p.openRank > 1) {
          throw CompileError("inline function '${f.name}': an open array parameter of an inline "
                  "function has one dimension; '${p.name}' has ${p.openRank}")
              .at(p.loc ?? f.loc);
        }
      }
    }
    // A field and a method of one name would make t.f(x) ambiguous
    for (final td in typeDefs) {
      for (final f in td.fields) {
        if (funcSignatures.containsKey('${td.name}_${f.name}')) {
          throw CompileError("type '${td.name}' has both a field and a method named '${f.name}'")
              .at(f.loc ?? td.loc);
        }
      }
    }
    _funcDecls = rawFuncDecls;
    _findWrittenParams(rawFuncDecls);
    final funcDecls = rawFuncDecls;
    final dataDecls = _dataDecls;

    _trapHandlers = _collectTrapHandlers(funcDecls);

    // Register global types and dims (constants may take their sizes)
    for (final d in dataDecls) {
      try {
        if (d.isConst) continue;
        _resolveVarDecl(d);
        _validateBackendType(d.typeName, "global variable '${d.name}'");
        if (d.isRefArray) _checkRefArrayElem(d.name, d.typeName, d.loc);
        if (d.isVolatile || d.boundAddr != null) {
          volatiles.add(d.name);
        }
        types[d.name] = TypeInfo(d.typeName, d.isPtr, false, d.isRefArray);
        var dims = d.arrayDims;
        if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
          dims = [d.arrayDim!];
        }
        if (dims != null && dims.isNotEmpty) {
          arrayDims[d.name] = dims;
          arrayLens[d.name] = dims[0];
        }
        if (d.boundAddr != null) {
          boundAddrs[d.name] = d.boundAddr!;
        } else {
          globals.add(d.name);
        }
      } on CompileError catch (e) {
        throw e.at(d.loc);
      }
    }

    // Evaluate every enum member and global constant (zero memory
    // allocated); this reports errors in constants nothing refers to.
    for (final name in List.of(_pendingConsts.keys)) {
      _constValue(name);
    }

    // Evaluate top-level verify assertions
    for (final d in root.decls) {
      if (d is VerifyNode) {
        final res = _evalConstExpr(d.cond);
        if (res == 0) {
          final tok = d.token;
          final loc = tok != null ? tok.loc : 'verify';
          throw CompileError("$loc: Compile-time verification failed: '${d.msg}'");
        }
      }
    }

    // Coroutine operations become statements (see coroutines.dart)
    _prototypeNames
      ..clear()
      ..addAll([for (final f in funcDecls) if (f.body == null && !f.isInline) f.name]);
    _lowerCoroutineOps(funcDecls);
    _checkPrototypes(funcDecls);

    // Decide which record variables are references (see references.dart)
    final savedTypes = Map<String, TypeInfo>.of(types);
    _classifyReferences(funcDecls, dataDecls);
    types = savedTypes;
    // Follow references through every path (see ownership.dart)
    _checkReferenceFlow(funcDecls);
    for (final g in _globalRefs) {
      final t = types[g]!;
      types[g] = TypeInfo(t.name, t.isPtr, true);
    }


    // Inline functions are expanded where they are called, wherever they
    // are declared
    for (final f in funcDecls) {
      if (f.isInline) inlineFuncs[f.name] = f;
    }

    // The global scope every function starts from
    for (final d in root.decls) {
      if (d is EnumDeclNode) {
        _globalConstNames.addAll([for (final (m, _) in d.members) m]);
      } else if (d is VarDeclNode && d.isConst) {
        _globalConstNames.add(d.name);
      }
    }
    _globalBoundNames.addAll(boundAddrs.keys);
    _globalScope = _ScopeSnapshot(this);
  }

  /// Checks every function (see check_walk.dart) and then the initial
  /// values of the globals.
  void _checkProgramBody() {
    for (final f in _funcDecls) {
      if (f.body != null) _checkEndsWithReturn(f);
    }
    for (final f in _funcDecls) {
      if (!f.isInline && f.body != null) _checkFunc(f);
    }
    _checkGlobalData(_dataDecls);
  }

  /// Type information for [name], or [def] when it is unknown.
  TypeInfo typeOf(String? name, [TypeInfo def = const TypeInfo('u32', false)]) =>
      types[name] ?? def;

  /// Field layout of [member] in record [sName], or the default
  /// `(0, 'u32', false, null)` when either is unknown.
  FieldInfo fieldOf(String sName, String member) =>
      structs[sName]?.fields[member] ?? _defaultField;

  /// Size of record [sName], or 4 if it is unknown.
  int structSize(String sName) => structs[sName]?.size ?? 4;

  /// Strips legacy `struct ` / `type ` prefixes from a type name. Tuple
  /// types (lists) are cleaned element by element.
  Object cleanType(Object? t) {
    if (t == null) return '';
    if (t is List) {
      return [
        for (final item in t)
          if (item is TupleElemType)
            (cleanType(item.$1) as String, item.$2)
          else
            cleanType(item)
      ];
    }
    final s = t as String;
    if (s.isEmpty) return '';
    return s.replaceAll('struct ', '').replaceAll('type ', '').trim();
  }

  /// [cleanType] for a type known to be a plain name; tuple types become ''.
  String cleanName(Object? t) {
    final c = cleanType(t);
    return c is String ? c : '';
  }

  void _validateBackendType(Object tName, [String context = '']) {
    if (tName is List) {
      for (final sub in tName) {
        _validateBackendType((sub as TupleElemType).$1, context);
      }
      return;
    }
    final clean = cleanName(tName);
    if ((clean == 'f32' || clean == 'f64') && !target.supportsType(clean)) {
      final ctxStr = context.isNotEmpty ? ' in $context' : '';
      throw CompileError("floating-point type '$clean' is not supported by target backend "
          "'${target.name}' yet; it is available with the LLVM compiler$ctxStr");
    }
    if (clean == 'u64' || clean == 's64') {
      if (!target.supportsType(clean)) {
        final targetName = target.name;
        final ctxStr = context.isNotEmpty ? ' in $context' : '';
        throw CompileError(
            "64-bit integer type '$clean' is not supported by target backend '$targetName'$ctxStr");
      }
    }
  }

  (String?, int) _resolveMethod(String structName, String methodName) {
    final direct = '${structName}_$methodName';
    if (funcSignatures.containsKey(direct)) {
      return (direct, 0);
    }
    // A string's methods are the string functions: s.find(c) calls
    // stringFind(s, c)
    if (structName == 'string' && methodName.isNotEmpty) {
      final helper = 'string${methodName[0].toUpperCase()}${methodName.substring(1)}';
      if (funcSignatures.containsKey(helper)) return (helper, 0);
    }
    final sInfo = structs[structName];
    for (final (embedType, embedOffset) in sInfo?.embedded ?? <(String, int)>[]) {
      final (subFunc, subOff) = _resolveMethod(embedType, methodName);
      if (subFunc != null) {
        return (subFunc, embedOffset + subOff);
      }
    }
    return (null, 0);
  }

  /// Lays out every record type, resolving them in dependency order.
  void _layoutStructs(List<TypeDefNode> structDefs) {
    var remaining = List<TypeDefNode>.of(structDefs);
    final maxIters = remaining.length + 1;
    for (var iter = 0; iter < maxIters; iter++) {
      var progress = false;
      final nextRemaining = <TypeDefNode>[];
      for (final d in remaining) {
        var canResolve = true;
        try {
          for (final f in d.fields) {
            try {
              f.dim = _evalDims(f.dimExprs, "field '${f.name}' of type '${d.name}'");
            } on CompileError catch (e) {
              throw e.at(f.loc ?? d.loc);
            }
          }
        } on _LayoutDeferred {
          canResolve = false;
        }
        for (final f in d.fields) {
          if (!canResolve) break;
          final fType = cleanName(f.type);
          try {
            _validateBackendType(fType, "field '${f.name}' of type '${d.name}'");
          } on CompileError catch (e) {
            throw e.at(f.loc ?? d.loc);
          }
          if (f.isRefArray && fType != 'string' && !_declaredTypes.contains(fType)) {
            throw CompileError(
                    "field '${f.name}' of type '${d.name}': an array of references needs a user-defined type or 'string', not '$fType'")
                .at(f.loc);
          }
          if (f.isPtr && !f.isArrayRef && !_declaredTypes.contains(fType)) {
            throw CompileError(
                    "field '${f.name}' of type '${d.name}': 'ref' needs a user-defined type, not '$fType'")
                .at(f.loc);
          }
          if (!f.isPtr &&
              !f.isRefArray &&
              !fnTypes.containsKey(fType) &&
              !['u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'f32', 'f64', 'bool', 'string', 'void']
                  .contains(fType)) {
            if (!structs.containsKey(fType)) {
              canResolve = false;
              break;
            }
          }
        }
        if (canResolve) {
          // Each field is placed at a multiple of its alignment (from the
          // backend); the record aligns to its most-aligned field
          var offset = 0;
          var recordAlign = 1;
          int alignUp(int v, int a) => (v + a - 1) ~/ a * a;
          final fields = <String, FieldInfo>{};
          final embeddedList = <(String, int)>[];
          for (final f in d.fields) {
            final fType = cleanName(f.type);
            final fPtr = f.isPtr;
            final fName = f.name;
            final fDim = f.dim;
            if (f.isEmbedded) {
              final embedSz = structs[fType]!.size;
              final embedAlign = structs[fType]!.align;
              if (embedAlign > recordAlign) recordAlign = embedAlign;
              offset = alignUp(offset, embedAlign);
              final embedBaseOff = offset;
              embeddedList.add((fType, embedBaseOff));
              fields[fName] = FieldInfo(embedBaseOff, fType, false, null);
              for (final sub in structs[fType]!.fields.entries) {
                if (sub.key.startsWith('__')) continue;
                final sv = sub.value;
                fields.putIfAbsent(
                    sub.key,
                    () => FieldInfo(embedBaseOff + sv.offset, sv.type, sv.isPtr, sv.dim,
                        isArrayRef: sv.isArrayRef, refElems: sv.refElems));
              }
              offset += embedSz;
              continue;
            }
            int elemSz;
            if (fPtr || f.isRefArray) {
              elemSz = target.pointerSize;
            } else if (fType == 'u32' || fType == 's32') {
              elemSz = 4;
            } else if (fType == 'u64' || fType == 's64' || fType == 'f64') {
              elemSz = 8;
            } else if (fnTypes.containsKey(fType)) {
              elemSz = target.pointerSize;
            } else if (fType == 'u16' || fType == 's16') {
              elemSz = 2;
            } else if (structs.containsKey(fType)) {
              elemSz = structs[fType]!.size;
            } else if (['u8', 's8', 'bool', 'string'].contains(fType)) {
              elemSz = 1;
            } else {
              elemSz = 4;
            }
            int fSize;
            if (fDim is List<int>) {
              var totalElems = 1;
              for (final dm in fDim) {
                totalElems *= dm;
              }
              fSize = elemSz * totalElems;
            } else if (fDim is int) {
              fSize = elemSz * fDim;
            } else {
              fSize = elemSz;
            }
            final fAlign = structs.containsKey(fType) && !fPtr
                ? structs[fType]!.align
                : target.alignOf(elemSz);
            if (fAlign > recordAlign) recordAlign = fAlign;
            offset = alignUp(offset, fAlign);
            fields[fName] =
                FieldInfo(offset, fType, fPtr, fDim, isArrayRef: f.isArrayRef, refElems: f.isRefArray);
            offset += fSize;
          }
          structs[d.name] =
              StructInfo(fields, alignUp(offset, recordAlign), embeddedList, recordAlign);
          progress = true;
        } else {
          nextRemaining.add(d);
        }
      }
      remaining = nextRemaining;
      if (remaining.isEmpty || !progress) break;
    }

    if (remaining.isNotEmpty) {
      // A field of a type that is not declared, or types that contain
      // each other
      const builtin = ['u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'f32', 'f64', 'bool', 'string', 'void'];
      for (final d in remaining) {
        for (final f in d.fields) {
          final fType = cleanName(f.type);
          if (f.isPtr || builtin.contains(fType) || _declaredTypes.contains(fType)) continue;
          throw CompileError("type '${d.name}': '$fType' is not a declared type").at(f.loc ?? d.loc);
        }
      }
      final unresolved = remaining.map((d) => "'${d.name}'").join(', ');
      throw CompileError(
              'types $unresolved contain each other; a field that refers to another record must be a reference (ref)')
          .at(remaining.first.loc);
    }
  }

  /// Every prototype must be either defined in the Action sources or marked
  /// `asm` (a routine supplied by an .asm file), but not both. The coroutine
  /// operations of protokernel.act are generated by the compiler.
  void _checkPrototypes(List<FuncDeclNode> funcs) {
    final defined = {for (final f in funcs) if (f.body != null) f.name};
    final asmNames = {for (final f in funcs) if (f.isAsm || f.isExtern) f.name};
    for (final f in funcs) {
      if (f.body != null || f.isInline) continue;
      if (f.isExtern) {
        if (defined.contains(f.name)) {
          throw CompileError(
              "'${f.name}' is declared 'extern' (a C function) but is also defined in Action").at(f.loc);
        }
        continue;
      }
      if (f.isAsm) {
        if (defined.contains(f.name)) {
          throw CompileError(
              "'${_displayName(f)}' is declared 'asm' but is also defined in Action").at(f.loc);
        }
        continue;
      }
      if (_coroutineOps.containsKey(f.name)) continue;
      if (!defined.contains(f.name) && !asmNames.contains(f.name)) {
        throw CompileError(
            "'${_displayName(f)}' is declared but never defined; if it is written in assembly, declare it 'asm'").at(f.loc);
      }
    }
  }

  /// Declarations that only one kind of target has: `extern` C functions
  /// (LLVM), and assembly routines and trap handlers (Particle).
  void _checkTargetDecls(List<FuncDeclNode> funcs) {
    for (final f in funcs) {
      CompileError? err;
      if (f.isVariadic && !f.isExtern) {
        err = CompileError("'${f.name}': only a C function declared 'extern' can take '...'");
      } else if (f.isExtern && !target.isHosted) {
        err = CompileError(
            "'${f.name}' is declared 'extern', a C function; C functions need the LLVM compiler (action_llvm)");
      } else if (f.isAsm && target.isHosted) {
        err = CompileError(
            "'${_displayName(f)}' is declared 'asm', a routine in Particle assembly, which the LLVM compiler cannot use; declare a C function with 'extern' instead");
      } else if (f.trapExpr != null && target.isHosted) {
        err = CompileError(
            "'${f.name}' is a trap handler; trap handlers are Particle hardware, which the LLVM compiler does not have");
      }
      if (err != null) throw err.at(f.loc);
      for (final p in f.params) {
        if (p.isRefArray) _checkRefArrayElem(p.name, p.type, p.loc ?? f.loc);
      }
      if (f.name == 'main' && f.body != null) _checkMainSignature(f);
      if (f.isExtern && f.params.any((p) => p.isOpenArr)) {
        final p = f.params.firstWhere((p) => p.isOpenArr);
        throw CompileError(
                "'${f.name}': parameter '${p.name}' is an open array, which a C function cannot take")
            .at(p.loc ?? f.loc);
      }
    }
  }

  /// The elements of an array of references are references to a
  /// user-defined type or to strings.
  void _checkRefArrayElem(String name, Object type, String? loc) {
    final t = cleanName(type);
    if (t == 'string' || _declaredTypes.contains(t)) return;
    throw CompileError(
            "'$name': an array of references needs a user-defined type or 'string', not '$t'")
        .at(loc);
  }

  /// `main` takes nothing, or the command line: `ref string args[]`.
  void _checkMainSignature(FuncDeclNode f) {
    final ps = f.params;
    final ok = ps.isEmpty ||
        (ps.length == 1 && ps[0].isRefArray && ps[0].isOpenArr && cleanName(ps[0].type) == 'string');
    if (!ok) {
      throw CompileError(
              "'main' takes no parameters, or the command line as 'ref string args[]'")
          .at(f.loc);
    }
  }

  /// A function's name as written in the source (`Type.method` for methods).
  String _displayName(FuncDeclNode f) {
    if (f.params.isNotEmpty && f.params.first.name == 'this') {
      final t = '${f.params.first.type}';
      if (f.name.startsWith('${t}_')) {
        return '$t.${f.name.substring(t.length + 1)}';
      }
    }
    return f.name;
  }

  /// Checks the trap handlers (`trap(N) name() { ... }`) in [funcs] and returns the handler's
  /// name for each bound trap number.
  Map<int, String> _collectTrapHandlers(List<FuncDeclNode> funcs) {
    final handlers = <int, String>{};
    for (final f in funcs) {
      final e = f.trapExpr;
      if (e == null) continue;
      int n;
      try {
        n = _evalConstExpr(e);
      } on NotConstantError {
        throw CompileError("'${f.name}': the trap number must be a constant").at(f.loc);
      }
      if (n < 0 || n >= target.vectorCount) {
        throw CompileError(
            "'${f.name}': trap $n is out of range (0-${target.vectorCount - 1})").at(f.loc);
      }
      if (n == 0) {
        throw CompileError(
            "'${f.name}': binding trap 0 (reset) is not supported yet; vector 0 runs the startup code").at(f.loc);
      }
      final other = handlers[n];
      if (other != null) {
        throw CompileError("trap $n is bound to both '$other' and '${f.name}'").at(f.loc);
      }
      handlers[n] = f.name;
      _trapHandlerNames.add(f.name);
    }
    return handlers;
  }

  /// True when local [d]'s declaration clears its storage first: it is in
  /// an inner block (whose words another block may have used, or an earlier
  /// pass of a loop) and its value does not set all of it.
  bool _declClearsFirst(VarDeclNode d) {
    if (!d.nested) return false;
    if (d.initExpr == null) return true;
    if (d.isPtr) return false;
    if (d.dimExprs.isNotEmpty || d.typeName == 'string') return true;
    return structs.containsKey(cleanName(d.typeName)) && !(types[d.name]?.isRef ?? false);
  }

  // ------------------------------------------------------- missing return

  /// A function that returns a value must not run off the end of its body
  /// (Go's rule): its last statement must be a terminating one.
  void _checkEndsWithReturn(FuncDeclNode f) {
    if (f.isTask) return;
    final ret = cleanType(f.retType);
    if (ret is String && ret == 'void') return;
    if (_terminates(f.body!)) return;
    throw CompileError("missing return at the end of ${_shownFunc(f.name)}: a function that "
            'returns a value must end with a return, or with an if/else, a switch with a default, '
            'or an endless while loop whose every path returns (or with inline assembly that '
            'leaves the result in R1)')
        .at(f.body!.endLoc ?? f.loc);
  }

  /// How messages name function [name]: `'f'`, or for one made from a
  /// lambda, `lambda 'cmp'` or `lambda at main.act:12:9`.
  String _shownFunc(String name) {
    for (final f in _funcDecls) {
      if (f.name == name) return f.lambdaShown ?? "'${_displayFuncName(f)}'";
    }
    return "'$name'";
  }

  String _displayFuncName(FuncDeclNode f) {
    if (f.params.isNotEmpty && f.params.first.name == 'this') {
      final t = cleanName(f.params.first.type);
      if (f.name.startsWith('${t}_')) return '$t.${f.name.substring(t.length + 1)}';
    }
    return f.name;
  }

  /// True when control cannot run past the end of [s]: a return, `trap(0)`
  /// (reset), inline assembly (which sets the result), a block ending in one, an if/else whose branches both end in
  /// one, a switch with a default whose every case ends in one, or a while
  /// loop with a constant true condition that no break leaves.
  bool _terminates(AstNode? s) {
    if (s == null) return false;
    if (s is ReturnNode || s is TupleReturnNode) return true;
    // Inline assembly at the end leaves the result in R1 itself
    if (s is AsmNode) return true;
    if (s is TrapNode) return s.trapNum == 0;
    if (s is ExprStmtNode) return _terminates(s.expr);
    if (s is CallNode) {
      if (s.name != 'trap' || s.args.length != 1 || funcSignatures.containsKey('trap')) return false;
      final c = _tryConst(s.args[0]);
      return c != null && c.value == BigInt.zero;
    }
    if (s is BlockNode) {
      final stmts = s.stmts.where((x) => !(x is BlockNode && x.stmts.isEmpty)).toList();
      return stmts.isNotEmpty && _terminates(stmts.last);
    }
    if (s is IfNode) {
      return s.elseBody != null && _terminates(s.thenBody) && _terminates(s.elseBody);
    }
    if (s is WhileNode) {
      final c = _tryConst(s.cond);
      return c != null && c.value != BigInt.zero && !_hasBreak(s.body, inLoop: false);
    }
    if (s is SwitchNode) {
      final body = s.body;
      if (body is! BlockNode) return false;
      var hasDefault = false;
      final cases = <List<AstNode>>[];
      var afterLabel = false;
      for (final x in body.stmts) {
        if (x is CaseLabelNode || x is DefaultLabelNode) {
          if (x is DefaultLabelNode) hasDefault = true;
          if (!afterLabel) cases.add([]);
          afterLabel = true;
          continue;
        }
        afterLabel = false;
        if (cases.isEmpty) cases.add([]);
        cases.last.add(x);
      }
      if (!hasDefault || cases.isEmpty) return false;
      for (var i = 0; i < cases.length; i++) {
        final c = cases[i];
        if (c.any((x) => _hasBreak(x, inLoop: false))) return false;
        final last = c.isEmpty ? null : c.last;
        // continue falls through into the next case
        if (last is ContinueNode && i + 1 < cases.length) continue;
        if (!_terminates(BlockNode(c))) return false;
      }
      return true;
    }
    return false;
  }

  /// True when [s] has a `break` that leaves the loop or switch around it
  /// (not one inside a nested loop or switch).
  bool _hasBreak(AstNode? s, {required bool inLoop}) {
    if (s == null) return false;
    if (s is BreakNode) return !inLoop;
    if (s is BlockNode) return s.stmts.any((x) => _hasBreak(x, inLoop: inLoop));
    if (s is IfNode) {
      return _hasBreak(s.thenBody, inLoop: inLoop) || _hasBreak(s.elseBody, inLoop: inLoop);
    }
    if (s is WhileNode || s is ForRangeNode || s is SwitchNode) return false;
    return false;
  }

  void _collectLocalDecls(AstNode? node, List<VarDeclNode> decls) {
    if (node == null) return;
    if (node is BlockNode) {
      for (final s in node.stmts) {
        _collectLocalDecls(s, decls);
      }
    } else if (node is IfNode) {
      _collectLocalDecls(node.thenBody, decls);
      if (node.elseBody != null) {
        _collectLocalDecls(node.elseBody, decls);
      }
    } else if (node is WhileNode) {
      _collectLocalDecls(node.body, decls);
    } else if (node is ForRangeNode) {
      decls.add(node.loopVar);
      decls.add(node.loopEnd);
      _collectLocalDecls(node.body, decls);
    } else if (node is SwitchNode) {
      _collectLocalDecls(node.body, decls);
    } else if (node is VarDeclNode) {
      if (!node.isConst && node.boundAddrExpr == null) {
        decls.add(node);
      }
    } else if (node is TupleAssignNode) {
      decls.addAll(node.targetDecls);
    }
  }

  void _collectCoroutineSteps(AstNode node, List<(int, AstNode)> steps) {
    if (node is YieldNode) {
      steps.add((node.stepConst, node.taskRef));
    } else if (node is WaitUntilNode) {
      steps.add((node.stepConst, node.taskRef));
    } else if (node is BlockNode) {
      for (final s in node.stmts) {
        _collectCoroutineSteps(s, steps);
      }
    } else if (node is IfNode) {
      _collectCoroutineSteps(node.thenBody, steps);
      if (node.elseBody != null) {
        _collectCoroutineSteps(node.elseBody!, steps);
      }
    } else if (node is WhileNode) {
      _collectCoroutineSteps(node.body, steps);
    } else if (node is ForRangeNode) {
      _collectCoroutineSteps(node.body, steps);
    } else if (node is SwitchNode) {
      _collectCoroutineSteps(node.body, steps);
    }
  }

  /// Evaluates the array dimensions and `@` address of [d].
  void _resolveVarDecl(VarDeclNode d) {
    if (d.dimExprs.isNotEmpty && d.arrayDims == null) {
      final dims = [
        for (final e in d.dimExprs) _evalConstIn(e, "array dimension of '${d.name}'")
      ];
      d.arrayDims = dims;
      d.arrayDim = dims[0];
    }
    if (d.boundAddrExpr != null && d.boundAddr == null) {
      d.boundAddr = _evalConstIn(d.boundAddrExpr!, "address of '${d.name}'");
    }
  }

  /// Evaluates field dimensions: `null`, one int, or a list of ints.
  Object? _evalDims(List<AstNode> exprs, String what) {
    if (exprs.isEmpty) return null;
    final dims = [for (final e in exprs) _evalConstIn(e, 'array dimension of $what')];
    return dims.length > 1 ? dims : dims[0];
  }

  /// Evaluates [e] as a constant, naming [what] in the error if it is not.
  int _evalConstIn(AstNode e, String what) {
    try {
      return _evalConstExpr(e);
    } on NotConstantError catch (err) {
      throw CompileError('The $what must be a constant expression: ${err.message}');
    }
  }

  /// Value of a global scalar's initializer, which must be constant.
  int _globalInitValue(VarDeclNode d) {
    _checkConstFits(d.initExpr, cleanName(d.typeName), d.isPtr, "global variable '${d.name}'");
    try {
      return _evalConstExpr(d.initExpr);
    } on NotConstantError catch (err) {
      throw CompileError(
          "The initializer of global variable '${d.name}' must be a constant expression: ${err.message}");
    }
  }

  /// Value of the named constant (as a 32-bit pattern), evaluating it now
  /// if it is still pending.
  int? _constValue(String name) {
    final c = _constInfo(name);
    return c == null ? null : constants[name];
  }

  /// For a call through a function value: the expression giving the
  /// function, its function type and the arguments. That is `t[i](x)` and
  /// `f()(x)`, and `r.f(x)` when `f` is a field of function type (not a
  /// method). Null for any other call.
  (AstNode, String, List<AstNode>)? _callValue(CallNode call) {
    if (call.name == callValueName) {
      final callee = call.args[0];
      return (callee, cleanName(_getExprType(callee).$1), call.args.sublist(1));
    }
    if (call.name.startsWith('__METHOD__')) {
      final m = call.name.substring(10);
      final Object rcvT;
      try {
        rcvT = _getExprType(call.args[0]).$1;
      } on CompileError {
        return null;
      }
      final t = cleanName(rcvT);
      if (_resolveMethod(t, m).$1 != null) return null;
      final f = structs[t]?.fields[m];
      if (f == null || f.isPtr || f.dim != null || !fnTypes.containsKey(cleanName(f.type))) {
        return null;
      }
      return (
        MemberAccessNode(call.args[0], m)..loc = call.loc,
        cleanName(f.type),
        call.args.sublist(1)
      );
    }
    return null;
  }

  /// The dimensions of a fixed array variable or field [e] (for a string,
  /// with its capacity last), or null.
  List<int>? _fixedDimsOf(AstNode e) {
    if (e is VarAccessNode) {
      final d = arrayDims[e.name];
      if (d != null && d.isNotEmpty) return d;
      final n = arrayLens[e.name];
      return n != null ? [n] : null;
    }
    if (e is MemberAccessNode) {
      final FieldInfo f;
      try {
        f = fieldOf(cleanName(_getExprType(e.expr).$1), e.member);
      } on CompileError {
        return null;
      }
      if (f.isArrayRef || f.isPtr) return null;
      final d = f.dim;
      return d is List<int> ? d : (d is int ? [d] : null);
    }
    return null;
  }

  /// True when [call] is one of the memory built-ins (see [_memoryBuiltins]).
  bool _isMemoryBuiltin(CallNode call) =>
      _memoryBuiltins.containsKey(call.name) && !funcSignatures.containsKey(call.name);

  /// Gives local [d] its type (a record reference when [funcRefs], the
  /// function's reference variables, holds it) and array dimensions, and
  /// returns its size in bytes.
  int _declareLocal(Set<String> funcRefs, VarDeclNode d) {
    _resolveVarDecl(d);
    final cleanT = cleanName(d.typeName);
    final isRecordRef = funcRefs.contains(d.name) &&
        structs.containsKey(cleanT) &&
        (d.arrayDims == null || d.arrayDims!.isEmpty);
    types[d.name] = TypeInfo(d.typeName, d.isPtr, isRecordRef, d.isRefArray);
    // T x[]: a heap array, however it gets its value (createArray, another
    // heap array, or a function's result)
    if (d.isPtr && (d.isRefArray || (cleanT != 'string' && !structs.containsKey(cleanT)))) {
      dynamicArrays.add(d.name);
    }
    var elemSize = 4;
    if (d.isRefArray) {
      // An array of references: one address per element
      elemSize = target.pointerSize;
    } else if (['u8', 's8', 'bool', 'string'].contains(d.typeName)) {
      elemSize = 1;
    } else if (['u16', 's16'].contains(d.typeName)) {
      elemSize = 2;
    } else if (['u64', 's64', 'f64'].contains(d.typeName)) {
      elemSize = 8;
    } else if (isRecordRef || d.isPtr || d.isRefArray || fnTypes.containsKey(cleanT)) {
      // A reference (record, heap array or string) or function holds one
      // address
      elemSize = target.pointerSize;
    } else if (structs.containsKey(cleanT)) {
      elemSize = structs[cleanT]!.size;
    }

    var dims = d.arrayDims;
    if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
      dims = [d.arrayDim!];
    }
    if (dims != null && dims.isNotEmpty) {
      arrayDims[d.name] = dims;
      arrayLens[d.name] = dims[0];
      var totalElems = 1;
      for (final dm in dims) {
        totalElems *= dm;
      }
      return elemSize * totalElems;
    }
    return elemSize;
  }

}
