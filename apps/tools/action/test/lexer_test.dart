import 'package:action/action.dart';
import 'package:test/test.dart';

List<String> kinds(String src) =>
    [for (final t in tokenize(src)) if (t.type != 'EOF') t.type];

List<String> values(String src) =>
    [for (final t in tokenize(src)) if (t.type != 'EOF') t.val];

void main() {
  group('lexer', () {
    test('keywords, identifiers and numbers', () {
      expect(values('u32 x = 0x1F;'), ['u32', 'x', '=', '0x1F', ';']);
      expect(kinds('while foo'), ['KEYWORD', 'IDENT']);
    });

    test('yield and wait_until are identifiers, not keywords', () {
      expect(kinds('yield wait_until pk_exit'), ['IDENT', 'IDENT', 'IDENT']);
    });

    test('continue is a keyword', () {
      expect(kinds('continue'), ['KEYWORD']);
    });

    test('compound assignment operators are single tokens', () {
      expect(values('a <<= b >>= c += d'), ['a', '<<=', 'b', '>>=', 'c', '+=', 'd']);
    });

    test('character literals, including \\x escapes', () {
      expect(values(r"'a' '\n' '\x41' '\''"), [r"'a'", r"'\n'", r"'\x41'", r"'\''"]);
      expect(kinds(r"'\x41'"), ['CHAR']);
    });

    test('an unexpected character is an error with its location', () {
      expect(
          () => tokenize('u32 x;\n#define A 1', fname: 'f.act'),
          throwsA(isA<CompileError>().having(
              (e) => e.message, 'message', contains("f.act:2:0: Unexpected character '#'"))));
      expect(() => tokenize('u32 \$x;'), throwsA(isA<CompileError>()));
    });

    test('comments and whitespace are skipped', () {
      expect(values('a // line\n/* block\n */ b'), ['a', 'b']);
    });
  });

  test('columns after a comment spanning lines count from that line', () {
    final toks = tokenize('/* one\n two */ x');
    expect(toks.first.val, equals('x'));
    expect(toks.first.lineno, equals(2));
    expect(toks.first.col, equals(8));
  });
}
