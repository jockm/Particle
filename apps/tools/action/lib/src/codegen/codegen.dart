// ------------------------------------------------------------------------------
// Code Generator (Frontend & AST Lowering)
// ------------------------------------------------------------------------------
//
// Port of the CodeGen class of act16c.py. The class is split over several
// `part` files to keep each one readable:
//
//   codegen.dart      state, program layout, functions (this file)
//   types.dart        expression typing, sizes, constant evaluation
//   statements.dart   statement lowering and conditional branches
//   expressions.dart  expression lowering, addressing, calls, loads/stores
//   references.dart   record references versus records stored in place

import '../ast.dart';
import '../backend/backend.dart';
import '../backend/particle.dart';
import '../errors.dart';

part 'types.dart';
part 'statements.dart';
part 'expressions.dart';
part 'references.dart';
part 'coroutines.dart';
part 'flow.dart';
part 'constants.dart';
part 'ownership.dart';

/// Type information recorded for a variable or parameter:
/// `(type name, is pointer, is reference)`.
class TypeInfo {
  /// Usually a type name; for tuple-typed declarations a list of
  /// [TupleElemType].
  final Object name;
  final bool isPtr;
  final bool isRef;
  const TypeInfo(this.name, this.isPtr, [this.isRef = false]);
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
  const FieldInfo(this.offset, this.type, this.isPtr, this.dim, {this.isArrayRef = false});
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
  const ParamSig(this.type, this.isPtr, this.isOpen);
}

/// Function signature: return type (a name or a tuple list), whether it
/// returns a pointer, and the parameter signatures.
class FuncSig {
  final Object retType;
  final bool retPtr;
  final List<ParamSig> params;
  const FuncSig(this.retType, this.retPtr, this.params);
}

const _defaultField = FieldInfo(0, 'u32', false, null);

/// A loop or `switch` enclosing the statement being generated.
class _FlowContext {
  /// Loop: label of the next iteration. Null for a switch. A `for` loop
  /// creates its step label only when a `continue` needs it, see
  /// [lazyContinue].
  String? continueLabel;

  /// For a `for` loop: makes the step label on first use.
  final String Function()? lazyContinue;

  final bool isSwitch;

  /// Loop: true when [continueLabel] is above the body (while loops).
  final bool continueBackward;

  /// Switch: its case/default labels in source order, and its end label.
  final List<String> caseLabels;
  final String? endLabel;

  /// Switch: index in [caseLabels] of the case being generated (-1 before
  /// the first label).
  int currentCase = -1;

  _FlowContext.loop(String this.continueLabel)
      : caseLabels = const [],
        endLabel = null,
        lazyContinue = null,
        isSwitch = false,
        continueBackward = true;
  _FlowContext.lazyLoop(String Function() this.lazyContinue)
      : caseLabels = const [],
        endLabel = null,
        isSwitch = false,
        continueBackward = false;
  _FlowContext.switchBlock(this.caseLabels, String this.endLabel)
      : continueLabel = null,
        lazyContinue = null,
        isSwitch = true,
        continueBackward = false;

  /// The next-iteration label, creating it if this loop defers it.
  String get loopTarget => continueLabel ??= lazyContinue!();
}

/// Thrown while laying out record types when a constant needs the size of a
/// type that has not been laid out yet; the type is retried on the next pass.
class _LayoutDeferred implements Exception {}
const _signedTypes = ['s8', 's16', 's32'];

class CodeGen {
  final bool boundsCheck;

  /// Run-time null checks on references held in globals, and on allocation.
  final bool referenceCheck;
  final Backend backend;

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
  int stackOffset = 0;
  String currentFuncName = '';
  (Object?, bool) currentFuncRet = (null, false);
  final List<(String, String)> strings = [];
  final List<String> breakStack = [];

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

  /// Innermost-last stack of loops and switches, for `continue`.
  final List<_FlowContext> flowStack = [];
  final Map<String, int> constants = {};

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

