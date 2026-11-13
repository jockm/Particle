part of '../compiler.dart';

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


class CodeGen extends Checker {
  final bool boundsCheck;

  /// Run-time null checks on references held in globals, and on allocation.
  final bool referenceCheck;
  final Backend backend;
  int stackOffset = 0;

  /// The bytes of the frame each local has (see [_allocateLocalFrame]).
  final Map<String, int> _localBytes = {};
  final List<(String, String)> strings = [];
  final List<String> breakStack = [];

  /// Innermost-last stack of loops and switches, for `continue`.

  CodeGen(
      {bool boundsCheck = true,
      bool referenceCheck = true,
      Backend? backend,
      Map<String, int> predefinedConstants = const {}})
      : this._(backend ?? ParticleAsmBackend(), boundsCheck, referenceCheck,
            predefinedConstants);

  CodeGen._(this.backend, this.boundsCheck, this.referenceCheck,
      Map<String, int> predefinedConstants)
      : super(backend, predefinedConstants: predefinedConstants) {
    backend.referenceCheck = referenceCheck;
  }

  List<String> get asm => backend.asm;

  void emit(String line, [String comment = '']) => backend.emit(line, comment);

  void emitLabel(String label) => backend.emitLabel(label);

  String newLabel([String prefix = 'L']) => backend.newLabel(prefix);

  void emitImmediate(int reg, int val) => backend.emitImmediate(reg, val);

  /// [emitImmediate] for use while R14 holds a live value.
  void emitImmediateKeepR14(int reg, int val) =>
      backend.emitImmediateKeepR14(reg, val);


