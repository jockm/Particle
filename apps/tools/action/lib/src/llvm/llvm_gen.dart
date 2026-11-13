part of '../compiler.dart';

// ------------------------------------------------------------------------------
// LLVM IR generator
// ------------------------------------------------------------------------------
//
// Generates LLVM IR (the .ll text form) for a program the checker has
// passed, for a host with an operating system (macOS or Linux, 64-bit).
// It walks the program the way the Particle generator does, with the same
// scopes, and keeps Particle's meaning:
//
//   * values are computed in 32 bits, or in 64 when an operand is u64/s64;
//     signed when an operand is signed; overflow wraps
//   * division follows RISC-V: by zero gives all ones (the remainder, the
//     dividend), and the most negative value divided by -1 is itself
//   * a shift count is masked to 5 bits (6 for a 64-bit value)
//   * locals start at zero; a heap array or string has a header before its
//     elements holding its length (or capacity)
//   * a failed run-time check prints a message and exits with 15; trap(N)
//     exits with N
//
// Every local lives in its own stack slot (alloca); clang's optimizer turns
// them into registers. Action functions are named `@act.name`, except
// `main` and C functions declared `extern`.

/// The LLVM target: a 64-bit host.
class LlvmTarget implements Target {
  @override
  String get name => 'llvm';
  @override
  int get pointerSize => 8;
  @override
  int alignOf(int size) => size >= 8 ? 8 : (size >= 4 ? 4 : (size >= 2 ? 2 : 1));
  @override
  int get vectorCount => 16;
  @override
  bool supportsType(String tName) => true;
  @override
  bool get isHosted => true;
  @override
  int get registerBits => 64;
}

/// A value: its LLVM operand, its type (`i32`, `i64` or `ptr`) and whether
/// it is signed (for widening and for signed operations).
class _V {
  final String v;
  final String ty;
  final bool signed;
  const _V(this.v, this.ty, [this.signed = false]);
  bool get isPtr => ty == 'ptr';
}

/// A loop or switch being generated.
class _LFlow {
  final String? breakTo;
  String? continueTo;
  final bool isSwitch;
  final List<String> caseBlocks;
  int currentCase = -1;
  _LFlow.loop(this.breakTo, this.continueTo)
      : isSwitch = false,
        caseBlocks = const [];
  _LFlow.switchBlock(this.breakTo, this.caseBlocks)
      : isSwitch = true,
        continueTo = null;
}

/// Size of the header before the elements of a heap array or string.
const int _heapHeader = 8;

class LlvmGen extends Checker {
  /// Run-time checks of indexes, and of references the flow analysis does
  /// not follow.
  final bool boundsCheck;
  final bool referenceCheck;

  /// Emit debug information.
  final bool debugInfo;

  LlvmGen(
      {this.boundsCheck = true,
      this.referenceCheck = true,
      this.debugInfo = true,
      Map<String, int> predefinedConstants = const {}})
      : super(LlvmTarget(), predefinedConstants: predefinedConstants);

  // ------------------------------------------------------------ module

  final List<String> _globalIr = [];
  final List<String> _funcIr = [];
  final Set<String> _declares = {};
  final Map<String, String> _stringLits = {};
  late _DebugInfo _di;
  bool _runtimeUsed = false;
  bool _strCopyUsed = false;

  // ---------------------------------------------------------- function

  List<String> _body = [];
  List<String> _allocas = [];
  final Map<String, String> _slots = {};
  int _tmpN = 0;
  int _lblN = 0;
  bool _terminated = false;
  String _retTy = 'void';
  String? _curLoc;

  /// The debug scope of the code being generated: the function's
  /// subprogram ([_subprogram]) or a block inside it.
  int? _scope;
  int? _subprogram;

  /// The function's blocks by the statement that opens them, the block
  /// each local is declared in, and each block's debug scope.
  final Map<AstNode, LocalScope> _blockOf = Map.identity();
  final Map<VarDeclNode, LocalScope> _declScope = Map.identity();
  final Map<LocalScope, int> _diBlocks = Map.identity();

  /// Each local's slot type and size, for clearing it (see [_genVarDecl]).
  final Map<String, (String, int)> _slotInfo = {};
  final List<_LFlow> _flows = [];
  final Map<AstNode, String> _caseBlocks = Map.identity();
  FuncDeclNode? _func;

