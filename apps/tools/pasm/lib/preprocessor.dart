// =============================================================================
// File: apps/tools/pasm/lib/preprocessor.dart
// Project: Particle RISC Architecture
// Description: Two-stage macro preprocessor supporting:
//   - File inclusion (.include) with cyclic dependency tracking
//   - Conditional assembly (.ifdef, .ifndef, .if, .else, .endif)
//   - Parametric macros (.macro / .endmacro) with unique label scoping (.%)
//   - Symbol definitions (.define)
//   - Arithmetic expression evaluation with operator precedence
//
// Matches exact behavior of tools/pasm.py:Preprocessor & Macro
// =============================================================================

import "dart:io";
import "isa.dart";

/// Encapsulates a macro definition declared via .macro <name> <params...>.
class Macro {
  final String name;
  final List<String> params;
  final List<String> lines;
  final String filename;
  final int lineno;

  Macro(this.name, this.params, this.lines, this.filename, this.lineno);
}

/// Preprocessor engine handling source transformation before assembly passes.
class Preprocessor {
  /// Directory paths searched in order for .include directives.
  final List<String> includeDirs;

  /// Global symbol defines registered via -D flags or .define directives.
  final Map<String, int> defines;

  /// Macro registry mapping uppercase macro names to their definitions.
  final Map<String, Macro> macros = {};

  /// Monotonically increasing counter for unique macro-local label generation (.%).
  int macroCounter = 0;

  /// Optional in-memory file overlays (canonical path -> lines) used by pasm_lsp
  /// to preprocess unsaved editor buffers without writing to disk.
  final Map<String, List<String>> fileOverlays;

  Preprocessor({
    List<String>? includeDirs,
    Map<String, int>? defines,
    Map<String, List<String>>? fileOverlays,
  })  : includeDirs = includeDirs ?? ["."],
        defines = defines ?? {},
        fileOverlays = fileOverlays ?? {};

  /// Safely resolves a file path to its canonical path if it exists on disk,
  /// or returns its absolute normalized path for in-memory overlay files.
  String canonicalPath(String path) {
    final f = File(path);
    if (f.existsSync()) {
      return f.resolveSymbolicLinksSync();
    }
    return f.absolute.path;
  }

