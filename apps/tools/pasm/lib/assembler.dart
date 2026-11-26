// =============================================================================
// File: apps/tools/pasm/lib/assembler.dart
// Project: Particle RISC Architecture
// Description: Two-pass instruction encoder and .lst listing generator.
//
// Matches exact behavior of tools/pasm.py:ParticleAssembler:
//   - Pass 1: Address calculation, label resolution, data sizing (.word, .asciz)
//   - Pass 2: 16-bit instruction encoding, memory layout, and listing formatting
//   - Encoding: Full coverage of loads, stores, math, bit ops, branches, and FIFOs
// =============================================================================

import 'isa.dart';
import 'preprocessor.dart';

/// Two-pass assembler for the Particle 32-bit RISC architecture (16-bit compact instructions).
class ParticleAssembler {
  final Preprocessor prep;

  /// Global symbol table mapping labels to absolute byte addresses.
  final Map<String, int> symbols = {};

  /// Current Program Counter tracking byte address (defaults to 0x00000100).
  int pc = 0;

  /// Symbol defined by the assembler after laying out all source files: the
  /// first free byte past everything assembled, aligned to 4. The Action
  /// runtime allocator (lib/alloc.asm) starts the heap there, so no code or
  /// data from any input file lies inside the heap.
  static const String imageEndSymbol = '__image_end';

  ParticleAssembler(this.prep);

  /// Defined (by pasm's --no-long-branches, or -D) when the code is for a
  /// core without the 2-word PC-relative instructions: they are rejected,
  /// JUMP and JUMP.cc use the forms without them, and lib/common.inc's
  /// RCALL uses LDI and JMP.
  static const noLongBranchesSymbol = '__NO_LONG_BRANCHES';

  /// Whether the 2-word PC-relative instructions may be used.
  bool get longBranches => !prep.defines.containsKey(noLongBranchesSymbol);

  /// The 2-word instructions with a fixed size.
  static const twoWordMnemonics = {
    'LDI', 'LDIS', 'LEA', 'BRA', 'BRA.Z', 'BRA.NZ', 'BRA.N', 'BRA.P',
    'BEQ', 'BNE',
  };

  /// JUMP and JUMP.Z/.NZ/.N/.P: their size depends on the distance.
  static bool isSizedJump(String mnem) =>
      mnem == 'JUMP' || const {'JUMP.Z', 'JUMP.NZ', 'JUMP.N', 'JUMP.P'}.contains(mnem);

  /// The bytes of an instruction line (without its labels) that isn't a
  /// sized JUMP.
  int _instBytes(String line) {
    final tokens = line.split(RegExp(r'\s+'));
    final mnem = tokens[0].toUpperCase();
    if (twoWordMnemonics.contains(mnem)) return 4;
    // BEXTR Rr, Rl is 1 word; BEXTR Rr, Rl, pos, len and SBEXTR are 2
    if (mnem == 'SBEXTR') return 4;
    if (mnem == 'BEXTR') {
      return line.substring(tokens[0].length).split(',').length > 2 ? 4 : 2;
    }
    if (mnem == 'RJUMP') {
      // RJUMP Rr, Rl is 1 word; RJUMP label, Rl is 2
      final first = line.substring(tokens[0].length).split(',')[0].trim();
      return regMap.containsKey(first.toLowerCase()) ? 2 : 4;
    }
    return 2;
  }

  /// Resolves a register token (e.g. "R0", "r14", "sp") to its 4-bit index.
  int parseReg(String token, String fname, int lno) {
    final t = token.trim().toLowerCase();
    if (regMap.containsKey(t)) {
      return regMap[t]!;
    }
    throw AssemblerError("Unknown register '$token'", fname, lno, 'register');
  }

  /// Parses memory operands enclosed in parentheses: `(Rr)`
  /// Supports Particle indirect addressing modes:
  ///   - `standard`: `(Rr)`
  ///   - `pre_inc`:  `(++Rr)`
  ///   - `post_inc`: `(Rr++)`
  ///   - `pre_dec`:  `(--Rr)`
  ///   - `post_dec`: `(Rr--)`
  (int, String)? parseMemOperand(String opStr, String fname, int lno) {
    final s = opStr.trim();
    if (!s.startsWith('(') || !s.endsWith(')')) return null;

    final inner = s.substring(1, s.length - 1).trim();
    String mode = 'standard';
    String regName = inner;

    if (inner.startsWith('++')) {
      mode = 'pre_inc';
      regName = inner.substring(2).trim();
    } else if (inner.startsWith('--')) {
      mode = 'pre_dec';
      regName = inner.substring(2).trim();
    } else if (inner.endsWith('++')) {
      mode = 'post_inc';
      regName = inner.substring(0, inner.length - 2).trim();
    } else if (inner.endsWith('--')) {
      mode = 'post_dec';
      regName = inner.substring(0, inner.length - 2).trim();
    }

    final r = parseReg(regName, fname, lno);
    return (r, mode);
  }

  /// Main two-pass assembly routine.
  /// Returns a tuple containing:
  ///   - Sparse memory map of emitted byte addresses to byte values
  ///   - Maximum emitted byte address
  ///   - Formatted `.lst` listing lines
  /// Main two-pass assembly routine.
  /// Accepts either a single file path (`String`) or multiple file paths (`List<String>`).
  /// Returns a tuple containing:
  ///   - Sparse memory map of emitted byte addresses to byte values
  ///   - Maximum emitted byte address
  ///   - Formatted `.lst` listing lines
  (Map<int, int>, int, List<String>) assemble(dynamic srcFiles) {
    _at = null;
    _errors.clear();
    _truncated = false;
    final (Map<int, int>, int, List<String>) result;
    try {
      result = _assemble(srcFiles);
    } on AssemblerError catch (e) {
      final at = _at;
      throw at == null ? e : _place(e, at);
    }
    if (_errors.isNotEmpty) throw AssemblerErrors(List.of(_errors), _truncated);
    return result;
  }

  /// The line being assembled, whose place an error raised without one
  /// takes.
  SourceLine? _at;

  /// The errors pass 2 found, and whether it stopped at [maxErrors].
  final List<AssemblerError> _errors = [];
  bool _truncated = false;

  /// Pass 2 stops after this many errors. A symbol already reported as
  /// undefined does not count again.
  static const maxErrors = 20;

  /// [e] placed at [line], with the macros [line] came from, when it has no
  /// place of its own or is at that line.
  AssemblerError _place(AssemblerError e, SourceLine line) {
    if (e.lineno == null || (e.filename == line.$1 && e.lineno == line.$2 && e.trace.isEmpty)) {
      return e.at(line.$1, line.$2, line.$4);
    }
    return e;
  }