  /// Generates the LLVM module for [root], after checking it.
  String generate(ProgramNode root, {String sourceName = 'main.act'}) {
    _prepare(root);
    final scope = _ScopeSnapshot(this);
    _checkProgramBody();
    scope.restore(this);

    final mainFile = _locFile(root.decls.isEmpty ? null : root.decls.first.loc) ?? sourceName;
    _di = _DebugInfo(this, mainFile);

    for (final d in _dataDecls) {
      if (d.isConst || d.boundAddr != null) continue;
      _genGlobal(d);
    }
    for (final f in _funcDecls) {
      if (f.isExtern) {
        _declareExtern(f);
      } else if (f.body != null) {
        _genFunction(f);
      }
    }
    if (_runtimeUsed) _genRuntime();
    if (_strCopyUsed) _genStrCopy();

    final out = <String>[
      '; Compiled from Action source by action_llvm',
      '',
      ..._globalIr,
      if (_globalIr.isNotEmpty) '',
      for (final e in _stringLits.entries) e.value,
      if (_stringLits.isNotEmpty) '',
      ..._funcIr,
      ..._declares.toList()..sort(),
      '',
      'attributes #0 = { nounwind uwtable }',
      'attributes #1 = { alwaysinline nounwind uwtable }',
      'attributes #2 = { noreturn nounwind }',
      '',
      if (debugInfo) ..._di.emit(),
    ];
    return '${out.join('\n')}\n';
  }

  // -------------------------------------------------------- locations

  static final RegExp _locRe = RegExp(r'^(.*):(\d+):(\d+)$');

  String? _locFile(String? loc) {
    if (loc == null) return null;
    final m = _locRe.firstMatch(loc);
    return m?.group(1);
  }

  (int, int) _lineCol(String? loc) {
    final m = loc == null ? null : _locRe.firstMatch(loc);
    if (m == null) return (0, 0);
    return (int.parse(m.group(2)!), int.parse(m.group(3)!) + 1);
  }

  /// `file:line:col` of the node being generated, for run-time messages.
  String get _where {
    final loc = _curLoc;
    if (loc == null) return currentFuncName;
    final m = _locRe.firstMatch(loc);
    if (m == null) return loc;
    final path = m.group(1)!;
    final slash = path.lastIndexOf('/');
    final (line, col) = _lineCol(loc);
    return '${slash < 0 ? path : path.substring(slash + 1)}:$line:$col';
  }

  String _dbg() {
    if (!debugInfo || _scope == null) return '';
    final (line, col) = _lineCol(_curLoc ?? _func?.loc);
    return ', !dbg !${_di.location(line, col, _scope!)}';
  }

  // ------------------------------------------------------- emitting IR

  String _t() => '%t${_tmpN++}';
  String _newBlock(String what) => '$what.${_lblN++}';

  void _ins(String s) {
    if (_terminated) _startBlock(_newBlock('dead'));
    _body.add('  $s${_dbg()}');
  }

  /// An instruction that gives a value.
  String _val(String s) {
    final t = _t();
    _ins('$t = $s');
    return t;
  }

  void _terminator(String s) {
    _ins(s);
    _terminated = true;
  }

  void _br(String label) => _terminator('br label %$label');

  void _startBlock(String label) {
    if (!_terminated) _body.add('  br label %$label${_dbg()}');
    _body.add('$label:');
    _terminated = false;
  }

  void _declare(String d) => _declares.add(d);

  // --------------------------------------------------------- constants

  _V _const(BigInt v, {bool wide = false}) {
    final fits32 = v >= _min32 && v <= _mask32;
    if (fits32 && !wide) {
      final s = v > BigInt.from(0x7FFFFFFF) ? v - (BigInt.one << 32) : v;
      return _V('$s', 'i32', v.isNegative);
    }
    final m64 = (BigInt.one << 64) - BigInt.one;
    var w = v & m64;
    if (w > BigInt.parse('7FFFFFFFFFFFFFFF', radix: 16)) w -= BigInt.one << 64;
    return _V('$w', 'i64', v.isNegative);
  }

  _V _i32(int n) => _V('$n', 'i32', n < 0);

  _V _constOf(_ConstVal c) => _const(c.value, wide: _is64Name(c.type));

  // ------------------------------------------------------------ types

  /// The LLVM type a value of [tName] is stored as.
  String _storeTy(Object? tName, bool isPtr) {
    if (isPtr) return 'ptr';
    final t = cleanName(tName);
    switch (t) {
      case 'u8':
      case 's8':
      case 'bool':
        return 'i8';
      case 'u16':
      case 's16':
        return 'i16';
      case 'u64':
      case 's64':
        return 'i64';
      case 'f32':
        return 'float';
      case 'f64':
        return 'double';
      case 'string':
        return 'ptr';
    }
    if (fnTypes.containsKey(t) || structs.containsKey(t)) return 'ptr';
    return 'i32';
  }

  /// The LLVM type a value of [tName] is computed in.
  String _regTy(Object? tName, bool isPtr) {
    final s = _storeTy(tName, isPtr);
    return s == 'i8' || s == 'i16' ? 'i32' : s;
  }

  bool _isStorageRecord(Object? tName, bool isPtr) =>
      !isPtr && structs.containsKey(cleanName(tName));

