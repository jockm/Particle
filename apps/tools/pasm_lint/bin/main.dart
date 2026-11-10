// =============================================================================
// File: apps/tools/pasm_lint/bin/main.dart
// Project: Particle RISC Architecture
// Description: Static assembly linter for Particle RISC (.asm) sources.
// Full parity with tools/pasm_lint.py.
// =============================================================================

import "dart:io";

final Set<String> regNames = {
  for (int i = 0; i < 16; i++) "r$i",
  "sp",
};

const Set<String> branchForward = {
  "FBRA", "FBRA.Z", "FBRA.NZ", "FBRA.P", "FBRA.N",
};

const Set<String> branchBackward = {
  "BBRA", "BBRA.Z", "BBRA.NZ", "BBRA.P", "BBRA.N",
};

const Set<String> imm4Shifts = {
  "SHIFTL", "SHIFTR", "ASHIFTR", "ROTL", "ROTR",
};

const Set<String> imm4ArithLogic = {
  "ADD", "SUB", "DIV", "MOD", "SADD", "SSUB", "SDIV", "SMOD",
  "SLT", "SSLT", "AND", "OR", "XOR", "MULL", "MULH", "SMULH", "MULHSU",
};

const Set<String> imm4BitOps = {
  "BSET", "BCLR", "BINV", "BGET",
};

const Set<String> memIndirectDisallowed = {
  "FIFO.W", "FIFO.R", "FIFO.STAT", "FIFO.TRYW", "FIFO.TRYR",
  "LD", "ADD", "SUB", "AND", "OR", "XOR", "SHIFTL", "SHIFTR", "ASHIFTR",
  "REV32", "NEG", "NOT", "NEZ", "CLZ", "BEXTR", "SEXT8", "SEXT16"
};

