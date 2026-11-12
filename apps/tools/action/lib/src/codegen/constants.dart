part of 'codegen.dart';

/// A constant's exact value and its type. [type] is null for an untyped
/// constant: a literal, an enum member, a `sizeof`, or an expression made
/// only of those. An untyped constant takes the type of whatever it is used
/// with, and its value must fit that type. A `const` has its declared type.
class _ConstVal {
  final BigInt value;
  final String? type;
  const _ConstVal(this.value, this.type);
}

/// Smallest and largest value of each integer type.
final Map<String, (BigInt, BigInt)> _intRanges = {
  'bool': (BigInt.zero, BigInt.one),
  'u8': (BigInt.zero, BigInt.from(0xFF)),
  's8': (BigInt.from(-0x80), BigInt.from(0x7F)),
  'u16': (BigInt.zero, BigInt.from(0xFFFF)),
  's16': (BigInt.from(-0x8000), BigInt.from(0x7FFF)),
  'u32': (BigInt.zero, BigInt.from(0xFFFFFFFF)),
  's32': (BigInt.from(-0x80000000), BigInt.from(0x7FFFFFFF)),
  'u64': (BigInt.zero, (BigInt.one << 64) - BigInt.one),
  's64': (-(BigInt.one << 63), (BigInt.one << 63) - BigInt.one),
};

final BigInt _mask32 = BigInt.from(0xFFFFFFFF);

/// Values a 32-bit register can be loaded with: anything that fits in u32
/// or s32.
final BigInt _min32 = BigInt.from(-0x80000000);

extension _ConstRules on CodeGen {
  /// The 32-bit pattern of an exact constant (its value modulo 2^32).
  int _bits32(BigInt v) => (v & _mask32).toInt();

  /// True when [v] fits integer type [type]. Types that are not integers
  /// (and unknown names) accept any value.
  bool _fitsType(BigInt v, Object? type) {
    final r = _intRanges[cleanName(type)];
    if (r == null) return true;
    return v >= r.$1 && v <= r.$2;
  }

  /// Exact value and type of constant expression [expr]. Throws
  /// [NotConstantError] if it is not constant. When [arrayNames] is true an
  /// array variable's name stands for its size in bytes, as it always has
  /// in constant contexts; code generation passes false, since there the
  /// name is the array's address.
  _ConstVal _constExact(AstNode? expr, {bool arrayNames = true}) {
    if (expr == null) return _ConstVal(BigInt.zero, null);
    if (expr is IntLitNode) {
      return _ConstVal(BigInt.from(expr.val), null);
    } else if (expr is VarAccessNode) {
      final c = _constInfo(expr.name);
      if (c != null) return c;
      if (arrayNames) {
        final sz = _arrayByteSize(expr.name);
        if (sz != null) return _ConstVal(BigInt.from(sz), null);
      }
      throw NotConstantError(
          "Constant expression references non-constant symbol '${expr.name}'");
    } else if (expr is SizeofNode) {
      return _ConstVal(BigInt.from(_sizeofValue(expr)), null);
    } else if (expr is UnaryOpNode) {
      final c = _constExact(expr.operand, arrayNames: arrayNames);
      final t = c.type;
      switch (expr.op) {
        case '-':
          return _typedResult(-c.value, t, expr.op);
        case '~':
          // Untyped (and signed) complement is -x-1; an unsigned typed
          // constant flips the bits of its width.
          final r = _intRanges[cleanName(t)];
          if (t != null && r != null && r.$1 == BigInt.zero) {
            return _ConstVal(c.value ^ r.$2, t);
          }
          return _typedResult(-c.value - BigInt.one, t, expr.op);
        case '!':
          return _ConstVal(c.value == BigInt.zero ? BigInt.one : BigInt.zero, null);
      }
    } else if (expr is BinaryOpNode && expr.op != '=') {
      final op = expr.op;
      final l = _constExact(expr.left, arrayNames: arrayNames);
      final r = _constExact(expr.right, arrayNames: arrayNames);
      final lv = l.value;
      final rv = r.value;
      if (op == '<<' || op == '>>') {
        // The result has the left operand's type; the count is any
        // non-negative constant.
        if (rv.isNegative) {
          throw CompileError('negative shift count $rv in constant expression');
        }
        if (rv > BigInt.from(1024)) {
          throw CompileError('shift count $rv is too large');
        }
        final n = rv.toInt();
        return _typedResult(op == '<<' ? lv << n : lv >> n, l.type, op);
      }
      final t = _combinedConstType(l, r, op);
      switch (op) {
        case '+':
          return _typedResult(lv + rv, t, op);
        case '-':
          return _typedResult(lv - rv, t, op);
        case '*':
          return _typedResult(lv * rv, t, op);
        case '/':
          if (rv == BigInt.zero) {
            throw CompileError('division by zero in constant expression');
          }
          return _typedResult(lv ~/ rv, t, op);
        case '%':
          if (rv == BigInt.zero) {
            throw CompileError('division by zero in constant expression');
          }
          return _typedResult(lv.remainder(rv), t, op);
        case '&':
          return _typedResult(lv & rv, t, op);
        case '|':
          return _typedResult(lv | rv, t, op);
        case '^':
          return _typedResult(lv ^ rv, t, op);
        case '==':
          return _bool(lv == rv);
        case '!=':
          return _bool(lv != rv);
        case '<':
          return _bool(lv < rv);
        case '<=':
          return _bool(lv <= rv);
        case '>':
          return _bool(lv > rv);
        case '>=':
          return _bool(lv >= rv);
        case '&&':
          return _bool(lv != BigInt.zero && rv != BigInt.zero);
        case '||':
          return _bool(lv != BigInt.zero || rv != BigInt.zero);
      }
    }
    throw NotConstantError(
        'Expression cannot be evaluated as constant: ${_pyClassName(expr)}');
  }

