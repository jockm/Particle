// =============================================================================
// File: apps/tools/pasm_lint/lib/linter.dart
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
//   9. Reject TRAP numbers outside 0..15, writes to R0 (hardwired to zero),
//      and stack pointer adjustments that are not a multiple of 4.
//  10. Warn when R14 is read after a LOAD16/24/32 or RCALL overwrote it.
//  11. Warn when data or code would be misaligned after byte-sized data.
//  12. Warn when pushes and pops do not balance before a routine returns.
//  13. Warn when an RCALL target is not defined in this file or its includes
//      (it must then come from another file in the build).
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
  "LD", "LDI", "LDIS", "ADD", "SUB", "AND", "OR", "XOR", "SHIFTL", "SHIFTR", "ASHIFTR",
  "ROTL", "ROTR", "MULL", "MULH", "SMULH", "MULHU", "MULHSU",
  "REV32", "NEG", "NOT", "NEZ", "CLZ", "BEXTR", "SEXT8", "SEXT16",
  "SLT", "SSLT", "SLE", "SSLE", "SEQ", "SNE", "BSET", "BCLR", "BINV", "BGET"
};

/// Memory store operations requiring parenthesized destination (ST* (Rd), Rs).
const Set<String> storeOps = {"ST8", "ST16", "ST32"};

/// Memory load/store operations supporting either LD* Rd, (Rs) or LD* (Rd), Rs.
const Set<String> loadWidthOps = {"LD8", "LD16", "LD32"};

/// Instructions whose first operand is a register they write (some also
/// read it). LD and LD8/16/32 write their first operand only in the load
/// form, which is checked separately.
const Set<String> writesFirstOperand = {
  ...imm4Shifts, ...imm4ArithLogic,
  "REV32", "NEG", "NOT", "NEZ", "CLZ", "SEXT8", "SEXT16", "BEXTR",
  "LDI", "LDIS", "LOAD16", "LOAD24", "LOAD32", "POP32", "FIFO.R", "XCHG",
};

/// Macros that leave R14 holding something else (they build values in it).
const Set<String> r14Clobbers = {"LOAD16", "LOAD24", "LOAD32", "RCALL"};

/// Instructions after which execution never continues on the next line.
const Set<String> unconditionalTransfers = {
  "FBRA", "BBRA", "RRET", "RET", "RETI", "JMP", "JUMP", "RJUMP", "BRANCH",
  "FAST_EXIT_TRAP", "HALT",
};

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
  "LD", "LDI", "LDIS", "LD8", "LD16", "LD32", "ST8", "ST16", "ST32", "TAS",

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

/// An instruction's (or directive's) first word and its operands, split as
/// the assembler splits them: the word up to the first space, then the
/// rest at commas, each trimmed. `LDI R5, _main + 4` has the two operands
/// `R5` and `_main + 4`.
(String, List<String>) splitInstruction(String text) {
  final t = text.trim();
  final sp = t.indexOf(RegExp(r"\s"));
  if (sp < 0) return (t, const <String>[]);
  final rest = t.substring(sp).trim();
  return (t.substring(0, sp), rest.isEmpty ? const <String>[] : rest.split(",").map((o) => o.trim()).toList());
}

/// Whether [s] is a name (a label or a symbol), not a number or an
/// expression.
bool _isName(String s) => RegExp(r"^[A-Za-z_.][A-Za-z0-9_.]*$").hasMatch(s);

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

/// Scans in-memory root lines and any referenced .include files on disk
/// to register declared .macro <NAME> identifiers.
void scanMacrosFromLines(
  String path,
  List<String> rawLines,
  List<String> incDirs,
  Set<String> userMacros,
  Set<String> visited,
) {
  final file = File(path);
  final realPath = file.existsSync() ? file.resolveSymbolicLinksSync() : file.absolute.path;
  visited.add(realPath);

  final macroRegex = RegExp(r"^\s*\.macro\s+([A-Za-z0-9_\.]+)", caseSensitive: false);
  final incRegex = RegExp(r"^\s*\.include\s+(.+)$", caseSensitive: false);

  for (final rawLine in rawLines) {
    final line = rawLine.replaceAll(RegExp(r";.*"), "").trim();
    if (line.isEmpty) continue;

    final mMacro = macroRegex.firstMatch(line);
    if (mMacro != null) {
      userMacros.add(mMacro.group(1)!.toUpperCase());
      continue;
    }

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

/// Scans included symbols starting from in-memory root lines.
void scanIncludedSymbolsFromLines(
  String path,
  List<String> rawLines,
  List<String> incDirs,
  Set<String> symbols,
  Set<String> visited,
) {
  final file = File(path);
  final realPath = file.existsSync() ? file.resolveSymbolicLinksSync() : file.absolute.path;
  visited.add(realPath);

  final incRegex = RegExp(r"^\s*\.include\s+(.+)$", caseSensitive: false);
  for (final rawLine in rawLines) {
    final line = rawLine.replaceAll(RegExp(r";.*"), "").trim();
    if (line.isEmpty) continue;
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
          scanIncludedSymbols(cand.path, incDirs, symbols, visited, isRoot: false);
          break;
        }
      }
    }
  }
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

