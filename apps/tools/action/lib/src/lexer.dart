// ------------------------------------------------------------------------------
// Lexer & Tokenizer
// ------------------------------------------------------------------------------
//
// Port of the tokenizer from act16c.py. The token kinds, their order of
// precedence and the line/column bookkeeping are kept as the Python
// implementation had them, with two changes:
//
//  * The C-style preprocessor has been removed from the language, so there
//    is no PREPROC token any more. A `#` (or any other character that starts
//    no token) is reported as an error instead of being silently skipped.
//  * Character literals accept two-digit hex escapes such as '\x41'.

import 'errors.dart';

/// Token kinds and their patterns, in order of precedence. The first pattern
/// that matches at a position wins, exactly as with Python's `re` alternation.
const List<(String, String)> tokenTypes = [
  ('COMMENT', r'//[^\n]*|/\*[\s\S]*?\*/'),
  // Numbers take every letter, digit and '_' that follows, so that a
  // malformed one (0b102, 0xFG, 12ab) is reported as a whole
  ('HEX', r'0x\w*'),
  ('BIN', r'0b\w*'),
  // 1.5, 2.0, 1e-3, 6.02e23: a digit on both sides of the point
  ('FLOAT', r'\d(?:_?\d)*(?:\.\d(?:_?\d)*(?:[eE][+-]?\d+)?|[eE][+-]?\d+)(?![\w.])'),
  ('INT', r'\d\w*'),
  ('STRING', r'"(?:\\.|[^"\\])*"'),
  ('CHAR', r"'(?:\\x[0-9a-fA-F]{2}|\\.|[^'\\])'"),
  ('KEYWORD',
      r'\b(?:ref|true|false|bool|string|u8|s8|u16|s16|u32|s32|u64|s64|f32|f64|void|const|if|else|while|for|return|break|continue|asm|switch|case|default|type|fn|inline|import|enum|verify|volatile|sizeof|extern)\b'),
  ('IDENT', r'[a-zA-Z_]\w*'),
  ('OP_ARROW', r'->'),
  ('OP_EQ', r'=='),
  ('OP_NE', r'!='),
  ('OP_LE', r'<='),
  ('OP_GE', r'>='),
  ('COMPOUND_ASSIGN', r'\+=|-=|\*=|/=|%=|&=|\|=|\^=|<<=|>>='),
  ('OP_SHL', r'<<'),
  ('OP_SHR', r'>>'),
  ('OP_AND', r'&&'),
  ('OP_OR', r'\|\|'),
  ('OP_ELLIPSIS', r'\.\.\.'),
  ('OP_RANGE', r'\.\.'),
  ('OP', r'[+\-*/%&|^~<>=!]'),
  ('PUNCT', r'[:;,(){}\[\]@.]'),
  ('SPACE', r'\s+'),
];

final RegExp _tokenRegex = RegExp(
    tokenTypes.map((t) => '(?<${t.$1}>${t.$2})').join('|'));

/// A single lexical token with its source position.
class Token {
  String type;
  String val;
  int lineno;
  int col;
  String fname;

  Token(this.type, this.val, this.lineno, this.col, [this.fname = '<stdin>']);

  @override
  String toString() => 'Token($type, ${_repr(val)}, $fname:$lineno:$col)';

  static String _repr(String s) => "'$s'";

  /// `file:line:col` prefix used in diagnostics.
  String get loc => '$fname:$lineno:$col';
}