  _ConstVal _bool(bool b) => _ConstVal(b ? BigInt.one : BigInt.zero, null);

  /// The type of a binary operation on two constants. An untyped operand
  /// takes the other operand's type and must fit it. Two typed constants of
  /// different types mix the way variables do: s32 if either is signed,
  /// otherwise u32.
  String? _combinedConstType(_ConstVal l, _ConstVal r, String op) {
    final lt = l.type;
    final rt = r.type;
    if (lt == null && rt == null) return null;
    if (lt == null) {
      _requireConstFits(l, rt!, "operand of '$op'");
      return rt;
    }
    if (rt == null) {
      _requireConstFits(r, lt, "operand of '$op'");
      return lt;
    }
    if (cleanName(lt) == cleanName(rt)) return lt;
    return (_isSignedName(cleanName(lt)) || _isSignedName(cleanName(rt))) ? 's32' : 'u32';
  }

  /// A result of [type]; a typed result must fit its type.
  _ConstVal _typedResult(BigInt v, String? type, String op) {
    if (type != null && !_fitsType(v, type)) {
      throw CompileError(
          "constant expression overflows ${cleanName(type)}: the result of '$op' is $v");
    }
    return _ConstVal(v, type);
  }

  void _requireConstFits(_ConstVal c, Object type, String what) {
    if (!_fitsType(c.value, type)) {
      throw CompileError(
          '$what: the constant ${c.value} does not fit in ${cleanName(type)}');
    }
  }

  /// The constant value of [expr] when it is a constant expression in
  /// generated code (array names are not constants there), else null.
  _ConstVal? _tryConst(AstNode? expr) {
    if (expr == null) return null;
    try {
      return _constExact(expr, arrayNames: false);
    } on NotConstantError {
      return null;
    }
  }

  /// When [expr] is an untyped constant, checks that it fits [type], the
  /// type it is used as. [isPtr] targets (references, pointers) and
  /// non-integer types take any value, as before.
  void _checkConstFits(AstNode? expr, Object? type, bool isPtr, String what) {
    if (expr == null || type == null || isPtr) return;
    if (!_intRanges.containsKey(cleanName(type))) return;
    final c = _tryConst(expr);
    if (c == null || c.type != null) return;
    try {
      _requireConstFits(c, type, what);
    } on CompileError catch (e) {
      throw e.at(expr.loc);
    }
  }

