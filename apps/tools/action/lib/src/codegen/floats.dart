part of 'codegen.dart';

// ------------------------------------------------------------------------------
// Floating point (f32, f64): the LLVM compiler only, for now
// ------------------------------------------------------------------------------
//
// A floating-point literal (1.5, 1e-3) is an untyped constant that takes the
// type it is used with. Integers and floats do not mix without a conversion
// (`f64(n)`, `s32(x)`), and neither do f32 and f64; an untyped integer
// constant may be used where a float is expected (`x * 2`). `%`, the bitwise
// operators and the shifts are for integers. Constants (`const f64 PI =
// 3.14159;`) are worked out in double precision at compile time.

/// The value and type of a floating-point constant.
typedef _FloatConst = (double, String);

extension _Floats on Checker {
  bool _isFloatName(Object? t) {
    if (t is! String) return false;
    final c = cleanName(t);
    return c == 'f32' || c == 'f64';
  }

  /// The floating-point type of [e]: 'f32' or 'f64', or 'float' for an
  /// untyped constant (a literal, or arithmetic on literals); null when [e]
  /// is not a floating-point value.
  String? _floatTypeOf(AstNode e) {
    if (e is FloatLitNode) return 'float';
    if (e is ConvertNode) return _isFloatName(e.typeName) ? e.typeName : null;
    if (e is VarAccessNode && !_isVariableInScope(e.name)) {
      final c = _floatConsts[e.name];
      if (c != null) return c.$2;
    }
    if (e is UnaryOpNode) return e.op == '-' ? _floatTypeOf(e.operand) : null;
    if (e is BinaryOpNode) {
      if (e.op == '=') return _floatTypeOf(e.left);
      if (!const ['+', '-', '*', '/'].contains(e.op)) return null;
      final l = _floatTypeOf(e.left);
      final r = _floatTypeOf(e.right);
      if (l != null && l != 'float') return l;
      if (r != null && r != 'float') return r;
      return l ?? r;
    }
    if (e is CompoundAssignNode) return _floatTypeOf(e.lhs);
    final Object t;
    final bool isPtr;
    try {
      (t, isPtr) = _getExprType(e);
    } on CompileError {
      return null;
    }
    return !isPtr && _isFloatName(t) ? cleanName(t) : null;
  }

  /// The value of a floating-point constant expression (rounded to f32
  /// when its type is f32), or null when [e] is not one.
  _FloatConst? _tryFloatConst(AstNode? e) {
    if (e == null) return null;
    if (e is FloatLitNode) return (e.val, 'float');
    if (e is VarAccessNode && !_isVariableInScope(e.name)) return _floatConsts[e.name];
    if (e is ConvertNode && _isFloatName(e.typeName)) {
      final inner = _tryFloatConst(e.expr);
      double? v = inner?.$1;
      if (v == null) {
        final c = _tryConst(e.expr);
        if (c == null) return null;
        v = c.value.toDouble();
      }
      return (_round(v, e.typeName), e.typeName);
    }
    if (e is UnaryOpNode && e.op == '-') {
      final c = _tryFloatConst(e.operand);
      return c == null ? null : (-c.$1, c.$2);
    }
    if (e is BinaryOpNode && const ['+', '-', '*', '/'].contains(e.op)) {
      final l = _tryFloatConst(e.left) ?? _intAsFloat(e.left);
      final r = _tryFloatConst(e.right) ?? _intAsFloat(e.right);
      if (l == null || r == null) return null;
      if (l.$2 == 'int' && r.$2 == 'int') return null;
      final t = l.$2 != 'float' && l.$2 != 'int' ? l.$2 : (r.$2 != 'int' ? r.$2 : 'float');
      final v = switch (e.op) {
        '+' => l.$1 + r.$1,
        '-' => l.$1 - r.$1,
        '*' => l.$1 * r.$1,
        _ => l.$1 / r.$1,
      };
      return (_round(v, t), t);
    }
    return null;
  }

  _FloatConst? _intAsFloat(AstNode e) {
    final c = _tryConst(e);
    return c == null ? null : (c.value.toDouble(), 'int');
  }