/// Recursively collects the labels and .define/.equ names of the files that
/// [path] includes (not [path] itself), for checking RCALL targets.
void scanIncludedSymbols(
  String path,
  List<String> incDirs,
  Set<String> symbols,
  Set<String> visited, {
  bool isRoot = true,
}) {
  final file = File(path);
  if (!file.existsSync()) return;
  final realPath = file.resolveSymbolicLinksSync();
  if (visited.contains(realPath)) return;
  visited.add(realPath);

  final incRegex = RegExp(r"^\s*\.include\s+(.+)$", caseSensitive: false);
  final labelRegex = RegExp(r"^\s*([A-Za-z0-9_\.]+):");
  final defRegex = RegExp(r"^\s*\.(?:define|equ)\s+([A-Za-z0-9_\.]+)", caseSensitive: false);
  final equRegex = RegExp(r"^\s*([A-Za-z0-9_\.]+)\s+\.equ", caseSensitive: false);

  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.replaceAll(RegExp(r";.*"), "").trim();
    if (line.isEmpty) continue;
    if (!isRoot) {
      final mLabel = labelRegex.firstMatch(line);
      if (mLabel != null) symbols.add(mLabel.group(1)!);
      final mDef = defRegex.firstMatch(line);
      if (mDef != null) symbols.add(mDef.group(1)!);
      final mEqu = equRegex.firstMatch(line);
      if (mEqu != null) symbols.add(mEqu.group(1)!);
    }
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
          scanIncludedSymbols(cand.path, incDirs, symbols, visited, isRoot: false);
          break;
        }
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Main Linting Engine
// -----------------------------------------------------------------------------

/// One diagnostic: its line (counted from 1), its code (one of
/// [diagnosticCodes]) and its message.
typedef LintMessage = (int, String, String);

/// Structured output returned by [lintLines] for both CLI and LSP diagnostics.
class LintResult {
  final List<LintMessage> errors;
  final List<LintMessage> warnings;

  const LintResult(this.errors, this.warnings);
}

