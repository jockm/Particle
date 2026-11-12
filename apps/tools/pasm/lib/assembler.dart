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

  /// Resolves a register token (e.g. "R0", "r14", "sp") to its 4-bit index.
  int parseReg(String token, String fname, int lno) {
    final t = token.trim().toLowerCase();
    if (regMap.containsKey(t)) {
      return regMap[t]!;
    }
    throw AssemblerError("Unknown register '$token'", fname, lno);
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
    final List<String> fileList = (srcFiles is List<String>)
        ? srcFiles
        : (srcFiles is List)
            ? srcFiles.map((e) => e.toString()).toList()
            : [srcFiles.toString()];

    final processedLines = <(String, int, String)>[];
    for (final f in fileList) {
      processedLines.addAll(prep.process(f));
    }

    // -------------------------------------------------------------------------
    // PASS 1: Symbol Calculation & Address Resolution
    // -------------------------------------------------------------------------
    pc = 0x00000100;
    var imageEnd = pc;
    for (final entry in processedLines) {
      var line = entry.$3;

      // Extract all labels preceding the instruction or directive
      while (true) {
        final (labelPart, rest) = splitLabel(line);
        if (labelPart == null) break;
        if (labelPart.isNotEmpty) {
          if (labelPart == imageEndSymbol) {
            throw AssemblerError(
                "'$imageEndSymbol' is defined by the assembler and cannot be used as a label",
                entry.$1,
                entry.$2);
          }
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
        }
      } else {
        // Native Particle RISC instructions are 16 bits (2 bytes)
        pc += 2;
      }
      // Highest address reached; an .org back to a lower address does not
      // lower the end of the image
      if (pc > imageEnd) imageEnd = pc;
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

    for (final entry in processedLines) {
      final fname = entry.$1;
      final lno = entry.$2;
      final origLine = entry.$3;
      var line = origLine;

      // Emit standalone label entries in listing output
      while (true) {
        final (lbl, rest) = splitLabel(line);
        if (lbl == null) break;
        if (lbl.isNotEmpty) {
          listingLines.add('                 $lbl:');
        }
        line = rest;
      }

      if (line.isEmpty) continue;

      final startPc = pc;
      final emittedBytes = <int>[];

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
              binaryData[pc] = 0;
              emittedBytes.add(0);
              pc += 1;
            }
          }
        } else if (d == '.byte') {
          for (final b in arg.split(',')) {
            final v = prep.parseExpr(b, symbols) & 0xFF;
            binaryData[pc] = v;
            emittedBytes.add(v);
            pc += 1;
          }
        } else if (d == '.half') {
          for (final h in arg.split(',')) {
            final v = prep.parseExpr(h, symbols) & 0xFFFF;
            binaryData[pc] = v & 0xFF;
            binaryData[pc + 1] = (v >> 8) & 0xFF;
            emittedBytes.addAll([v & 0xFF, (v >> 8) & 0xFF]);
            pc += 2;
          }
        } else if (d == '.word') {
          for (final w in arg.split(',')) {
            final v = prep.parseExpr(w, symbols) & 0xFFFFFFFF;
            for (int i = 0; i < 4; i++) {
              final b = (v >> (i * 8)) & 0xFF;
              binaryData[pc + i] = b;
              emittedBytes.add(b);
            }
            pc += 4;
          }
        } else if (d == '.asciz' || d == '.string') {
          final m = RegExp(r'"(.*)"').firstMatch(arg);
          final rawStr = m != null ? m.group(1)! : '';
          final s = _unescapeAsciz(rawStr);
          for (final ch in s) {
            binaryData[pc] = ch;
            emittedBytes.add(ch);
            pc += 1;
          }
          binaryData[pc] = 0;
          emittedBytes.add(0);
          pc += 1;
        }
      } else {
        final instWord = encodeInstruction(line, pc, fname, lno);
        final b0 = instWord & 0xFF;
        final b1 = (instWord >> 8) & 0xFF;
        binaryData[pc] = b0;
        binaryData[pc + 1] = b1;
        emittedBytes.addAll([b0, b1]);
        pc += 2;
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
      return prep.parseExpr(ops[idx], symbols);
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
      if (ops.length != 1)
        throw AssemblerError('JTBL expects 1 operand: JTBL Rr', fname, lno);
      final rr = getR(0);
      return (0x81 << 8) | (rr << 4);
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
                'Branch out of 8-bit unsigned range ($offset)', fname, lno);
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
              '$mnem expects 2 operands: $mnem Rr, <label>', fname, lno);

        final r = getR(0);
        final tgt = getV(1);
        final diff = isBackward ? (curPc - tgt) : (tgt - curPc);
        final offset = diff ~/ 2;

        // Wide conditional branch via R14 with 8-bit immediate (offset > 15)
        if (r == 14 && (offset > 15)) {
          if (offset < 0 || offset > 255) {
            throw AssemblerError(
                'Branch out of 8-bit immediate range ($offset)', fname, lno);
          }
          final op = isBackward
              ? (cond == '.NZ' ? 0xCB : (0xC6 + condIdx))
              : (cond == '.NZ' ? 0xBB : (0xB6 + condIdx));
          return (op << 8) | (offset & 0xFF);
        }

        // Standard conditional branch: 4-bit immediate field (0..15 halfwords)
        if (offset < 0 || offset > 15) {
          throw AssemblerError(
              'Branch out of 4-bit immediate range ($offset)', fname, lno);
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
        if (rr == 14) {
          if (val >= 0 && val <= 255) return ((baseOp + 3) << 8) | (val & 0xFF);
          if (val >= -255 && val < 0)
            return ((baseOp + 4) << 8) | ((-val) & 0xFF);
        }
        if (val >= 0 && val <= 15)
          return ((baseOp + 1) << 8) | (rr << 4) | (val & 0x0F);
        if (val >= -15 && val < 0)
          return ((baseOp + 2) << 8) | (rr << 4) | ((-val) & 0x0F);
        throw AssemblerError(
            'Immediate value $val out of range for $mnem', fname, lno);
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
              'Immediate value $val out of range for LD', fname, lno);
        }
      }
    }

    if (mnem == 'PUSH4') {
      final rr = getR(0);
      final v = getV(1);
      return (0x05 << 8) | (rr << 4) | (v & 0x0F);
    }

    if (mnem == 'PUSH8') {
      final rr = getR(0);
      final v = getV(1);
      return (0x06 << 8) | (v & 0xFF);
    }

    // -------------------------------------------------------------------------
    // Multipliers (MULL, MULH, SMULH, MULHSU)
    // -------------------------------------------------------------------------
    if (['MULL', 'MULH', 'SMULH', 'MULHSU'].contains(mnem)) {
      final rr = getR(0);
      final baseLut = {
        'MULL': 0x78,
        'MULH': 0x79,
        'SMULH': 0x7A,
        'MULHSU': 0x7B
      };
      try {
        final rl = parseReg(ops[1], fname, lno);
        return (baseLut[mnem]! << 8) | (rr << 4) | rl;
      } catch (_) {
        final v = getV(1);
        if (v < 0 || v > 15) {
          throw AssemblerError(
              'Immediate multiplier $v out of 4-bit unsigned range (0-15)',
              fname,
              lno);
        }
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
              'Bit index $v out of 4-bit immediate range (0-15)', fname, lno);
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
        final v = getV(1);
        return (immOp << 8) | (rr << 4) | (v & 0x0F);
      }
    }

    if (mnem == 'NOT') return (0x72 << 8) | (getR(0) << 4);
    if (mnem == 'NEZ') return (0x73 << 8) | (getR(0) << 4);
    if (mnem == 'SEXT8') return (0x61 << 8) | (getR(0) << 4);
    if (mnem == 'SEXT16') return (0x6A << 8) | (getR(0) << 4);
    if (mnem == 'CLZ') return (0x82 << 8) | (getR(0) << 4);

    if (mnem == 'TAS') {
      if (ops.length != 2)
        throw AssemblerError(
            'TAS expects 2 operands: TAS (Rr), Rl', fname, lno);
      final memTarget = parseMemOperand(ops[0], fname, lno);
      if (memTarget == null)
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
      final rr = getR(0);
      final rl = ops.length > 1 ? getR(1) : 0;
      return (0xA0 << 8) | (rr << 4) | rl;
    }

    if (mnem == 'RJUMP') {
      final rr = getR(0);
      final rl = ops.length > 1 ? getR(1) : 0;
      return (0xA1 << 8) | (rr << 4) | rl;
    }

    if (mnem == 'TRAP') {
      try {
        final rr = parseReg(ops[0], fname, lno);
        return (0xA2 << 8) | (rr << 4);
      } catch (_) {
        final v = getV(0);
        return (0xA3 << 8) | (v & 0x0F);
      }
    }

    // -------------------------------------------------------------------------
    // Context Exchange: XCHG, XCHGALL, XCHGMOST, RBASE
    // -------------------------------------------------------------------------
    if (mnem == 'XCHG') return (0xD0 << 8) | (getR(0) << 4);
    if (mnem == 'XCHGALL') return 0xD100;
    if (mnem == 'XCHGMOST') return 0xD200;

    if (mnem == 'RBASE') {
      final op0 = ops[0].trim().toLowerCase();
      if (regMap.containsKey(op0)) {
        final rr = getR(0);
        return (0xD4 << 8) | ((rr & 0x0F) << 4);
      } else {
        final imm = getV(0);
        return (0xD3 << 8) | (imm & 0xFF);
      }
    }

    // -------------------------------------------------------------------------
    // Streaming FIFOs & Inter-core Mailbox
    // -------------------------------------------------------------------------
    if (mnem == 'FIFO.W') {
      final rr = getR(0);
      int chan = 0;
      if (ops.length > 1) {
        final op1 = ops[1].trim().toLowerCase();
        chan = regMap.containsKey(op1)
            ? regMap[op1]!
            : (int.tryParse(ops[1]) ?? 0);
      }
      return (0xE1 << 8) | (rr << 4) | (chan & 0x0F);
    }

    if (mnem == 'FIFO.R') {
      final rr = getR(0);
      int chan = 0;
      if (ops.length > 1) {
        final op1 = ops[1].trim().toLowerCase();
        chan = regMap.containsKey(op1)
            ? regMap[op1]!
            : (int.tryParse(ops[1]) ?? 0);
      }
      return (0xE0 << 8) | (rr << 4) | (chan & 0x0F);
    }

    // Register-channel FIFO forms use the opcodes of spec 4.10
    if (mnem == 'FIFO.STAT') {
      final rr = getR(0);
      final rl = ops.length > 1 ? parseReg(ops[1], fname, lno) : 0;
      return (0xE4 << 8) | (rr << 4) | rl;
    }

    if (mnem == 'FIFO.TRYR') {
      final rr = getR(0);
      final rl = ops.length > 1 ? parseReg(ops[1], fname, lno) : 0;
      return (0xE6 << 8) | (rr << 4) | rl;
    }

    if (mnem == 'FIFO.TRYW') {
      final rr = getR(0);
      final rl = ops.length > 1 ? parseReg(ops[1], fname, lno) : 0;
      return (0xE7 << 8) | (rr << 4) | rl;
    }

    if (mnem == 'MBOX') {
      final rr = getR(0);
      int vec = 0;
      if (ops.length > 1) {
        final op1 = ops[1].trim().toLowerCase();
        vec = regMap.containsKey(op1)
            ? parseReg(ops[1], fname, lno)
            : (int.tryParse(ops[1]) ?? 0);
      }
      return (0xE5 << 8) | (rr << 4) | (vec & 0x0F);
    }

    throw AssemblerError(
        "Unimplemented instruction mnemonic '$mnem'", fname, lno);
  }
}