  /// Records a pass 2 error; false once there are too many.
  bool _record(AssemblerError e) {
    final repeat = e.code == 'undefined-symbol' &&
        e.symbol != null &&
        _errors.any((o) => o.code == 'undefined-symbol' && o.symbol == e.symbol);
    _errors.add(e);
    final counted = <String>{};
    var n = 0;
    for (final o in _errors) {
      if (o.code == 'undefined-symbol' && o.symbol != null && !counted.add(o.symbol!)) continue;
      n++;
    }
    if (!repeat && n >= maxErrors) {
      _truncated = true;
      return false;
    }
    return true;
  }

  (Map<int, int>, int, List<String>) _assemble(dynamic srcFiles) {
    final List<String> fileList = (srcFiles is List<String>)
        ? srcFiles
        : (srcFiles is List)
            ? srcFiles.map((e) => e.toString()).toList()
            : [srcFiles.toString()];

    final processedLines = <SourceLine>[];
    for (final f in fileList) {
      processedLines.addAll(prep.process(f));
    }

    // -------------------------------------------------------------------------
    // PASS 1: Symbol Calculation & Address Resolution
    // -------------------------------------------------------------------------
    // A JUMP's size depends on how far its target is, and the addresses
    // depend on the sizes, so pass 1 repeats until no JUMP needs to grow.
    // JUMPs start at their shortest form and only ever grow, so this ends.
    _jumpSizes.clear();
    var imageEnd = 0;
    for (var round = 0;; round++) {
      final jumpAddrs = <int, int>{};
      imageEnd = _pass1(processedLines, jumpAddrs);
      var grew = false;
      for (final j in jumpAddrs.entries) {
        final jump = _tryJump(processedLines[j.key].$3);
        if (jump == null) continue;
        final need = jumpSize(jump.$1, jump.$2, j.value, jump.$3);
        if (need > (_jumpSizes[j.key] ?? 2)) {
          _jumpSizes[j.key] = need;
          grew = true;
        }
      }
      if (!grew) break;
      if (round > 1000) {
        throw AssemblerError('JUMP sizes did not settle', null, null, 'jump');
      }
    }

    // End of the whole image, across all source files, aligned to 4
    symbols[imageEndSymbol] = (imageEnd + 3) & ~3;

    // -------------------------------------------------------------------------
    // PASS 2: Code Emission, Word Assembly & Listing Formatting
    // -------------------------------------------------------------------------
    pc = 0x00000100;
    final binaryData = <int, int>{};
    final listingLines = <String>[];
    int maxAddr = pc;

    for (var index = 0; index < processedLines.length; index++) {
      final entry = processedLines[index];
      final fname = entry.$1;
      final lno = entry.$2;
      final origLine = entry.$3;
      var line = origLine;
      _at = entry;

      // Emit standalone label entries in listing output, with their address
      while (true) {
        final (lbl, rest) = splitLabel(line);
        if (lbl == null) break;
        if (lbl.isNotEmpty) {
          final addr = symbols[lbl] ?? pc;
          listingLines.add(
              '${addr.toRadixString(16).padLeft(8, '0').toUpperCase()}         $lbl:');
        }
        line = rest;
      }

      if (line.isEmpty) continue;

      final startPc = pc;
      final emittedBytes = <int>[];

      /// Writes byte [b] at the PC; an address already written is an error.
      void emit(int b) {
        if (binaryData.containsKey(pc)) {
          throw AssemblerError(
              'overlaps bytes already emitted at 0x${pc.toRadixString(16).toUpperCase().padLeft(8, '0')}',
              fname, lno, 'overlap');
        }
        binaryData[pc] = b;
        emittedBytes.add(b);
        pc += 1;
      }

      /// [expr] as a value from [lo] to [hi], for directive [d].
      int dataValue(String expr, int lo, int hi, String d) {
        final v = prep.parseExpr(expr, symbols);
        if (v < lo || v > hi) {
          throw AssemblerError('$d value $v out of range ($lo..$hi)', fname, lno, 'range');
        }
        return v;
      }

      // An error is recorded and the line takes the room pass 1 gave it,
      // so the lines after it keep their addresses
      try {
        if (line.startsWith('.')) {
          final parts = line.split(RegExp(r'\s+'));
          final d = parts[0].toLowerCase();
          final arg =
              parts.length > 1 ? line.substring(parts[0].length).trim() : '';

          if (d == '.org') {
            pc = prep.parseExpr(arg, symbols);
          } else if (d == '.align') {
            final boundary = prep.parseExpr(arg, symbols);
            final rem = pc % boundary;
            if (rem != 0) {
              final pad = boundary - rem;
              for (int i = 0; i < pad; i++) {
                emit(0);
              }
            }
          } else if (d == '.byte') {
            for (final b in arg.split(',')) {
              emit(dataValue(b, -128, 255, '.byte') & 0xFF);
            }
          } else if (d == '.half') {
            for (final h in arg.split(',')) {
              final v = dataValue(h, -32768, 65535, '.half') & 0xFFFF;
              emit(v & 0xFF);
              emit((v >> 8) & 0xFF);
            }
          } else if (d == '.word') {
            for (final w in arg.split(',')) {
              final v = dataValue(w, -0x80000000, 0xFFFFFFFF, '.word') & 0xFFFFFFFF;
              for (int i = 0; i < 4; i++) {
                emit((v >> (i * 8)) & 0xFF);
              }
            }
          } else if (d == '.asciz' || d == '.string') {
            final m = RegExp(r'"(.*)"').firstMatch(arg);
            final rawStr = m != null ? m.group(1)! : '';
            final s = _unescapeAsciz(rawStr);
            for (final ch in s) {
              emit(ch);
            }
            emit(0);
          }
        } else {
          if (pc.isOdd) {
            throw AssemblerError(
                'instruction at odd address 0x${pc.toRadixString(16).toUpperCase().padLeft(8, '0')}',
                fname, lno, 'misaligned');
          }
          final isJump = isSizedJump(line.split(RegExp(r'\s+'))[0].toUpperCase());
          final words = isJump
              ? _encodeJump(line, pc, _jumpSizes[index] ?? 2, fname, lno)
              : encodeInstructionWords(line, pc, fname, lno);
          for (final w in words) {
            emit(w & 0xFF);
            emit((w >> 8) & 0xFF);
          }
        }
      } on AssemblerError catch (e) {
        pc = startPc + _sizeOf(line, index);
        if (!_record(_place(e, entry))) break;
      }

      if (pc > maxAddr) maxAddr = pc;

      // Format listing line matching tools/pasm.py
      if (emittedBytes.isNotEmpty) {
        final hexStr = emittedBytes
            .take(4)
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join();
        listingLines.add(
            '${startPc.toRadixString(16).padLeft(8, '0').toUpperCase()}  ${hexStr.padRight(12)} ${lno.toString().padRight(5)} $origLine');
      } else {
        listingLines.add(
            '${startPc.toRadixString(16).padLeft(8, '0').toUpperCase()}  ${"".padRight(12)} ${lno.toString().padRight(5)} $origLine');
      }
    }

    return (binaryData, maxAddr, listingLines);
  }