  /// [v] as an integer of [ty] (`i32` or `i64`), or as a pointer.
  _V _conv(_V v, String ty) {
    if (v.ty == ty) return v;
    if (_isFloatTy(ty) || _isFloatTy(v.ty)) return _convFloat(v, ty);
    if (ty == 'ptr') {
      if (v.v == '0') return const _V('null', 'ptr');
      return _V(_val('inttoptr ${v.ty} ${v.v} to ptr'), 'ptr');
    }
    if (v.isPtr) return _V(_val('ptrtoint ptr ${v.v} to $ty'), ty);
    final from = int.parse(v.ty.substring(1));
    final to = int.parse(ty.substring(1));
    if (to > from) {
      return _V(_val('${v.signed ? 'sext' : 'zext'} ${v.ty} ${v.v} to $ty'), ty, v.signed);
    }
    return _V(_val('trunc ${v.ty} ${v.v} to $ty'), ty, v.signed);
  }

  bool _isFloatTy(String ty) => ty == 'float' || ty == 'double';

  /// [v] converted between integer and floating-point types (an integer by
  /// its signedness; a float to an integer toward zero).
  _V _convFloat(_V v, String ty) {
    if (_isFloatTy(v.ty) && _isFloatTy(ty)) {
      return _V(_val('${ty == 'double' ? 'fpext' : 'fptrunc'} ${v.ty} ${v.v} to $ty'), ty);
    }
    if (_isFloatTy(ty)) {
      final iv = v.isPtr ? _conv(v, 'i64') : v;
      return _V(_val('${iv.signed ? 'sitofp' : 'uitofp'} ${iv.ty} ${iv.v} to $ty'), ty);
    }
    if (ty == 'ptr') return _conv(_convFloat(v, 'i64'), 'ptr');
    return _V(_val('fptosi ${v.ty} ${v.v} to $ty'), ty, true);
  }

  /// A floating-point constant of LLVM type [ty]: the bits of a double, as
  /// LLVM writes them (an f32 is rounded first).
  String _fpLit(double v, String ty) {
    final d = ty == 'float' ? (Float32List(1)..[0] = v)[0] : v;
    final bits = (ByteData(8)..setFloat64(0, d)).getUint64(0);
    final hex = BigInt.from(bits).toUnsigned(64).toRadixString(16);
    return '0x${hex.padLeft(16, '0').toUpperCase()}';
  }

  /// The zero of LLVM type [ty].
  String _zeroOf(String ty) => ty == 'ptr' ? 'null' : (_isFloatTy(ty) ? '0.0' : '0');

  /// Loads a value of [tName] from [ptr]. A record stored in place gives
  /// its address.
  _V _load(String ptr, Object? tName, bool isPtr, {bool volatile = false}) {
    if (_isStorageRecord(tName, isPtr)) return _V(ptr, 'ptr');
    final st = _storeTy(tName, isPtr);
    final vol = volatile ? 'volatile ' : '';
    final raw = _val('load $vol$st, ptr $ptr');
    final signed = _isSignedName(cleanName(tName)) && !isPtr;
    if (st == 'i8' || st == 'i16') {
      return _V(_val('${signed ? 'sext' : 'zext'} $st $raw to i32'), 'i32', signed);
    }
    return _V(raw, st, signed);
  }

  /// Stores [v] as a value of [tName] at [ptr].
  void _store(String ptr, _V v, Object? tName, bool isPtr, {bool volatile = false}) {
    final st = _storeTy(tName, isPtr);
    final vol = volatile ? 'volatile ' : '';
    if (cleanName(tName) == 'bool' && !isPtr) {
      final iv = _conv(v, v.isPtr ? 'i64' : v.ty);
      final b = _val('icmp ne ${iv.ty} ${iv.v}, 0');
      final z = _val('zext i1 $b to i8');
      _ins('store ${vol}i8 $z, ptr $ptr');
      return;
    }
    final cv = st == 'ptr' ? _conv(v, 'ptr') : _conv(v.isPtr ? _conv(v, 'i64') : v, st);
    _ins('store $vol$st ${cv.v}, ptr $ptr');
  }

  /// [v] as an i1 truth value.
  String _truth(_V v) {
    if (v.isPtr) return _val('icmp ne ptr ${v.v}, null');
    if (_isFloatTy(v.ty)) return _val('fcmp une ${v.ty} ${v.v}, 0.0');
    return _val('icmp ne ${v.ty} ${v.v}, 0');
  }

  _V _fromBool(String i1) => _V(_val('zext i1 $i1 to i32'), 'i32');

  /// Address [ptr] plus [bytes] (an i64 operand).
  String _offset(String ptr, String bytes) =>
      bytes == '0' ? ptr : _val('getelementptr inbounds i8, ptr $ptr, i64 $bytes');

  /// A pointer to a fixed address (an `@` variable or a memory built-in).
  String _addrPtr(String i64) => _val('inttoptr i64 $i64 to ptr');
}
