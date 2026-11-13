part of '../compiler.dart';

// ------------------------------------------------------------------------------
// LLVM generator: globals, functions, C functions and the run-time helpers
// ------------------------------------------------------------------------------

extension _LlvmFunctions on LlvmGen {
  /// The LLVM name of Action function [name].
  String _fnName(String name) => name == 'main' ? '@main' : '@"act.$name"';

  String _globalName(String name) => '@"act.$name"';

  // ------------------------------------------------------------ globals

  void _genGlobal(VarDeclNode d) {
    final name = _globalName(d.name);
    var dims = d.arrayDims;
    if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
      dims = [d.arrayDim!];
    }
    final cleanT = cleanName(d.typeName);
    final (line, _) = _lineCol(d.loc);
    final path = _locFile(d.loc) ?? 'main.act';
    String text;
    int diType;
    if (dims != null && dims.isNotEmpty) {
      final elem = d.isRefArray ? target.pointerSize : _getElemSize(d.typeName, d.isPtr);
      final size = dims.fold(elem, (a, b) => a * b);
      final align = structs.containsKey(cleanT) && !d.isPtr && !d.isRefArray
          ? structs[cleanT]!.align
          : target.alignOf(elem);
      final (ty, init) = _dataInit(d, size);
      text = '$name = internal ${d.isReadOnly ? 'constant' : 'global'} $ty $init, align $align';
      diType = _di.array(_diElement(d.typeName, d.isRefArray), elem, dims);
    } else if (structs.containsKey(cleanT) && !d.isPtr && !_globalRefs.contains(d.name)) {
      final info = structs[cleanT]!;
      final (ty, init) = _dataInit(d, info.size);
      text = '$name = internal global $ty $init, align ${info.align}';
      diType = _di.record(cleanT);
    } else {
      final isRef = d.isPtr || _globalRefs.contains(d.name);
      final st = _storeTy(d.typeName, isRef);
      String init;
      final fnInit = d.initExpr;
      if (st == 'ptr' && !isRef && fnTypes.containsKey(cleanT) && fnInit is VarAccessNode) {
        init = _fnName(fnInit.name);
      } else if (st == 'ptr') {
        init = 'null';
      } else if (d.initExpr == null) {
        init = _zeroOf(st);
      } else if (_isFloatTy(st)) {
        final f = _tryFloatConst(d.initExpr);
        init = _fpLit(f?.$1 ?? _constExact(d.initExpr).value.toDouble(), st);
      } else {
        var v = _constExact(d.initExpr).value;
        if (cleanT == 'bool') v = v == BigInt.zero ? BigInt.zero : BigInt.one;
        init = _intText(v, int.parse(st.substring(1)));
      }
      final align = st == 'ptr' || st == 'double' ? 8 : (st == 'float' ? 4 : int.parse(st.substring(1)) ~/ 8);
      text = '$name = internal global $st $init, align $align';
      diType = isRef && structs.containsKey(cleanT)
          ? _di.pointerTo(_di.record(cleanT))
          : (d.isPtr ? _di.pointerTo(_di.element(d.typeName, false)) : _di.scalar(d.typeName));
    }
    if (debugInfo) text += ', !dbg !${_di.global(d.name, path, line, diType)}';
    _globalIr.add(text);
  }

  /// The type and initial contents of global [d] ([size] bytes), as an
  /// LLVM constant: an array of bytes, or, when it holds function values,
  /// a packed structure of byte runs and the functions' addresses.
  (String, String) _dataInit(VarDeclNode d, int size) {
    final hasImage = d.initList != null || d.initExpr is StringLitNode;
    if (!hasImage) return ('[$size x i8]', 'zeroinitializer');
    final funcs = <int, String>{};
    final bytes = _initImage(d, size, funcs);
    String run(List<int> part) {
      final b = StringBuffer('c"');
      for (final x in part) {
        if (x >= 0x20 && x < 0x7F && x != 0x22 && x != 0x5C) {
          b.writeCharCode(x);
        } else {
          b.write('\\${x.toRadixString(16).padLeft(2, '0').toUpperCase()}');
        }
      }
      b.write('"');
      return b.toString();
    }
    if (funcs.isEmpty) return ('[$size x i8]', run(bytes));
    final types = <String>[];
    final values = <String>[];
    var at = 0;
    for (final off in funcs.keys.toList()..sort()) {
      if (off > at) {
        types.add('[${off - at} x i8]');
        values.add('[${off - at} x i8] ${run(bytes.sublist(at, off))}');
      }
      types.add('ptr');
      values.add('ptr ${_fnName(funcs[off]!)}');
      at = off + target.pointerSize;
    }
    if (at < size) {
      types.add('[${size - at} x i8]');
      values.add('[${size - at} x i8] ${run(bytes.sublist(at, size))}');
    }
    return ('<{ ${types.join(', ')} }>', '<{ ${values.join(', ')} }>');
  }

  /// The debug type of an element of an array of [tName]: for an array of
  /// references, a pointer.
  int _diElement(Object tName, bool refElems) {
    if (!refElems) return _di.element(tName, false);
    final t = cleanName(tName);
    return t == 'string' ? _di.scalar('string') : _di.pointerTo(_di.scalar(t));
  }

  /// [v] wrapped to [bits] bits, written as a signed decimal.
  String _intText(BigInt v, int bits) {
    final mod = BigInt.one << bits;
    var w = v % mod;
    if (w >= (mod >> 1)) w -= mod;
    return '$w';
  }

  // ------------------------------------------------------- C functions

  /// The C type of an `extern` parameter or result of type [t].
  String _cType(Object? t, bool isPtr, {bool withAttr = true}) {
    final c = cleanName(t);
    if (isPtr || c == 'string' || structs.containsKey(c) || fnTypes.containsKey(c)) return 'ptr';
    String attr(String a) => withAttr ? ' $a' : '';
    switch (c) {
      case 'void':
        return 'void';
      case 'bool':
        return 'i1${attr('zeroext')}';
      case 'u8':
        return 'i8${attr('zeroext')}';
      case 's8':
        return 'i8${attr('signext')}';
      case 'u16':
        return 'i16${attr('zeroext')}';
      case 's16':
        return 'i16${attr('signext')}';
      case 'u64':
      case 's64':
        return 'i64';
      case 'f32':
        return 'float';
      case 'f64':
        return 'double';
    }
    return 'i32';
  }

  void _declareExtern(FuncDeclNode f) {
    final params = [for (final p in f.params) _cType(p.type, p.isPtr)];
    if (f.isVariadic) params.add('...');
    _declare('declare ${_cType(f.retType, f.retPtr)} @${f.name}(${params.join(', ')})');
  }

  // --------------------------------------------------------- functions

  /// The LLVM result type of a function returning [retType].
  String _retType(Object retType, bool retPtr) {
    if (retType is List) {
      final elems = [
        for (final e in retType)
          if (e is (Object?, bool)) _regTy(e.$1, e.$2) else _regTy(e, false)
      ];
      return '{ ${elems.join(', ')} }';
    }
    final c = cleanName(retType);
    if (c == 'void' || c.isEmpty) return 'void';
    if (retPtr || structs.containsKey(c)) return 'ptr';
    return _regTy(c, false);
  }

  void _genFunction(FuncDeclNode func) {
    _globalScope?.restore(this);
    _func = func;
    currentFuncName = func.name;
    currentFuncRet = (cleanType(func.retType), func.retPtr);
    _body = [];
    _allocas = [];
    _slots.clear();
    _flows.clear();
    _tmpN = 0;
    _lblN = 0;
    _terminated = false;
    _curLoc = func.loc;
    locals = {};
    openArrays.clear();
    openRanks.clear();
    dynamicArrays.clear();
    borrowedParams.clear();
    affineState = {};

    final isMain = func.name == 'main';
    final ret = isMain ? 'i32' : _retType(func.retType, func.retPtr);
    _retTy = ret;
    final path = _locFile(func.loc) ?? 'main.act';
    final (line, _) = _lineCol(func.loc);
    _scope = debugInfo ? _di.subprogram(_displayName(func), path, line) : null;
    _subprogram = _scope;
    _blockOf.clear();
    _declScope.clear();
    _diBlocks.clear();
    void mapScopes(LocalScope s) {
      if (s.opener != null) _blockOf[s.opener!] = s;
      for (final d in s.decls) {
        _declScope[d] = s;
      }
      s.children.forEach(mapScopes);
    }

    if (func.scopes != null) mapScopes(func.scopes!);

    // Parameters: each gets a slot
    final sigParams = <String>[];
    var argNo = 0;
    for (final p in func.params) {
      final cleanPt = cleanName(p.type);
      final isRef = (structs.containsKey(cleanPt) && !p.isPtr) || p.isOpenArr;
      types[p.name] = TypeInfo(p.type, p.isPtr, isRef, p.isRefArray);
      borrowedParams.add(p.name);
      locals[p.name] = 0;
      argNo++;
      if (p.isOpenArr) {
        openArrays.add(p.name);
        locals[lenName(p.name)] = 0;
        if (isMain) {
          // The command line: C's argc and argv
          sigParams.add('i32 %a.${p.name}.len');
          sigParams.add('ptr %a.${p.name}');
        } else {
          sigParams.add('ptr %a.${p.name}');
          sigParams.add('i32 %a.${p.name}.len');
        }
        _paramSlot(p.name, 'ptr', '%a.${p.name}', _diParam(p, argNo, path, line));
        _paramSlot(lenName(p.name), 'i32', '%a.${p.name}.len', null);
        if (p.openRank > 1) openRanks[p.name] = p.openRank;
        for (var k = 1; k < p.openRank; k++) {
          locals[lenName(p.name, k)] = 0;
          sigParams.add('i32 %a.${p.name}.len$k');
          _paramSlot(lenName(p.name, k), 'i32', '%a.${p.name}.len$k', null);
        }
      } else {
        final ty = isRef ? 'ptr' : _regTy(p.type, p.isPtr);
        sigParams.add('$ty %a.${p.name}');
        // The slot holds the value as stored (a u8 in one byte)
        final st = isRef ? 'ptr' : _storeTy(p.type, p.isPtr);
        final slot = _newSlot(p.name, st);
        _storeParam(slot, ty, st, '%a.${p.name}', cleanPt == 'bool' && !p.isPtr);
        _declareVar(slot, _diParam(p, argNo, path, line));
      }
    }

    _enterFunctionScope(func);
    final decls = <VarDeclNode>[];
    _collectLocalDecls(func.body, decls);
    final funcRefs = _functionRefs[func.name] ?? const <String>{};
    for (final d in decls) {
      _declareLocal(funcRefs, d);
      locals[d.name] = 0;
      _localSlot(d, path);
    }

    currentFuncIsTask = func.isTask;
    if (func.isTask) _genTaskDispatch(func);

    _genBlock(func.body!);

    if (func.isTask) {
      _startBlock('task.end');
      _setTaskStep(func, 0);
      _terminator('ret i32 ${_pkStatus('PK_ENDED')}');
    }
    if (!_terminated) _terminator(_defaultReturn());

    final linkage = isMain ? '' : 'internal ';
    final attrs = func.isInline ? '#1' : '#0';
    final dbg = _subprogram != null ? ' !dbg !$_subprogram' : '';
    _funcIr.add('; Function: ${_displayName(func)}');
    _funcIr.add('define $linkage$ret ${_fnName(func.name)}(${sigParams.join(', ')}) $attrs$dbg {');
    _funcIr.add('entry:');
    _funcIr.addAll(_allocas);
    _funcIr.addAll(_body);
    _funcIr.add('}');
    _funcIr.add('');
    _scope = null;
    _subprogram = null;
    _func = null;
  }

  String _defaultReturn() {
    if (_retTy == 'void') return 'ret void';
    if (_retTy == 'ptr') return 'ret ptr null';
    if (_retTy.startsWith('{')) return 'ret $_retTy zeroinitializer';
    return 'ret $_retTy ${_zeroOf(_retTy)}';
  }

  int? _diParam(Param p, int arg, String path, int line) {
    if (!debugInfo || _scope == null) return null;
    final t = types[p.name]!;
    final int ty;
    if (p.isOpenArr) {
      ty = _di.pointerTo(_diElement(p.type, p.isRefArray));
    } else if (t.isRef) {
      ty = _di.pointerTo(_di.scalar(p.type));
    } else {
      ty = _di.scalar(p.type);
    }
    return _di.variable(p.name, _scope!, path, _lineCol(p.loc ?? _func?.loc).$1, ty, arg: arg);
  }

  /// A stack slot of LLVM type [ty] for variable [name].
  String _newSlot(String name, String ty, {int? align}) {
    final slot = '%v.${name.replaceAll(internalNameMark, '.')}.${_slots.length}';
    _allocas.add('  $slot = alloca $ty${align != null ? ', align $align' : ''}');
    _slots[name] = slot;
    return slot;
  }

  void _paramSlot(String name, String ty, String value, int? diVar) {
    final slot = _newSlot(name, ty);
    _allocas.add('  store $ty $value, ptr $slot');
    _declareVar(slot, diVar);
  }

  void _storeParam(String slot, String ty, String st, String value, bool isBool) {
    if (st == ty) {
      _allocas.add('  store $ty $value, ptr $slot');
    } else if (isBool) {
      final n = '%b.${slot.substring(1)}';
      _allocas.add('  $n = icmp ne $ty $value, 0');
      _allocas.add('  $n.z = zext i1 $n to i8');
      _allocas.add('  store i8 $n.z, ptr $slot');
    } else {
      final n = '%c.${slot.substring(1)}';
      _allocas.add('  $n = trunc $ty $value to $st');
      _allocas.add('  store $st $n, ptr $slot');
    }
  }

  /// The location of the function's first line, for code in its entry.
  String _entryDbg() {
    if (_scope == null) return '';
    final (line, col) = _lineCol(_func?.loc);
    return ', !dbg !${_di.location(line, col, _scope!)}';
  }

  void _declareVar(String slot, int? diVar, {int? scope}) {
    if (diVar == null || _scope == null) return;
    _declare('declare void @llvm.dbg.declare(metadata, metadata, metadata)');
    final (line, col) = _lineCol(_func?.loc);
    _allocas.add('  call void @llvm.dbg.declare(metadata ptr $slot, metadata !$diVar, '
        'metadata !${_di.expression()}), !dbg !${_di.location(line, col, scope ?? _scope!)}');
  }

  /// The debug scope of block [s]: a lexical block, or for the outermost
  /// block (and a `switch` case) the scope around it.
  int _diScopeOf(LocalScope? s) {
    if (s == null || s.parent == null) return _subprogram!;
    if (s.isCase) return _diScopeOf(s.parent);
    return _diBlocks.putIfAbsent(s, () {
      final parent = _diScopeOf(s.parent);
      final loc = s.opener?.loc ?? _func?.loc;
      final (line, col) = _lineCol(loc);
      return _di.lexicalBlock(parent, _locFile(loc) ?? 'main.act', line, col);
    });
  }

  /// A zeroed stack slot for local [d].
  void _localSlot(VarDeclNode d, String path) {
    final t = types[d.name]!;
    final cleanT = cleanName(d.typeName);
    var dims = d.arrayDims;
    if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
      dims = [d.arrayDim!];
    }
    String slot;
    int? diType;
    if (dims != null && dims.isNotEmpty) {
      final elem = d.isRefArray ? target.pointerSize : _getElemSize(d.typeName, d.isPtr);
      final size = dims.fold(elem, (a, b) => a * b);
      final align = structs.containsKey(cleanT) && !d.isPtr && !d.isRefArray
          ? structs[cleanT]!.align
          : target.alignOf(elem);
      slot = _newSlot(d.name, '[$size x i8]', align: align);
      _slotInfo[d.name] = ('[', size);
      _zero(slot, size);
      if (debugInfo) diType = _di.array(_diElement(d.typeName, d.isRefArray), elem, dims);
    } else if (_isStorageRecord(d.typeName, d.isPtr) && !t.isRef) {
      final info = structs[cleanT]!;
      slot = _newSlot(d.name, '[${info.size} x i8]', align: info.align);
      _slotInfo[d.name] = ('[', info.size);
      _zero(slot, info.size);
      if (debugInfo) diType = _di.record(cleanT);
    } else {
      final st = _storeTy(d.typeName, d.isPtr || t.isRef);
      slot = _newSlot(d.name, st);
      _slotInfo[d.name] = (st, 0);
      _allocas.add('  store $st ${_zeroOf(st)}, ptr $slot');
      if (debugInfo) {
        diType = t.isRef
            ? _di.pointerTo(_di.record(cleanT))
            : (d.isPtr ? _di.pointerTo(_di.element(d.typeName, false)) : _di.scalar(d.typeName));
      }
    }
    if (debugInfo && _scope != null && !d.name.endsWith('~end')) {
      final line = _lineCol(d.loc ?? _func?.loc).$1;
      final scope = _diScopeOf(_declScope[d]);
      _declareVar(slot, _di.variable(d.name, scope, path, line, diType!), scope: scope);
    }
  }

  void _zero(String slot, int size) {
    _declare('declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)');
    _allocas.add('  call void @llvm.memset.p0.i64(ptr align 1 $slot, i8 0, i64 $size, i1 false)${_entryDbg()}');
  }

  // --------------------------------------------------------------- tasks

  /// The entry of a task: continue where it left off, from `t.lc`.
  void _genTaskDispatch(FuncDeclNode func) {
    final steps = <(int, AstNode)>[];
    _collectCoroutineSteps(func.body!, steps);
    final state = _load(_slots[func.params.first.name]!, 'ptr', true);
    final lc = _val('load i16, ptr ${state.v}');
    final cases = <String>[];
    final seen = <int>{};
    for (final (n, _) in steps) {
      if (seen.add(n)) cases.add('i16 $n, label %step.$n');
    }
    _terminator('switch i16 $lc, label %step.0 [ ${cases.join(' ')} ]');
    _body.add('step.0:');
    _terminated = false;
  }

  void _setTaskStep(FuncDeclNode func, int step) {
    final state = _load(_slots[func.params.first.name]!, 'ptr', true);
    _ins('store i16 $step, ptr ${state.v}');
  }

  // ------------------------------------------------------------- runtime

  /// The helpers run-time checks call: print a message, exit with 15.
  void _genRuntime() {
    _declare('declare i32 @dprintf(i32, ptr, ...)');
    _declare('declare void @exit(i32) #2');
    final msgs = {
      'index': 'action: index %u is out of range for \'%s\' (length %u) at %s\n',
      'null': 'action: null reference in %s at %s\n',
      'oom': 'action: out of memory at %s\n',
    };
    final g = <String, String>{};
    msgs.forEach((k, m) => g[k] = _stringConst(m));
    _funcIr.addAll([
      'define internal void @act.fail.index(i32 %i, ptr %what, i32 %len, ptr %where) #2 {',
      '  %r = call i32 (i32, ptr, ...) @dprintf(i32 2, ptr ${g['index']}, i32 %i, ptr %what, i32 %len, ptr %where)',
      '  call void @exit(i32 15)',
      '  unreachable',
      '}',
      '',
      'define internal void @act.fail.null(ptr %what, ptr %where) #2 {',
      '  %r = call i32 (i32, ptr, ...) @dprintf(i32 2, ptr ${g['null']}, ptr %what, ptr %where)',
      '  call void @exit(i32 15)',
      '  unreachable',
      '}',
      '',
      'define internal void @act.fail.oom(ptr %where) #2 {',
      '  %r = call i32 (i32, ptr, ...) @dprintf(i32 2, ptr ${g['oom']}, ptr %where)',
      '  call void @exit(i32 15)',
      '  unreachable',
      '}',
      '',
    ]);
  }

  /// `@act.strcopy(dst, src, cap)`: copies a string into a buffer of cap
  /// bytes, at most cap - 1 characters and a terminator.
  void _genStrCopy() {
    _funcIr.addAll([
      'define internal void @act.strcopy(ptr %dst, ptr %src, i32 %cap) #0 {',
      'entry:',
      '  %room = sub i32 %cap, 1',
      '  br label %loop',
      'loop:',
      '  %i = phi i32 [ 0, %entry ], [ %next, %body ]',
      '  %full = icmp uge i32 %i, %room',
      '  br i1 %full, label %done, label %check',
      'check:',
      '  %sp = getelementptr inbounds i8, ptr %src, i32 %i',
      '  %c = load i8, ptr %sp',
      '  %end = icmp eq i8 %c, 0',
      '  br i1 %end, label %done, label %body',
      'body:',
      '  %dp = getelementptr inbounds i8, ptr %dst, i32 %i',
      '  store i8 %c, ptr %dp',
      '  %next = add i32 %i, 1',
      '  br label %loop',
      'done:',
      '  %tp = getelementptr inbounds i8, ptr %dst, i32 %i',
      '  store i8 0, ptr %tp',
      '  ret void',
      '}',
      '',
    ]);
  }

  /// A private constant holding [s] with its terminator; returns its name.
  String _stringConst(String s) {
    final key = s;
    final existing = _stringLits[key];
    if (existing != null) return existing.substring(0, existing.indexOf(' '));
    final name = '@.str.${_stringLits.length}';
    final bytes = <int>[...s.codeUnits, 0];
    final text = StringBuffer();
    for (final b in bytes) {
      if (b >= 32 && b < 127 && b != 34 && b != 92) {
        text.writeCharCode(b);
      } else {
        text.write('\\${(b & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    _stringLits[key] = '$name = private unnamed_addr constant [${bytes.length} x i8] c"$text", align 1';
    return name;
  }

  /// Calls a run-time failure helper: it does not return.
  void _fail(String kind, List<String> args) {
    _runtimeUsed = true;
    _ins('call void @act.fail.$kind(${args.join(', ')})');
    _terminator('unreachable');
  }

  /// Exits with 15 when [i1] (an i1) is false.
  void _failUnless(String i1, String kind, List<String> args) {
    final ok = _newBlock('ok');
    final bad = _newBlock('fail');
    _terminator('br i1 $i1, label %$ok, label %$bad');
    _body.add('$bad:');
    _terminated = false;
    _fail(kind, args);
    _body.add('$ok:');
    _terminated = false;
  }

  /// With reference checks on: exits with 15 when [ptr] is null.
  void _nullCheck(String ptr, String what) {
    if (!referenceCheck) return;
    final ok = _val('icmp ne ptr $ptr, null');
    _failUnless(ok, 'null', ['ptr ${_stringConst(what)}', 'ptr ${_stringConst(_where)}']);
  }

  /// With bounds checks on: exits with 15 unless [idx] < [len] (unsigned).
  void _boundsCheck(_V idx, _V len, String what) {
    if (!boundsCheck) return;
    final i = _conv(idx, 'i32');
    final l = _conv(len, 'i32');
    final ok = _val('icmp ult i32 ${i.v}, ${l.v}');
    _failUnless(ok, 'index',
        ['i32 ${i.v}', 'ptr ${_stringConst(what)}', 'i32 ${l.v}', 'ptr ${_stringConst(_where)}']);
  }

  /// Exits with 15 when an allocation gave null (always: there is nothing
  /// to continue with).
  void _allocCheck(String ptr) {
    final ok = _val('icmp ne ptr $ptr, null');
    _failUnless(ok, 'oom', ['ptr ${_stringConst(_where)}']);
  }
}