/// Runs all static lint and control-flow checks on in-memory [lines] for [filepath].
/// Does not require [filepath] to exist on disk, allowing live unsaved buffer linting
/// inside pasm_lsp while still resolving relative .include directives from [filepath]'s parent.
LintResult lintLines(String filepath, List<String> lines, List<String> includeDirs) {
  final file = File(filepath);
  final errors = <LintMessage>[];
  final warnings = <LintMessage>[];

  // Build standard search paths for includes
  final fileParent = file.parent.path;
  final incDirs = <String>[
    if (fileParent.isNotEmpty) fileParent else ".",
    ".",
    "lib",
    if (file.parent.parent.path.isNotEmpty) file.parent.parent.path,
    ...includeDirs,
  ];

  // Pre-scan all macros from in-memory lines and included files
  final userMacros = <String>{};
  scanMacrosFromLines(filepath, lines, incDirs, userMacros, <String>{});

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
      // Validate string closing quotes (ignoring escaped quotes)
      if (cleaned.startsWith(".ascii") || cleaned.startsWith(".asciz") || cleaned.startsWith(".string")) {
        var unescapedQuotes = 0;
        for (var idx = 0; idx < cleaned.length; idx++) {
          if (cleaned[idx] == '"') {
            var slashCount = 0;
            var sIdx = idx - 1;
            while (sIdx >= 0 && cleaned[sIdx] == r"\") {
              slashCount++;
              sIdx--;
            }
            if (slashCount % 2 == 0) {
              unescapedQuotes++;
            }
          }
        }
        if (unescapedQuotes < 2 || unescapedQuotes % 2 != 0) {
          errors.add((lno, "syntax", "Unterminated or malformed string literal in directive."));
        }
      }

      // Check numeric bounds on .byte and .half. The values are split at
      // commas, as the assembler splits them; an expression is not checked
      // here (the assembler checks it)
      final (dirWord, dirValues) = splitInstruction(cleaned);
      if (dirValues.isNotEmpty) {
        final dirName = dirWord.toLowerCase();
        for (final dv in dirValues) {
          final val = parseNumeric(dv);
          if (val != null) {
            if (dirName == ".byte" && (val < -128 || val > 255)) {
              errors.add((lno, "range", "Directive .byte value $val out of 8-bit range (-128..255)."));
            } else if (dirName == ".half" && (val < -32768 || val > 65535)) {
              errors.add((lno, "range", "Directive .half value $val out of 16-bit range (-32768..65535)."));
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

    final (mnemWord, ops) = splitInstruction(cleaned);
    if (mnemWord.isEmpty) continue;

    final mnem = mnemWord.toUpperCase();

    // 1. Verify mnemonic or user macro existence
    if (!allValidMnemonics.contains(mnem) && !userMacros.contains(mnem)) {
      errors.add((lno, "syntax", "Unrecognized mnemonic '$mnem'."));
      continue;
    }

    // If it is an expanded macro, skip low-level native opcode constraints
    if (userMacros.contains(mnem)) {
      continue;
    }

    // 2. Validate Zero-Operand Instructions
    if (zeroOperandOps.contains(mnem)) {
      if (ops.isNotEmpty) {
        errors.add((lno, "syntax", "$mnem takes 0 operands, but got ${ops.length}."));
      }
      continue;
    }

    // 3. Validate Single-Register ALU / Unary Operations
    if (unaryRegisterOps.contains(mnem)) {
      if (ops.length != 1) {
        errors.add((lno, "syntax", "$mnem requires exactly 1 operand, but got ${ops.length}."));
      } else {
        final regUpper = ops[0].toUpperCase();
        if (!validRegisters.contains(regUpper)) {
          errors.add((lno, "register", "Invalid register operand '${ops[0]}' for $mnem. Expected r0..r15 or sp."));
        }
      }
      continue;
    }

    // 4. Validate Memory Stores: ST* (Rd), Rs
    if (storeOps.contains(mnem)) {
      if (ops.length != 2) {
        errors.add((lno, "syntax", "$mnem expects 2 operands (e.g. $mnem (Rd), Rs), got ${ops.length}."));
      } else {
        if (!ops[0].startsWith("(") || !ops[0].endsWith(")")) {
          errors.add((lno, "syntax", "$mnem destination must use parenthesized memory indirect syntax: $mnem (Rd), Rs."));
        } else {
          final baseReg = extractIndirectBaseReg(ops[0]);
          if (!validRegisters.contains(baseReg)) {
            errors.add((lno, "register", "Invalid register '$baseReg' in indirect operand '${ops[0]}'."));
          }
        }
        final srcReg = ops[1].toUpperCase();
        if (!validRegisters.contains(srcReg)) {
          errors.add((lno, "register", "Invalid source register '${ops[1]}' for $mnem."));
        }
      }
      continue;
    }

    // 5. Validate Memory Loads & Stores via LD8/LD16/LD32:
    //    pasm supports both LD* Rd, (Rs) (load) and LD* (Rd), Rs (store / PUSH32 / POP32)
    if (loadWidthOps.contains(mnem)) {
      if (ops.length != 2) {
        errors.add((lno, "syntax", "$mnem expects 2 operands (e.g. $mnem Rd, (Rs) or $mnem (Rd), Rs), got ${ops.length}."));
      } else {
        final leftIsMem = ops[0].startsWith("(") && ops[0].endsWith(")");
        final rightIsMem = ops[1].startsWith("(") && ops[1].endsWith(")");

        if (!leftIsMem && !rightIsMem) {
          errors.add((lno, "syntax", "$mnem requires a parenthesized memory indirect operand: $mnem Rd, (Rs) or $mnem (Rd), Rs."));
        } else if (leftIsMem && rightIsMem) {
          errors.add((lno, "syntax", "$mnem cannot have two memory operands: ${ops[0]}, ${ops[1]}."));
        } else if (rightIsMem) {
          // Standard Load: LD* Rd, (Rs)
          final destReg = ops[0].toUpperCase();
          if (!validRegisters.contains(destReg)) {
            errors.add((lno, "register", "Invalid destination register '${ops[0]}' for $mnem."));
          }
          final baseReg = extractIndirectBaseReg(ops[1]);
          if (!validRegisters.contains(baseReg)) {
            errors.add((lno, "register", "Invalid register '$baseReg' in indirect operand '${ops[1]}'."));
          }
        } else {
          // Store Form via LD*: LD* (Rd), Rs (e.g. PUSH32 / POP32)
          final baseReg = extractIndirectBaseReg(ops[0]);
          if (!validRegisters.contains(baseReg)) {
            errors.add((lno, "register", "Invalid register '$baseReg' in indirect operand '${ops[0]}'."));
          }
          final srcReg = ops[1].toUpperCase();
          if (!validRegisters.contains(srcReg)) {
            errors.add((lno, "register", "Invalid source register '${ops[1]}' for $mnem."));
          }
        }
      }
      continue;
    }

    // 5a. TRAP numbers: there are 16 trap vectors
    if (mnem == "TRAP" && ops.length == 1) {
      final n = parseNumeric(ops[0]);
      if (n != null && (n < 0 || n > 15)) {
        errors.add((lno, "range", "TRAP $n is out of range: trap numbers are 0..15."));
      }
    }

    // 5b. R0 is hardwired to zero: writing it has no effect
    if (ops.isNotEmpty &&
        ops[0].toUpperCase() == "R0" &&
        (writesFirstOperand.contains(mnem) || (mnem == "LD" && ops.length == 2))) {
      errors.add((lno, "r0-write", "$mnem writes R0, which is hardwired to zero; the result is lost."));
    }

    // 5c. The stack pointer must stay a multiple of 4
    if (const {"ADD", "SUB", "SADD", "SSUB"}.contains(mnem) &&
        ops.length == 2 &&
        const {"R15", "SP"}.contains(ops[0].toUpperCase())) {
      final n = parseNumeric(ops[1]);
      if (n != null && n % 4 != 0) {
        errors.add((lno, "stack-misaligned", "$mnem ${ops[0]}, $n leaves the stack pointer misaligned; adjust it by a multiple of 4."));
      }
    }

    // 6. Check for disallowed memory-indirect parentheses on native ALU/control ops
    for (final op in ops) {
      if (op.startsWith("(") && op.endsWith(")")) {
        if (memIndirectDisallowed.contains(mnem)) {
          errors.add((lno, "syntax", "Instruction '$mnem' does not accept indirect memory operand '$op'."));
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
            errors.add((lno, "register", "Register identifier '$cleanReg' is out of range (allowed: r0..r15, sp)."));
          }
        }
      }
    }

    // 8. Validate immediate shift and rotate limits (4-bit unsigned: 0..15)
    if (imm4Shifts.contains(mnem)) {
      if (ops.length == 2) {
        final imm = parseNumeric(ops[1]);
        if (imm != null && (imm < 0 || imm > 15)) {
          errors.add((lno, "range", "Immediate $imm (${ops[1]}) out of 4-bit unsigned range (0..15) for $mnem ${ops[0]}."));
        }
      } else if (ops.length > 2) {
        errors.add((lno, "syntax", "$mnem is strictly a 2-operand instruction in Particle RISC, but got ${ops.length} operands."));
      } else if (ops.length < 2) {
        errors.add((lno, "syntax", "$mnem requires 2 operands, but got ${ops.length}."));
      }
    }

    // 9. Validate arithmetic / logic immediate bounds (4-bit unsigned: 0..15)
    if (imm4ArithLogic.contains(mnem)) {
      if (ops.length == 2) {
        final imm = parseNumeric(ops[1]);
        if (imm != null && (imm < 0 || imm > 15)) {
          errors.add((lno, "range", "Immediate $imm (${ops[1]}) out of 4-bit unsigned range (0..15) for $mnem ${ops[0]}."));
        }
      } else if (ops.length > 2) {
        errors.add((lno, "syntax", "$mnem is strictly a 2-operand instruction in Particle RISC, but got ${ops.length} operands."));
      } else if (ops.length < 2) {
        errors.add((lno, "syntax", "$mnem requires 2 operands, but got ${ops.length}."));
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
            errors.add((lno, "range", "Immediate $imm (${ops[1]}) out of 8-bit unsigned range (0..255) for LD R14. Use LOAD16/LOAD32."));
          }
        } else {
          if (imm != null && (imm < -15 || imm > 15)) {
            errors.add((lno, "range", "Immediate $imm (${ops[1]}) out of 4-bit unsigned range (0..15) for LD ${ops[0]}. Use LOAD16/LOAD32 or load via R14."));
          }
        }
      } else if (ops.length > 2) {
        errors.add((lno, "syntax", "LD is strictly a 2-operand instruction in Particle RISC, but got ${ops.length} operands."));
      } else if (ops.length < 2) {
        errors.add((lno, "syntax", "LD requires 2 operands, but got ${ops.length}."));
      }
    }

    // 10a. Validate LDI / LDIS operand arity and 16-bit immediate bounds
    if (mnem == "LDI" || mnem == "LDIS") {
      if (ops.length != 2) {
        errors.add((lno, "syntax", "$mnem expects 2 operands ($mnem Rl, <imm16>), but got ${ops.length}."));
      } else {
        final destReg = ops[0].toUpperCase();
        if (!validRegisters.contains(destReg)) {
          errors.add((lno, "register", "Invalid destination register '${ops[0]}' for $mnem. Expected r0..r15 or sp."));
        }
        if (validRegisters.contains(ops[1].toUpperCase())) {
          errors.add((lno, "syntax", "$mnem immediate operand cannot be a register ('${ops[1]}')."));
        } else {
          final imm = parseNumeric(ops[1]);
          if (mnem == "LDI") {
            if (imm != null && (imm < 0 || imm > 0xFFFF)) {
              errors.add((lno, "range", "Immediate $imm (${ops[1]}) out of 16-bit unsigned range (0..65535) for LDI."));
            }
          } else {
            if (imm != null && (imm < -32768 || imm > 0xFFFF)) {
              errors.add((lno, "range", "Immediate $imm (${ops[1]}) out of 16-bit signed range (-32768..32767) for LDIS."));
            }
          }
        }
      }
    }

    // 11. Enforce branch directions (FBRA forward, BBRA backward) and unresolved target detection
    if (branchForward.contains(mnem) || branchBackward.contains(mnem)) {
      String? targetLabel;
      if (ops.length == 1) {
        if (!validRegisters.contains(ops[0].toUpperCase()) && _isName(ops[0])) {
          targetLabel = ops[0];
        }
      } else if (ops.length == 2) {
        if (!validRegisters.contains(ops[1].toUpperCase()) && _isName(ops[1])) {
          targetLabel = ops[1];
        }
      }

      if (targetLabel != null) {
        if (labels.containsKey(targetLabel)) {
          final tgtLno = labels[targetLabel]!;
          if (branchForward.contains(mnem) && tgtLno < lno) {
            errors.add((lno, "branch-direction", "Forward branch '$mnem $targetLabel' branches backward (target on line $tgtLno). Use BBRA/BBRA.* instead."));
          } else if (branchBackward.contains(mnem) && tgtLno > lno) {
            errors.add((lno, "branch-direction", "Backward branch '$mnem $targetLabel' branches forward (target on line $tgtLno). Use FBRA/FBRA.* instead."));
          }
        } else if (!defines.contains(targetLabel)) {
          errors.add((lno, "undefined-symbol", "Branch target label '$targetLabel' is undefined in this module."));
        }
      }
    }
  }

  // Checks that follow the code from line to line
  final includedSymbols = <String>{};
  scanIncludedSymbolsFromLines(filepath, lines, incDirs, includedSymbols, <String>{});
  final parsed = parseLines(lines);
  checkR14Clobbers(parsed, userMacros, warnings);
  checkAlignment(parsed, warnings);
  checkStackBalance(parsed, warnings);
  for (final pl in parsed) {
    if (pl.mnem != "RCALL" || pl.ops.length != 1) continue;
    final target = pl.ops[0];
    if (validRegisters.contains(target.toUpperCase()) || !_isName(target)) continue;
    if (labels.containsKey(target) || defines.contains(target) || includedSymbols.contains(target)) {
      continue;
    }
    warnings.add((pl.lno, "external-call",
        "RCALL target '$target' is not defined in this file or its includes; it must come from another file in the build."));
  }
  errors.sort((a, b) => a.$1.compareTo(b.$1));
  warnings.sort((a, b) => a.$1.compareTo(b.$1));

  final hidden = findSuppressions(lines);
  errors.removeWhere((d) => hidden.hides(d.$1, d.$2));
  warnings.removeWhere((d) => hidden.hides(d.$1, d.$2));

  return LintResult(errors, warnings);
}