const Set<String> allValidMnemonics = {
  // ALU / Arithmetic / Logic
  "NOP", "ADD", "SUB", "AND", "OR", "XOR", "DIV", "MOD",
  "SADD", "SSUB", "SDIV", "SMOD", "SLT", "SSLT", "SGT", "SGE", "SLE", "SSLE",
  "SEQ", "SNE", "SHIFTL", "SHIFTR", "ASHIFTR", "REV32", "NEG", "NOT",
  "NEZ", "CLZ", "BEXTR", "BSET", "BCLR", "BINV", "BGET", "SEXT8", "SEXT16",
  "MULL", "MULH", "MULHU", "MULHSU", "SMULH", "ROTL", "ROTR",

  // Data Transfer / Memory
  "LD", "LD8", "LD16", "LD32", "ST8", "ST16", "ST32", "TAS",
  "LOAD16", "LOAD24", "LOAD32", "PUSH8", "PUSH16", "PUSH32",
  "POP8", "POP16", "POP32", "PUSH4",

  // Flow Control
  "FBRA", "FBRA.Z", "FBRA.NZ", "FBRA.P", "FBRA.N",
  "BBRA", "BBRA.Z", "BBRA.NZ", "BBRA.P", "BBRA.N",
  "RCALL", "RRET", "BRANCH", "JUMP", "JMP", "RJUMP", "CALL", "RET", "TRAP", "JTBL",
  "HALT", "RESET", "WAIT", "INTR", "FAST_ENTER_TRAP", "FAST_EXIT_TRAP",

  // FIFO / Inter-core
  "FIFO.W", "FIFO.R", "FIFO.STAT", "FIFO.TRYW", "FIFO.TRYR", "MBOX", "XCHG", "XCHGALL", "XCHGMOST", "RBASE",

  // Assembler Directives
  ".BYTE", ".HALF", ".WORD", ".ORG", ".ALIGN", ".GLOBAL", ".EXTERN",
  ".DEFINE", ".EQU", ".INCLUDE", ".STRING", ".ASCII", ".ASCIZ", ".BLOCK"
};

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
  final incRegex = RegExp(r'''^\s*\.include\s+["']([^"']+)["']''', caseSensitive: false);

  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.replaceAll(RegExp(r";.*"), "").trim();
    if (line.isEmpty) continue;

    final mMacro = macroRegex.firstMatch(line);
    if (mMacro != null) {
      userMacros.add(mMacro.group(1)!.toUpperCase());
      continue;
    }

    final mInc = incRegex.firstMatch(line);
    if (mInc != null) {
      final target = mInc.group(1)!.trim();
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

int lintFile(String filepath, List<String> includeDirs) {
  final file = File(filepath);
  if (!file.existsSync()) {
    stderr.writeln("[ERROR] File not found: $filepath");
    return 1;
  }

  final lines = file.readAsLinesSync();
  final errors = <(int, String)>[];
  final warnings = <(int, String)>[];

  final fileParent = file.parent.path;
  final incDirs = <String>[
    if (fileParent.isNotEmpty) fileParent else ".",
    ".",
    "lib",
    if (file.parent.parent.path.isNotEmpty) file.parent.parent.path,
    ...includeDirs,
  ];

  final userMacros = <String>{};
  scanMacrosFromFile(filepath, incDirs, userMacros, <String>{});

  final labels = <String, int>{};
  final defines = <String>{};

  final labelRegex = RegExp(r"^([A-Za-z0-9_\.]+):");
  final defineRegex = RegExp(r"^\.(?:define|equ)\s+([A-Za-z0-9_]+)", caseSensitive: false);
  final equRegex = RegExp(r"^([A-Za-z0-9_\.]+)\s+\.equ\b", caseSensitive: false);

  for (var i = 0; i < lines.length; i++) {
    final lno = i + 1;
    final line = lines[i].replaceAll(RegExp(r";.*"), "").trim();
    if (line.isEmpty) continue;

    final mDef = defineRegex.firstMatch(line);
    if (mDef != null) defines.add(mDef.group(1)!);

    final mEqu = equRegex.firstMatch(line);
    if (mEqu != null) defines.add(mEqu.group(1)!);

    final mLabel = labelRegex.firstMatch(line);
    if (mLabel != null) labels[mLabel.group(1)!] = lno;
  }

  final inlineLabelRegex = RegExp(r"^([A-Za-z0-9_\.]+):\s*(.*)");

  for (var i = 0; i < lines.length; i++) {
    final lno = i + 1;
    var cleaned = lines[i].replaceAll(RegExp(r";.*"), "").trim();
    if (cleaned.isEmpty) continue;

    final mInline = inlineLabelRegex.firstMatch(cleaned);
    if (mInline != null) {
      cleaned = mInline.group(2)!.trim();
      if (cleaned.isEmpty) continue;
    }

    final tokens = cleaned.split(RegExp(r"[\s,]+")).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) continue;

    final mnem = tokens[0].toUpperCase();
    final ops = tokens.sublist(1);

    // 0. Check for valid mnemonic, user macro, or directive
    if (!allValidMnemonics.contains(mnem) && !userMacros.contains(mnem) && !mnem.startsWith(".")) {
      errors.add((lno, "Unrecognized mnemonic '$mnem'."));
      continue;
    }

    // Directives skipped for instruction checks
    if (mnem.startsWith(".")) continue;

    // 1. Check for illegal 3-operand forms on 2-operand instructions
    if (imm4Shifts.contains(mnem) || imm4ArithLogic.contains(mnem) || mnem == "LD") {
      if (ops.length > 2) {
        errors.add((lno, "$mnem is strictly a 2-operand instruction in Particle RISC, but got ${ops.length} operands: '${ops.join(", ")}'"));
      }
    }

    // 2. Check illegal indirect parentheses operands
    for (final op in ops) {
      if (op.startsWith("(") && op.endsWith(")")) {
        if (memIndirectDisallowed.contains(mnem)) {
          errors.add((lno, "Instruction '$mnem' does not accept indirect memory operand '$op'. Use plain register or direct channel ID."));
        }
      }
    }

    // 3. Check LD immediate ranges
    if (mnem == "LD" && ops.length >= 2) {
      final dest = ops[0].toLowerCase();
      final valStr = ops[1];
      if (!regNames.contains(valStr.toLowerCase()) && !(valStr.startsWith("(") && valStr.endsWith(")"))) {
        final val = parseNumeric(valStr);
        if (val != null) {
          if (dest == "r14") {
            if (val < 0 || val > 255) {
              errors.add((lno, "Immediate $valStr ($val) out of 8-bit unsigned range (0..255) for LD R14."));
            }
          } else {
            if (val < 0 || val > 15) {
              errors.add((lno, "Immediate $valStr ($val) out of 4-bit unsigned range (0..15) for LD ${ops[0].toUpperCase()}. Use LOAD16/LOAD32 or load via R14."));
            }
          }
        }
      }
    }

    // 4. Check ALU arithmetic/logic Imm4 ranges
    if (imm4ArithLogic.contains(mnem) && ops.length >= 2) {
      final valStr = ops[1];
      if (!regNames.contains(valStr.toLowerCase())) {
        final val = parseNumeric(valStr);
        if (val != null && (val < 0 || val > 15)) {
          errors.add((lno, "Immediate $valStr ($val) out of 4-bit unsigned range (0..15) for $mnem. Load into register first."));
        }
      }
    }

    // 5. Check Shift Imm4 counts
    if (imm4Shifts.contains(mnem) && ops.length >= 2) {
      final valStr = ops[1];
      if (!regNames.contains(valStr.toLowerCase())) {
        final val = parseNumeric(valStr);
        if (val != null && (val < 0 || val > 15)) {
          errors.add((lno, "Shift count $valStr ($val) out of 4-bit range (0..15) for $mnem. Shifting > 15 must use a register operand."));
        }
      }
    }

    // 6. Check Bit manipulation Imm4 ranges
    if (imm4BitOps.contains(mnem) && ops.length >= 2) {
      final valStr = ops[1];
      if (!regNames.contains(valStr.toLowerCase())) {
        final val = parseNumeric(valStr);
        if (val != null && (val < 0 || val > 15)) {
          errors.add((lno, "Bit position $valStr ($val) out of 4-bit range (0..15) for $mnem."));
        }
      }
    }

    // 7. Check Forward / Backward branch direction consistency
    String? targetLabel;
    if (branchForward.contains(mnem) || branchBackward.contains(mnem)) {
      if (ops.length == 1 && !regNames.contains(ops[0].toLowerCase()) && parseNumeric(ops[0]) == null) {
        targetLabel = ops[0];
      } else if (ops.length == 2 && !regNames.contains(ops[1].toLowerCase()) && parseNumeric(ops[1]) == null) {
        targetLabel = ops[1];
      }

      if (targetLabel != null && labels.containsKey(targetLabel)) {
        final tgtLno = labels[targetLabel]!;
        if (branchForward.contains(mnem) && tgtLno < lno) {
          errors.add((lno, "Forward branch '$mnem $targetLabel' branches backward (target on line $tgtLno). Use BBRA/BBRA.* instead."));
        } else if (branchBackward.contains(mnem) && tgtLno > lno) {
          errors.add((lno, "Backward branch '$mnem $targetLabel' branches forward (target on line $tgtLno). Use FBRA/FBRA.* instead."));
        }
      }
    }
  }

  if (errors.isEmpty && warnings.isEmpty) {
    return 0;
  }

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

void main(List<String> args) {
  String? source;
  final includes = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == "-I" || arg == "--include") {
      if (i + 1 < args.length) includes.add(args[++i]);
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
