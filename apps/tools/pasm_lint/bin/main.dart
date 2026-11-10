// =============================================================================
// File: apps/tools/pasm_lint/bin/main.dart
// Project: Particle RISC Architecture
// Description: Static assembly linter for Particle RISC (.asm) sources.
//
// Responsibilities:
//   1. Verify immediate operand bounds (4-bit unsigned, 8-bit unsigned R14).
//   2. Verify branch direction constraints (FBRA forwards, BBRA backwards).
//   3. Enforce 2-operand instruction limits for native Particle ALU/shift ops.
//   4. Scan user macros (.macro) and included files (.include) to prevent
//      false-positive unrecognized mnemonic errors on macro expansions.
//   5. Remain completely silent on success (exit 0) for clean pipeline builds.
// =============================================================================

import "dart:io";

// -----------------------------------------------------------------------------
// ISA Instruction Classification Sets
// -----------------------------------------------------------------------------

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
  "MULHSU",
  "BSET",
  "BCLR",
  "BINV",
  "BGET",
};

/// Full canonical set of valid native Particle RISC mnemonics.
const Set<String> allValidMnemonics = {
  // System & Control
  "NOP", "HALT", "RESET", "WAIT", "INTR", "RET", "RETI", "TRAP",
  "RCALL", "RRET", "BRANCH", "JUMP", "JMP", "RJUMP",

  // PC-Relative Branching
  "FBRA", "FBRA.Z", "FBRA.NZ", "FBRA.P", "FBRA.N",
  "BBRA", "BBRA.Z", "BBRA.NZ", "BBRA.P", "BBRA.N",

  // Multi-byte Pseudo-ops / Macros
  "LOAD16", "LOAD24", "LOAD32", "PUSH32", "POP32",
  "PUSH4", "PUSH8",
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
  "MULL", "MULH", "SMULH", "MULHSU",

  // Bit Manipulation & System Registers
  "REV32", "NEG", "NOT", "NEZ", "CLZ", "JTBL", "BEXTR",
  "BSET", "BCLR", "BINV", "BGET",
  "SEXT8", "SEXT16", "XCHG", "XCHGALL", "XCHGMOST", "RBASE"
};

// -----------------------------------------------------------------------------
// Helper Routines
// -----------------------------------------------------------------------------

/// Parses integer literals supporting hexadecimal (0x), binary (0b),
/// and standard base-10 representations.
int? parseNumeric(String valStr) {
  final clean = valStr.trim();
  if (clean.isEmpty) return null;
  if (clean.startsWith("0x") || clean.startsWith("0X")) {
    return int.tryParse(clean.substring(2), radix: 16);
  } else if (clean.startsWith("0b") || clean.startsWith("0B")) {
    return int.tryParse(clean.substring(2), radix: 2);
  }
  return int.tryParse(clean, radix: 10);
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
  final equRegex = RegExp(r"^\s*([A-Za-z0-9_\.]+)\s+\.equ\b", caseSensitive: false);

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
  final inlineLabelRegex = RegExp(r"^([A-Za-z0-9_\.]+):\s*(.*)");

  for (var i = 0; i < lines.length; i++) {
    final lno = i + 1;
    var cleaned = lines[i].replaceAll(RegExp(r";.*"), "").trim();
    if (cleaned.isEmpty) continue;

    // Strip out leading labels on the same line as code
    final mInline = inlineLabelRegex.firstMatch(cleaned);
    if (mInline != null) {
      cleaned = mInline.group(2)!.trim();
      if (cleaned.isEmpty) continue;
    }

    // Directives (.ascii, .word, .org, etc.) are skipped by instruction linter
    if (cleaned.startsWith(".")) continue;

    final tokens = cleaned.split(RegExp(r"[\s,]+")).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) continue;

    final mnem = tokens[0].toUpperCase();

    // 1. Verify mnemonic or user macro existence
    if (!allValidMnemonics.contains(mnem) && !userMacros.contains(mnem)) {
      errors.add((lno, "Unrecognized mnemonic '$mnem'."));
      continue;
    }

    // 2. Validate immediate shift and rotate limits (4-bit unsigned: 0..15)
    if (imm4Shifts.contains(mnem)) {
      if (tokens.length == 3) {
        final imm = parseNumeric(tokens[2]);
        if (imm != null && (imm < 0 || imm > 15)) {
          errors.add((lno, "Immediate $imm (${tokens[2]}) out of 4-bit unsigned range (0..15) for $mnem ${tokens[1]}."));
        }
      } else if (tokens.length > 3) {
        errors.add((lno, "$mnem is strictly a 2-operand instruction in Particle RISC, but got ${tokens.length - 1} operands."));
      }
    }

    // 3. Validate arithmetic / logic immediate bounds (4-bit unsigned: 0..15)
    if (imm4ArithLogic.contains(mnem)) {
      if (tokens.length == 3) {
        final imm = parseNumeric(tokens[2]);
        if (imm != null && (imm < 0 || imm > 15)) {
          errors.add((lno, "Immediate $imm (${tokens[2]}) out of 4-bit unsigned range (0..15) for $mnem ${tokens[1]}."));
        }
      } else if (tokens.length > 3) {
        errors.add((lno, "$mnem is strictly a 2-operand instruction in Particle RISC, but got ${tokens.length - 1} operands."));
      }
    }

    // 4. Validate LD immediate bounds:
    //    LD R14, Imm8     -> 0..255
    //    LD R0..R13, Imm4 -> 0..15
    if (mnem == "LD") {
      if (tokens.length == 3) {
        final destReg = tokens[1].toUpperCase();
        final imm = parseNumeric(tokens[2]);
        if (destReg == "R14") {
          if (imm != null && (imm < 0 || imm > 255)) {
            errors.add((lno, "Immediate $imm (${tokens[2]}) out of 8-bit unsigned range (0..255) for LD R14. Use LOAD16/LOAD32."));
          }
        } else {
          if (imm != null && (imm < 0 || imm > 15)) {
            errors.add((lno, "Immediate $imm (${tokens[2]}) out of 4-bit unsigned range (0..15) for LD ${tokens[1]}. Use LOAD16/LOAD32 or load via R14."));
          }
        }
      } else if (tokens.length > 3) {
        errors.add((lno, "LD is strictly a 2-operand instruction in Particle RISC, but got ${tokens.length - 1} operands."));
      }
    }

    // 5. Enforce branch directions (FBRA forward, BBRA backward)
    if (branchForward.contains(mnem) || branchBackward.contains(mnem)) {
      if (tokens.length >= 2) {
        final targetLabel = tokens[1];
        if (labels.containsKey(targetLabel)) {
          final tgtLno = labels[targetLabel]!;
          if (branchForward.contains(mnem) && tgtLno < lno) {
            errors.add((lno, "Forward branch '$mnem $targetLabel' branches backward (target on line $tgtLno). Use BBRA/BBRA.* instead."));
          } else if (branchBackward.contains(mnem) && tgtLno > lno) {
            errors.add((lno, "Backward branch '$mnem $targetLabel' branches forward (target on line $tgtLno). Use FBRA/FBRA.* instead."));
          }
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