  /// [v] as a value of type [t] (an f32 has fewer digits).
  double _round(double v, String t) =>
      t == 'f32' ? (Float32List(1)..[0] = v)[0] : v;

  /// A floating-point constant declared `const f32/f64 NAME = ...;`.
  void _defineFloatConst(VarDeclNode d) {
    final t = cleanName(d.typeName);
    final c = _tryFloatConst(d.initExpr) ?? _intAsFloat(d.initExpr ?? IntLitNode(0));
    if (c == null) {
      throw CompileError("constant '${d.name}' of type $t needs a constant value").at(d.loc);
    }
    if (c.$2 != 'float' && c.$2 != 'int' && c.$2 != t) {
      throw CompileError("constant '${d.name}' is a $t, not a ${c.$2}; convert it: $t(...)")
          .at(d.loc);
    }
    _floatConsts[d.name] = (_round(c.$1, t), t);
  }

  /// Integer and floating-point operands do not mix, nor f32 and f64; `%`,
  /// the bitwise operators and the shifts are for integers.
  void _checkFloatOperands(String op, AstNode l, AstNode r) {
    final lf = _floatTypeOf(l);
    final rf = _floatTypeOf(r);
    if (lf == null && rf == null) return;
    if (const ['%', '&', '|', '^', '<<', '>>', '&&', '||'].contains(op)) {
      throw CompileError("'$op' is for integers, not ${lf ?? rf} values"
          .replaceAll('float values', 'floating-point values'));
    }
    for (final (f, other, otherF) in [(lf, r, rf), (rf, l, lf)]) {
      if (f == null || otherF != null) continue;
      // An untyped integer constant takes the float's type
      final c = _tryConst(other);
      if (c != null && c.type == null) continue;
      final (ot, _) = _getExprType(other);
      final shown = f == 'float' ? 'a floating-point' : 'an $f';
      throw CompileError("$shown value and a ${cleanName(ot)} value do not mix; "
          'convert one, as in ${f == 'float' ? 'f64' : f}(x) or ${cleanName(ot)}(x)');
    }
    if (lf != null && rf != null && lf != 'float' && rf != 'float' && lf != rf) {
      throw CompileError('$lf and $rf values do not mix; convert one, as in $lf(x)');
    }
  }

  /// The operators in [v] follow the rules above (so that an error is
  /// reported where the values meet, not where the result goes).
  void _checkFloatTree(AstNode v) {
    if (v is BinaryOpNode && v.op != '=' && !v.identity) {
      _checkFloatTree(v.left);
      _checkFloatTree(v.right);
      _checkFloatOperands(v.op, v.left, v.right);
    } else if (v is UnaryOpNode) {
      _checkFloatTree(v.operand);
      final f = _floatTypeOf(v.operand);
      if (f != null && v.op != '-') {
        throw CompileError("'${v.op}' is for integers, not ${f == 'float' ? 'floating-point' : f} values");
      }
    }
  }

  /// 'a' or 'an', for a type name in a message.
  String _an(String t) => RegExp(r'^[aefhilmnorsx]').hasMatch(t) ? 'an $t' : 'a $t';

  /// A value [v] stored in, passed as or returned as a [t] ([what]): a
  /// float only where a float of that type is expected.
  void _checkFloatTarget(Object? t, bool isPtr, AstNode v, String what) {
    _checkFloatTree(v);
    final tf = !isPtr && _isFloatName(t);
    final vf = _floatTypeOf(v);
    if (!tf && vf == null) return;
    final ct = cleanName(t);
    if (tf) {
      if (vf == null) {
        final c = _tryConst(v);
        if (c != null && c.type == null) return;
        final (vt, _) = _getExprType(v);
        throw CompileError("$what is ${_an(ct)}; convert the ${cleanName(vt)} value with $ct(x)");
      }
      if (vf != 'float' && vf != ct) {
        throw CompileError("$what is ${_an(ct)}; convert the $vf value with $ct(x)");
      }
      return;
    }
    if (vf == 'float' && v is FloatLitNode) {
      throw CompileError("$what is ${_an(ct)}, and ${v.text} is not an integer");
    }
    throw CompileError("$what is ${_an(ct)}; convert the ${vf == 'float' ? 'floating-point' : vf} "
        'value with $ct(x)');
  }
}