  CodeGen(
      {this.boundsCheck = true,
      this.referenceCheck = true,
      Backend? backend,
      Map<String, int> predefinedConstants = const {}})
      : backend = backend ?? ParticleAsmBackend(),
        predefinedConstants = Map.of(predefinedConstants) {
    this.backend.referenceCheck = referenceCheck;
  }

  List<String> get asm => backend.asm;

  void emit(String line, [String comment = '']) => backend.emit(line, comment);

  void emitLabel(String label) => backend.emitLabel(label);

  String newLabel([String prefix = 'L']) => backend.newLabel(prefix);

  void emitImmediate(int reg, int val) => backend.emitImmediate(reg, val);

  /// [emitImmediate] for use while R14 holds a live value.
  void emitImmediateKeepR14(int reg, int val) =>
      backend.emitImmediateKeepR14(reg, val);

  /// Type information for [name], or [def] when it is unknown.
  TypeInfo typeOf(String? name, [TypeInfo def = const TypeInfo('u32', false)]) =>
      types[name] ?? def;

  /// Field layout of [member] in record [sName], or the default
  /// `(0, 'u32', false, null)` when either is unknown.
  FieldInfo fieldOf(String sName, String member) =>
      structs[sName]?.fields[member] ?? _defaultField;

  /// Size of record [sName], or 4 if it is unknown.
  int structSize(String sName) => structs[sName]?.size ?? 4;

  void _emitStringInit(String name, AstNode initExpr, int? capacity) {
    if (initExpr is! StringLitNode) {
      throw CompileError(
          "String variable '$name' must be initialized with a string literal");
    }
    final rawStr = initExpr.val;
    if (capacity == null) {
      throw CompileError(
          "'>' not supported between instances of 'int' and 'NoneType'");
    }
    if (rawStr.length > capacity) {
      throw CompileError(
          'String literal length (${rawStr.length}) exceeds capacity ($capacity) of string $name[$capacity]');
    }
    stringLens[name] = rawStr.length;
    final lbl = newLabel('str');
    strings.add((lbl, rawStr));

    emit('LOAD32  R13, $lbl', 'Load address of string literal ${pyRepr(rawStr)}');
    final offset = stackOffset - locals[name]!;
    if (offset > 0) {
      emitImmediate(14, offset);
      emit('ADD     R14, R15', "Base address of local string '$name'");
    } else {
      emit('LD      R14, R15', "Base address of local string '$name'");
    }
    final lblLoop = newLabel('str_cpy');
    final lblDone = newLabel('str_done');

    emitLabel(lblLoop);
    emit('LD8     R12, (R13)', 'Fetch literal byte');
    emit('FBRA.Z  R12, $lblDone', 'End of literal reached');
    emit('LD8     (R14), R12', 'Store byte into string buffer');
    emit('ADD     R13, 1', 'literal_ptr++');
    emit('ADD     R14, 1', 'buffer_ptr++');
    emit('BBRA    $lblLoop', 'Copy next byte');
    emitLabel(lblDone);
    emit('LD8     (R14), R12', 'Store null terminator');
  }

  void _emitStringScanLen(String? arrName, int targetReg) {
    if (boundAddrs.containsKey(arrName)) {
      emitImmediate(14, boundAddrs[arrName]!);
    } else if (locals.containsKey(arrName)) {
      final offset = stackOffset - locals[arrName]!;
      if (offset > 0) {
        emitImmediate(14, offset);
        emit('ADD     R14, R15');
      } else {
        emit('LD      R14, R15');
      }
      final tInfo = typeOf(arrName);
      final isLocalFixed =
          arrayDims.containsKey(arrName) || arrayLens.containsKey(arrName);
      if (tInfo.isRef || tInfo.isPtr || !isLocalFixed) {
        emit('LD32    R14, (R14)', "Dereference param/ptr string '$arrName'");
      }
    } else if (globals.contains(arrName)) {
      emit('LOAD32  R14, _$arrName');
    } else {
      emitImmediate(targetReg, 0);
      return;
    }

    _emitStringScanAt14(arrName, targetReg);
  }

