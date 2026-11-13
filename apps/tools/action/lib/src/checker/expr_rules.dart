part of '../compiler.dart';

/// Rules about expressions that both the checker and code generation use.
extension _ExprRules on Checker {
  /// True for a variable holding a heap array reference (`T x[]`), as
  /// opposed to a fixed array or an open array parameter.
  bool _isHeapArrayRef(String name) =>
      (locals.containsKey(name) || globals.contains(name)) &&
      typeOf(name).isPtr &&
      !openArrays.contains(name) &&
      !arrayDims.containsKey(name) &&
      !arrayLens.containsKey(name);

  /// Reports a name that is not a variable, constant or function in scope.
  Never _undefinedName(String name) =>
      throw CompileError("undefined identifier '$name'");

  /// The channel of a FIFO built-in: its first argument, a constant.
  int _fifoChannel(CallNode expr) {
    if (expr.args.isEmpty) {
      throw CompileError("${expr.name} needs a channel number");
    }
    try {
      return _evalConstExpr(expr.args[0]);
    } on NotConstantError {
      throw CompileError("${expr.name}: the channel must be a constant");
    }
  }

  /// Number of call slots the arguments take: one each, two for an open
  /// array (pointer and length).
  int _argSlotCount(List<AstNode> args, List<ParamSig> paramSigs) {
    var n = 0;
    for (var i = 0; i < args.length; i++) {
      n += i < paramSigs.length ? paramSigs[i].slots : 1;
    }
    return n;
  }

  /// True for an argument whose code only touches its own register (and
  /// R13/R14), so it can be loaded straight into its argument register
  /// without disturbing those already loaded.
  bool _isLeafArg(AstNode arg) {
    if (arg is IntLitNode || arg is StringLitNode || arg is VarAccessNode || arg is SizeofNode) {
      return true;
    }
    if (arg is UnaryOpNode && (arg.op == '-' || arg.op == '~')) {
      return _isLeafArg(arg.operand);
    }
    return false;
  }

  /// True when either operand of [expr] has a signed type; signed division,
  /// remainder and right shift are then used (as comparisons already did).
  bool _isSignedBinary(BinaryOpNode expr) =>
      _isSignedOperand(expr.left) || _isSignedOperand(expr.right);

  /// True when [expr] yields a signed value: its type is signed, or it is
  /// arithmetic (or a negation) over a signed operand. _getExprType types
  /// every operator result as u32, so `(a - b) / 2` needs this look inside.
  bool _isSignedOperand(AstNode expr) {
    if (expr is BinaryOpNode &&
        const ['+', '-', '*', '/', '%', '&', '|', '^', '<<', '>>'].contains(expr.op)) {
      return _isSignedOperand(expr.left) || _isSignedOperand(expr.right);
    }
    if (expr is UnaryOpNode && expr.op == '-') {
      return _isSignedOperand(expr.operand);
    }
    final (t, _) = _getExprType(expr);
    return _isSignedName(t);
  }

  /// True when a compound assignment to a [lhsType] target with [rhs] is
  /// signed arithmetic.
  bool _isSignedCompound(Object lhsType, AstNode rhs) =>
      _isSignedName(lhsType) || _isSignedOperand(rhs);

  bool _isWordType(Object tName) =>
      ['u32', 's32', 'string'].contains(tName) ||
      fnTypes.containsKey(tName) ||
      structs.containsKey(tName);
}