  void _emitStringInit(String name, StringLitNode initExpr) {
    final rawStr = initExpr.val;
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

  /// Checks [root] (throwing the first error) and generates the complete
  /// assembly program for it.
  String generate(ProgramNode root) {
    asm.add(
        '; ==============================================================================');
    asm.add('; Compiled from Action source by action');
    asm.add('; Target Architecture: Particle 32-bit RISC');
    asm.add(
        '; ==============================================================================\n');
    asm.add('.include "lib/common.inc"\n');

    // Check the whole program first; then put the program-level state
    // back as it was before the functions were checked, since code
    // generation walks them again in the same order
    _prepare(root);
    final scope = _ScopeSnapshot(this);
    _checkProgramBody();
    scope.restore(this);
    final funcDecls = _funcDecls;
    final dataDecls = _dataDecls;

    if (_funcDecls.any((f) => f.name == 'main')) {
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
        final handler = _trapHandlers[v];
        if (handler != null) {
          emit('RCALL   _$handler', 'Trap $v handler');
        }
        emit('FAST_EXIT_TRAP');
        emit('.align  ${backend.vectorStride}');
        asm.add('');
      }
    }

    for (final f in funcDecls) {
      if (!f.isInline && f.body != null) genFunc(f);
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
        var dims = d.arrayDims;
        if ((dims == null || dims.isEmpty) && d.arrayDim != null && d.arrayDim != 0) {
          dims = [d.arrayDim!];
        }
        if (d.isReadOnly) asm.add("; constant table '${d.name}' (read-only)");
        emitLabel('_${d.name}');
        final hasImage = d.initList != null ||
            (d.initExpr is StringLitNode && dims != null && dims.isNotEmpty);
        if (hasImage) {
          final cleanT = cleanName(d.typeName);
          var size = dims == null || dims.isEmpty
              ? structs[cleanT]!.size
              : dims.fold(_getElemSize(d.typeName, false), (a, b) => a * b);
          final bytes = _initImage(d, size);
          while (bytes.length % 4 != 0) {
            bytes.add(0);
          }
          for (var i = 0; i < bytes.length; i += 4) {
            final w = bytes[i] | bytes[i + 1] << 8 | bytes[i + 2] << 16 | bytes[i + 3] << 24;
            emit('.word   0x${w.toRadixString(16).padLeft(8, '0').toUpperCase()}');
          }
          continue;
        }
        if (dims != null && dims.isNotEmpty) {
          final gT = cleanName(d.typeName);
          final elemSz = d.isRefArray
              ? backend.pointerSize
              : ['u8', 's8', 'bool', 'string'].contains(gT)
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
            final words = (structs[cleanT]!.size + 3) ~/ 4;
            for (var i = 0; i < words; i++) {
              emit('.word   0');
            }
            continue;
          }
          if (init is IntLitNode) {
            emit('.word   ${init.val}');
          } else if (init != null) {
            emit('.word   ${_evalConstExpr(init)}');
          } else {
            emit('.word   0');
          }
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
  ///
  /// A block's locals come after those of the blocks around it, and blocks
  /// side by side (which never run at the same time) share the same words,
  /// so the frame is as big as the deepest set of blocks.
  int _allocateLocalFrame(String funcName, LocalScope? scopes) {
    final funcRefs = _functionRefs[funcName] ?? const <String>{};
    final base = stackOffset;
    int layout(LocalScope scope, int start) {
      var end = start;
      for (final d in scope.decls) {
        final words = (_declareLocal(funcRefs, d) + 3) ~/ 4;
        end += words * 4;
        locals[d.name] = base + end;
        _localBytes[d.name] = words * 4;
      }
      var deepest = end;
      for (final c in scope.children) {
        final e = layout(c, end);
        if (e > deepest) deepest = e;
      }
      return deepest;
    }

    final totalFrameWords = scopes == null ? 0 : layout(scopes, 0) ~/ 4;
    stackOffset += totalFrameWords * 4;

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

  /// Clears the words of local [name] (a declaration in an inner block).
  void _clearLocal(String name) {
    final words = (_localBytes[name] ?? 4) ~/ 4;
    final offset = stackOffset - locals[name]!;
    emitImmediate(14, offset);
    emit('ADD     R14, R15', "Clear '$name'");
    if (words <= 4) {
      for (var w = 0; w < words; w++) {
        if (w > 0) emit('ADD     R14, 4');
        emit('ST32    (R14), R0');
      }
    } else {
      final lbl = newLabel('local_clr');
      emitImmediate(13, words);
      emitLabel(lbl);
      emit('ST32    (R14), R0', 'Clear word');
      emit('ADD     R14, 4');
      emit('SUB     R13, 1');
      emit('BBRA.NZ R13, $lbl');
    }
  }

  void genFunc(FuncDeclNode func) {
    // Every function starts from the program's global scope
    _globalScope?.restore(this);
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
      if (func.params.isNotEmpty) {
        // There is no command line: 'args' is empty
        emit('LD      R1, 0', 'args: no strings');
        emit('LD      R2, 0', 'args.len = 0');
      }
    } else {
      emit('PUSH32  R14', 'Preserve return address link');
      stackOffset = 4;
    }

    openArrays.clear();
    dynamicArrays.clear();
    borrowedParams.clear();
    openRanks.clear();
    affineState = {};
    var rIdx = 1;
    for (final p in func.params) {
      final pType = p.type;
      final pPtr = p.isPtr;
      final pName = p.name;
      final isOpenArr = p.isOpenArr;
      final cleanPt = cleanName(pType);
      final isRef = (structs.containsKey(cleanPt) && !pPtr) || isOpenArr;
      types[pName] = TypeInfo(pType, pPtr, isRef, p.isRefArray);
      borrowedParams.add(pName);
      if (isOpenArr) {
        openArrays.add(pName);
        _bindParamSlot(rIdx, pName, "Spill open array ptr '$pName'");
        rIdx++;
        _bindParamSlot(rIdx, '${pName}__len', "Spill open array len '$pName'");
        rIdx++;
        if (p.openRank > 1) openRanks[pName] = p.openRank;
        for (var k = 1; k < p.openRank; k++) {
          _bindParamSlot(rIdx, '${pName}__len$k', "Spill open array len $k of '$pName'");
          rIdx++;
        }
      } else {
        _bindParamSlot(rIdx, pName, "Spill param '$pName'");
        rIdx++;
      }
    }

    // Local constants may size local arrays: work the dimensions out first
    _enterFunctionScope(func);

    // Allocate the function's local stack frame
    _allocateLocalFrame(func.name, func.scopes);

    final coroSteps = <(int, AstNode)>[];
    if (func.body != null) {
      _collectCoroutineSteps(func.body!, coroSteps);
    }

    // A task dispatches on its state's continuation counter
    currentFuncIsTask = func.isTask;
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
    _enterBlock();
    for (final stmt in block.stmts) {
      genStmt(stmt);
    }
    _leaveBlock();
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