/// Splits [sourceText] into tokens, dropping whitespace and comments and
/// appending a final `EOF` token.
List<Token> tokenize(String sourceText, {String fname = '<stdin>'}) {
  final tokens = <Token>[];
  var lineno = 1;
  var lineStart = 0;
  var lastEnd = 0;
  for (final mo in _tokenRegex.allMatches(sourceText)) {
    if (mo.start > lastEnd) {
      // Characters between two tokens that start no token at all.
      final bad = sourceText[lastEnd];
      throw CompileError(
          "$fname:$lineno:${lastEnd - lineStart}: Unexpected character '$bad'");
    }
    lastEnd = mo.end;
    String? kind;
    for (final t in tokenTypes) {
      if (mo.namedGroup(t.$1) != null) {
        kind = t.$1;
        break;
      }
    }
    final val = mo.group(0)!;
    final col = mo.start - lineStart;
    if (kind == 'SPACE') {
      lineno += '\n'.allMatches(val).length;
      if (val.contains('\n')) {
        lineStart = mo.end - (val.length - val.lastIndexOf('\n') - 1);
      }
      continue;
    } else if (kind == 'COMMENT') {
      lineno += '\n'.allMatches(val).length;
      if (val.contains('\n')) {
        lineStart = mo.start + val.lastIndexOf('\n') + 1;
      }
      continue;
    }
    tokens.add(Token(kind!, val, lineno, col, fname));
  }
  if (lastEnd < sourceText.length) {
    final bad = sourceText[lastEnd];
    throw CompileError(
        "$fname:$lineno:${lastEnd - lineStart}: Unexpected character '$bad'");
  }
  tokens.add(Token('EOF', '', lineno, 0, fname));
  return tokens;
}

/// Equivalent of Python's `int(text, 0)`: decimal, `0x` hexadecimal or `0b`
/// binary, with an optional leading minus sign and `_` between digits. Like
/// Python, a decimal literal with a leading zero (other than zero itself) is
/// rejected.
int parseIntAuto(String text) {
  final digits = RegExp(r'^[+-]?(0x[0-9a-fA-F](_?[0-9a-fA-F])*|0b[01](_?[01])*|\d(_?\d)*)$');
  if (!digits.hasMatch(text.trim())) {
    final t = text.trim();
    final why = t.startsWith('0x')
        ? 'a hexadecimal number has the digits 0-9 and a-f'
        : t.startsWith('0b')
            ? 'a binary number has the digits 0 and 1'
            : 'a number has the digits 0-9';
    throw CompileError("invalid number '$t': $why, and '_' may only be put between two digits");
  }
  text = text.replaceAll('_', '');
  var s = text.trim();
  var neg = false;
  if (s.startsWith('-')) {
    neg = true;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  int? v;
  if (s.startsWith('0x') || s.startsWith('0X')) {
    v = int.tryParse(s.substring(2), radix: 16);
  } else if (s.startsWith('0b')) {
    v = int.tryParse(s.substring(2), radix: 2);
  } else if (RegExp(r'^\d+$').hasMatch(s) &&
      !(s.length > 1 && s.startsWith('0') && RegExp(r'[1-9]').hasMatch(s))) {
    v = int.tryParse(s);
  }
  if (v == null) {
    throw CompileError("invalid literal for int() with base 0: '$text'");
  }
  return neg ? -v : v;
}

/// Decodes backslash escapes the way Python's `unicode_escape` codec does for
/// the ASCII subset used in Action sources (`\n`, `\t`, `\\`, `\"`, `\'`,
/// `\0`, octal, `\xHH`, ...). Unknown escapes are kept verbatim.
String decodeEscapes(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch != '\\' || i + 1 >= s.length) {
      out.write(ch);
      i++;
      continue;
    }
    final n = s[i + 1];
    switch (n) {
      case '\n':
        i += 2;
        continue;
      case '\\':
        out.write('\\');
      case "'":
        out.write("'");
      case '"':
        out.write('"');
      case 'a':
        out.write('\x07');
      case 'b':
        out.write('\x08');
      case 'f':
        out.write('\x0c');
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 't':
        out.write('\t');
      case 'v':
        out.write('\x0b');
      case 'x':
        final m = RegExp(r'^[0-9a-fA-F]{2}').matchAsPrefix(s.substring(i + 2));
        if (m == null) {
          throw CompileError(
              "(unicode error) 'unicodeescape' codec can't decode bytes: truncated \\xXX escape");
        }
        out.writeCharCode(int.parse(m.group(0)!, radix: 16));
        i += 2 + 2;
        continue;
      default:
        if (RegExp(r'[0-7]').hasMatch(n)) {
          final m = RegExp(r'^[0-7]{1,3}').matchAsPrefix(s.substring(i + 1))!;
          out.writeCharCode(int.parse(m.group(0)!, radix: 8) & 0x1FF);
          i += 1 + m.group(0)!.length;
          continue;
        }
        out.write('\\');
        out.write(n);
    }
    i += 2;
  }
  return out.toString();
}