/// The codes of the assembler's and the linter's diagnostics.
const diagnosticCodes = {
  // Errors
  "syntax", "register", "range", "undefined-symbol", "expression",
  "branch-range", "branch-direction", "jump", "include", "reserved-name",
  "r0-write", "stack-misaligned",
  // Warnings
  "external-call", "r14-clobbered", "misaligned", "stack-balance",
};

/// The diagnostics hidden by comments:
///   `; pasm-disable-line`       this line
///   `; pasm-disable-next-line`  the next line
///   `; pasm-disable` ... `; pasm-enable`  the lines between
///   `; pasm-disable-file`       the whole file
/// Each may name codes (`; pasm-disable-line undefined-symbol, range`);
/// without codes it hides every diagnostic.
class Suppressions {
  /// For each line (counted from 1), the codes hidden there; an empty set
  /// hides every code.
  final Map<int, Set<String>> lines;

  /// The codes hidden in the whole file (empty: every code), or null.
  final Set<String>? file;

  const Suppressions(this.file, this.lines);

  /// Whether a diagnostic with [code] on line [lno] is hidden.
  bool hides(int lno, [String? code]) => _covers(file, code) || _covers(lines[lno], code);

  static bool _covers(Set<String>? codes, String? code) =>
      codes != null && (codes.isEmpty || (code != null && codes.contains(code)));
}

