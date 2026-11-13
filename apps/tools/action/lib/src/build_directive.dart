// ------------------------------------------------------------------------------
// Build directives: which targets and operating systems a file is built for
// ------------------------------------------------------------------------------
//
// A file may start with one line such as
//
//   //act:build llvm && macos
//
// before its first import or declaration (only comments and blank lines may
// come before it). The expression uses the names of [buildTargets] and
// [buildOses] with `!`, `&&`, `||` and parentheses. A file whose directive is
// false for the build is left out entirely: it is read only as far as the
// directive, never parsed or checked. This follows Go's `//go:build`.

import 'dart:io' show Platform;

import 'errors.dart';

/// The compilers a file can be built for.
const buildTargets = ['particle', 'llvm'];

/// The operating systems a file can be built for. Particle programs run
/// without one (`none`); LLVM programs run on the computer they are built
/// on.
const buildOses = ['none', 'macos', 'linux'];

/// Every target with each operating system it can have.
const validBuilds = [('particle', 'none'), ('llvm', 'macos'), ('llvm', 'linux')];

/// The marker that starts a build directive.
const buildDirectiveMark = '//act:build';

/// The operating system of this computer, as a build name: what an LLVM
/// program built here runs on. Null on any other system.
String? hostOs() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  return null;
}

/// The operating system [target] builds for on this computer.
String? defaultOs(String target) => target == 'particle' ? 'none' : hostOs();

/// A file's build directive.
class BuildDirective {
  /// The expression as written.
  final String text;

  /// The directive's location (`file:line:column`).
  final String loc;

  /// 1-based line of the directive.
  final int line;

  final _Expr _expr;

  BuildDirective._(this.text, this.loc, this.line, this._expr);

  /// Whether the file is built for [target] on [os].
  bool matches(String target, String? os) =>
      _expr.eval((name) => name == target || name == os);

  /// The builds the file is part of, from [validBuilds].
  List<(String, String)> get builds =>
      [for (final b in validBuilds) if (matches(b.$1, b.$2)) b];
}

/// Reads the build directive of a file with [content], or null when it has
/// none. Throws a [CompileError] when a directive is misplaced, repeated,
/// malformed, names something unknown or can never be true.
BuildDirective? readBuildDirective(String content, String fname) {
  final lines = content.split('\n');
  BuildDirective? found;
  var inHeader = true;
  var inBlock = false;
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i].endsWith('\r') ? lines[i].substring(0, lines[i].length - 1) : lines[i];
    final t = raw.trim();
    final loc = '$fname:${i + 1}:${raw.indexOf(t) + 1}';
    final isDirective = t == buildDirectiveMark || t.startsWith('$buildDirectiveMark ');
    if (inHeader) {
      if (inBlock) {
        if (t.contains('*/')) {
          inBlock = false;
          if (t.substring(t.indexOf('*/') + 2).trim().isNotEmpty) inHeader = false;
        }
        continue;
      }
      if (isDirective) {
        if (found != null) {
          throw CompileError(
              "only one $buildDirectiveMark line is allowed; the first is on line ${found.line}").at(loc);
        }
        final text = t.substring(buildDirectiveMark.length).trim();
        found = BuildDirective._(text, loc, i + 1, _parse(text, loc));
        continue;
      }
      if (t.isEmpty || t.startsWith('//')) continue;
      if (t.startsWith('/*')) {
        if (!t.contains('*/')) {
          inBlock = true;
        } else if (t.substring(t.indexOf('*/') + 2).trim().isNotEmpty) {
          inHeader = false;
        }
        continue;
      }
      inHeader = false;
    }
    if (isDirective) {
      throw CompileError(
          '$buildDirectiveMark must come before the first import or declaration, '
          'with only comments and blank lines above it').at(loc);
    }
  }
  return found;
}

// ------------------------------------------------------------- expressions

abstract class _Expr {
  bool eval(bool Function(String name) isSet);
}

class _Name extends _Expr {
  final String name;
  _Name(this.name);
  @override
  bool eval(bool Function(String) isSet) => isSet(name);
}

class _Not extends _Expr {
  final _Expr e;
  _Not(this.e);
  @override
  bool eval(bool Function(String) isSet) => !e.eval(isSet);
}

class _And extends _Expr {
  final _Expr a, b;
  _And(this.a, this.b);
  @override
  bool eval(bool Function(String) isSet) => a.eval(isSet) && b.eval(isSet);
}

class _Or extends _Expr {
  final _Expr a, b;
  _Or(this.a, this.b);
  @override
  bool eval(bool Function(String) isSet) => a.eval(isSet) || b.eval(isSet);
}

/// Parses [text]: `||` binds loosest, then `&&`, then `!`.
_Expr _parse(String text, String loc) {
  final tokens = <String>[];
  final tokenRe = RegExp(r'\s*(&&|\|\||!|\(|\)|[A-Za-z_][A-Za-z0-9_]*)');
  var pos = 0;
  while (pos < text.length) {
    if (text.substring(pos).trim().isEmpty) break;
    final m = tokenRe.matchAsPrefix(text, pos);
    if (m == null) {
      throw CompileError(
          "$buildDirectiveMark: unexpected '${text.substring(pos).trim()[0]}' in '$text'").at(loc);
    }
    tokens.add(m.group(1)!);
    pos = m.end;
  }
  if (tokens.isEmpty) {
    throw CompileError(
        '$buildDirectiveMark needs an expression, such as '
        "'$buildDirectiveMark llvm' or '$buildDirectiveMark particle'").at(loc);
  }
  var i = 0;
  Never fail(String what) => throw CompileError(
      "$buildDirectiveMark: $what in '$text'").at(loc);
  late _Expr Function() orExpr;
  _Expr primary() {
    if (i >= tokens.length) fail('the expression ends too soon');
    final t = tokens[i++];
    if (t == '!') return _Not(primary());
    if (t == '(') {
      final e = orExpr();
      if (i >= tokens.length || tokens[i] != ')') fail("a '(' is not closed");
      i++;
      return e;
    }
    if (t == ')' || t == '&&' || t == '||') fail("unexpected '$t'");
    if (!buildTargets.contains(t) && !buildOses.contains(t)) {
      throw CompileError(
          "$buildDirectiveMark: unknown name '$t'; the names are "
          '${buildTargets.join(', ')}, ${buildOses.take(buildOses.length - 1).join(', ')} '
          'and ${buildOses.last}').at(loc);
    }
    return _Name(t);
  }
  _Expr andExpr() {
    var e = primary();
    while (i < tokens.length && tokens[i] == '&&') {
      i++;
      e = _And(e, primary());
    }
    return e;
  }
  orExpr = () {
    var e = andExpr();
    while (i < tokens.length && tokens[i] == '||') {
      i++;
      e = _Or(e, andExpr());
    }
    return e;
  };
  final e = orExpr();
  if (i < tokens.length) fail("unexpected '${tokens[i]}'");
  if (!validBuilds.any((b) => e.eval((n) => n == b.$1 || n == b.$2))) {
    throw CompileError(
        "$buildDirectiveMark $text can never be true: the builds are "
        "particle with none, and llvm with macos or linux").at(loc);
  }
  return e;
}
