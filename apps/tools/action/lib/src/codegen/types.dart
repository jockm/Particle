part of 'codegen.dart';

/// Raised when an expression is not a compile-time constant. Constant `if`
/// pruning catches it and falls back to a runtime branch; anywhere else it
/// is reported as a normal compile error (Python raised `ValueError`).
class NotConstantError extends CompileError {
  NotConstantError(super.message);

  @override
  CompileError withMessage(String msg) => NotConstantError(msg);
}

extension _TypeRules on CodeGen {
  /// Infers `(type name, is pointer)` for an expression.
  (Object, bool) _getExprType(AstNode? expr) {
    if (expr is ExistsNode) {
      return ('u32', false);
    } else if (expr is HeapAllocNode) {
      return (expr.typeName, true);
    } else if (expr is HeapArrayAllocNode) {
      return (expr.typeName, true);
    } else if (expr is HeapStringAllocNode) {
      return ('string', true);
    }
    while (expr != null &&
        expr.innerExpr != null &&
        expr is! MemberAccessNode &&
        expr is! UnaryOpNode) {
      expr = expr.innerExpr;
    }
    if (expr is VarAccessNode) {
      if (funcSignatures.containsKey(expr.name)) {
        return ('fn_${expr.name}', false);
      }
      final info = typeOf(expr.name);
      return (info.name, info.isPtr);
    } else if (expr is MemberAccessNode && expr.member == 'len') {
      return ('u32', false);
    } else if (expr is MemberAccessNode) {
      final base = expr.expr;
      if (base is VarAccessNode &&
          structs.containsKey(base.name) &&
          !locals.containsKey(base.name) &&
          !globals.contains(base.name) &&
          !boundAddrs.containsKey(base.name)) {
        final mangled = '${base.name}_${expr.member}';
        if (funcSignatures.containsKey(mangled)) {
          return ('fn_$mangled', false);
        }
        throw CompileError("Type '${base.name}' has no method '${expr.member}'");
      }

      final (pT, _) = _getExprType(expr.expr);
      final possibleType = cleanName(pT);
      final mangled = '${possibleType}_${expr.member}';
      if (funcSignatures.containsKey(mangled)) {
        final baseName = expr.expr.nodeName ?? 'instance';
        throw CompileError(
            "Cannot extract unbound method reference from instance '$baseName'. "
            "Use '$possibleType.${expr.member}' with signature fn($possibleType, ...) instead.");
      }

      final f = fieldOf(possibleType, expr.member);
      return (f.type, f.isPtr);
    } else if (expr is ArrayAccessNode) {
      AstNode curr = expr;
      while (curr is ArrayAccessNode) {
        curr = curr.base;
      }
      if (curr is VarAccessNode) {
        final tName = typeOf(curr.name).name;
        final cleanT = cleanType(tName);
        final elemT = cleanT == 'string' ? 'u8' : tName;
        return (elemT, false);
      } else if (curr is MemberAccessNode) {
        final (baseT, _) = _getExprType(curr.expr);
        final sName = cleanName(baseT);
        final f = fieldOf(sName, curr.member);
        return (cleanType(f.type) == 'string' ? 'u8' : f.type, false);
      }
      return ('u32', false);
    } else if (expr is CallNode) {
      String fname;
      if (expr.name.startsWith('__METHOD__')) {
        final mName = expr.name.replaceAll('__METHOD__', '');
        final (rcvT, _) = _getExprType(expr.args[0]);
        final sName = cleanName(rcvT);
        final (resolved, _) = _resolveMethod(sName, mName);
        fname = resolved ?? '${sName}_$mName';
      } else {
        fname = expr.name;
      }
      final sig = funcSignatures[fname];
      if (sig != null) {
        return (sig.retType, sig.retPtr);
      }
      return ('u32', false);
    }
    return ('u32', false);
  }

  bool _isSignedName(Object t) => t is String && _signedTypes.contains(t);

  /// Byte size of a scalar or record type name (the `sizeof` rules).
  int _sizeOfTypeName(String tClean) {
    if (['u8', 's8', 'bool', 'string'].contains(tClean)) return 1;
    if (['u16', 's16'].contains(tClean)) return 2;
    if (['u32', 's32', 'void'].contains(tClean) || fnTypes.containsKey(tClean)) {
      return 4;
    }
    if (['u64', 's64'].contains(tClean)) return 8;
    if (structs.containsKey(tClean)) return structs[tClean]!.size;
    if (_declaredTypes.contains(tClean)) throw _LayoutDeferred();
    return 4;
  }

  /// Total byte size of a fixed array variable, or null if [vName] is not one.
  int? _arrayByteSize(String vName) {
    if (arrayDims.containsKey(vName)) {
      final elemSz = _getElemSize(typeOf(vName).name, false);
      var tot = 1;
      for (final dm in arrayDims[vName]!) {
        tot *= dm;
      }
      return elemSz * tot;
    } else if (arrayLens.containsKey(vName)) {
      final elemSz = _getElemSize(typeOf(vName).name, false);
      return elemSz * arrayLens[vName]!;
    }
    return null;
  }

  /// Value of constant expression [expr] as a 32-bit pattern (its exact
  /// value modulo 2^32). See [_constExact] for the rules.
  int _evalConstExpr(AstNode? expr) => _bits32(_constExact(expr).value);

  /// Value of `sizeof(...)`.
  int _sizeofValue(SizeofNode expr) {
    Object target = expr.target;
    // If target is a variable name, resolve to its type
    if (target is String) {
      final vName = target;
      final sz = _arrayByteSize(vName);
      if (sz != null) return sz;
      if (types.containsKey(vName)) {
        final tInfo = types[vName]!;
        if (tInfo.isPtr) {
          // pointer
          return 4;
        }
        target = tInfo.name;
      }
      return _sizeOfTypeName(cleanName(target));
    } else if (target is VarAccessNode) {
      final sz = _arrayByteSize(target.name);
      if (sz != null) return sz;
      final (tName, isP) = _getExprType(target);
      if (isP) return 4;
      return _sizeOfTypeName(cleanName(tName));
    } else {
      final (tName, isP) = _getExprType(target as AstNode);
      if (isP) return 4;
      return _sizeOfTypeName(cleanName(tName));
    }
  }

  int _getElemSize(Object? tName, bool isPtr) {
    if (isPtr) return 4;
    final clean = cleanName(tName);
    if (['u8', 's8', 'bool', 'string'].contains(clean)) {
      return 1;
    } else if (['u16', 's16'].contains(clean)) {
      return 2;
    } else if (structs.containsKey(clean)) {
      return structs[clean]!.size;
    }
    return 4;
  }
}

/// Python class name of a node, for diagnostics (`BinaryOpNode`, ...).
String _pyClassName(AstNode node) => node.runtimeType.toString();
