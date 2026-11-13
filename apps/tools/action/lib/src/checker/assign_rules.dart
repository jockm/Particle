part of '../compiler.dart';

bool _listEq(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The checker's rules for what may be assigned to a variable.
extension _AssignRules on Checker {
  void _validateFnTypeAssignment(Object targetType, AstNode rhsExpr, [String? targetName]) {
    final cleanTgt = cleanName(targetType);
    final rhsTObj = _getExprType(rhsExpr).$1;
    final rhsT = rhsTObj is String ? rhsTObj : rhsTObj.toString();
    final cleanRhs = cleanName(rhsTObj);

    // 1. Function pointer targets
    if (targetType is String && fnTypes.containsKey(targetType)) {
      final (expParams, expRet) = fnTypes[targetType]!;
      if (rhsT.startsWith('fn_')) {
        final fnName = rhsT.substring(3);
        final sig = funcSignatures[fnName];
        if (sig == null) {
          throw CompileError(
              "Unknown function '$fnName' in function pointer assignment");
        }
        final actRet = sig.retType;
        final actParams = [for (final p in sig.params) cleanName(p.type)];
        final expParamsClean = [for (final p in expParams) cleanName(p)];
        if (expParamsClean.length != actParams.length ||
            !_listEq(expParamsClean, actParams) ||
            expRet != actRet) {
          String sigText(List<Object> ps, Object? r) =>
              "fn(${ps.join(', ')})${cleanName(r) == 'void' ? '' : ' -> ${cleanName(r)}'}";
          throw CompileError('Function signature mismatch: cannot assign '
              '${_shownFunc(fnName)} (${sigText(actParams, actRet)}) to type '
              "'$targetType' (${sigText(expParamsClean, expRet)})");
        }
      } else if (fnTypes.containsKey(rhsT)) {
        final a = fnTypes[targetType]!;
        final b = fnTypes[rhsT]!;
        if (!_listEq(a.$1, b.$1) || a.$2 != b.$2) {
          throw CompileError(
              "Function type mismatch: cannot assign '$rhsT' to '$targetType'");
        }
      } else {
        throw CompileError(
            "Cannot assign non-function value of type '$rhsT' to function pointer '$targetType'");
      }
      return;
    }

    // 2. Reject function references assigned to non-function types
    if (rhsT.startsWith('fn_') || fnTypes.containsKey(rhsT)) {
      throw CompileError(
          "Cannot implicitly convert function reference to non-function type '$targetType'");
    }

    // 3. HeapAllocNode (Type.create())
    if (rhsExpr is HeapAllocNode) {
      final allocT = cleanName(rhsExpr.typeName);
      if (cleanTgt != allocT) {
        throw CompileError(
            "Cannot assign instance of type '$allocT' to variable of type '$targetType'");
      }
      return;
    }

    // 4. HeapStringAllocNode (string.create())
    if (rhsExpr is HeapStringAllocNode) {
      if (cleanTgt != 'string') {
        throw CompileError(
            "Cannot assign string allocation to non-string variable of type '$targetType'");
      }
      return;
    }

    // 5. User struct reference targets
    if (structs.containsKey(cleanTgt)) {
      // Allow assigning 0 (null reference)
      if (rhsExpr is IntLitNode && rhsExpr.val == 0) {
        return;
      }
      if (cleanRhs != cleanTgt) {
        throw CompileError(
            "Cannot assign type '$cleanRhs' to reference variable of type '$targetType'");
      }
      return;
    }

    // 6. Primitive scalar target with struct/reference RHS
    const primitives = ['u8', 's8', 'u16', 's16', 'u32', 's32', 'bool'];
    if (primitives.contains(cleanTgt)) {
      if (structs.containsKey(cleanRhs)) {
        throw CompileError(
            "cannot assign a reference to a '$cleanRhs' to ${targetName != null ? "'$targetName'" : 'a variable'} of type '$targetType'");
      }
      if (cleanRhs == 'string' && rhsExpr is! IntLitNode) {
        throw CompileError(
            "Cannot assign string to scalar variable of type '$targetType'");
      }
    }
  }
}