  /// The bytes pass 1 gives [line] (without its labels), at [index] in the
  /// processed lines; not for .org and .align.
  int _sizeOf(String line, int index) {
    if (line.startsWith('.')) {
      final parts = line.split(RegExp(r'\s+'));
      final d = parts[0].toLowerCase();
      final arg = parts.length > 1 ? line.substring(parts[0].length).trim() : '';
      if (d == '.byte') return arg.split(',').length;
      if (d == '.half') return arg.split(',').length * 2;
      if (d == '.word') return arg.split(',').length * 4;
      if (d == '.asciz' || d == '.string') {
        final m = RegExp(r'"(.*)"').firstMatch(arg);
        return _unescapeAsciz(m != null ? m.group(1)! : '').length + 1;
      }
      return 0;
    }
    final mnem = line.split(RegExp(r'\s+'))[0].toUpperCase();
    if (isSizedJump(mnem)) return _jumpSizes[index] ?? 2;
    return _instBytes(line);
  }

  /// Bytes chosen for each JUMP, by its index in the processed lines.
  final Map<int, int> _jumpSizes = {};

  /// One run of pass 1: lays out every line, defining the labels, and
  /// records the address of each JUMP in [jumpAddrs]. Returns the end of
  /// the image.
  int _pass1(List<SourceLine> processedLines, Map<int, int> jumpAddrs) {
    pc = 0x00000100;
    var imageEnd = pc;
    final definedAt = <String, (String, int)>{};
    for (var index = 0; index < processedLines.length; index++) {
      final entry = processedLines[index];
      var line = entry.$3;
      _at = entry;

      // Extract all labels preceding the instruction or directive
      while (true) {
        final (labelPart, rest) = splitLabel(line);
        if (labelPart == null) break;
        if (labelPart.isNotEmpty) {
          if (labelPart == imageEndSymbol) {
            throw AssemblerError(
                "'$imageEndSymbol' is defined by the assembler and cannot be used as a label",
                entry.$1,
                entry.$2, 'reserved-name');
          }
          if (regMap.containsKey(labelPart.toLowerCase())) {
            throw AssemblerError(
                "'$labelPart' is a register name and cannot be used as a label",
                entry.$1, entry.$2, 'reserved-name');
          }
          final earlier = definedAt[labelPart];
          if (earlier != null) {
            throw AssemblerError(
                "label '$labelPart' is already defined at ${earlier.$1.split(RegExp(r'[/\\\\]')).last}:${earlier.$2}",
                entry.$1, entry.$2, 'duplicate-symbol');
          }
          definedAt[labelPart] = (entry.$1, entry.$2);
          symbols[labelPart] = pc;
        }
        line = rest;
        if (line.isEmpty) break;
      }

      if (line.isEmpty) continue;

      if (line.startsWith('.')) {
        final parts = line.split(RegExp(r'\s+'));
        final d = parts[0].toLowerCase();
        final arg =
            parts.length > 1 ? line.substring(parts[0].length).trim() : '';

        if (d == '.org') {
          pc = prep.parseExpr(arg, symbols);
        } else if (d == '.align') {
          final boundary = prep.parseExpr(arg, symbols);
          if (boundary < 1) {
            throw AssemblerError('.align needs a positive boundary, not $boundary', entry.$1, entry.$2, 'range');
          }
          final rem = pc % boundary;
          if (rem != 0) {
            pc += (boundary - rem);
          }
        } else if (d == '.byte') {
          pc += arg.split(',').length;
        } else if (d == '.half') {
          pc += arg.split(',').length * 2;
        } else if (d == '.word') {
          pc += arg.split(',').length * 4;
        } else if (d == '.asciz' || d == '.string') {
          final m = RegExp(r'"(.*)"').firstMatch(arg);
          final rawStr = m != null ? m.group(1)! : '';
          final decoded = _unescapeAsciz(rawStr);
          pc += decoded.length + 1; // null terminator byte
        } else if (d != '.org' && !ignoredDirectives.contains(d)) {
          throw AssemblerError("unknown directive '${parts[0]}'", entry.$1, entry.$2);
        }
      } else {
        final mnem = line.split(RegExp(r'\s+'))[0].toUpperCase();
        if (isSizedJump(mnem)) {
          jumpAddrs[index] = pc;
          pc += _jumpSizes[index] ?? 2;
        } else {
          pc += _instBytes(line);
        }
      }
      // Highest address reached; an .org back to a lower address does not
      // lower the end of the image
      if (pc > imageEnd) imageEnd = pc;
    }
    return imageEnd;
  }

  /// A JUMP or JUMP.cc line's mnemonic, condition register (-1 for JUMP)
  /// and target, or null while its label is not yet defined (in an early
  /// run of pass 1) or its register is wrong (pass 2 reports it).
  (String, int, int)? _tryJump(String line) {
    var rest = line;
    while (true) {
      final (lbl, r) = splitLabel(rest);
      if (lbl == null) break;
      rest = r;
    }
    rest = rest.trim();
    final mnem = rest.split(RegExp(r'\s+'))[0].toUpperCase();
    final ops = rest.substring(mnem.length).split(',').map((o) => o.trim()).toList();
    try {
      if (mnem == 'JUMP') return (mnem, -1, prep.parseExpr(ops[0], symbols));
      final reg = regMap[ops[0].toLowerCase()];
      if (reg == null || ops.length != 2) return null;
      return (mnem, reg, prep.parseExpr(ops[1], symbols));
    } catch (_) {
      return null;
    }
  }

  /// The bytes the far forms of JUMP use without the 2-word branches: 6 for
  /// LDI R14 + JMP (a target below 64K), 10 for LDI R14 + 2 PUSH8 + JMP.
  static int _farBytes(int to) => (to >= 0 && to <= 0xFFFF) ? 6 : 10;

  /// Bytes a JUMP ([reg] -1) or JUMP.cc Rreg at [from] needs to reach [to].
  /// JUMP: 2 for FBRA/BBRA (up to 255 halfwords away), 4 for BRA disp16
  /// (up to 32K halfwords), else the far form. JUMP.cc: 2 for the short
  /// conditional branch (15 halfwords, or 255 for R14), 4 for BRA.cc
  /// disp16, else a short branch around the far form (Z and NZ invert the
  /// condition; N and P have no inverse, so they branch over an FBRA).
  int jumpSize(String mnem, int reg, int from, int to) {
    final hw = (to - from) ~/ 2;
    final short = mnem == 'JUMP' ? 255 : (reg == 14 ? 255 : 15);
    if (hw.abs() <= short) return 2;
    if (longBranches && hw >= -32768 && hw <= 32767) return 4;
    if (mnem == 'JUMP') return _farBytes(to);
    final around = (mnem == 'JUMP.Z' || mnem == 'JUMP.NZ') ? 2 : 4;
    return around + _farBytes(to);
  }

