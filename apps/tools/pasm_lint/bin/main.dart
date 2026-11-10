// =============================================================================
// File: apps/tools/pasm_lint/bin/main.dart
// Project: Particle RISC Architecture
// Description: Static assembly linter for Particle RISC (.asm) sources.
//
// Responsibilities:
//   1. Verify immediate operand bounds (4-bit unsigned, 8-bit unsigned R14).
//   2. Verify branch direction constraints (FBRA forwards, BBRA backwards).
//   3. Enforce operand arity and instruction limits for native Particle ops.
//   4. Validate register names (r0..r15, sp) and detect invalid registers.
//   5. Validate memory load/store addressing modes:
//      - ST8/ST16/ST32 require parenthesized memory on the left: ST* (Rd), Rs
//      - LD8/LD16/LD32 accept memory indirect on either side:
//        LD* Rd, (Rs) [load] or LD* (Rd), Rs [store/push/pop]
//   6. Catch undefined branch target labels.
//   7. Scan user macros (.macro) and included files (.include) to prevent
//      false-positive unrecognized mnemonic errors on macro expansions.
//   8. Remain completely silent on success (exit 0) for clean pipeline builds.
// =============================================================================

import "dart:io";

// -----------------------------------------------------------------------------
// ISA Instruction Classification Sets
// -----------------------------------------------------------------------------

/// Valid register identifiers in Particle RISC.
const Set<String> validRegisters = {
  "R0", "R1", "R2", "R3", "R4", "R5", "R6", "R7",
  "R8", "R9", "R10", "R11", "R12", "R13", "R14", "R15", "SP"
};

/// Forward conditional and unconditional branches.
/// The target label must be located at a higher line number than the branch.
const Set<String> branchForward = {
  "FBRA",
  "FBRA.Z",
  "FBRA.NZ",
  "FBRA.P",
  "FBRA.N",
};

/// Backward conditional and unconditional branches.
/// The target label must be located at an earlier line number than the branch.
const Set<String> branchBackward = {
  "BBRA",
  "BBRA.Z",
  "BBRA.NZ",
  "BBRA.P",
  "BBRA.N",
};

/// 2-operand shift and rotate instructions that accept a 4-bit immediate (0..15).
const Set<String> imm4Shifts = {
  "SHIFTL",
  "SHIFTR",
  "ASHIFTR",
  "ROTL",
  "ROTR",
};

/// 2-operand ALU operations that accept a 4-bit immediate (0..15).
const Set<String> imm4ArithLogic = {
  "ADD",
  "SUB",
  "DIV",
  "MOD",
  "SADD",
  "SSUB",
  "SDIV",
  "SMOD",
  "AND",
  "OR",
  "XOR",
  "MULL",
  "MULH",
  "SMULH",
  "MULHU",
  "MULHSU",
  "BSET",
  "BCLR",
  "BINV",
  "BGET",
  "SLT",
  "SSLT",
  "SLE",
  "SSLE",
  "SEQ",
  "SNE",
};

/// Instructions strictly expecting 0 operands.
const Set<String> zeroOperandOps = {
  "NOP", "HALT", "RESET", "WAIT", "INTR", "RET", "RETI", "RRET"
};

/// Single-register ALU / unary operations strictly expecting 1 operand.
const Set<String> unaryRegisterOps = {
  "REV32", "NEG", "NOT", "NEZ", "CLZ", "SEXT8", "SEXT16",
  "FAST_ENTER_TRAP", "FAST_EXIT_TRAP",
};

/// Instructions where parenthesized indirect memory operands are forbidden.
const Set<String> memIndirectDisallowed = {
  "FIFO.W", "FIFO.R", "FIFO.STAT", "FIFO.TRYW", "FIFO.TRYR",
  "LD", "ADD", "SUB", "AND", "OR", "XOR", "SHIFTL", "SHIFTR", "ASHIFTR",
  "ROTL", "ROTR", "MULL", "MULH", "SMULH", "MULHU", "MULHSU",
  "REV32", "NEG", "NOT", "NEZ", "CLZ", "BEXTR", "SEXT8", "SEXT16",
  "SLT", "SSLT", "SLE", "SSLE", "SEQ", "SNE", "BSET", "BCLR", "BINV", "BGET"
};