final _suppressRe = RegExp(r"(?<![\w-])pasm-(disable-next-line|disable-line|disable-file|disable|enable)(?![\w-])");

/// The codes named right after a directive: the words from [rest] up to
/// the first that is not a code. Other text (a reason) may follow.
Set<String> _codesAfter(String rest) {
  final codes = <String>{};
  for (final w in rest.split(RegExp(r"[\s,]+"))) {
    if (w.isEmpty) continue;
    if (!diagnosticCodes.contains(w)) break;
    codes.add(w);
  }
  return codes;
}

/// [a] and [b] together, where an empty set means every code.
Set<String>? _merge(Set<String>? a, Set<String>? b) {
  if (a == null) return b;
  if (b == null) return a;
  if (a.isEmpty || b.isEmpty) return <String>{};
  return {...a, ...b};
}

/// Finds the `; pasm-disable...` comments in [lines].
Suppressions findSuppressions(List<String> lines) {
  Set<String>? file;
  final hidden = <int, Set<String>>{};
  void hide(int lno, Set<String> codes) => hidden[lno] = _merge(hidden[lno], codes)!;
  Set<String>? block;
  for (var i = 0; i < lines.length; i++) {
    final lno = i + 1;
    final code = _stripComment(lines[i]);
    final comment = lines[i].substring(code.length);
    var enabled = false;
    for (final m in _suppressRe.allMatches(comment)) {
      final codes = _codesAfter(comment.substring(m.end));
      switch (m.group(1)) {
        case "disable-line":
          hide(lno, codes);
        case "disable-next-line":
          hide(lno + 1, codes);
        case "disable-file":
          file = _merge(file, codes);
        case "disable":
          block = _merge(block, codes);
        case "enable":
          enabled = true;
      }
    }
    if (block != null && !enabled) hide(lno, block);
    if (enabled) block = null;
  }
  return Suppressions(file, hidden);
}

