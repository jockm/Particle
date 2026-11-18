// The path helpers, with Windows paths (checked on any system) and with
// POSIX paths.

import 'package:action/action.dart';
import 'package:action/src/paths.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Windows paths', () {
    late bool saved;
    setUp(() {
      saved = p.windowsPaths;
      p.windowsPaths = true;
    });
    tearDown(() => p.windowsPaths = saved);

    test('backslashes become slashes', () {
      expect(p.slashes(r'C:\Users\jock\Particle'), equals('C:/Users/jock/Particle'));
      expect(p.slashes(r'C:\a/b\c'), equals('C:/a/b/c'));
    });

    test('a drive, a share or a slash starts an absolute path', () {
      expect(p.isAbsolute(r'C:\Users\jock'), isTrue);
      expect(p.isAbsolute('c:/Users/jock'), isTrue);
      expect(p.isAbsolute(r'\\server\share\x.act'), isTrue);
      expect(p.isAbsolute('/x.act'), isTrue);
      expect(p.isAbsolute(r'apps\act\x.act'), isFalse);
      expect(p.isAbsolute('apps/act/x.act'), isFalse);
      expect(p.isAbsolute('C:x.act'), isFalse);
    });

    test('join keeps an absolute part and uses slashes', () {
      expect(p.join(r'C:\proj', 'apps/act/x.act'), equals('C:/proj/apps/act/x.act'));
      expect(p.join('C:/proj/', r'lib\string.act'), equals('C:/proj/lib/string.act'));
      expect(p.join(r'C:\proj', r'D:\other\y.act'), equals('D:/other/y.act'));
      expect(p.join('C:/proj', 'lib', 'x.act'), equals('C:/proj/lib/x.act'));
    });

    test('an absolute path is not joined to the current folder', () {
      // What 'make build' hit: the resolved path came back absolute with
      // backslashes and was taken for a relative one
      const resolved = r'C:\Users\jock\Projects\Particle\apps\act\test_coroutine.act';
      expect(p.absolute(resolved), equals('C:/Users/jock/Projects/Particle/apps/act/test_coroutine.act'));
      expect(p.realPath(p.realPath(resolved)),
          equals('C:/Users/jock/Projects/Particle/apps/act/test_coroutine.act'));
    });

    test('dirname stops at the drive', () {
      expect(p.dirname(r'C:\a\b.act'), equals('C:/a'));
      expect(p.dirname('C:/a'), equals('C:/'));
      expect(p.dirname('C:/'), equals('C:/'));
      expect(p.dirname('//server/share'), equals('//server'));
      expect(p.dirname('x.act'), equals(''));
    });

    test('basename and withoutExtension', () {
      expect(p.basename(r'C:\a\b.act'), equals('b.act'));
      expect(p.withoutExtension(r'C:\a.d\b.act'), equals('C:/a.d/b'));
      expect(p.withoutExtension(r'C:\a.d\b'), equals('C:/a.d/b'));
    });

    test('normalize keeps the drive', () {
      expect(p.normalize(r'C:\a\.\b\..\c.act'), equals('C:/a/c.act'));
      expect(p.normalize('C:/../x.act'), equals('C:/x.act'));
      expect(p.normalize('C://a//b'), equals('C:/a/b'));
      expect(p.normalize('C:/'), equals('C:/'));
      expect(p.normalize(r'..\x\..\y'), equals('../y'));
    });

    test('a message with a drive in its location is split correctly', () {
      final d = Diagnostic.fromError(CompileError('C:/proj/x.act:3:4: undeclared name'));
      expect(d.path, equals('C:/proj/x.act'));
      expect(d.line, equals(3));
      expect(d.column, equals(4));
      expect(d.message, equals('undeclared name'));
    });
  });

  group('POSIX paths', () {
    late bool saved;
    setUp(() {
      saved = p.windowsPaths;
      p.windowsPaths = false;
    });
    tearDown(() => p.windowsPaths = saved);

    test('backslashes are left alone', () {
      expect(p.slashes(r'a\b'), equals(r'a\b'));
      expect(p.isAbsolute(r'C:\x'), isFalse);
      expect(p.isAbsolute('C:/x'), isFalse);
    });

    test('the helpers work as before', () {
      expect(p.join('/a', 'b', 'c.act'), equals('/a/b/c.act'));
      expect(p.join('/a', '/b'), equals('/b'));
      expect(p.dirname('/a/b.act'), equals('/a'));
      expect(p.dirname('/a'), equals('/'));
      expect(p.dirname('/'), equals('/'));
      expect(p.basename('/a/b.act'), equals('b.act'));
      expect(p.normalize('/a/./b/../c'), equals('/a/c'));
      expect(p.normalize('a/../../b'), equals('../b'));
      expect(p.normalize(''), equals('.'));
      expect(p.withoutExtension('/a.d/b.act'), equals('/a.d/b'));
    });
  });
}