/// Memory store operations requiring parenthesized destination (ST* (Rd), Rs).
const Set<String> storeOps = {"ST8", "ST16", "ST32"};

/// Memory load/store operations supporting either LD* Rd, (Rs) or LD* (Rd), Rs.
const Set<String> loadWidthOps = {"LD8", "LD16", "LD32"};

/// Full canonical set of valid native Particle RISC mnemonics.
const Set<String> allValidMnemonics = {
  // System & Control
  "NOP", "HALT", "RESET", "WAIT", "INTR", "RET", "RETI", "TRAP",
  "RCALL", "RRET", "BRANCH", "JUMP", "JMP", "RJUMP", "CALL",

  // PC-Relative Branching
  "FBRA", "FBRA.Z", "FBRA.NZ", "FBRA.P", "FBRA.N",
  "BBRA", "BBRA.Z", "BBRA.NZ", "BBRA.P", "BBRA.N",

  // Multi-byte Pseudo-ops / Macros
  "LOAD16", "LOAD24", "LOAD32", "PUSH32", "POP32",
  "PUSH4", "PUSH8", "PUSH16", "POP8", "POP16",
  "FAST_ENTER_TRAP", "FAST_EXIT_TRAP",

  // Comparisons (Signed and Unsigned)
  "SLT", "SLE", "SEQ", "SNE", "SSLT", "SSLE",

  // Streaming FIFOs & Inter-core Mailbox
  "FIFO.W", "FIFO.R", "FIFO.STAT", "FIFO.TRYW", "FIFO.TRYR", "MBOX",

  // Memory Operations
  "LD", "LD8", "LD16", "LD32", "ST8", "ST16", "ST32", "TAS",

  // Arithmetic & Logic
  "ADD", "SUB", "DIV", "MOD",
  "SADD", "SSUB", "SDIV", "SMOD",
  "AND", "OR", "XOR", "SHIFTL", "SHIFTR", "ASHIFTR", "ROTL", "ROTR",
  "MULL", "MULH", "SMULH", "MULHU", "MULHSU",

  // Bit Manipulation & System Registers
  "REV32", "NEG", "NOT", "NEZ", "CLZ", "JTBL", "BEXTR",
  "BSET", "BCLR", "BINV", "BGET",
  "SEXT8", "SEXT16", "XCHG", "XCHGALL", "XCHGMOST", "RBASE"
};

// -----------------------------------------------------------------------------
// Helper Routines
// -----------------------------------------------------------------------------

/// Parses integer literals supporting hexadecimal (0x), binary (0b),
/// and standard base-10 representations (including negative values).
int? parseNumeric(String valStr) {
  var clean = valStr.trim();
  if (clean.isEmpty) return null;

  var sign = 1;
  if (clean.startsWith("-")) {
    sign = -1;
    clean = clean.substring(1).trim();
  } else if (clean.startsWith("+")) {
    clean = clean.substring(1).trim();
  }

  int? parsed;
  if (clean.startsWith("0x") || clean.startsWith("0X")) {
    parsed = int.tryParse(clean.substring(2), radix: 16);
  } else if (clean.startsWith("0b") || clean.startsWith("0B")) {
    parsed = int.tryParse(clean.substring(2), radix: 2);
  } else {
    parsed = int.tryParse(clean, radix: 10);
  }

  return (parsed != null) ? parsed * sign : null;
}

/// Extracts inner register token from memory indirect syntax like (R1), (R2++), (--R3).
String extractIndirectBaseReg(String op) {
  var inner = op.substring(1, op.length - 1).trim();
  while (inner.startsWith("++") || inner.startsWith("--")) {
    inner = inner.substring(2).trim();
  }
  while (inner.endsWith("++") || inner.endsWith("--")) {
    inner = inner.substring(0, inner.length - 2).trim();
  }
  final plusIdx = inner.indexOf("+");
  if (plusIdx != -1) {
    inner = inner.substring(0, plusIdx).trim();
  }
  final minusIdx = inner.indexOf("-");
  if (minusIdx != -1) {
    inner = inner.substring(0, minusIdx).trim();
  }
  return inner.toUpperCase();
}