  /// Resolves an include path against:
  /// 1. Directory of current file
  /// 2. Raw relative path
  /// 3. Configured include directories
  /// 4. Basename inside include directories
  String resolveInclude(String currentFile, String incPath) {
    final candidates = <String>[
      "${File(currentFile).parent.path}/$incPath",
      incPath,
    ];
    for (final idir in includeDirs) {
      candidates.add("$idir/$incPath");
      final base = incPath.split("/").last.split(r"\\").last;
      candidates.add("$idir/$base");
    }

    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) {
        return f.resolveSymbolicLinksSync();
      }
      final absCand = f.absolute.path;
      if (fileOverlays.containsKey(absCand)) {
        return absCand;
      }
    }
    throw AssemblerError("Include file not found: $incPath");
  }

  /// Parses and evaluates an arithmetic expression supporting symbols, defines,
  /// register aliases, bitwise operations, shifts, and standard precedence.
  int parseExpr(String exprStr, Map<String, int> symbols) {
    var expr = exprStr.trim();
    if (expr.isEmpty) throw AssemblerError("Empty expression");

    // Replace symbol and register tokens with literal decimal strings
    final tokenPattern = RegExp(r"([A-Za-z0-9_\.]+)");
    expr = expr.replaceAllMapped(tokenPattern, (match) {
      final tok = match.group(1)!;
      if (symbols.containsKey(tok)) return "${symbols[tok]}";
      if (defines.containsKey(tok)) return "${defines[tok]}";
      final lower = tok.toLowerCase();
      if (regMap.containsKey(lower)) return "${regMap[lower]}";
      return tok;
    });

    try {
      return _evaluateExpression(expr);
    } catch (e) {
      throw AssemblerError("Invalid expression '$exprStr': $e");
    }
  }

  /// Recursive descent expression evaluator supporting standard C operator precedence:
  /// ( ) -> ~ - (unary) -> * / % -> + - -> << >> -> & -> ^ -> |
  int _evaluateExpression(String expr) {
    var clean = expr.replaceAll(" ", "");

    // Unwrap redundant outer enclosing parentheses
    while (clean.startsWith("(") && clean.endsWith(")")) {
      int depth = 0;
      bool matched = true;
      for (int i = 0; i < clean.length - 1; i++) {
        if (clean[i] == "(") depth++;
        if (clean[i] == ")") depth--;
        if (depth == 0) {
          matched = false;
          break;
        }
      }
      if (matched) {
        clean = clean.substring(1, clean.length - 1);
      } else {
        break;
      }
    }

    // Direct literal evaluation (Hex, Bin, Dec)
    final directNum = _parseLiteral(clean);
    if (directNum != null) return directNum;

    // Bitwise OR (|) - lowest precedence
    int idx = _findOp(clean, ["|"]);
    if (idx != -1) {
      return _evaluateExpression(clean.substring(0, idx)) |
             _evaluateExpression(clean.substring(idx + 1));
    }

    // Bitwise XOR (^)
    idx = _findOp(clean, ["^"]);
    if (idx != -1) {
      return _evaluateExpression(clean.substring(0, idx)) ^
             _evaluateExpression(clean.substring(idx + 1));
    }

    // Bitwise AND (&)
    idx = _findOp(clean, ["&"]);
    if (idx != -1) {
      return _evaluateExpression(clean.substring(0, idx)) &
             _evaluateExpression(clean.substring(idx + 1));
    }

    // Shifts (<<, >>)
    idx = _findOp(clean, [">>", "<<"]);
    if (idx != -1) {
      final op = clean.substring(idx, idx + 2);
      final left = _evaluateExpression(clean.substring(0, idx));
      final right = _evaluateExpression(clean.substring(idx + 2));
      return (op == ">>") ? (left >> right) : (left << right);
    }

    // Addition / Subtraction (+, -)
    idx = _findOp(clean, ["+", "-"]);
    if (idx > 0) {
      final op = clean[idx];
      return (op == "+")
          ? _evaluateExpression(clean.substring(0, idx)) + _evaluateExpression(clean.substring(idx + 1))
          : _evaluateExpression(clean.substring(0, idx)) - _evaluateExpression(clean.substring(idx + 1));
    }

    // Multiplication / Division / Modulo (*, /, %)
    idx = _findOp(clean, ["*", "/", "%"]);
    if (idx != -1) {
      final op = clean[idx];
      final l = _evaluateExpression(clean.substring(0, idx));
      final r = _evaluateExpression(clean.substring(idx + 1));
      if (op == "*") return l * r;
      if (op == "/") return l ~/ r;
      if (op == "%") return l % r;
    }

    // Unary Negation (-) or Bitwise NOT (~)
    if (clean.startsWith("-")) return -_evaluateExpression(clean.substring(1));
    if (clean.startsWith("~")) return ~_evaluateExpression(clean.substring(1));

    throw FormatException("Cannot evaluate '$clean'");
  }

  /// Parses a single token integer literal (0x hex, 0b binary, decimal).
  int? _parseLiteral(String s) {
    if (s.startsWith("0x") || s.startsWith("0X")) return int.tryParse(s.substring(2), radix: 16);
    if (s.startsWith("0b") || s.startsWith("0B")) return int.tryParse(s.substring(2), radix: 2);
    return int.tryParse(s);
  }

  /// Finds the right-most operator outside parenthesized subexpressions.
  int _findOp(String s, List<String> ops) {
    int depth = 0;
    for (int i = s.length - 1; i >= 0; i--) {
      if (s[i] == ")") depth++;
      if (s[i] == "(") depth--;
      if (depth == 0) {
        for (final op in ops) {
          if (op.length == 1 && s[i] == op && i > 0 &&
              s[i - 1] != "*" && s[i - 1] != "/" && s[i - 1] != "<" && s[i - 1] != ">") {
            return i;
          } else if (op.length == 2 && i >= 1 && s.substring(i - 1, i + 1) == op) {
            return i - 1;
          }
        }
      }
    }
    return -1;
  }

  /// Processes source lines recursively, expanding macros and resolving includes.
  /// Matches exact recursion semantics of tools/pasm.py:Preprocessor.process.
  List<(String, int, String)> process(String filename, [List<String>? lines, Set<String>? visited]) {
    visited ??= <String>{};
    final absPath = canonicalPath(filename);

    List<String> rawLines;
    if (lines == null) {
      if (visited.contains(absPath)) return [];
      visited.add(absPath);
      if (fileOverlays.containsKey(absPath)) {
        rawLines = fileOverlays[absPath]!;
      } else if (fileOverlays.containsKey(filename)) {
        rawLines = fileOverlays[filename]!;
      } else {
        rawLines = File(absPath).readAsLinesSync();
      }
    } else {
      rawLines = lines;
    }

    final expanded = <(String, int, String)>[];
    final condStack = <bool>[];
    bool inMacro = false;
    String macroName = "";
    List<String> macroParams = [];
    final macroBody = <String>[];
    int macroStartLine = 0;

    for (int lno = 1; lno <= rawLines.length; lno++) {
      final raw = rawLines[lno - 1];
      // Strip comments (semicolon to end of line)
      final line = raw.replaceAll(RegExp(r";.*"), "").trim();
      if (line.isEmpty) continue;

      // Evaluate active condition status from conditional stack
      final active = condStack.isEmpty ? true : condStack.every((c) => c);

      // Preprocessor directive handling
      if (line.startsWith(".")) {
        final parts = line.split(RegExp(r"\s+"));
        final directive = parts[0].toLowerCase();
        final arg = parts.length > 1 ? line.substring(parts[0].length).trim() : "";

        if (directive == ".ifdef") {
          condStack.add(defines.containsKey(arg));
          continue;
        } else if (directive == ".ifndef") {
          condStack.add(!defines.containsKey(arg));
          continue;
        } else if (directive == ".if") {
          final val = parseExpr(arg, defines);
          condStack.add(val != 0);
          continue;
        } else if (directive == ".else") {
          if (condStack.isNotEmpty) {
            condStack[condStack.length - 1] = !condStack.last;
          }
          continue;
        } else if (directive == ".endif") {
          if (condStack.isNotEmpty) {
            condStack.removeLast();
          }
          continue;
        }

        if (!active) continue;

        if (directive == ".macro") {
          final mParts = arg.split(RegExp(r"\s+"));
          macroName = mParts[0];
          macroParams = mParts.length > 1
              ? arg.substring(mParts[0].length).split(",").map((p) => p.trim()).where((p) => p.isNotEmpty).toList()
              : [];
          inMacro = true;
          macroBody.clear();
          macroStartLine = lno;
          continue;
        } else if (directive == ".endmacro") {
          macros[macroName] = Macro(macroName, macroParams, List.from(macroBody), absPath, macroStartLine);
          inMacro = false;
          continue;
        } else if (directive == ".include") {
          var incFile = arg.trim();
          if ((incFile.startsWith('"') && incFile.endsWith('"')) ||
              (incFile.startsWith("'") && incFile.endsWith("'"))) {
            incFile = incFile.substring(1, incFile.length - 1);
          }
          final fullInc = resolveInclude(absPath, incFile);
          expanded.addAll(process(fullInc, null, visited));
          continue;
        } else if (directive == ".define") {
          final defParts = arg.split(RegExp(r"\s+"));
          final val = defParts.length > 1 ? parseExpr(arg.substring(defParts[0].length).trim(), defines) : 1;
          defines[defParts[0]] = val;
          continue;
        }
      }

      // Collect macro body lines verbatim
      if (inMacro) {
        macroBody.add(raw);
        continue;
      }

      if (!active) continue;

      // Check for macro invocation
      final firstWord = line.split(RegExp(r"\s+"))[0];
      if (macros.containsKey(firstWord)) {
        final m = macros[firstWord]!;
        final argStr = line.substring(firstWord.length).trim();
        final args = argStr.isNotEmpty
            ? argStr.split(",").map((a) => a.trim()).toList()
            : <String>[];
        macroCounter++;
        final uniqueSuffix = "_$macroCounter";

        // Expand macro body: replace %param with values, and replace .% with unique suffix
        final mLines = <String>[];
        for (final ml in m.lines) {
          var subL = ml;
          for (int p = 0; p < m.params.length && p < args.length; p++) {
            subL = subL.replaceAll("%${m.params[p]}", args[p]);
          }
          subL = subL.replaceAll(".%", uniqueSuffix);
          mLines.add(subL);
        }
        // Recurse into expanded macro lines
        expanded.addAll(process(absPath, mLines, visited));
        continue;
      }

      // Standard preprocessed source line
      expanded.add((absPath, lno, line));
    }

    return expanded;
  }
}
