// ==============================================================================
// Python-compatibility helpers for the Particle simulator (psim.dart)
//
// The original tool was written in Python. These helpers reproduce the bits of
// Python behaviour that are visible to the user: int() parsing rules, the
// "{:08X}" format spec, repr() of strings, and the error text Python prints
// when an exception escapes.
// ==============================================================================

/// Equivalent of Python's ValueError. [message] is the text Python would show
/// after "ValueError: ".
class PyValueError implements Exception {
  final String message;
  PyValueError(this.message);

  @override
  String toString() => 'ValueError: $message';
}

/// Raised where Python would raise KeyboardInterrupt (Ctrl+C).
class KeyboardInterrupt implements Exception {
  @override
  String toString() => 'KeyboardInterrupt';
}

/// Python's repr() for a str.
String pyRepr(String s) {
  final useDouble = s.contains("'") && !s.contains('"');
  final quote = useDouble ? '"' : "'";
  final b = StringBuffer(quote);
  for (final r in s.runes) {
    if (r == 0x5C) {
      b.write(r'\\');
    } else if (String.fromCharCode(r) == quote) {
      b.write('\\$quote');
    } else if (r == 0x0A) {
      b.write(r'\n');
    } else if (r == 0x0D) {
      b.write(r'\r');
    } else if (r == 0x09) {
      b.write(r'\t');
    } else if (r < 0x20 || (r >= 0x7F && r < 0xA0)) {
      b.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
    } else {
      b.writeCharCode(r);
    }
  }
  b.write(quote);
  return b.toString();
}

/// Python's f"{v:0<width>X}" (uppercase hex, zero padded; a negative value is
/// rendered as '-' followed by the zero-padded magnitude, like Python does).
String pyHex(int v, int width) {
  if (v < 0) {
    return '-${(-v).toRadixString(16).toUpperCase().padLeft(width - 1, '0')}';
  }
  return v.toRadixString(16).toUpperCase().padLeft(width, '0');
}

/// f"{v:08X}"
String hex8(int v) => pyHex(v, 8);

bool _isPyWhitespace(int c) =>
    c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0x1C || c == 0x1D ||
    c == 0x1E || c == 0x1F || c == 0x85 || c == 0xA0 || c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 ||
    c == 0x202F || c == 0x205F || c == 0x3000;

/// Python's str.strip() with no arguments.
String pyStrip(String s) {
  final runes = s.runes.toList();
  var start = 0;
  var end = runes.length;
  while (start < end && _isPyWhitespace(runes[start])) {
    start++;
  }
  while (end > start && _isPyWhitespace(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes.sublist(start, end));
}

/// Python's str.split() with no arguments (split on runs of whitespace).
List<String> pySplit(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  var inWord = false;
  for (final r in s.runes) {
    if (_isPyWhitespace(r)) {
      if (inWord) {
        out.add(cur.toString());
        cur.clear();
        inWord = false;
      }
    } else {
      cur.writeCharCode(r);
      inWord = true;
    }
  }
  if (inWord) out.add(cur.toString());
  return out;
}

int _digitValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
  if (c >= 0x61 && c <= 0x7A) return c - 0x61 + 10; // a-z
  if (c >= 0x41 && c <= 0x5A) return c - 0x41 + 10; // A-Z
  return 99;
}

/// Python's int(text, base) for base 0 or 16 (the only bases psim uses).
///
/// Supports sign, 0x/0o/0b prefixes, underscores between digits and Python's
/// rule that base-0 decimal literals may not have leading zeros. Throws
/// [PyValueError] with Python's exact message on bad input. Values wider than
/// 64 bits wrap (Python would keep them exact; every use masks to 32 bits).
int pyInt(String text, int base) {
  PyValueError err() => PyValueError(
      'invalid literal for int() with base $base: ${pyRepr(text)}');

  final s = pyStrip(text).runes.toList();
  var i = 0;
  var neg = false;
  if (s.isNotEmpty && (s[0] == 0x2B || s[0] == 0x2D)) {
    neg = s[0] == 0x2D;
    i = 1;
  }
  var b = base;
  var prefixed = false;
  if (s.length - i >= 2 && s[i] == 0x30) {
    final p = s[i + 1] | 0x20; // ASCII lower-case
    if ((b == 16 || b == 0) && p == 0x78) {
      b = 16;
      i += 2;
      prefixed = true;
    } else if (b == 0 && p == 0x6F) {
      b = 8;
      i += 2;
      prefixed = true;
    } else if (b == 0 && p == 0x62) {
      b = 2;
      i += 2;
      prefixed = true;
    }
  }
  var autoDecimal = false;
  if (b == 0) {
    b = 10;
    autoDecimal = true;
  }
  var v = 0;
  var nDigits = 0;
  var prevUnderscore = false;
  while (i < s.length) {
    final c = s[i];
    if (c == 0x5F) {
      if (prevUnderscore || (nDigits == 0 && !prefixed)) throw err();
      prevUnderscore = true;
      i++;
      continue;
    }
    final d = _digitValue(c);
    if (d >= b) throw err();
    // Base-0 decimal: "0" may only be followed by more zeros.
    if (autoDecimal && nDigits > 0 && d != 0 && v == 0) throw err();
    v = v * b + d;
    nDigits++;
    prevUnderscore = false;
    i++;
  }
  if (nDigits == 0 || prevUnderscore) throw err();
  return neg ? -v : v;
}
