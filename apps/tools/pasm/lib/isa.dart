// =============================================================================
// File: apps/tools/pasm/lib/isa.dart
// Project: Particle RISC Architecture
// Description: Core ISA definitions, register mappings, label split helpers,
//              and exception diagnostics.
//
// Matches exact behavior of tools/pasm.py:
//   - REG_MAP: R0..R15 and SP alias (R15)
//   - split_label: Splits label outside quoted strings
//   - AssemblerError: Formatted diagnostic messages
// =============================================================================

/// Canonical register name-to-index mapping.
/// R0 through R15 are standard general-purpose 32-bit registers.
/// SP is an alias for R15 (Stack Pointer).
final Map<String, int> regMap = {
  for (int i = 0; i < 16; i++) "r$i": i,
  "sp": 15,
};

/// Exception thrown when syntax, immediate ranges, or operands fail validation.
/// Emits clean compiler-style diagnostic messages: "<file>:<line>: error: <msg>"
class AssemblerError implements Exception {
  final String message;
  final String? filename;
  final int? lineno;

  AssemblerError(this.message, [this.filename, this.lineno]);

  @override
  String toString() {
    final loc = "${filename ?? "input"}:${lineno ?? "?"}: error: ";
    return "$loc$message";
  }
}

/// Splits a source line into (label, rest) at the first unquoted colon (:).
///
/// String literals (enclosed in double or single quotes) may contain colons
/// (e.g., in .asciz "Time: 12:00"). This function ignores colons inside quotes
/// and returns (null, line) if no unquoted colon exists.
(String?, String) splitLabel(String line) {
  bool inQuote = false;
  int? quoteChar;

  for (int idx = 0; idx < line.length; idx++) {
    final code = line.codeUnitAt(idx);
    // Double quote (0x22) or Single quote (0x27)
    if (code == 0x22 || code == 0x27) {
      if (!inQuote) {
        inQuote = true;
        quoteChar = code;
      } else if (code == quoteChar && (idx == 0 || line.codeUnitAt(idx - 1) != 0x5C)) {
        inQuote = false;
      }
    } else if (code == 0x3A && !inQuote) { // Colon (0x3A)
      return (line.substring(0, idx).trim(), line.substring(idx + 1).trim());
    }
  }
  return (null, line);
}