  /// Encodes a JUMP or JUMP.cc line at [curPc] in [size] bytes (see
  /// [jumpSize]).
  List<int> _encodeJump(String line, int curPc, int size, String fname, int lno) {
    final tokens = line.split(RegExp(r'\s+'));
    final mnem = tokens[0].toUpperCase();
    final opStr = line.substring(tokens[0].length).trim();
    final ops = opStr.isEmpty ? <String>[] : opStr.split(',').map((o) => o.trim()).toList();
    final cond = mnem == 'JUMP' ? '' : mnem.substring(4); // .Z, .NZ, .N, .P
    if (cond.isEmpty && ops.length != 1) {
      throw AssemblerError('JUMP expects 1 operand: JUMP <label>', fname, lno);
    }
    if (cond.isNotEmpty && ops.length != 2) {
      throw AssemblerError('$mnem expects 2 operands: $mnem Rr, <label>', fname, lno);
    }
    final reg = cond.isEmpty ? 0 : parseReg(ops[0], fname, lno);
    final to = prep.parseExpr(ops.last, symbols) & 0xFFFFFFFF;
    if (to.isOdd) {
      throw AssemblerError('$mnem target 0x${to.toRadixString(16)} is not even', fname, lno, 'jump');
    }
    final back = to < curPc;
    final hw = (to - curPc).abs() ~/ 2;
    // The far forms (R14 holds the target)
    const jmpR14 = (0xA0 << 8) | (14 << 4); // JMP R14, R0
    List<int> far(int bytes) => bytes == 6
        ? [(0x07 << 8) | 14, to & 0xFFFF, jmpR14]
        : [
            (0x07 << 8) | 14, (to >> 16) & 0xFFFF, // LDI   R14, to >> 16
            (0x06 << 8) | ((to >> 8) & 0xFF), // PUSH8 R14, (to >> 8) & 0xFF
            (0x06 << 8) | (to & 0xFF), // PUSH8 R14, to & 0xFF
            jmpR14,
          ];
    final disp = ((to - curPc) ~/ 2) & 0xFFFF;
    if (cond.isEmpty) {
      switch (size) {
        case 2:
          return [((back ? 0xC0 : 0xB0) << 8) | hw];
        case 4:
          return [0xCC00, disp]; // BRA disp16
        default:
          return far(size);
      }
    }
    // Short conditional forms: Imm4 for any register, Imm8 for R14
    int shortBranch(String c, bool backward, int halfwords) {
      final imm8 = reg == 14 && halfwords > 15;
      final fwd = {
        '.Z': imm8 ? 0xB7 : 0xB4, '.N': imm8 ? 0xB8 : 0xB5,
        '.P': imm8 ? 0xB9 : 0xB6, '.NZ': imm8 ? 0xBB : 0xBA,
      }[c]!;
      final op = backward ? fwd + 0x10 : fwd;
      return imm8 ? (op << 8) | halfwords : (op << 8) | (reg << 4) | halfwords;
    }
    if (size == 2) return [shortBranch(cond, back, hw)];
    if (size == 4) {
      final op = {'.Z': 0xBC, '.NZ': 0xBD, '.N': 0xBE, '.P': 0xBF}[cond]!;
      return [(op << 8) | (reg << 4), disp];
    }
    if (cond == '.Z' || cond == '.NZ') {
      // The inverted condition branches past the far form
      final farWords = far(size - 2);
      return [shortBranch(cond == '.Z' ? '.NZ' : '.Z', false, 1 + farWords.length), ...farWords];
    }
    // .N/.P: taken, branch over the FBRA to the far form; not taken, the FBRA
    // skips it
    final farWords = far(size - 4);
    return [shortBranch(cond, false, 2), (0xB0 << 8) | (1 + farWords.length), ...farWords];
  }

  /// Decodes escape sequences (\n, \r, \t, \0, \\, \", \') inside string literals.
  List<int> _unescapeAsciz(String s) {
    final out = <int>[];
    for (int i = 0; i < s.length; i++) {
      if (s[i] == r'\' && i + 1 < s.length) {
        i++;
        switch (s[i]) {
          case 'n':
            out.add(10);
            break;
          case 'r':
            out.add(13);
            break;
          case 't':
            out.add(9);
            break;
          case '0':
            out.add(0);
            break;
          case r'\':
            out.add(92);
            break;
          case '"':
            out.add(34);
            break;
          case "'":
            out.add(39);
            break;
          default:
            out.add(s.codeUnitAt(i));
            break;
        }
      } else {
        out.add(s.codeUnitAt(i));
      }
    }
    return out;
  }

  /// Directives accepted and ignored: `.global` names a symbol other files
  /// use (every label is visible already), `.data` marks where data starts.
  static const ignoredDirectives = {'.global', '.data'};

  /// The number of operands of each instruction (LDI, LDIS and JUMP are
  /// checked where they are encoded).
  static const Map<String, int> operandCounts = {
    'NOP': 0, 'XCHGALL': 0, 'XCHGMOST': 0,
    'RETI': 0, 'EI': 0, 'DI': 0, 'WAIT': 0, 'HALT': 0,
    'NEG': 1, 'NOT': 1, 'NEZ': 1, 'SEXT8': 1, 'SEXT16': 1, 'REV32': 1,
    'XCHG': 1, 'BRANCH': 1, 'TRAP': 1,
    'FBRA': 1, 'BBRA': 1,
    'LD': 2, 'PUSH4': 2, 'PUSH8': 2,
    'LD8': 2, 'LD16': 2, 'LD32': 2, 'ST8': 2, 'ST16': 2, 'ST32': 2,
    'ADD': 2, 'SUB': 2, 'DIV': 2, 'MOD': 2,
    'SADD': 2, 'SSUB': 2, 'SDIV': 2, 'SMOD': 2,
    'AND': 2, 'OR': 2, 'XOR': 2,
    'SHIFTL': 2, 'SHIFTR': 2, 'ASHIFTR': 2, 'ROTL': 2, 'ROTR': 2,
    'MULL': 2, 'MULH': 2, 'SMULH': 2, 'MULHU': 2, 'MULHSU': 2,
    'BEXTR': 2, 'CLZ': 2, 'BSET': 2, 'BCLR': 2, 'BINV': 2, 'BGET': 2,
    'TAS': 2, 'SLT': 2, 'SSLT': 2, 'SEQ': 2, 'SNE': 2, 'SLE': 2, 'SSLE': 2,
    'JMP': 2, 'RJUMP': 2,
    'FBRA.Z': 2, 'FBRA.N': 2, 'FBRA.P': 2, 'FBRA.NZ': 2,
    'BBRA.Z': 2, 'BBRA.N': 2, 'BBRA.P': 2, 'BBRA.NZ': 2,
    'FIFO.R': 2, 'FIFO.W': 2, 'FIFO.STAT': 2, 'FIFO.TRYR': 2, 'FIFO.TRYW': 2,
    'MBOX': 2,
  };