/// Recursively scans an assembly file and any referenced .include files
/// to register declared .macro <NAME> identifiers.
void scanMacrosFromFile(
  String path,
  List<String> incDirs,
  Set<String> userMacros,
  Set<String> visited,
) {
  final file = File(path);
  if (!file.existsSync()) return;

  final realPath = file.resolveSymbolicLinksSync();
  if (visited.contains(realPath)) return;
  visited.add(realPath);

  final macroRegex = RegExp(r"^\s*\.macro\s+([A-Za-z0-9_\.]+)", caseSensitive: false);
  final incRegex = RegExp(r"^\s*\.include\s+(.+)$", caseSensitive: false);

  for (final rawLine in file.readAsLinesSync()) {
    // Strip trailing line comments
    final line = rawLine.replaceAll(RegExp(r";.*"), "").trim();
    if (line.isEmpty) continue;

    // Detect .macro definitions
    final mMacro = macroRegex.firstMatch(line);
    if (mMacro != null) {
      userMacros.add(mMacro.group(1)!.toUpperCase());
      continue;
    }

    // Follow .include dependencies (stripping quotes cleanly)
    final mInc = incRegex.firstMatch(line);
    if (mInc != null) {
      var target = mInc.group(1)!.trim();
      if ((target.startsWith('"') && target.endsWith('"')) ||
          (target.startsWith("'") && target.endsWith("'"))) {
        target = target.substring(1, target.length - 1);
      }
      for (final d in incDirs) {
        final cand = File("$d/$target");
        if (cand.existsSync()) {
          scanMacrosFromFile(cand.path, incDirs, userMacros, visited);
          break;
        }
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Main Linting Engine
// -----------------------------------------------------------------------------

int lintFile(String filepath, List<String> includeDirs) {
  final file = File(filepath);
  if (!file.existsSync()) {
    stderr.writeln("[ERROR] File not found: $filepath");
    return 1;
  }

  final lines = file.readAsLinesSync();
  final errors = <(int, String)>[];
  final warnings = <(int, String)>[];

  // Build standard search paths for includes
  final fileParent = file.parent.path;
  final incDirs = <String>[
    if (fileParent.isNotEmpty) fileParent else ".",
    ".",
    "lib",
    if (file.parent.parent.path.isNotEmpty) file.parent.parent.path,
    ...includeDirs,
  ];

  // Pre-scan all macros to avoid false-positive unknown mnemonic warnings
  final userMacros = <String>{};
  scanMacrosFromFile(filepath, incDirs, userMacros, <String>{});

  // Pass 1: Record all label positions and directive definitions
  final labels = <String, int>{};
  final defines = <String>{};

  final labelRegex = RegExp(r"^\s*([A-Za-z0-9_\.]+):");
  final defineRegex = RegExp(r"^\s*\.define\s+([A-Za-z0-9_\.]+)", caseSensitive: false);
  final equRegex = RegExp(r"^\s*([A-Za-z0-9_\.]+)\s+\.equ", caseSensitive: false);

  for (var i = 0; i < lines.length; i++) {
    final lno = i + 1;
    final line = lines[i].replaceAll(RegExp(r";.*"), "").trim();
    if (line.isEmpty) continue;

    final mLabel = labelRegex.firstMatch(line);
    if (mLabel != null) {
      labels[mLabel.group(1)!] = lno;
    }

    final mDef = defineRegex.firstMatch(line);
    if (mDef != null) {
      defines.add(mDef.group(1)!);
    }

    final mEqu = equRegex.firstMatch(line);
    if (mEqu != null) {
      defines.add(mEqu.group(1)!);
    }
  }

  // Pass 2: Verify instructions, operand counts, and immediate ranges
  // Safe label match that ignores colons inside string literals
  final inlineLabelRegex = RegExp(r"^\s*([A-Za-z0-9_\.]+):\s*(.*)");

  for (var i = 0; i < lines.length; i++) {
    final lno = i + 1;
    var cleaned = lines[i].replaceAll(RegExp(r";.*"), "").trim();
    if (cleaned.isEmpty) continue;

    // Directives: check for bounds or quote errors, then skip instruction checks
    if (cleaned.startsWith(".") && !cleaned.startsWith("._")) {
      // Validate string closing quotes
      if (cleaned.startsWith(".ascii") || cleaned.startsWith(".asciz") || cleaned.startsWith(".string")) {
        final quoteCount = cleaned.split("").where((c) => c == '"').length;
        if (quoteCount < 2 || quoteCount % 2 != 0) {
          errors.add((lno, "Unterminated or malformed string literal in directive."));
        }
      }

      // Check numeric bounds on .byte and .half
      final dirTokens = cleaned.split(RegExp(r"[\s,]+")).where((t) => t.isNotEmpty).toList();
      if (dirTokens.length > 1) {
        final dirName = dirTokens[0].toLowerCase();
        for (var d = 1; d < dirTokens.length; d++) {
          final val = parseNumeric(dirTokens[d]);
          if (val != null) {
            if (dirName == ".byte" && (val < -128 || val > 255)) {
              errors.add((lno, "Directive .byte value $val out of 8-bit range (-128..255)."));
            } else if (dirName == ".half" && (val < -32768 || val > 65535)) {
              errors.add((lno, "Directive .half value $val out of 16-bit range (-32768..65535)."));
            }
          }
        }
      }
      continue;
    }

    // Strip out leading labels on the same line as code
    final mInline = inlineLabelRegex.firstMatch(cleaned);
    if (mInline != null) {
      cleaned = mInline.group(2)!.trim();
      if (cleaned.isEmpty) continue;
    }

    if (cleaned.startsWith(".") && !cleaned.startsWith("._")) continue;

    final tokens = cleaned.split(RegExp(r"[\s,]+")).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) continue;

    final mnem = tokens[0].toUpperCase();
    final ops = tokens.sublist(1);

    // 1. Verify mnemonic or user macro existence
    if (!allValidMnemonics.contains(mnem) && !userMacros.contains(mnem)) {
      errors.add((lno, "Unrecognized mnemonic '$mnem'."));
      continue;
    }

    // If it is an expanded macro, skip low-level native opcode constraints
    if (userMacros.contains(mnem)) {
      continue;
    }

    // 2. Validate Zero-Operand Instructions
    if (zeroOperandOps.contains(mnem)) {
      if (ops.isNotEmpty) {
        errors.add((lno, "$mnem takes 0 operands, but got ${ops.length}."));
      }
      continue;
    }

    // 3. Validate Single-Register ALU / Unary Operations
    if (unaryRegisterOps.contains(mnem)) {
      if (ops.length != 1) {
        errors.add((lno, "$mnem requires exactly 1 operand, but got ${ops.length}."));
      } else {
        final regUpper = ops[0].toUpperCase();
        if (!validRegisters.contains(regUpper)) {
          errors.add((lno, "Invalid register operand '${ops[0]}' for $mnem. Expected r0..r15 or sp."));
        }
      }
      continue;
    }

    // 4. Validate Memory Stores: ST* (Rd), Rs
    if (storeOps.contains(mnem)) {
      if (ops.length != 2) {
        errors.add((lno, "$mnem expects 2 operands (e.g. $mnem (Rd), Rs), got ${ops.length}."));
      } else {
        if (!ops[0].startsWith("(") || !ops[0].endsWith(")")) {
          errors.add((lno, "$mnem destination must use parenthesized memory indirect syntax: $mnem (Rd), Rs."));
        } else {
          final baseReg = extractIndirectBaseReg(ops[0]);
          if (!validRegisters.contains(baseReg)) {
            errors.add((lno, "Invalid register '$baseReg' in indirect operand '${ops[0]}'."));
          }
        }
        final srcReg = ops[1].toUpperCase();
        if (!validRegisters.contains(srcReg)) {
          errors.add((lno, "Invalid source register '${ops[1]}' for $mnem."));
        }
      }
      continue;
    }

    // 5. Validate Memory Loads & Stores via LD8/LD16/LD32:
    //    pasm supports both LD* Rd, (Rs) (load) and LD* (Rd), Rs (store / PUSH32 / POP32)
    if (loadWidthOps.contains(mnem)) {
      if (ops.length != 2) {
        errors.add((lno, "$mnem expects 2 operands (e.g. $mnem Rd, (Rs) or $mnem (Rd), Rs), got ${ops.length}."));
      } else {
        final leftIsMem = ops[0].startsWith("(") && ops[0].endsWith(")");
        final rightIsMem = ops[1].startsWith("(") && ops[1].endsWith(")");

        if (!leftIsMem && !rightIsMem) {
          errors.add((lno, "$mnem requires a parenthesized memory indirect operand: $mnem Rd, (Rs) or $mnem (Rd), Rs."));
        } else if (leftIsMem && rightIsMem) {
          errors.add((lno, "$mnem cannot have two memory operands: ${ops[0]}, ${ops[1]}."));
        } else if (rightIsMem) {
          // Standard Load: LD* Rd, (Rs)
          final destReg = ops[0].toUpperCase();
          if (!validRegisters.contains(destReg)) {
            errors.add((lno, "Invalid destination register '${ops[0]}' for $mnem."));
          }
          final baseReg = extractIndirectBaseReg(ops[1]);
          if (!validRegisters.contains(baseReg)) {
            errors.add((lno, "Invalid register '$baseReg' in indirect operand '${ops[1]}'."));
          }
        } else {
          // Store Form via LD*: LD* (Rd), Rs (e.g. PUSH32 / POP32)
          final baseReg = extractIndirectBaseReg(ops[0]);
          if (!validRegisters.contains(baseReg)) {
            errors.add((lno, "Invalid register '$baseReg' in indirect operand '${ops[0]}'."));
          }
          final srcReg = ops[1].toUpperCase();
          if (!validRegisters.contains(srcReg)) {
            errors.add((lno, "Invalid source register '${ops[1]}' for $mnem."));
          }
        }
      }
      continue;
    }

    // 6. Check for disallowed memory-indirect parentheses on native ALU/control ops
    for (final op in ops) {
      if (op.startsWith("(") && op.endsWith(")")) {
        if (memIndirectDisallowed.contains(mnem)) {
          errors.add((lno, "Instruction '$mnem' does not accept indirect memory operand '$op'."));
        }
      }
    }

    // 7. Validate Register Names on General Operands
    for (final op in ops) {
      final upper = op.toUpperCase();
      if (upper.startsWith("R") || upper == "SP") {
        final cleanReg = upper.replaceAll(RegExp(r"[^A-Za-z0-9]"), "");
        if (cleanReg.startsWith("R") && cleanReg != "RBASE") {
          final regNum = int.tryParse(cleanReg.substring(1));
          if (regNum != null && (regNum < 0 || regNum > 15)) {
            errors.add((lno, "Register identifier '$cleanReg' is out of range (allowed: r0..r15, sp)."));
          }
        }
      }
    }

    // 8. Validate immediate shift and rotate limits (4-bit unsigned: 0..15)
    if (imm4Shifts.contains(mnem)) {
      if (ops.length == 2) {
        final imm = parseNumeric(ops[1]);
        if (imm != null && (imm < 0 || imm > 15)) {
          errors.add((lno, "Immediate $imm (${ops[1]}) out of 4-bit unsigned range (0..15) for $mnem ${ops[0]}."));
        }
      } else if (ops.length > 2) {
        errors.add((lno, "$mnem is strictly a 2-operand instruction in Particle RISC, but got ${ops.length} operands."));
      } else if (ops.length < 2) {
        errors.add((lno, "$mnem requires 2 operands, but got ${ops.length}."));
      }
    }

    // 9. Validate arithmetic / logic immediate bounds (4-bit unsigned: 0..15)
    if (imm4ArithLogic.contains(mnem)) {
      if (ops.length == 2) {
        final imm = parseNumeric(ops[1]);
        if (imm != null && (imm < 0 || imm > 15)) {
          errors.add((lno, "Immediate $imm (${ops[1]}) out of 4-bit unsigned range (0..15) for $mnem ${ops[0]}."));
        }
      } else if (ops.length > 2) {
        errors.add((lno, "$mnem is strictly a 2-operand instruction in Particle RISC, but got ${ops.length} operands."));
      } else if (ops.length < 2) {
        errors.add((lno, "$mnem requires 2 operands, but got ${ops.length}."));
      }
    }

    // 10. Validate LD immediate bounds:
    //     LD R14, Imm8     -> 0..255 (or -255..0)
    //     LD R0..R13, Imm4 -> 0..15
    if (mnem == "LD") {
      if (ops.length == 2) {
        final destReg = ops[0].toUpperCase();
        final imm = parseNumeric(ops[1]);
        if (destReg == "R14") {
          if (imm != null && (imm < -255 || imm > 255)) {
            errors.add((lno, "Immediate $imm (${ops[1]}) out of 8-bit unsigned range (0..255) for LD R14. Use LOAD16/LOAD32."));
          }
        } else {
          if (imm != null && (imm < -15 || imm > 15)) {
            errors.add((lno, "Immediate $imm (${ops[1]}) out of 4-bit unsigned range (0..15) for LD ${ops[0]}. Use LOAD16/LOAD32 or load via R14."));
          }
        }
      } else if (ops.length > 2) {
        errors.add((lno, "LD is strictly a 2-operand instruction in Particle RISC, but got ${ops.length} operands."));
      } else if (ops.length < 2) {
        errors.add((lno, "LD requires 2 operands, but got ${ops.length}."));
      }
    }

    // 11. Enforce branch directions (FBRA forward, BBRA backward) and unresolved target detection
    if (branchForward.contains(mnem) || branchBackward.contains(mnem)) {
      String? targetLabel;
      if (ops.length == 1) {
        if (!validRegisters.contains(ops[0].toUpperCase()) && parseNumeric(ops[0]) == null) {
          targetLabel = ops[0];
        }
      } else if (ops.length == 2) {
        if (!validRegisters.contains(ops[1].toUpperCase()) && parseNumeric(ops[1]) == null) {
          targetLabel = ops[1];
        }
      }

      if (targetLabel != null) {
        if (labels.containsKey(targetLabel)) {
          final tgtLno = labels[targetLabel]!;
          if (branchForward.contains(mnem) && tgtLno < lno) {
            errors.add((lno, "Forward branch '$mnem $targetLabel' branches backward (target on line $tgtLno). Use BBRA/BBRA.* instead."));
          } else if (branchBackward.contains(mnem) && tgtLno > lno) {
            errors.add((lno, "Backward branch '$mnem $targetLabel' branches forward (target on line $tgtLno). Use FBRA/FBRA.* instead."));
          }
        } else if (!defines.contains(targetLabel)) {
          errors.add((lno, "Branch target label '$targetLabel' is undefined in this module."));
        }
      }
    }
  }

  // Silence is golden on success
  if (errors.isEmpty && warnings.isEmpty) {
    return 0;
  }

  // Display human-readable error diagnostics
  stderr.writeln("=== Particle Assembly Lint: $filepath ===");
  for (final err in errors) {
    stderr.writeln("[ERROR] Line ${err.$1.toString().padLeft(4)}: ${err.$2}");
  }
  for (final warn in warnings) {
    stderr.writeln("[WARN]  Line ${warn.$1.toString().padLeft(4)}: ${warn.$2}");
  }
  stderr.writeln("\nResult: ${errors.length} error(s), ${warnings.length} warning(s).");

  return errors.isNotEmpty ? 1 : 0;
}

// -----------------------------------------------------------------------------
// CLI Entry Point
// -----------------------------------------------------------------------------

void main(List<String> args) {
  String? source;
  final includes = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == "-I" || arg == "--include") {
      if (i + 1 < args.length) {
        includes.add(args[++i]);
      }
    } else if (arg.startsWith("-I")) {
      includes.add(arg.substring(2));
    } else if (!arg.startsWith("-")) {
      source = arg;
    }
  }

  if (source == null) {
    stderr.writeln("Usage: pasm_lint [options] <source.asm>");
    exit(1);
  }

  exit(lintFile(source, includes));
}
