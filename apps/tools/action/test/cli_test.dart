import 'package:action/action.dart';
import 'package:test/test.dart';

void main() {
  group('command line', () {
    test('options and sources', () {
      final a = parseArgs(['-o', 'out.asm', '-DX=1', '-D', 'Y', '-Ilib', '--include-dir=inc',
          '-fno-bounds-check', 'a.act', 'b.act']);
      expect(a.output, 'out.asm');
      expect(a.defines, ['X=1', 'Y']);
      expect(a.includeDirs, ['lib', 'inc']);
      expect(a.boundsCheck, isFalse);
      expect(a.sources, ['a.act', 'b.act']);
    });

    test('bounds checking is on by default', () {
      expect(parseArgs(['a.act']).boundsCheck, isTrue);
    });

    test('reference checking is on by default and can be turned off', () {
      expect(parseArgs(['a.act']).referenceCheck, isTrue);
      expect(parseArgs(['-fno-reference-check', 'a.act']).referenceCheck, isFalse);
      expect(parseArgs(['-fno-reference-check', '-freference-check', 'a.act']).referenceCheck,
          isTrue);
    });

    test('-h needs no sources', () {
      expect(parseArgs(['-h']).help, isTrue);
    });

    test('missing sources and unknown options are usage errors', () {
      expect(() => parseArgs([]), throwsA(isA<UsageError>()));
      expect(() => parseArgs(['--bogus', 'a.act']), throwsA(isA<UsageError>()));
      expect(() => parseArgs(['a.act', '-o']), throwsA(isA<UsageError>()));
    });

    test('the tool is called action', () {
      expect(toolName, 'action');
      expect(helpText, startsWith('usage: action'));
    });
  });
}