  /// Encodes an instruction into one or two 16-bit machine words (little-endian).
  List<int> encodeInstructionWords(
      String line, int curPc, String fname, int lno) {
    final tokens = line.split(RegExp(r'\s+'));
    final mnem = tokens[0].toUpperCase();
    if (mnem == 'LDI' || mnem == 'LDIS') {
      final opStr = line.length > tokens[0].length
          ? line.substring(tokens[0].length).trim()
          : '';
      final ops = opStr.isNotEmpty
          ? opStr.split(',').map((o) => o.trim()).toList()
          : <String>[];
      if (ops.length != 2) {
        throw AssemblerError(
            '$mnem expects 2 operands: $mnem Rl, <imm16>', fname, lno);
      }
      final rl = parseReg(ops[0], fname, lno);
      final val = prep.parseExpr(ops[1], symbols);
      if (mnem == 'LDI') {
        if (val < 0 || val > 0xFFFF) {
          throw AssemblerError(
              'Immediate value $val out of 16-bit unsigned range (0..65535) for LDI',
              fname,
              lno, 'range');
        }
        return [(0x07 << 8) | rl, val & 0xFFFF];
      } else {
        if (val < -32768 || val > 0xFFFF) {
          throw AssemblerError(
              'Immediate value $val out of 16-bit signed range (-32768..32767) for LDIS',
              fname,
              lno, 'range');
        }
        return [(0x08 << 8) | rl, val & 0xFFFF];
      }
    }
    if (twoWordMnemonics.contains(mnem) ||
        (mnem == 'RJUMP' && _instBytes(line) == 4)) {
      return _encodeLong(line, mnem, curPc, fname, lno);
    }
    if (mnem == 'SBEXTR' || (mnem == 'BEXTR' && _instBytes(line) == 4)) {
      return _encodeBextrImm(line, mnem, fname, lno);
    }
    return [encodeInstruction(line, curPc, fname, lno)];
  }

  /// Encodes `BEXTR Rr, Rl, pos, len` and `SBEXTR Rr, Rl, pos, len`
  /// (0x8D): Rr = the len-bit field of Rl at bit pos (sign-extended for
  /// SBEXTR); the second word holds pos (bits 4:0), len (9:5) and the sign
  /// (15).
  List<int> _encodeBextrImm(String line, String mnem, String fname, int lno) {
    final opStr = line.substring(line.split(RegExp(r'\s+'))[0].length).trim();
    final ops = opStr.isEmpty ? <String>[] : opStr.split(',').map((o) => o.trim()).toList();
    if (ops.length != 4 || ops.any((o) => o.isEmpty)) {
      throw AssemblerError('$mnem expects 4 operands: $mnem Rr, Rl, <pos>, <len>', fname, lno);
    }
    final rr = parseReg(ops[0], fname, lno);
    final rl = parseReg(ops[1], fname, lno);
    int value(int i, int hi, String what) {
      if (regMap.containsKey(ops[i].toLowerCase())) {
        throw AssemblerError("$mnem's $what is a number, not a register", fname, lno, 'register');
      }
      final v = prep.parseExpr(ops[i], symbols);
      if (v < 0 || v > hi) {
        throw AssemblerError('$mnem $what $v out of range (0..$hi)', fname, lno, 'range');
      }
      return v;
    }
    final pos = value(2, 31, 'position');
    final len = value(3, 31, 'length');
    final sign = mnem == 'SBEXTR' ? 0x8000 : 0;
    return [(0x8D << 8) | (rr << 4) | rl, sign | (len << 5) | pos];
  }

  /// Encodes the 2-word PC-relative instructions: BRA, BRA.Z/NZ/N/P,
  /// RJUMP label, Rl, BEQ, BNE (a halfword displacement) and LEA (bytes).
  List<int> _encodeLong(String line, String mnem, int curPc, String fname, int lno) {
    final opStr = line.substring(line.split(RegExp(r'\s+'))[0].length).trim();
    final ops = opStr.isEmpty ? <String>[] : opStr.split(',').map((o) => o.trim()).toList();
    final form = switch (mnem) {
      'BRA' => 'BRA <label>',
      'LEA' => 'LEA Rl, <label>',
      'RJUMP' => 'RJUMP <label>, Rl',
      'BEQ' || 'BNE' => '$mnem Rr, Rl, <label>',
      _ => '$mnem Rr, <label>',
    };
    final want = form.split(',').length;
    if (ops.length != want || ops.any((o) => o.isEmpty)) {
      throw AssemblerError('$mnem expects $want ${want == 1 ? 'operand' : 'operands'}: $form', fname, lno);
    }
    if (!longBranches) {
      throw AssemblerError(
          '$mnem needs a core with the 2-word branches (this is assembled with --no-long-branches)',
          fname, lno, 'long-branch');
    }
    int reg(int i) => parseReg(ops[i], fname, lno);
    final targetOp = mnem == 'RJUMP' ? ops[0] : ops.last;
    if (regMap.containsKey(targetOp.toLowerCase())) {
      throw AssemblerError('$mnem takes a label or address, not a register: $form', fname, lno);
    }
    final to = prep.parseExpr(targetOp, symbols);
    final bytes = to - curPc;
    if (mnem == 'LEA') {
      if (bytes < -32768 || bytes > 32767) {
        throw AssemblerError('LEA target out of range ($bytes bytes; -32768..32767)', fname, lno, 'branch-range');
      }
      return [(0x09 << 8) | reg(0), bytes & 0xFFFF];
    }
    if (to.isOdd) {
      throw AssemblerError('$mnem target 0x${(to & 0xFFFFFFFF).toRadixString(16)} is not even', fname, lno, 'jump');
    }
    final hw = bytes ~/ 2;
    if (hw < -32768 || hw > 32767) {
      throw AssemblerError('$mnem target out of range ($hw halfwords; -32768..32767)', fname, lno, 'branch-range');
    }
    final d = hw & 0xFFFF;
    return switch (mnem) {
      'BRA' => [0xCC00, d],
      'RJUMP' => [(0xCD << 8) | reg(1), d],
      'BEQ' => [(0xCE << 8) | (reg(0) << 4) | reg(1), d],
      'BNE' => [(0xCF << 8) | (reg(0) << 4) | reg(1), d],
      _ => [
          ({'BRA.Z': 0xBC, 'BRA.NZ': 0xBD, 'BRA.N': 0xBE, 'BRA.P': 0xBF}[mnem]! << 8) | (reg(0) << 4),
          d,
        ],
    };
  }