/// CLI wrapper around [lintLines] that reads [filepath] from disk and prints
/// human-readable diagnostics to stderr on failure.
int lintFile(String filepath, List<String> includeDirs) {
  final file = File(filepath);
  if (!file.existsSync()) {
    stderr.writeln("[ERROR] File not found: $filepath");
    return 1;
  }

  final lines = file.readAsLinesSync();
  final result = lintLines(filepath, lines, includeDirs);
  final errors = result.errors;
  final warnings = result.warnings;

  // Silence is golden on success
  if (errors.isEmpty && warnings.isEmpty) {
    return 0;
  }

  // Display human-readable error diagnostics
  stderr.writeln("=== Particle Assembly Lint: $filepath ===");
  for (final err in errors) {
    stderr.writeln("[ERROR] Line ${err.$1.toString().padLeft(4)}: ${err.$3} [${err.$2}]");
  }
  for (final warn in warnings) {
    stderr.writeln("[WARN]  Line ${warn.$1.toString().padLeft(4)}: ${warn.$3} [${warn.$2}]");
  }
  stderr.writeln("\nResult: ${errors.length} error(s), ${warnings.length} warning(s).");

  return errors.isNotEmpty ? 1 : 0;
}

// -----------------------------------------------------------------------------
// Line-by-line flow checks
// -----------------------------------------------------------------------------

/// One source line: its labels, and either a directive or an instruction.
class ParsedLine {
  final int lno;
  final List<String> labels;

  /// Directive name in lower case (".word"), or null.
  final String? directive;

  /// The directive's text after its name.
  final String directiveArgs;

  /// Instruction mnemonic in upper case, or null.
  final String? mnem;
  final List<String> ops;

  ParsedLine(this.lno, this.labels, this.directive, this.directiveArgs, this.mnem, this.ops);
}

/// Splits the file into labels, directives and instructions. Lines inside
/// .macro ... .endmacro are left out: their operands are parameters.
List<ParsedLine> parseLines(List<String> lines) {
  final out = <ParsedLine>[];
  final labelRe = RegExp(r"^([A-Za-z0-9_\.]+):\s*(.*)$");
  var inMacro = false;
  for (var i = 0; i < lines.length; i++) {
    var text = _stripComment(lines[i]).trim();
    if (text.isEmpty) continue;
    final lower = text.toLowerCase();
    if (lower.startsWith(".macro")) {
      inMacro = true;
      continue;
    }
    if (lower.startsWith(".endmacro") || lower.startsWith(".endm")) {
      inMacro = false;
      continue;
    }
    if (inMacro) continue;
    final labels = <String>[];
    while (true) {
      final m = labelRe.firstMatch(text);
      if (m == null) break;
      labels.add(m.group(1)!);
      text = m.group(2)!.trim();
    }
    if (text.isEmpty) {
      out.add(ParsedLine(i + 1, labels, null, "", null, const []));
    } else if (text.startsWith(".") && !text.startsWith("._")) {
      final sp = text.indexOf(RegExp(r"\s"));
      final name = (sp < 0 ? text : text.substring(0, sp)).toLowerCase();
      final args = sp < 0 ? "" : text.substring(sp).trim();
      out.add(ParsedLine(i + 1, labels, name, args, null, const []));
    } else {
      final (mnemWord, ops) = splitInstruction(text);
      out.add(ParsedLine(i + 1, labels, null, "", mnemWord.toUpperCase(), ops));
    }
  }
  return out;
}

/// Removes a `;` comment, leaving any `;` inside a string literal.
String _stripComment(String line) {
  var inStr = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == "\\" && inStr) {
      i++;
    } else if (c == '"') {
      inStr = !inStr;
    } else if (c == ";" && !inStr) {
      return line.substring(0, i);
    }
  }
  return line;
}

