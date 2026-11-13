// ------------------------------------------------------------------------------
// Compiler driver: source loading, imports and program assembly
// ------------------------------------------------------------------------------

import 'dart:io';

import 'ast.dart';
import 'particle/backend.dart';
import 'particle/particle.dart';
import 'compiler.dart';
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

  /// Emit runtime reference checks: a null reference the compiler cannot
  /// follow (one held in a global) traps when it is used, and so does a
  /// failed allocation.
  final bool referenceCheck;

  /// Source text to use instead of a file's contents on disk, keyed by the
  /// file's absolute path with symbolic links resolved. An editor passes
  /// its unsaved text this way.
  final Map<String, String> overlays;

  const CompileOptions(
      {this.includeDirs = const [],
      this.defines = const [],
      this.boundsCheck = true,
      this.referenceCheck = true,
      this.overlays = const {}});
}

/// Loads [sources] (and everything they import) and returns the merged
/// program. Each file is read once, however many times it is imported.
ProgramNode loadProgram(List<String> sources, CompileOptions options) {
  // Aliases may be declared after their use, or in another file, so a
  // program that declares any is loaded a second time with them resolved
  final first = _loadOnce(sources, options, const {});
  final aliasDecls = first.decls.whereType<TypeAliasNode>().toList();
  if (aliasDecls.isEmpty) return first;
  return _loadOnce(sources, options, _resolveAliases(aliasDecls, first.decls));
}

/// Resolves each alias to a type that is not an alias, checking that every
/// target exists and that there are no cycles or clashing names.
Map<String, String> _resolveAliases(
    List<TypeAliasNode> aliasDecls, List<AstNode> decls) {
  const builtin = {'u8', 's8', 'u16', 's16', 'u32', 's32', 'bool', 'string'};
  final declared = <String>{
    for (final d in decls)
      if (d is TypeDefNode) d.name else if (d is FnTypeNode) d.name
  };
  final raw = <String, TypeAliasNode>{};
  for (final a in aliasDecls) {
    if (builtin.contains(a.name) || declared.contains(a.name)) {
      throw CompileError("${a.loc}: type '${a.name}' is already defined");
    }
    if (raw.containsKey(a.name)) {
      throw CompileError("${a.loc}: type alias '${a.name}' is already defined");
    }
    raw[a.name] = a;
  }
  final resolved = <String, String>{};
  for (final a in aliasDecls) {
    final seen = <String>{a.name};
    var target = a.target;
    while (raw.containsKey(target)) {
      if (!seen.add(target)) {
        throw CompileError("${a.loc}: type alias '${a.name}' refers to itself");
      }
      target = raw[target]!.target;
    }
    if (!builtin.contains(target) && !declared.contains(target)) {
      throw CompileError("${a.loc}: type alias '${a.name}' names unknown type '$target'");
    }
    resolved[a.name] = target;
  }
  return resolved;
}

ProgramNode _loadOnce(
    List<String> sources, CompileOptions options, Map<String, String> aliases) {
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
      content = options.overlays[realP] ?? File(realP).readAsStringSync();
    } on FileSystemException {
      throw CompileError("[Errno 2] No such file or directory: '$filePath'");
    }

    final fileTokens = tokenize(content, fname: realP);
    final parserInst = Parser(fileTokens, aliases: aliases);
    final parsedAst = parserInst.parseProgram();

    for (final decl in parsedAst.decls) {
      if (decl is ImportNode) {
        final res = resolvePath(decl.path, realP);
        if (res == null) {
          throw CompileError(
                  "Imported file '${decl.path}' not found (referenced from $realP)")
              .at(decl.loc);
        }
        ingestFile(res);
      } else {
        if (decl is FuncDeclNode) {
          if (decl.body != null) {
            if (seenFuncs.containsKey(decl.name)) {
              final prevF = seenFuncs[decl.name];
              throw CompileError(
                      "Redefinition of function '${decl.name}' in $realP (previously defined in $prevF)")
                  .at(decl.loc);
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
    if (name == 'true' || name == 'false') {
      throw CompileError("-D $d: '$name' is built in and cannot be redefined");
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
///
/// Warnings and information are added to [notes] when it is given, also
/// when compilation then fails.
String compile(List<String> sources,
    {CompileOptions options = const CompileOptions(),
    Backend? backend,
    List<CompileNote>? notes}) {
  final predefined = parseDefines(options.defines);
  final mergedAst = loadProgram(sources, options);
  final cg = CodeGen(
      boundsCheck: options.boundsCheck,
      referenceCheck: options.referenceCheck,
      backend: backend ?? ParticleAsmBackend(),
      predefinedConstants: predefined);
  try {
    return cg.generate(mergedAst);
  } finally {
    notes?.addAll(cg.notes);
  }
}

/// Compiles [sources] to LLVM IR text for a 64-bit host (action_llvm).
String compileLlvm(List<String> sources,
    {CompileOptions options = const CompileOptions(),
    bool debugInfo = true,
    List<CompileNote>? notes}) {
  final predefined = parseDefines(options.defines);
  final mergedAst = loadProgram(sources, options);
  final gen = LlvmGen(
      boundsCheck: options.boundsCheck,
      referenceCheck: options.referenceCheck,
      debugInfo: debugInfo,
      predefinedConstants: predefined);
  try {
    return gen.generate(mergedAst);
  } finally {
    notes?.addAll(gen.notes);
  }
}
