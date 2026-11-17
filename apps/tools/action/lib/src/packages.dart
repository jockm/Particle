// ------------------------------------------------------------------------------
// Packages: finding the module, and naming package declarations
// ------------------------------------------------------------------------------
//
// A package is a folder of .act files that each start with `package name;`.
// It is imported by its path: the module's name (from action.json) and the
// folder below action.json's folder, as in Go:
//
//   import "github.com/jockm/Particle/drivers/uart";
//
// Every top-level name a package declares gets an internal name, its prefix
// (the folder with `.` between the parts) and the name: `init` in
// drivers/uart is `drivers.uart..init`. That is done on the tokens before
// the files are parsed, so the rest of the compiler sees one program with
// ordinary names:
//
//   - in a package's own files, each use of one of its top-level names;
//   - in any file, `alias.name` for a package it imports.
//
// The program's own package (`package main;`) keeps its names, and so do
// `asm` and `extern` prototypes, whose names are labels or C names.

import 'ast.dart';
import 'errors.dart';
import 'lexer.dart';
import 'modules.dart';
import 'scope_resolve.dart';

/// The module a program belongs to: the folder holding its action.json and
/// the module name declared there.
class ModuleInfo {
  final String root;
  final String name;

  /// Its action.json (with its requirements).
  final ModuleFile file;
  ModuleInfo(this.root, this.name, this.file);
}

/// The module of the program whose files are in [startDir]: the nearest
/// action.json in it or a folder above it that names a module (its
/// `"module": { "name": ... }`), or null when there is none.
ModuleInfo? findModule(String startDir) {
  final m = findModuleFile(startDir);
  return m == null ? null : ModuleInfo(m.root, m.name, m);
}

/// The import statements of a file, from its tokens (before parsing):
/// path, alias (or null), and the location of the path.
List<(String, String?, String)> scanImports(List<Token> tokens) {
  final out = <(String, String?, String)>[];
  var depth = 0;
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.val == '{') depth++;
    if (t.val == '}') depth--;
    if (depth != 0 || t.type != 'KEYWORD' || t.val != 'import') continue;
    if (i + 1 >= tokens.length || tokens[i + 1].type != 'STRING') continue;
    final pathTok = tokens[i + 1];
    final path = pathTok.val.substring(1, pathTok.val.length - 1);
    String? alias;
    if (i + 3 < tokens.length && tokens[i + 2].type == 'IDENT' && tokens[i + 2].val == 'as' &&
        tokens[i + 3].type == 'IDENT') {
      alias = tokens[i + 3].val;
    }
    out.add((path, alias, pathTok.loc));
  }
  return out;
}

/// The `package name;` a file starts with, from its tokens: the name and
/// its location, or null when the file has none. A `package` line anywhere
/// else is an error.
(String, String)? scanPackage(List<Token> tokens) {
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.type == 'KEYWORD' && t.val == 'package') {
      if (i != 0) {
        throw CompileError("${t.loc}: 'package' must come first in the file, before any import or declaration");
      }
      if (i + 1 < tokens.length && tokens[i + 1].type == 'IDENT') {
        return (tokens[i + 1].val, tokens[i + 1].loc);
      }
      throw CompileError("${t.loc}: expected a package name after 'package'");
    }
  }
  return null;
}

/// Built-in names an import name must not take.
const builtinNames = {
  'trap', 'readFifo', 'writeFifo', 'tryReadFifo', 'peek8', 'peek16', 'peek32', 'poke8',
  'poke16', 'poke32', 'callAddr', 'this',
};

/// The token types that name a type, for telling a field's name from its
/// type in a `type` body.
const _typeKeywords = {
  'u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'f32', 'f64', 'bool', 'string', 'void',
};

