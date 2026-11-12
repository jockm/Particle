// ------------------------------------------------------------------------------
// Compiler driver: source loading, imports and program assembly
// ------------------------------------------------------------------------------

import 'dart:io';

import 'ast.dart';
import 'backend/backend.dart';
import 'backend/particle.dart';
import 'codegen/codegen.dart';
import 'errors.dart';
import 'lexer.dart';
import 'parser.dart';
import 'paths.dart' as p;

/// Options controlling one compilation.
class CompileOptions {
  /// Directories searched by `import`, in order (from `-I`).
  final List<String> includeDirs;

  /// Raw `-D` arguments (`NAME` or `NAME=VALUE`). Each defines an integer
  /// `const`: `NAME` alone has the value 1.
  final List<String> defines;

  /// Emit runtime array bounds checks.
  final bool boundsCheck;

  const CompileOptions(
      {this.includeDirs = const [],
      this.defines = const [],
      this.boundsCheck = true});
}

/// Loads [sources] (and everything they import) and returns the merged
/// program. Each file is read once, however many times it is imported.
ProgramNode loadProgram(List<String> sources, CompileOptions options) {
  final allDecls = <AstNode>[];
  final seenFuncs = <String, String>{};
  final seenTypes = <String, String>{};

  final importedFiles = <String>{};
  final searchDirs = List<String>.of(options.includeDirs);
  if (!searchDirs.contains('lib')) {
    searchDirs.add('lib');
  }
  if (!searchDirs.contains('.')) {
    searchDirs.add('.');
  }

  String? resolvePath(String target, String currentFile) {
    final candidates = [
      p.join(p.dirname(currentFile), target),
      target,
      p.absolute(target),
    ];
    for (final sdir in searchDirs) {
      candidates.add(p.join(sdir, target));
      candidates.add(p.join(Directory.current.path, sdir, target));
    }
    for (final cand in candidates) {
      if (File(cand).existsSync()) {
        return p.realPath(cand);
      }
    }
    return null;
  }

  void ingestFile(String filePath) {
    final realP = p.realPath(filePath);
    if (importedFiles.contains(realP)) {
      return;
    }
    importedFiles.add(realP);

    final String content;
    try {
      content = File(realP).readAsStringSync();
    } on FileSystemException {
      throw CompileError("[Errno 2] No such file or directory: '$filePath'");
    }

    final fileTokens = tokenize(content, fname: realP);
    final parserInst = Parser(fileTokens);
    final parsedAst = parserInst.parseProgram();

    for (final decl in parsedAst.decls) {
      if (decl is ImportNode) {
        final res = resolvePath(decl.path, realP);
        if (res == null) {
          throw CompileError(
              "Imported file '${decl.path}' not found (referenced from $realP)");
        }
        ingestFile(res);
      } else {
        if (decl is FuncDeclNode) {
          if (decl.body != null) {
            if (seenFuncs.containsKey(decl.name)) {
              final prevF = seenFuncs[decl.name];
              throw CompileError(
                  "Redefinition of function '${decl.name}' in $realP (previously defined in $prevF)");
            }
            seenFuncs[decl.name] = realP;
          }
        } else if (decl is TypeDefNode) {
          seenTypes[decl.name] = realP;
        }
        allDecls.add(decl);
      }
    }
  }

  for (final srcPath in sources) {
    ingestFile(srcPath);
  }
  return ProgramNode(allDecls);
}

/// Parses `-D` arguments into integer constants. `NAME` alone is 1;
/// `NAME=VALUE` takes a decimal or `0x` hexadecimal integer.
Map<String, int> parseDefines(List<String> defines) {
  final defs = <String, int>{};
  for (final d in defines) {
    final eq = d.indexOf('=');
    final name = (eq < 0 ? d : d.substring(0, eq)).trim();
    if (!RegExp(r'^[a-zA-Z_]\w*$').hasMatch(name)) {
      throw CompileError("-D $d: '$name' is not a valid identifier");
    }
    if (eq < 0) {
      defs[name] = 1;
      continue;
    }
    final value = d.substring(eq + 1).trim();
    try {
      defs[name] = parseIntAuto(value);
    } on CompileError {
      throw CompileError("-D $d: the value must be an integer");
    }
  }
  return defs;
}

/// Compiles [sources] to assembly text for [backend] (Particle by default).
String compile(List<String> sources,
    {CompileOptions options = const CompileOptions(), Backend? backend}) {
  final predefined = parseDefines(options.defines);
  final mergedAst = loadProgram(sources, options);
  final cg = CodeGen(
      boundsCheck: options.boundsCheck,
      backend: backend ?? ParticleAsmBackend(),
      predefinedConstants: predefined);
  return cg.generate(mergedAst);
}