  /// Encodes a single instruction into a 16-bit machine word.
  /// Matches exact opcode and immediate dispatch from tools/pasm.py:encode_instruction.
  int encodeInstruction(String line, int curPc, String fname, int lno) {
    final tokens = line.split(RegExp(r'\s+'));
    final mnem = tokens[0].toUpperCase();
    final opStr = line.length > tokens[0].length
        ? line.substring(tokens[0].length).trim()
        : '';
    final ops = opStr.isNotEmpty
        ? opStr.split(',').map((o) => o.trim()).toList()
        : <String>[];

    int getR(int idx) {
      if (idx >= ops.length)
        throw AssemblerError('Missing register operand ${idx + 1}', fname, lno);
      return parseReg(ops[idx], fname, lno);
    }

    int getV(int idx) {
      if (idx >= ops.length)
        throw AssemblerError(
            'Missing immediate or label operand ${idx + 1}', fname, lno);
      if (ops[idx].startsWith('(') && parseMemOperand(ops[idx], fname, lno) != null) {
        throw AssemblerError(
            "$mnem does not take a memory operand ('${ops[idx]}')", fname, lno);
      }
      return prep.parseExpr(ops[idx], symbols);
    }

    /// Operand [idx] as a value from [lo] to [hi].
    int getImm(int idx, int lo, int hi, [String what = 'Immediate value']) {
      final v = getV(idx);
      if (v < lo || v > hi) {
        throw AssemblerError(
            '$what $v out of range ($lo..$hi) for $mnem', fname, lno, 'range');
      }
      return v;
    }

    /// Whether operand [idx] is a register.
    bool isReg(int idx) => regMap.containsKey(ops[idx].trim().toLowerCase());

    if (ops.any((o) => o.isEmpty)) {
      throw AssemblerError('$mnem has an empty operand', fname, lno);
    }
    final counts = operandCounts[mnem];
    if (counts != null && counts != ops.length) {
      throw AssemblerError(
          '$mnem expects $counts ${counts == 1 ? 'operand' : 'operands'}', fname, lno);
    }

    // -------------------------------------------------------------------------
    // Control Flow: BRANCH & JTBL
    // -------------------------------------------------------------------------
    if (mnem == 'BRANCH') {
      if (ops.length != 1)
        throw AssemblerError('BRANCH expects 1 operand: BRANCH Rr', fname, lno);
      final rr = getR(0);
      return (0xA4 << 8) | (rr << 4);
    }
    if (mnem == 'JTBL') {
      if (ops.isEmpty || ops.length > 2)
        throw AssemblerError('JTBL expects 1 or 2 operands: JTBL Rr or JTBL Rr, <entry bytes>', fname, lno);
      final rr = getR(0);
      // The entry size in bytes (2, 4, 8 or 16) goes in Rl[1:0]
      var code = 0;
      if (ops.length == 2) {
        final size = getV(1);
        const codes = {2: 0, 4: 1, 8: 2, 16: 3};
        if (!codes.containsKey(size)) {
          throw AssemblerError('JTBL entry size $size must be 2, 4, 8 or 16 bytes', fname, lno, 'range');
        }
        code = codes[size]!;
      }
      return (0x81 << 8) | (rr << 4) | code;
    }

    // -------------------------------------------------------------------------
    // Forward / Backward Branches (FBRA, BBRA and conditionals .Z, .N, .P, .NZ)
    // -------------------------------------------------------------------------
    for (final entry in [('FBRA', false), ('BBRA', true)]) {
      final branchPfx = entry.$1;
      final isBackward = entry.$2;

      if (mnem == branchPfx || mnem.startsWith('$branchPfx.')) {
        final cond = mnem.substring(branchPfx.length);

        // Unconditional branch: 8-bit unsigned displacement (0..255 halfwords)
        if (cond.isEmpty) {
          if (ops.length != 1)
            throw AssemblerError(
                '$mnem expects 1 operand: $mnem <label>', fname, lno);
          final tgt = getV(0);
          final diff = isBackward ? (curPc - tgt) : (tgt - curPc);
          final offset = diff ~/ 2;
          if (offset < 0 || offset > 255) {
            throw AssemblerError(
                'Branch out of 8-bit unsigned range ($offset)', fname, lno, 'branch-range');
          }
          final baseOp = isBackward ? 0xC0 : 0xB0;
          return (baseOp << 8) | (offset & 0xFF);
        }

        if (!['.Z', '.N', '.P', '.NZ'].contains(cond)) {
          throw AssemblerError('Invalid branch condition: $cond', fname, lno);
        }

        final condIdx = {'.Z': 1, '.N': 2, '.P': 3, '.NZ': 4}[cond]!;
        if (ops.length != 2)
          throw AssemblerError(
              '$mnem expects 2 operands: $mnem Rr, <label>'
              '${cond == '.NZ' ? '' : ' or $mnem Rr, Rl'}', fname, lno);

        final r = getR(0);

        // Register displacement (.Z, .N, .P only): PC +/- Rl * 2
        if (cond != '.NZ' && regMap.containsKey(ops[1].trim().toLowerCase())) {
          final rl = getR(1);
          final op = (isBackward ? 0xC0 : 0xB0) + condIdx;
          return (op << 8) | (r << 4) | rl;
        }

        final tgt = getV(1);
        final diff = isBackward ? (curPc - tgt) : (tgt - curPc);
        final offset = diff ~/ 2;

        // Wide conditional branch via R14 with 8-bit immediate (offset > 15)
        if (r == 14 && (offset > 15)) {
          if (offset < 0 || offset > 255) {
            throw AssemblerError(
                'Branch out of 8-bit immediate range ($offset)', fname, lno, 'branch-range');
          }
          final op = isBackward
              ? (cond == '.NZ' ? 0xCB : (0xC6 + condIdx))
              : (cond == '.NZ' ? 0xBB : (0xB6 + condIdx));
          return (op << 8) | (offset & 0xFF);
        }

        // Standard conditional branch: 4-bit immediate field (0..15 halfwords)
        if (offset < 0 || offset > 15) {
          throw AssemblerError(
              'Branch out of 4-bit immediate range ($offset)', fname, lno, 'branch-range');
        }

        final op = isBackward
            ? (cond == '.NZ' ? 0xCA : (0xC3 + condIdx))
            : (cond == '.NZ' ? 0xBA : (0xB3 + condIdx));
        return (op << 8) | (r << 4) | (offset & 0x0F);
      }
    }

    // -------------------------------------------------------------------------
    // Relational Comparisons: SLT (Unsigned) / SSLT (Signed)
    // -------------------------------------------------------------------------
    if (mnem == 'SLT' || mnem == 'SSLT') {
      final baseOp = (mnem == 'SLT') ? 0x90 : 0x95;
      final rr = getR(0);
      try {
        final rl = parseReg(ops[1], fname, lno);
        return (baseOp << 8) | (rr << 4) | rl;
      } catch (_) {
        final val = getV(1);
        // SSLT's positive immediates are signed fields: 0..7 (Imm4) and
        // 0..127 (Imm8); its negative forms take -15..-1 and -255..-1
        final maxPos4 = mnem == 'SLT' ? 15 : 7;
        final maxPos8 = mnem == 'SLT' ? 255 : 127;
        if (rr == 14) {
          if (val >= 0 && val <= maxPos8) return ((baseOp + 3) << 8) | (val & 0xFF);
          if (val >= -255 && val < 0)
            return ((baseOp + 4) << 8) | ((-val) & 0xFF);
          throw AssemblerError(
              'Immediate value $val out of range (-255..$maxPos8) for $mnem R14',
              fname, lno, 'range');
        }
        if (val >= 0 && val <= maxPos4)
          return ((baseOp + 1) << 8) | (rr << 4) | (val & 0x0F);
        if (val >= -15 && val < 0)
          return ((baseOp + 2) << 8) | (rr << 4) | ((-val) & 0x0F);
        throw AssemblerError(
            'Immediate value $val out of range (-15..$maxPos4) for $mnem', fname, lno, 'range');
      }
    }

    // -------------------------------------------------------------------------
    // Memory Operations: LD8, ST8, LD16, ST16, LD32, ST32
    // -------------------------------------------------------------------------
    for (final entry in [
      ('8', 0x10, 0x15),
      ('16', 0x20, 0x25),
      ('32', 0x30, 0x35)
    ]) {
      final widthName = entry.$1;
      final baseLd = entry.$2;
      final baseSt = entry.$3;

      if (mnem == 'LD$widthName' || mnem == 'ST$widthName') {
        if (ops.length != 2)
          throw AssemblerError('$mnem expects 2 operands', fname, lno);
        final memLeft = parseMemOperand(ops[0], fname, lno);
        final memRight = parseMemOperand(ops[1], fname, lno);
        final modeOffsets = {
          'standard': 0,
          'pre_inc': 1,
          'post_inc': 2,
          'pre_dec': 3,
          'post_dec': 4
        };

        if (memRight != null && mnem.startsWith('ST')) {
          throw AssemblerError(
              '$mnem stores a register to memory: $mnem (Rr), Rl', fname, lno);
        }
        if (memRight != null) {
          final rr = parseReg(ops[0], fname, lno);
          final rl = memRight.$1;
          final mode = memRight.$2;
          final op = baseLd + modeOffsets[mode]!;
          return (op << 8) | (rr << 4) | rl;
        } else if (memLeft != null) {
          final rr = memLeft.$1;
          final mode = memLeft.$2;
          final rl = parseReg(ops[1], fname, lno);
          final op = baseSt + modeOffsets[mode]!;
          return (op << 8) | (rr << 4) | rl;
        } else {
          throw AssemblerError(
              'Memory access syntax requires parentheses: $line', fname, lno);
        }
      }
    }

    // -------------------------------------------------------------------------
    // NOP, LD, PUSH4, PUSH8
    // -------------------------------------------------------------------------
    if (mnem == 'NOP') return 0x0000;

    if (mnem == 'LD') {
      if (ops.length == 2) {
        final rr = getR(0);
        try {
          final rl = parseReg(ops[1], fname, lno);
          return (0x00 << 8) | (rr << 4) | rl;
        } catch (_) {
          final val = getV(1);
          if (rr == 14 && (val >= 0 && val <= 255)) {
            return (0x02 << 8) | (val & 0xFF);
          } else if (rr == 14 && (val >= -255 && val < 0)) {
            return (0x04 << 8) | ((-val) & 0xFF);
          } else if (val >= 0 && val <= 15) {
            return (0x01 << 8) | (rr << 4) | (val & 0x0F);
          } else if (val >= -15 && val < 0) {
            return (0x03 << 8) | (rr << 4) | ((-val) & 0x0F);
          }
          throw AssemblerError(
              'Immediate value $val out of range for LD', fname, lno, 'range');
        }
      }
      throw AssemblerError('LD expects 2 operands', fname, lno);
    }

    if (mnem == 'PUSH4') {
      final rr = getR(0);
      final v = getImm(1, 0, 15);
      return (0x05 << 8) | (rr << 4) | (v & 0x0F);
    }

    if (mnem == 'PUSH8') {
      if (getR(0) != 14) {
        throw AssemblerError('PUSH8 works on R14: PUSH8 R14, <imm8>', fname, lno, 'register');
      }
      final v = getImm(1, 0, 255);
      return (0x06 << 8) | (v & 0xFF);
    }

    // -------------------------------------------------------------------------
    // Multipliers (MULL, MULH, SMULH, MULHSU)
    // -------------------------------------------------------------------------
    if (['MULL', 'MULH', 'SMULH', 'MULHU', 'MULHSU'].contains(mnem)) {
      final rr = getR(0);
      final baseLut = {
        'MULL': 0x78,
        'MULH': 0x79,
        'SMULH': 0x7A,
        'MULHU': 0x79,
        'MULHSU': 0x7B
      };
      try {
        final rl = parseReg(ops[1], fname, lno);
        return (baseLut[mnem]! << 8) | (rr << 4) | rl;
      } catch (_) {
        final v = mnem == 'SMULH'
            ? getImm(1, -8, 7, 'Immediate multiplier')
            : getImm(1, 0, 15, 'Immediate multiplier');
        return ((baseLut[mnem]! + 4) << 8) | (rr << 4) | (v & 0x0F);
      }
    }

    // -------------------------------------------------------------------------
    // Bit Operations & Bitfield (BEXTR, BSET, BCLR, BINV, BGET)
    // -------------------------------------------------------------------------
    if (mnem == 'BEXTR') {
      final rr = getR(0);
      final rl = parseReg(ops[1], fname, lno);
      return (0x80 << 8) | (rr << 4) | rl;
    }

    if (['BSET', 'BCLR', 'BINV', 'BGET'].contains(mnem)) {
      final rr = getR(0);
      final regLut = {'BSET': 0x83, 'BCLR': 0x85, 'BINV': 0x87, 'BGET': 0x89};
      final immLut = {'BSET': 0x84, 'BCLR': 0x86, 'BINV': 0x88, 'BGET': 0x8A};
      try {
        final rl = parseReg(ops[1], fname, lno);
        return (regLut[mnem]! << 8) | (rr << 4) | rl;
      } catch (_) {
        final v = getV(1);
        if (v < 0 || v > 15) {
          throw AssemblerError(
              'Bit index $v out of 4-bit immediate range (0-15)', fname, lno, 'range');
        }
        return (immLut[mnem]! << 8) | (rr << 4) | (v & 0x0F);
      }
    }

    // -------------------------------------------------------------------------
    // Arithmetic & Logic Operations
    // -------------------------------------------------------------------------
    final arithOps = {
      'ADD': (0x40, 0x44),
      'SUB': (0x41, 0x45),
      'DIV': (0x42, 0x46),
      'MOD': (0x43, 0x47),
      'SADD': (0x50, 0x54),
      'SSUB': (0x51, 0x55),
      'SDIV': (0x52, 0x56),
      'SMOD': (0x53, 0x57),
      'AND': (0x66, 0x6F),
      'OR': (0x67, 0x70),
      'XOR': (0x68, 0x71),
      'SHIFTL': (0x60, 0x69),
      'SHIFTR': (0x62, 0x6B),
      'ASHIFTR': (0x63, 0x6C),
      'ROTL': (0x64, 0x6D),
      'ROTR': (0x65, 0x6E),
    };
    if (arithOps.containsKey(mnem)) {
      final rr = getR(0);
      final entry = arithOps[mnem]!;
      final rOp = entry.$1;
      final immOp = entry.$2;
      try {
        final rl = parseReg(ops[1], fname, lno);
        return (rOp << 8) | (rr << 4) | rl;
      } catch (_) {
        const signedOps = {'SADD', 'SSUB', 'SDIV', 'SMOD'};
        final v = signedOps.contains(mnem) ? getImm(1, -8, 7) : getImm(1, 0, 15);
        return (immOp << 8) | (rr << 4) | (v & 0x0F);
      }
    }

    if (mnem == 'NOT') return (0x72 << 8) | (getR(0) << 4);
    if (mnem == 'NEZ') return (0x73 << 8) | (getR(0) << 4);
    if (mnem == 'SEXT8') return (0x61 << 8) | (getR(0) << 4);
    if (mnem == 'SEXT16') return (0x6A << 8) | (getR(0) << 4);
    if (mnem == 'CLZ') return (0x82 << 8) | (getR(0) << 4) | getR(1);

    if (mnem == 'TAS') {
      if (ops.length != 2)
        throw AssemblerError(
            'TAS expects 2 operands: TAS (Rr), Rl', fname, lno);
      final memTarget = parseMemOperand(ops[0], fname, lno);
      if (memTarget == null || memTarget.$2 != 'standard')
        throw AssemblerError('TAS operand 1 must be (Rr)', fname, lno);
      final rr = memTarget.$1;
      final rl = parseReg(ops[1], fname, lno);
      return (0x8B << 8) | (rr << 4) | rl;
    }

    // -------------------------------------------------------------------------
    // Extended Native ISA
    // -------------------------------------------------------------------------
    if (mnem == 'NEG') return (0x48 << 8) | (getR(0) << 4);
    if (mnem == 'REV32') return (0x8C << 8) | (getR(0) << 4);

    if (['SEQ', 'SNE', 'SLE', 'SSLE'].contains(mnem)) {
      final lut = {'SEQ': 0x9A, 'SNE': 0x9B, 'SLE': 0x9C, 'SSLE': 0x9D};
      return (lut[mnem]! << 8) | (getR(0) << 4) | getR(1);
    }

    // -------------------------------------------------------------------------
    // Control Flow: JMP, RJUMP, TRAP
    // -------------------------------------------------------------------------
    if (mnem == 'JMP') {
      return (0xA0 << 8) | (getR(0) << 4) | getR(1);
    }

    if (mnem == 'RJUMP') {
      return (0xA1 << 8) | (getR(0) << 4) | getR(1);
    }

    if (mnem == 'TRAP') {
      try {
        final rr = parseReg(ops[0], fname, lno);
        return (0xA2 << 8) | (rr << 4);
      } catch (_) {
        final v = getImm(0, 0, 15, 'Trap number');
        return (0xA3 << 8) | (v & 0x0F);
      }
    }

    // -------------------------------------------------------------------------
    // Context Exchange: XCHG, XCHGALL, XCHGMOST
    // -------------------------------------------------------------------------
    if (mnem == 'XCHG') return (0xD0 << 8) | (getR(0) << 4);
    if (mnem == 'XCHGALL') return 0xD100;
    if (mnem == 'XCHGMOST') return 0xD200;

    // -------------------------------------------------------------------------
    // Streaming FIFOs & Inter-core Mailbox
    // -------------------------------------------------------------------------
    if (mnem == 'FIFO.W') {
      if (!isReg(1)) {
        throw AssemblerError(
            'FIFO.W takes the channel in a register: FIFO.W Rr, Rl', fname, lno, 'register');
      }
      return (0xE1 << 8) | (getR(0) << 4) | getR(1);
    }

    if (mnem == 'FIFO.R') {
      if (!isReg(1)) {
        throw AssemblerError(
            'FIFO.R takes the channel in a register: FIFO.R Rr, Rl', fname, lno, 'register');
      }
      return (0xE0 << 8) | (getR(0) << 4) | getR(1);
    }

    // Register-channel FIFO forms use the opcodes of spec 4.10
    if (mnem == 'FIFO.STAT') {
      if (!isReg(1)) {
        throw AssemblerError(
            'FIFO.STAT takes the channel in a register: FIFO.STAT Rr, Rl', fname, lno, 'register');
      }
      return (0xE4 << 8) | (getR(0) << 4) | getR(1);
    }

    if (mnem == 'FIFO.TRYR') {
      if (!isReg(1)) {
        throw AssemblerError(
            'FIFO.TRYR takes the channel in a register: FIFO.TRYR Rr, Rl', fname, lno, 'register');
      }
      return (0xE6 << 8) | (getR(0) << 4) | getR(1);
    }

    if (mnem == 'FIFO.TRYW') {
      if (!isReg(1)) {
        throw AssemblerError(
            'FIFO.TRYW takes the channel in a register: FIFO.TRYW Rr, Rl', fname, lno, 'register');
      }
      return (0xE7 << 8) | (getR(0) << 4) | getR(1);
    }

    if (mnem == 'MBOX') {
      final rr = getR(0);
      // MBOX Rr, Rl: the target core in Rl bits 7:0, the vector in 11:8
      if (isReg(1)) return (0xE2 << 8) | (rr << 4) | getR(1);
      // MBOX Rr, Imm4: vector Imm4 on the core's default target
      final vec = getImm(1, 0, 15, 'Vector');
      return (0xE5 << 8) | (rr << 4) | (vec & 0x0F);
    }

    // Returning from an MBOX trap (to EPC), and masking MBOX traps
    if (mnem == 'RETI') return 0xE300;
    if (mnem == 'EI') return 0xE800;
    if (mnem == 'DI') return 0xE900;
    // Sleeping: until an MBOX is pending (WAIT), or until reset (HALT)
    if (mnem == 'WAIT') return 0xEA00;
    if (mnem == 'HALT') return 0xEB00;

    throw AssemblerError(
        "Unimplemented instruction mnemonic '$mnem'", fname, lno);
  }
}