  /// `.len` of the string whose address is in R14: counts bytes up to the
  /// terminator into [targetReg].
  void _emitStringScanAt14(String? arrName, int targetReg) {
    final lblScan = newLabel('str_scan');
    final lblDone = newLabel('str_scan_done');

    emit('LD      R$targetReg, 0', "Init .len scan counter for '${arrName ?? 'string'}'");
    emitLabel(lblScan);
    emit('LD8     R13, (R14)', 'Load byte from string buffer');
    emit('FBRA.Z  R13, $lblDone', 'Null terminator reached');
    emit('ADD     R$targetReg, 1', 'len++');
    emit('ADD     R14, 1', 'ptr++');
    emit('BBRA    $lblScan', 'Check next byte');
    emitLabel(lblDone);
  }


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
    if (clean == 'u64' || clean == 's64') {
      if (!backend.supportsType(clean)) {
        final targetName = backend.name;
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
    final sInfo = structs[structName];
    for (final (embedType, embedOffset) in sInfo?.embedded ?? <(String, int)>[]) {
      final (subFunc, subOff) = _resolveMethod(embedType, methodName);
      if (subFunc != null) {
        return (subFunc, embedOffset + subOff);
      }
    }
    return (null, 0);
  }

  String _escapeAsmString(String s) {
    final out = StringBuffer();
    for (final code in s.runes) {
      final ch = String.fromCharCode(code);
      if (ch == '\\') {
        out.write('\\\\');
      } else if (ch == '"') {
        out.write('\\"');
      } else if (ch == '\n') {
        out.write('\\n');
      } else if (ch == '\r') {
        out.write('\\r');
      } else if (ch == '\t') {
        out.write('\\t');
      } else if (code == 0) {
        out.write('\\0');
      } else if (32 <= code && code <= 126) {
        out.write(ch);
      } else {
        out.write('\\x${code.toRadixString(16).padLeft(2, '0')}');
      }
    }
    return out.toString();
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
            f.dim = _evalDims(f.dimExprs, "field '${f.name}' of type '${d.name}'");
          }
        } on _LayoutDeferred {
          canResolve = false;
        }
        for (final f in d.fields) {
          if (!canResolve) break;
          final fType = cleanName(f.type);
          _validateBackendType(fType, "field '${f.name}' of type '${d.name}'");
          if (f.isPtr && !f.isArrayRef && !_declaredTypes.contains(fType)) {
            throw CompileError(
                    "field '${f.name}' of type '${d.name}': 'ref' needs a user-defined type, not '$fType'")
                .at(f.loc);
          }
          if (!f.isPtr &&
              !['u8', 's8', 'u16', 's16', 'u32', 's32', 'bool', 'string', 'void']
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
                        isArrayRef: sv.isArrayRef));
              }
              offset += embedSz;
              continue;
            }
            int elemSz;
            if (fPtr) {
              elemSz = backend.pointerSize;
            } else if (fType == 'u32' || fType == 's32') {
              elemSz = 4;
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
                : backend.alignOf(elemSz);
            if (fAlign > recordAlign) recordAlign = fAlign;
            offset = alignUp(offset, fAlign);
            fields[fName] = FieldInfo(offset, fType, fPtr, fDim, isArrayRef: f.isArrayRef);
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
      final unresolved = remaining.map((d) => d.name).join(', ');
      throw CompileError(
          'Circular dependency or unknown type in struct/type definition: $unresolved');
    }
  }

  /// Every prototype must be either defined in the Action sources or marked
  /// `asm` (a routine supplied by an .asm file), but not both. The coroutine
  /// operations of protokernel.act are generated by the compiler.
  void _checkPrototypes(List<FuncDeclNode> funcs) {
    final defined = {for (final f in funcs) if (f.body != null) f.name};
    final asmNames = {for (final f in funcs) if (f.isAsm) f.name};
    for (final f in funcs) {
      if (f.body != null || f.isInline) continue;
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
      if (n < 0 || n >= backend.vectorCount) {
        throw CompileError(
            "'${f.name}': trap $n is out of range (0-${backend.vectorCount - 1})").at(f.loc);
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

  /// Generates the complete assembly program for [root].
  String generate(ProgramNode root) {
    asm.add(
        '; ==============================================================================');
    asm.add('; Compiled from Action source by action');
    asm.add('; Target Architecture: Particle 32-bit RISC');
    asm.add(
        '; ==============================================================================\n');
    asm.add('.include "lib/common.inc"\n');

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

    final typeDefs = root.decls.whereType<TypeDefNode>().toList();
    _declaredTypes.addAll(typeDefs.map((t) => t.name));
    _layoutStructs(typeDefs);

    for (final d in root.decls) {
      try {
        if (d is FnTypeNode) {
          fnTypes[d.name] = (d.paramTypes, d.retType);
        }
      } on CompileError catch (e) {
        throw e.at(d.loc);
      }
    }
    final dataDecls = root.decls.whereType<VarDeclNode>().toList();
    final rawFuncDecls = root.decls.whereType<FuncDeclNode>().toList();
    for (final f in rawFuncDecls) {
      _validateBackendType(f.retType, "return type of function '${f.name}'");
      for (final p in f.params) {
        _validateBackendType(p.type, "parameter '${p.name}' of function '${f.name}'");
      }
      funcSignatures[f.name] = FuncSig(
          cleanType(f.retType),
          f.retPtr,
          [
            for (final p in f.params)
              ParamSig(cleanName(p.type), p.isPtr, p.isOpenArr)
          ]);
    }
    final hasMain = rawFuncDecls.any((f) => f.name == 'main');
    final funcDecls = rawFuncDecls;

    final trapHandlers = _collectTrapHandlers(funcDecls);
    if (hasMain) {
      asm.add(
          '; ------------------------------------------------------------------------------');
      asm.add('; Direct Stride Vector Table & Startup Code (Auto-generated)');
      asm.add(
          '; ------------------------------------------------------------------------------');
      asm.add('.org 0x${backend.vectorBase.toRadixString(16).toUpperCase().padLeft(8, '0')}');
      emitLabel('_vector_reset');
      emit('LOAD32  R15, 0x00010000', 'Initialize stack pointer SP');
      emit('LOAD32  R14, _main', 'Load main entry address');
      emit('JMP     R14, R0', 'Jump to _main (discard link)');
      emit('.align  ${backend.vectorStride}');
      asm.add('');
      // Every other vector has the same shape, so no trap lands in code:
      // swap to the shadow registers, call the bound handler if there is
      // one, swap back and return
      for (var v = 1; v < backend.vectorCount; v++) {
        emitLabel(v == 1 ? '_vector_mbox' : '_vector_$v');
        emit('FAST_ENTER_TRAP');
        final handler = trapHandlers[v];
        if (handler != null) {
          emit('RCALL   _$handler', 'Trap $v handler');
        }
        emit('FAST_EXIT_TRAP');
        emit('.align  ${backend.vectorStride}');
        asm.add('');
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

    // Register global types and dims
    for (final d in dataDecls) {
      try {
        if (d.isConst) continue;
        _resolveVarDecl(d);
        _validateBackendType(d.typeName, "global variable '${d.name}'");
        if (d.isVolatile || d.boundAddr != null) {
          volatiles.add(d.name);
        }
        types[d.name] = TypeInfo(d.typeName, d.isPtr, false);
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

    for (final f in funcDecls) {
      if (f.isInline) {
        inlineFuncs[f.name] = f;
        continue;
      }
      if (f.body != null) {
        genFunc(f);
      }
    }

    // Emit global variable data section AFTER all code
    final emitGlobals =
        dataDecls.where((d) => !d.isConst && d.boundAddr == null).toList();
    if (emitGlobals.isNotEmpty) {
      asm.add(
          '; ------------------------------------------------------------------------------');
      asm.add('; Global Variable Allocation');
      asm.add(
          '; ------------------------------------------------------------------------------');
      emit('.align  4');
      for (final d in emitGlobals) {
        try {
          var dims = d.arrayDims;
          if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
            dims = [d.arrayDim!];
          }
          emitLabel('_${d.name}');
          if (dims != null && dims.isNotEmpty) {
            if (d.initExpr != null) {
              throw CompileError(
                  "Global array '${d.name}' cannot have an initializer; global arrays start zero-filled");
            }
            final gT = cleanName(d.typeName);
            final elemSz = ['u8', 's8', 'bool', 'string'].contains(gT)
                ? 1
                : (['u16', 's16'].contains(gT)
                    ? 2
                    : (structs.containsKey(gT) && !d.isPtr ? structs[gT]!.size : 4));
            var totalElems = 1;
            for (final dm in dims) {
              totalElems *= dm;
            }
            final totalWords = (elemSz * totalElems + 3) ~/ 4;
            for (var i = 0; i < totalWords; i++) {
              emit('.word   0');
            }
          } else {
            final init = d.initExpr;
            final cleanT = cleanName(d.typeName);
            if (structs.containsKey(cleanT) && !d.isPtr && !_globalRefs.contains(d.name)) {
              // A record stored in place: reserve the whole record
              if (init != null) {
                throw CompileError(
                    "global '${d.name}' of type '$cleanT' cannot have an initializer unless it is a reference");
              }
              final words = (structs[cleanT]!.size + 3) ~/ 4;
              for (var i = 0; i < words; i++) {
                emit('.word   0');
              }
              continue;
            }
            if (init is IntLitNode) {
              _checkConstFits(init, cleanT, d.isPtr, "global variable '${d.name}'");
              emit('.word   ${init.val}');
            } else if (init != null) {
              emit('.word   ${_globalInitValue(d)}');
            } else {
              emit('.word   0');
            }
          }
        } on CompileError catch (e) {
          throw e.at(d.loc);
        }
      }
      asm.add('');
    }

    if (strings.isNotEmpty) {
      asm.add(
          '; ------------------------------------------------------------------------------');
      asm.add('; String Literal Table');
      asm.add(
          '; ------------------------------------------------------------------------------');
      for (final (lbl, s) in strings) {
        final escaped = _escapeAsmString(s);
        emitLabel(lbl);
        emit('.asciz  "$escaped"');
      }
      asm.add('');
    }

    asm.add(
        '; ------------------------------------------------------------------------------');
    asm.add('; Runtime Memory Allocator');
    asm.add(
        '; ------------------------------------------------------------------------------');
    asm.add('.include "lib/alloc.asm"\n');
    return asm.join('\n');
  }

  /// Gives parameter slot [slot] a home in the frame. Slots 1..4 arrive in
  /// R1..R4 and are spilled; slot 5 and up are already in the caller's
  /// stack-argument area, just above the saved return address, slot 5 at
  /// the lowest address. Their locals positions are therefore 0, -4, ...
  void _bindParamSlot(int slot, String name, String comment) {
    if (slot <= 4) {
      emit('PUSH32  R$slot', comment);
      stackOffset += 4;
      locals[name] = stackOffset;
    } else {
      locals[name] = -(slot - 5) * 4;
    }
  }

  /// Lays out [localDecls] (the locals of function [funcName]) in a frame
  /// below the current stack position, allocates it and zero-fills it.
  /// Used for functions and for each inline expansion. Returns the frame
  /// size in bytes.
  int _allocateLocalFrame(String funcName, List<VarDeclNode> localDecls) {
    final funcRefs = _functionRefs[funcName] ?? const <String>{};
    var totalFrameWords = 0;
    for (final d in localDecls) {
      _resolveVarDecl(d);
      final cleanT = cleanName(d.typeName);
      final isRecordRef = funcRefs.contains(d.name) &&
          structs.containsKey(cleanT) &&
          (d.arrayDims == null || d.arrayDims!.isEmpty);
      types[d.name] = TypeInfo(d.typeName, d.isPtr, isRecordRef);
      var elemSize = 4;
      if (['u8', 's8', 'bool', 'string'].contains(d.typeName)) {
        elemSize = 1;
      } else if (['u16', 's16'].contains(d.typeName)) {
        elemSize = 2;
      } else if (isRecordRef) {
        // A record reference holds one address
        elemSize = backend.pointerSize;
      } else if (!d.isPtr && structs.containsKey(cleanT)) {
        elemSize = structs[cleanT]!.size;
      }

      var dims = d.arrayDims;
      if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
        dims = [d.arrayDim!];
      }
      int varSize;
      if (dims != null && dims.isNotEmpty) {
        arrayDims[d.name] = dims;
        arrayLens[d.name] = dims[0];
        var totalElems = 1;
        for (final dm in dims) {
          totalElems *= dm;
        }
        varSize = elemSize * totalElems;
      } else {
        varSize = elemSize;
      }

      final words = (varSize + 3) ~/ 4;
      stackOffset += words * 4;
      locals[d.name] = stackOffset;
      totalFrameWords += words;
    }

    if (totalFrameWords > 0) {
      final frameBytes = totalFrameWords * 4;
      emitImmediate(14, frameBytes);
      emit('SUB     R15, R14', 'Allocate local stack frame ($frameBytes bytes)');
      // Efficient zero-initialization of local frame
      if (totalFrameWords <= 4) {
        for (var wIdx = 0; wIdx < totalFrameWords; wIdx++) {
          final off = wIdx * 4;
          if (off == 0) {
            emit('ST32    (R15), R0', 'Zero-init local frame word');
          } else {
            emitImmediate(14, off);
            emit('ADD     R14, R15');
            emit('ST32    (R14), R0', 'Zero-init local frame word');
          }
        }
      } else {
        final lblClrLoop = newLabel('frame_clr');
        newLabel('frame_clr_done');
        emitImmediate(13, totalFrameWords);
        emit('LD      R14, R15', 'Base of local frame for zero-init');
        emitLabel(lblClrLoop);
        emit('ST32    (R14), R0', 'Clear frame word');
        emit('ADD     R14, 4');
        emit('SUB     R13, 1');
        emit('BBRA.NZ R13, $lblClrLoop');
      }
    }
    return totalFrameWords * 4;
  }

  void genFunc(FuncDeclNode func) {
    try {
      _genFunc(func);
    } on CompileError catch (e) {
      throw e.at(func.loc);
    }
  }

  void _genFunc(FuncDeclNode func) {
    currentFuncName = func.name;
    currentFuncRet = (cleanType(func.retType), func.retPtr);
    asm.add(
        '; ------------------------------------------------------------------------------');
    asm.add('; Function: ${func.name}');
    asm.add(
        '; ------------------------------------------------------------------------------');
    emitLabel('_${func.name}');

    locals = {};
    stackOffset = 0;

    if (func.name == 'main') {
      emit('LD      R14, 1', 'Accumulate 0x00010000 into R14');
      emit('PUSH8   R14, 0');
      emit('PUSH8   R14, 0');
      emit('LD      R15, R14', 'Initialize Stack Pointer (SP = 0x00010000)');
    } else {
      emit('PUSH32  R14', 'Preserve return address link');
      stackOffset = 4;
    }

    openArrays.clear();
    dynamicArrays.clear();
    borrowedParams.clear();
    affineState = {};
    var rIdx = 1;
    for (final p in func.params) {
      final pType = p.type;
      final pPtr = p.isPtr;
      final pName = p.name;
      final isOpenArr = p.isOpenArr;
      final cleanPt = cleanName(pType);
      final isRef = (structs.containsKey(cleanPt) && !pPtr) || isOpenArr;
      types[pName] = TypeInfo(pType, pPtr, isRef);
      borrowedParams.add(pName);
      if (isOpenArr) {
        openArrays.add(pName);
        _bindParamSlot(rIdx, pName, "Spill open array ptr '$pName'");
        rIdx++;
        _bindParamSlot(rIdx, '${pName}__len', "Spill open array len '$pName'");
        rIdx++;
      } else {
        _bindParamSlot(rIdx, pName, "Spill param '$pName'");
        rIdx++;
      }
    }

    // Local constants may size local arrays, so register them first
    if (func.body != null) {
      _preRegisterLocalConsts(func.body);
    }

    // Pre-scan and allocate function-level local stack frame
    final localDecls = <VarDeclNode>[];
    if (func.body != null) {
      _collectLocalDecls(func.body, localDecls);
    }

    _allocateLocalFrame(func.name, localDecls);

    final coroSteps = <(int, AstNode)>[];
    if (func.body != null) {
      _collectCoroutineSteps(func.body!, coroSteps);
    }

    // A task dispatches on its state's continuation counter
    currentFuncIsTask = func.isTask;
    if (func.isTask) {
      _checkTask(func);
    }
    if (func.isTask) {
      emit('; Coroutine entry continuation dispatch');
      final taskRef = VarAccessNode(func.params.first.name);
      _emitLvalueAddr(taskRef, 14);
      emit('LD16     R1, (R14)', 'Read continuation counter');
      final lblEntry0 = '._step_${func.name}_0';
      final lblSkip0 = newLabel('coro_skip');
      emit('LD       R3, R1', 'Copy lc for check');
      emit('SEQ      R3, R0', 'Check if initial entry (lc == 0)');
      emit('FBRA.Z   R3, $lblSkip0', 'Hop if not lc == 0');
      emit('FBRA     $lblEntry0', 'Wide branch to initial entry (8-bit)');
      emitLabel(lblSkip0);
      final seen = <int>{};
      for (final (sVal, _) in coroSteps) {
        if (seen.add(sVal)) {
          final lblS = '._step_${func.name}_$sVal';
          final lblSkipS = newLabel('coro_skip');
          emitImmediate(2, sVal);
          emit('LD       R3, R1', 'Copy lc for check');
          emit('SEQ      R3, R2', 'Check step $sVal');
          emit('FBRA.Z   R3, $lblSkipS', 'Hop if not matched');
          emit('FBRA     $lblS', 'Wide branch to step $sVal (8-bit)');
          emitLabel(lblSkipS);
        }
      }
      emitLabel(lblEntry0);
    }

    genBlock(func.body!);

    if (func.isTask) {
      // Falling off the end, or 'return;', ends the task
      emitLabel('._task_end_${func.name}');
      emit('; Coroutine fallthrough completion (PK_ENDED)');
      final taskRef = VarAccessNode(func.params.first.name);
      _emitLvalueAddr(taskRef, 14);
      emit('LD16     (R14), R0', 'Reset continuation counter (lc = 0)');
      final ended = _pkStatus('PK_ENDED');
      emitImmediate(1, ended);
    }

    emitLabel('._epilogue_${func.name}');
    if (func.name == 'main') {
      if (stackOffset > 0) {
        emitImmediate(14, stackOffset);
        emit('ADD     R15, R14', 'Deallocate stack frame');
      }
      final spinLbl = '._halt_${func.name}';
      emitLabel(spinLbl);
      emit('BBRA    $spinLbl', 'Halt loop upon main completion');
    } else {
      final frameLocals = stackOffset - 4;
      if (frameLocals > 0) {
        emitImmediate(14, frameLocals);
        emit('ADD     R15, R14', 'Deallocate locals and spilled params');
      }
      emit('POP32   R14', 'Restore return address link');
      emit('RRET', 'Return to caller');
    }
    asm.add('');
  }

  void genBlock(BlockNode block) {
    for (final stmt in block.stmts) {
      genStmt(stmt);
    }
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
      decls.add(VarDeclNode(node.varType, false, node.varName, null));
      decls.add(VarDeclNode('u32', false, '${node.varName}__end', null));
      _collectLocalDecls(node.body, decls);
    } else if (node is SwitchNode) {
      _collectLocalDecls(node.body, decls);
    } else if (node is VarDeclNode) {
      if (!node.isConst && node.boundAddrExpr == null) {
        decls.add(node);
      }
    } else if (node is TupleAssignNode) {
      for (final t in node.targets) {
        if (!t.isWildcard && t.typeName != null) {
          decls.add(VarDeclNode(t.typeName!, t.isPtr, t.name!));
        }
      }
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

  /// Registers the function's local `const` declarations, in order.
  void _preRegisterLocalConsts(AstNode? node) {
    if (node is BlockNode) {
      for (final s in node.stmts) {
        _preRegisterLocalConsts(s);
      }
    } else if (node is IfNode) {
      _preRegisterLocalConsts(node.thenBody);
      _preRegisterLocalConsts(node.elseBody);
    } else if (node is WhileNode) {
      _preRegisterLocalConsts(node.body);
    } else if (node is ForRangeNode) {
      _preRegisterLocalConsts(node.body);
    } else if (node is SwitchNode) {
      _preRegisterLocalConsts(node.body);
    } else if (node is VarDeclNode && node.isConst) {
      _defineLocalConst(node);
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


  void _collectSwitchLabels(AstNode node, List<(int, String)> cases,
      List<String?> defaultHolder, List<String> ordered) {
    if (node is CaseLabelNode) {
      final e = node.expr;
      if (e is IntLitNode) {
        node.val = e.val;
      } else {
        node.val = _evalConstExpr(e);
      }
      node.label = newLabel('case_${node.val}');
      cases.add((node.val!, node.label!));
      ordered.add(node.label!);
    } else if (node is DefaultLabelNode) {
      node.label = newLabel('default');
      defaultHolder[0] = node.label;
      ordered.add(node.label!);
    } else if (node is BlockNode) {
      for (final s in node.stmts) {
        _collectSwitchLabels(s, cases, defaultHolder, ordered);
      }
    } else if (node is IfNode) {
      _collectSwitchLabels(node.thenBody, cases, defaultHolder, ordered);
      if (node.elseBody != null) {
        _collectSwitchLabels(node.elseBody!, cases, defaultHolder, ordered);
      }
    } else if (node is WhileNode) {
      _collectSwitchLabels(node.body, cases, defaultHolder, ordered);
    }
  }
}

/// Python `repr()` of a string, used in assembly comments.
String pyRepr(String s) {
  final quote = (s.contains("'") && !s.contains('"')) ? '"' : "'";
  final out = StringBuffer(quote);
  for (final code in s.runes) {
    final ch = String.fromCharCode(code);
    if (ch == '\\') {
      out.write('\\\\');
    } else if (ch == quote) {
      out.write('\\$quote');
    } else if (ch == '\n') {
      out.write('\\n');
    } else if (ch == '\r') {
      out.write('\\r');
    } else if (ch == '\t') {
      out.write('\\t');
    } else if (code < 0x20 || (code >= 0x7f && code <= 0xa0) || code == 0xad) {
      out.write('\\x${code.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.write(ch);
    }
  }
  out.write(quote);
  return out.toString();
}

/// Python list repr of strings, used in diagnostics: `['u32', 'u32']`.
String pyListRepr(List<String> items) =>
    '[${items.map((s) => "'$s'").join(', ')}]';