/// Rewrites the tokens of one file of the program:
///
/// - `alias.name`, for an import of the file ([imports]), becomes one name:
///   the package's internal name for it. The name must be declared in the
///   package and be `pub`. Any other use of an import name is an error,
///   including declaring something with it.
/// - With [prefix] (a file of a package other than the program's own), each
///   use of one of the package's own top-level names ([own]) becomes its
///   internal name. Names after `.` (fields, methods), field names in a
///   `type` body and the labels of `{x: 1}` and `T.create(x: 1)` are not
///   top-level names and are left alone, and so are [plain] names (`asm`
///   and `extern` prototypes).
///
/// [used] receives each import name the file uses.
List<Token> rewritePackageTokens(List<Token> tokens,
    {required Map<String, PackageInfo> imports,
    String? prefix,
    Set<String> own = const {},
    Set<String> plain = const {},
    void Function(String alias)? used}) {
  // Always a new list: the parser changes the tokens it is given
  final out = <Token>[];
  Token? prevOf(int k) => k >= 0 && k < out.length ? out[k] : null;

  // Brace depths at which a `type Name {` body was opened
  final typeBodies = <int>[];
  var depth = 0;

  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    final prev = prevOf(out.length - 1);
    final next = i + 1 < tokens.length ? tokens[i + 1] : null;

    if (t.val == '{' && t.type == 'PUNCT') {
      depth++;
      // type Name {   (out ends with: type, Name)
      if (out.length >= 2 && out[out.length - 2].val == 'type' && out[out.length - 2].type == 'KEYWORD') {
        typeBodies.add(depth);
      }
      out.add(t);
      continue;
    }
    if (t.val == '}' && t.type == 'PUNCT') {
      if (typeBodies.isNotEmpty && typeBodies.last == depth) typeBodies.removeLast();
      depth--;
      out.add(t);
      continue;
    }
    if (t.type != 'IDENT' || (prev != null && prev.val == '.' && prev.type == 'PUNCT')) {
      out.add(t);
      continue;
    }
    // The header: `package name;` and `import "path" as name;`
    if (prev != null &&
        ((prev.type == 'KEYWORD' && prev.val == 'package') ||
            (prev.type == 'IDENT' && prev.val == 'as' && out.length >= 2 && out[out.length - 2].type == 'STRING') ||
            (t.val == 'as' && prev.type == 'STRING'))) {
      out.add(t);
      continue;
    }

    final pkg = imports[t.val];
    if (pkg != null) {
      final nameTok = i + 2 < tokens.length ? tokens[i + 2] : null;
      if (next == null || next.val != '.' || nameTok == null || nameTok.type != 'IDENT') {
        throw CompileError("${t.loc}: '${t.val}' is the name of an imported package; "
            "use its declarations as '${t.val}.name'");
      }
      final name = nameTok.val;
      if (!pkg.names.contains(name)) {
        throw CompileError("${nameTok.loc}: package '${pkg.name}' has no '$name'");
      }
      if (!pkg.pubNames.contains(name)) {
        throw CompileError("${nameTok.loc}: '$name' is not pub in package '${pkg.name}'");
      }
      used?.call(t.val);
      out.add(Token('IDENT', pkg.plainNames.contains(name) ? name : pkg.internal(name), t.lineno,
          t.col, t.fname));
      i += 2;
      continue;
    }

    if (prefix != null && own.contains(t.val) && !plain.contains(t.val)) {
      // A field's name in a type body follows its type
      final inTypeBody = typeBodies.isNotEmpty && typeBodies.last == depth;
      final afterType = prev != null &&
          (prev.type == 'IDENT' || (prev.type == 'KEYWORD' && _typeKeywords.contains(prev.val)));
      if (inTypeBody && afterType) {
        out.add(t);
        continue;
      }
      // A label: `{x: 1}`, `T.create(x: 1, pos.y: 2)`
      if (prev != null && const {'{', ',', '('}.contains(prev.val) && _isLabel(tokens, i)) {
        out.add(t);
        continue;
      }
      out.add(Token('IDENT', '$prefix$packageMark${t.val}', t.lineno, t.col, t.fname));
      continue;
    }
    out.add(t);
  }
  return out;
}

/// True when the tokens from [i] are `name(.name)*` followed by `:`.
bool _isLabel(List<Token> tokens, int i) {
  var k = i;
  while (k + 2 < tokens.length && tokens[k + 1].val == '.' && tokens[k + 2].type == 'IDENT') {
    k += 2;
  }
  return k + 1 < tokens.length && tokens[k + 1].val == ':' && tokens[k + 1].type == 'PUNCT';
}

/// The prefix of the internal names of the package in folder [rel] (the
/// folder below the module's root, with `/` between the parts), checking
/// that each part is letters and digits, starting with a letter.
String packagePrefix(String rel, String importPath, String loc) {
  final parts = rel.split('/').where((s) => s.isNotEmpty).toList();
  for (final part in parts) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(part)) {
      throw CompileError("$loc: package path '$importPath': folder '$part' must be letters and "
          'digits, starting with a letter');
    }
  }
  if (parts.isEmpty) {
    throw CompileError("$loc: '$importPath' is the module itself, not a package folder in it");
  }
  return parts.join('.');
}