  /// The type the non-constant operand of a binary operation gives an
  /// untyped constant on the other side: its declared type, or for an
  /// operator result the 32-bit type the operation is done in.
  Object _operandType(AstNode expr) {
    if (expr is BinaryOpNode || expr is UnaryOpNode) {
      return _isSignedOperand(expr) ? 's32' : 'u32';
    }
    final (t, isPtr) = _getExprType(expr);
    return isPtr ? 'u32' : t;
  }

  /// Go's rule for a binary operation with one untyped constant operand and
  /// one that is not constant: the constant takes the other operand's type
  /// and must fit it. Shift counts only have to be non-negative, and a
  /// constant divisor must not be zero.
  void _checkBinaryConsts(BinaryOpNode expr) {
    final op = expr.op;
    if (op == '=' || op == '&&' || op == '||') return;
    final l = _tryConst(expr.left);
    final r = _tryConst(expr.right);
    if (op == '<<' || op == '>>') {
      if (r != null && r.value.isNegative) {
        throw CompileError("negative shift count ${r.value}");
      }
      return;
    }
    if ((op == '/' || op == '%') && r != null && r.value == BigInt.zero) {
      throw CompileError('division by zero');
    }
    if ((l == null) == (r == null)) return;
    if (l != null && l.type == null) {
      _requireConstFits(l, _operandType(expr.right), "operand of '$op'");
    } else if (r != null && r.type == null) {
      _requireConstFits(r, _operandType(expr.left), "operand of '$op'");
    }
  }

  /// Emits [expr] as an immediate when it is a constant operation (unary or
  /// binary), evaluated exactly. Returns false when it is not one.
  bool _emitFoldedConst(AstNode expr, int targetReg) {
    if (expr is! UnaryOpNode && !(expr is BinaryOpNode && expr.op != '=')) {
      return false;
    }
    final c = _tryConst(expr);
    if (c == null) return false;
    _requireRegisterValue(c.value);
    emitImmediate(targetReg, _bits32(c.value));
    return true;
  }

  /// A constant loaded into a 32-bit register must fit u32 or s32.
  void _requireRegisterValue(BigInt v) {
    if (v < _min32 || v > _mask32) {
      throw CompileError('the constant $v does not fit in 32 bits');
    }
  }

  /// Exact value and type of the named constant, evaluating it now if it
  /// is still pending. Null when [name] is not a constant.
  _ConstVal? _constInfo(String name) {
    final known = _constExactValues[name];
    if (known != null) return known;
    if (!_pendingConsts.containsKey(name)) {
      // -D values, and anything registered before exact values existed
      final v = constants[name];
      if (v == null) return null;
      final c = _ConstVal(BigInt.from(v), _constTypes[name]);
      _constExactValues[name] = c;
      return c;
    }
    final expr = _pendingConsts[name]!;
    if (!_constsInProgress.add(name)) {
      throw CompileError("Circular constant definition involving '$name'");
    }
    try {
      final c = _defineConst(name, _constTypes[name], expr);
      _pendingConsts.remove(name);
      return c;
    } on CompileError catch (e) {
      throw e.at(expr.loc);
    } finally {
      _constsInProgress.remove(name);
    }
  }

  /// Evaluates the constant [name] of declared [type] (null for an enum
  /// member) from [expr] and records it. The value must fit the type; the
  /// constant then has that type.
  _ConstVal _defineConst(String name, String? type, AstNode? expr) {
    final c = _constExact(expr);
    final typed = type != null && _intRanges.containsKey(cleanName(type));
    if (typed) {
      if (!_fitsType(c.value, type)) {
        throw CompileError(
            "constant '$name': the value ${c.value} does not fit in ${cleanName(type)}");
      }
    } else {
      _requireRegisterValue(c.value);
    }
    final r = _ConstVal(c.value, typed ? type : c.type);
    _constExactValues[name] = r;
    constants[name] = _bits32(c.value);
    return r;
  }

