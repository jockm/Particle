part of '../compiler.dart';

/// Code generation for constants and `bool` values.
extension _ConstEmit on CodeGen {
  /// Emits [expr] as an immediate when it is a constant operation (unary or
  /// binary), evaluated exactly. Returns false when it is not one.
  bool _emitFoldedConst(AstNode expr, int targetReg) {
    if (expr is! UnaryOpNode &&
        expr is! ConvertNode &&
        expr is! MemberAccessNode &&
        !(expr is BinaryOpNode && expr.op != '=')) {
      return false;
    }
    final c = _tryConst(expr);
    if (c == null) return false;
    emitImmediate(targetReg, _bits32(c.value));
    return true;
  }

  /// Before a value from [rhs] in register [reg] is stored as a `bool`
  /// ([targetType]), turns it into 0 or 1 unless it already is one.
  void _normalizeBool(Object? targetType, AstNode rhs, int reg) {
    if (cleanName(targetType) != 'bool' || _isBoolValued(rhs)) return;
    emit('NEZ     R$reg', 'Store as a bool: 0 or 1');
  }

  /// After a compound assignment to a `bool` computed its result in [reg].
  void _normalizeBoolResult(Object? targetType, int reg) {
    if (cleanName(targetType) != 'bool') return;
    emit('NEZ     R$reg', 'Store as a bool: 0 or 1');
  }
}