bool _isR14(String op) => op.toUpperCase() == "R14";

bool _isMem(String op) => op.startsWith("(") && op.endsWith(")");

/// Whether [pl] reads R14, and whether it writes it.
(bool, bool) _r14Use(ParsedLine pl) {
  final mnem = pl.mnem!;
  final ops = pl.ops;
  var reads = false;
  var writes = false;
  for (var k = 0; k < ops.length; k++) {
    final op = ops[k];
    if (_isMem(op)) {
      if (extractIndirectBaseReg(op) == "R14") {
        reads = true;
        if (op.contains("++") || op.contains("--")) writes = true;
      }
      continue;
    }
    if (!_isR14(op)) continue;
    if (k == 1 && mnem == "JMP") {
      // JMP Rr, Rl: the link register is only written
      writes = true;
      continue;
    }
    if (k == 0) {
      // A destination that is only written
      final pureWrite = const {"LDI", "LDIS", "LOAD16", "LOAD24", "LOAD32", "POP32", "FIFO.R"}.contains(mnem) ||
          (mnem == "LD" && ops.length == 2) ||
          (const {"LD8", "LD16", "LD32"}.contains(mnem) && ops.length == 2 && _isMem(ops[1]));
      if (pureWrite) {
        writes = true;
        continue;
      }
      if (writesFirstOperand.contains(mnem)) writes = true;
    }
    reads = true;
  }
  if (mnem == "FIFO.TRYR" || mnem == "FIFO.TRYW") writes = true; // status in R14
  return (reads, writes);
}

/// 47: R14 is read after a macro overwrote it, with no new value in
/// between. Followed in straight-line code; a label starts afresh.
void checkR14Clobbers(List<ParsedLine> lines, Set<String> userMacros, List<LintMessage> warnings) {
  int? clobberLine;
  String? clobberBy;
  for (final pl in lines) {
    if (pl.labels.isNotEmpty) clobberLine = null;
    final mnem = pl.mnem;
    if (mnem == null) continue;
    if (userMacros.contains(mnem) && !r14Clobbers.contains(mnem) && !allValidMnemonics.contains(mnem)) {
      // A user macro may do anything with R14
      clobberLine = null;
      continue;
    }
    final (reads, writes) = _r14Use(pl);
    final destIsR14 = pl.ops.isNotEmpty && _isR14(pl.ops[0]);
    if (reads && clobberLine != null) {
      warnings.add((pl.lno, "r14-clobbered",
          "R14 is read here, but $clobberBy on line $clobberLine overwrote it (LOAD16/24/32 and RCALL use R14)."));
      clobberLine = null;
    }
    if (writes || (r14Clobbers.contains(mnem) && mnem != "RCALL" && destIsR14)) {
      clobberLine = null;
    } else if (r14Clobbers.contains(mnem)) {
      clobberLine = pl.lno;
      clobberBy = mnem;
    }
    if (unconditionalTransfers.contains(mnem)) clobberLine = null;
  }
}

/// Number of bytes a string literal directive emits, or null if unsure.
int? _stringBytes(String args) {
  final start = args.indexOf('"');
  if (start < 0) return null;
  var n = 0;
  for (var i = start + 1; i < args.length; i++) {
    final c = args[i];
    if (c == '"') return n;
    if (c == "\\") {
      if (i + 1 < args.length && args[i + 1] == "x") {
        i += 3;
      } else if (i + 1 < args.length && RegExp(r"[0-7]").hasMatch(args[i + 1])) {
        // Octal escape: up to three digits
        var k = 0;
        while (k < 3 && i + 1 < args.length && RegExp(r"[0-7]").hasMatch(args[i + 1])) {
          i++;
          k++;
        }
      } else {
        i++;
      }
    }
    n++;
  }
  return null;
}