  /// Registers a `-D` value for a constant the source also declares with
  /// [type]: the source's type applies and the value must fit it.
  void _typePredefinedConst(String name, String? type) {
    final v = predefinedConstants[name];
    if (v == null || type == null || !_intRanges.containsKey(cleanName(type))) return;
    final c = _ConstVal(BigInt.from(v), type);
    if (!_fitsType(c.value, type)) {
      throw CompileError(
          "constant '$name' (from -D): the value $v does not fit in ${cleanName(type)}");
    }
    _constTypes[name] = type;
    _constExactValues[name] = c;
  }

  /// Defines local `const` [d] (or applies its type to a `-D` value).
  void _defineLocalConst(VarDeclNode d) {
    final type = cleanName(d.typeName);
    if (predefinedConstants.containsKey(d.name)) {
      _typePredefinedConst(d.name, type);
      return;
    }
    _constTypes[d.name] = type;
    _defineConst(d.name, type, d.initExpr);
  }

  /// The value of a condition that is a constant operation (unary or
  /// binary), or null when it is not one.
  bool? _foldedCondition(AstNode cond) {
    if (cond is! UnaryOpNode && !(cond is BinaryOpNode && cond.op != '=')) {
      return null;
    }
    final c = _tryConst(cond);
    if (c == null) return null;
    return c.value != BigInt.zero;
  }

  /// `x op= c`: an untyped constant takes the target's type and must fit
  /// it, as in `x = x op c` (a shift count only has to be non-negative).
  void _checkCompoundConst(CompoundAssignNode expr, String op) {
    final (t, isPtr) = _getExprType(expr.lhs);
    if (op == '<<' || op == '>>') {
      final r = _tryConst(expr.rhs);
      if (r != null && r.value.isNegative) {
        throw CompileError('negative shift count ${r.value}');
      }
      return;
    }
    if (op == '/' || op == '%') {
      final r = _tryConst(expr.rhs);
      if (r != null && r.value == BigInt.zero) {
        throw CompileError('division by zero');
      }
    }
    _checkConstFits(expr.rhs, t, isPtr, "'${op}=' on ${_targetName(expr.lhs)}");
  }

  /// How a diagnostic names an assignment target.
  String _targetName(AstNode target) {
    if (target is VarAccessNode) return "'${target.name}'";
    if (target is MemberAccessNode) return "field '${target.member}'";
    if (target is ArrayAccessNode) return 'an array element';
    return 'the target';
  }

  /// Each case label of [sw] is a constant used as the switch value's type.
  void _checkCaseConsts(SwitchNode sw) {
    final (t, isPtr) = _getExprType(sw.expr);
    void walk(AstNode? n) {
      if (n is CaseLabelNode) {
        _checkConstFits(n.expr, t, isPtr, 'case label');
      } else if (n is BlockNode) {
        n.stmts.forEach(walk);
      } else if (n is IfNode) {
        walk(n.thenBody);
        walk(n.elseBody);
      } else if (n is WhileNode) {
        walk(n.body);
      } else if (n is ForRangeNode) {
        walk(n.body);
      }
    }

    walk(sw.body);
  }

  /// True when [e] always yields 0 or 1: a comparison, `!`, `&&`, `||`,
  /// `exists()`, a constant 0 or 1, or a value of type `bool`.
  bool _isBoolValued(AstNode e) {
    if (e is BinaryOpNode &&
        const ['==', '!=', '<', '<=', '>', '>=', '&&', '||'].contains(e.op)) {
      return true;
    }
    if (e is UnaryOpNode && e.op == '!') return true;
    if (e is ExistsNode) return true;
    final c = _tryConst(e);
    if (c != null) return c.value == BigInt.zero || c.value == BigInt.one;
    final (t, isPtr) = _getExprType(e);
    return !isPtr && cleanName(t) == 'bool';
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