/// 48: .half or .word data, or code, placed after byte-sized data that
/// leaves it misaligned, with no .align in between.
void checkAlignment(List<ParsedLine> lines, List<LintMessage> warnings) {
  // Bytes of byte-sized data since the last .align or .org, modulo 4; -1
  // when unknown (a string or .space whose size could not be worked out)
  int? pending; // null: no byte-sized data since the last alignment
  int? since;
  int itemCount(String args) =>
      args.split(",").where((t) => t.trim().isNotEmpty).length;
  for (final pl in lines) {
    final d = pl.directive;
    if (d != null) {
      if (d == ".align" || d == ".org" || d == ".balign" || d == ".p2align") {
        pending = null;
        continue;
      }
      int? bytes;
      if (d == ".byte") {
        bytes = itemCount(pl.directiveArgs);
      } else if (d == ".ascii") {
        bytes = _stringBytes(pl.directiveArgs);
      } else if (d == ".asciz" || d == ".string") {
        final b = _stringBytes(pl.directiveArgs);
        bytes = b == null ? null : b + 1;
      } else if (d == ".space" || d == ".skip" || d == ".zero") {
        final v = parseNumeric(pl.directiveArgs.split(",").first);
        bytes = v;
      } else if (d == ".half" || d == ".word") {
        final need = d == ".half" ? 2 : 4;
        final p = pending;
        if (p != null && (p < 0 || p % need != 0)) {
          final what = p < 0 ? "an unknown number of bytes" : "$p byte(s) past an aligned address";
          warnings.add((pl.lno, "misaligned",
              "$d data follows byte-sized data from line $since ($what) with no .align; it will be misaligned. Add '.align $need'."));
          pending = null;
          continue;
        }
        if (p != null) {
          pending = (p + need * itemCount(pl.directiveArgs)) % 4;
        }
        continue;
      } else {
        continue;
      }
      if (pending == null) since = pl.lno;
      if (bytes == null || pending == -1) {
        pending = -1;
      } else {
        pending = ((pending ?? 0) + bytes) % 4;
      }
      continue;
    }
    if (pl.mnem != null) {
      final p = pending;
      if (p != null && (p < 0 || p.isOdd)) {
        final what = p < 0 ? "an unknown number of bytes" : "$p byte(s) past an aligned address";
        warnings.add((pl.lno, "misaligned",
            "Code follows byte-sized data from line $since ($what) with no .align; instructions must be on even addresses. Add '.align 2'."));
      }
      pending = null;
    }
  }
}

/// 51: pushes and pops balance on every path from a routine's label to
/// its returns. A routine starts at a label not beginning with '.'; local
/// labels ('.' first) are reached by branches with the depth at the branch.
/// Routines that change R15 any other way are skipped.
void checkStackBalance(List<ParsedLine> lines, List<LintMessage> warnings) {
  int? depth = 0; // null: unknown (skip until the next routine)
  var inRoutine = false;
  String routine = "";
  final atLabel = <String, int>{};
  var reachable = true;
  for (final pl in lines) {
    for (final l in pl.labels) {
      if (!l.startsWith(".")) {
        // A new routine
        inRoutine = true;
        routine = l;
        depth = 0;
        atLabel.clear();
        reachable = true;
      } else if (inRoutine) {
        final recorded = atLabel[l];
        if (!reachable) {
          depth = recorded;
          reachable = recorded != null;
          if (!reachable) depth = null;
        } else if (recorded != null && depth != null && recorded != depth) {
          warnings.add((pl.lno, "stack-balance",
              "In '$routine': the stack depth at '$l' differs between paths ($recorded and $depth pushes)."));
          depth = null;
        }
        if (depth != null) atLabel[l] = depth;
        reachable = true;
      }
    }
    final mnem = pl.mnem;
    if (mnem == null || !inRoutine || depth == null) {
      if (mnem != null && unconditionalTransfers.contains(mnem)) reachable = false;
      continue;
    }
    final ops = pl.ops;
    final first = ops.isNotEmpty ? ops[0].toUpperCase() : "";
    if (mnem == "PUSH32" ||
        (mnem == "LD32" && ops.length == 2 && ops[0].replaceAll(" ", "").toUpperCase() == "(--R15)")) {
      depth = depth + 1;
    } else if (mnem == "POP32" ||
        (mnem == "LD32" && ops.length == 2 && ops[1].replaceAll(" ", "").toUpperCase() == "(R15++)")) {
      depth = depth - 1;
      if (depth < 0) {
        warnings.add((pl.lno, "stack-balance", "In '$routine': more pops than pushes."));
        depth = null;
        continue;
      }
    } else if ((first == "R15" || first == "SP") &&
        (writesFirstOperand.contains(mnem) || mnem == "LD")) {
      depth = null; // the routine manages the stack itself
      continue;
    }
    if (branchForward.contains(mnem) || branchBackward.contains(mnem)) {
      final target = ops.isEmpty ? null : ops.last;
      if (target != null && target.startsWith(".")) {
        final prev = atLabel[target];
        if (prev != null && prev != depth) {
          warnings.add((pl.lno, "stack-balance",
              "In '$routine': branch to '$target' with $depth push(es) outstanding; it is reached elsewhere with $prev."));
        }
        atLabel[target] = depth;
      }
    }
    final isReturn = mnem == "RRET" ||
        mnem == "RET" ||
        mnem == "RETI" ||
        mnem == "FAST_EXIT_TRAP" ||
        (mnem == "JMP" && ops.length == 2 && _isR14(ops[0]) && ops[1].toUpperCase() == "R0");
    if (isReturn && depth != 0) {
      warnings.add((pl.lno, "stack-balance",
          "In '$routine': returns with $depth push(es) not popped."));
    }
    if (unconditionalTransfers.contains(mnem)) reachable = false;
  }
}

