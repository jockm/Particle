// ------------------------------------------------------------------------------
// Loading a program made of packages
// ------------------------------------------------------------------------------
//
// Used when the program's files start with `package main;`. Each imported
// package is a folder of files with the same `package` line; it is loaded
// once, before the files that import it, and an import cycle is an error.
// File imports (`import "x.act";`) still work: the file joins the package
// that imports it. lib/string.act is loaded first, as the prelude: its names
// are seen everywhere. See packages.dart for how names are rewritten.

import 'dart:io';

import 'ast.dart';
import 'errors.dart';
import 'lexer.dart';
import 'packages.dart';
import 'parser.dart';
import 'paths.dart' as p;
import 'scope_resolve.dart';

/// One file of a package being loaded: its tokens and its imports.
class _UnitFile {
  final String path;
  final List<Token> tokens;
  final Map<String, PackageInfo> imports = {};
  final Map<String, String> importLocs = {};
  final Set<String> used = {};
  _UnitFile(this.path, this.tokens);
}

class PackageLoader {
  final String? Function(String target, String fromFile) resolvePath;
  final bool Function(String path) isBuilt;
  final String Function(String path) read;
  final Map<String, String> aliases;
  final Set<String> predefined;

  final List<AstNode> decls = [];
  final List<(String, String?)> warnings = [];
  final Map<String, PackageInfo> packages = {};
  final Map<String, Map<String, PackageInfo>> fileImports = {};
  final Map<String, PackageInfo> filePackages = {};

  final Map<String, PackageInfo> _byFolder = {};
  final List<String> _loading = [];
  final Set<String> _plainFiles = {};
  final Map<String, String> _seenFuncs = {};
  ModuleInfo? _module;
  String? _preludePath;
  late String _startDir;

  PackageLoader(
      {required this.resolvePath,
      required this.isBuilt,
      required this.read,
      required this.aliases,
      required this.predefined});

  List<Token> _tokens(String path) => tokenize(read(path), fname: path);

  /// Loads the program whose own files are [sources] (`package main;`).
  void loadProgram(List<String> sources) {
    _startDir = p.dirname(p.realPath(sources.first));
    _preludePath = resolvePath('lib/string.act', sources.first) ?? resolvePath('string.act', sources.first);
    if (_preludePath == null) {
      throw CompileError(
          "the prelude lib/string.act was not found: a program with packages needs it (add its folder with -I)");
    }
    _loadPlain(_preludePath!);
    _loadUnit([for (final s in sources) p.realPath(s)], null, 'main', null, null);
  }

  /// Loads the files of one package's folder, [sources], on their own, as
  /// an editor checks them: as if a program imported the package.
  void loadPackage(List<String> sources) {
    final folder = p.dirname(p.realPath(sources.first));
    _startDir = folder;
    _preludePath = resolvePath('lib/string.act', sources.first) ?? resolvePath('string.act', sources.first);
    if (_preludePath != null) _loadPlain(_preludePath!);
    final module = _module = findModule(folder);
    if (module == null || !folder.startsWith('${module.root}/')) {
      throw CompileError("${sources.first}: checking package files needs the module's name: add "
          "\"module\": { \"name\": \"...\" } to the \"action\" section of the project's action.json");
    }
    final rel = folder.substring(module.root.length + 1);
    final importPath = '${module.name}/$rel';
    final prefix = packagePrefix(rel, importPath, '${sources.first}:1:0');
    _loading.add(folder);
    final info = _loadUnit([for (final s in sources) p.realPath(s)], prefix, null, importPath, folder);
    _loading.removeLast();
    _byFolder[folder] = info!;
  }

  /// Loads a file that belongs to no package (the prelude, and files it
  /// imports): its names are seen everywhere.
  void _loadPlain(String path) {
    if (!_plainFiles.add(path) || !isBuilt(path)) return;
    final ast = Parser(_tokens(path), aliases: aliases).parseProgram();
    for (final d in ast.decls) {
      if (d is ImportNode) {
        final res = resolvePath(d.path, path);
        if (res == null) {
          throw CompileError("Imported file '${d.path}' not found (referenced from $path)").at(d.loc);
        }
        _loadPlain(res);
      } else if (d is PackageNode) {
        throw CompileError('$path: the prelude cannot be a package file');
      } else {
        _add(d, path);
      }
    }
  }

  void _add(AstNode d, String path) {
    if (d is FuncDeclNode && d.body != null) {
      final prev = _seenFuncs[d.name];
      if (prev != null) {
        throw CompileError("Redefinition of function '${d.name}' in $path (previously defined in $prev)")
            .at(d.loc);
      }
      _seenFuncs[d.name] = path;
    }
    decls.add(d);
  }

  /// The package imported as [importPath] from [loc] (loading it first).
  PackageInfo _import(String importPath, String loc) {
    _module ??= findModule(_startDir);
    final module = _module;
    if (module == null) {
      throw CompileError("$loc: importing the package '$importPath' needs the module's name: add "
          "\"module\": { \"name\": \"...\" } to the \"action\" section of the project's action.json");
    }
    if (!importPath.startsWith('${module.name}/')) {
      throw CompileError("$loc: '$importPath' is not in this module (${module.name}); "
          'packages from other modules are not supported yet');
    }
    final rel = importPath.substring(module.name.length + 1);
    final prefix = packagePrefix(rel, importPath, loc);
    final folder = p.join(module.root, rel);
    final known = _byFolder[folder];
    if (known != null) return known;
    if (_loading.contains(folder)) {
      final cycle = [..._loading.skipWhile((f) => f != folder), folder]
          .map((f) => f.startsWith('${module.root}/') ? f.substring(module.root.length + 1) : f)
          .join(' -> ');
      throw CompileError('$loc: import cycle: $cycle');
    }
    final dir = Directory(folder);
    if (!dir.existsSync()) {
      throw CompileError("$loc: package '$importPath' not found (no folder $folder)");
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .map((f) => p.realPath(f.path))
        .where((f) => f.endsWith('.act'))
        .toList()
      ..sort();
    final built = files.where(isBuilt).toList();
    if (built.isEmpty) {
      throw CompileError("$loc: package '$importPath' has no .act files for this build");
    }
    _loading.add(folder);
    final info = _loadUnit(built, prefix, null, importPath, folder);
    _loading.removeLast();
    _byFolder[folder] = info!;
    return info;
  }

  /// Loads one package: the program's own (no [prefix]; its files must say
  /// `package main;`) or an imported one, whose files must all give the
  /// same name. Returns the package's description (null for the program).
  PackageInfo? _loadUnit(
      List<String> ownFiles, String? prefix, String? mustBe, String? importPath, String? folder) {
    // Its files: the folder's (or the program's), then the files they
    // import with `import "x.act";`, which join the package
    final files = <_UnitFile>[];
    final seen = <String>{};
    String? name;
    void addFile(String path, bool own) {
      if (!seen.add(path)) return;
      if (!own && path == _preludePath) return;
      if (!isBuilt(path)) return;
      final tokens = _tokens(path);
      final pkg = scanPackage(tokens);
      if (own) {
        if (pkg == null) {
          throw CompileError(mustBe == 'main'
              ? "$path: every file of the program must start with 'package main;' when one does"
              : "$path: every file in a package's folder must start with a 'package' line");
        }
        if (mustBe != null && pkg.$1 != mustBe) {
          throw CompileError("${pkg.$2}: the program's files must say 'package $mustBe;', not "
              "'package ${pkg.$1};'");
        }
        if (name != null && pkg.$1 != name) {
          throw CompileError("${pkg.$2}: '${p.basename(path)}' says 'package ${pkg.$1};', but the other "
              "files in its folder say 'package $name;'");
        }
        name ??= pkg.$1;
      } else if (pkg != null) {
        throw CompileError("${pkg.$2}: '${p.basename(path)}' is a file of package '${pkg.$1}'; "
            'import its folder as a package instead');
      }
      final unit = _UnitFile(path, tokens);
      files.add(unit);
      for (final (target, alias, loc) in scanImports(tokens)) {
        if (target.endsWith('.act')) {
          final res = resolvePath(target, path);
          if (res == null) {
            throw CompileError("$loc: Imported file '$target' not found (referenced from $path)");
          }
          addFile(res, false);
        } else {
          final info = _import(target, loc);
          final as = alias ?? info.name;
          if (unit.imports.containsKey(as)) {
            throw CompileError("$loc: '$as' already names another import of this file; "
                "use 'import \"$target\" as other;'");
          }
          if (builtinNames.contains(as) || predefined.contains(as)) {
            throw CompileError("$loc: the import name '$as' is a built-in name; "
                "use 'import \"$target\" as other;'");
          }
          unit.imports[as] = info;
          unit.importLocs[as] = loc;
        }
      }
    }

    for (final f in ownFiles) {
      addFile(f, true);
    }

    // Pass 1: the package's top-level names, its pub names and its plain ones
    final names = <String>{}, pubNames = <String>{}, plainNames = <String>{};
    final firstPass = <_UnitFile, List<AstNode>>{};
    for (final f in files) {
      final ast = Parser(rewritePackageTokens(f.tokens, imports: f.imports), aliases: aliases)
          .parseProgram();
      firstPass[f] = ast.decls;
      for (final d in ast.decls) {
        final declared = _declaredNames(d);
        names.addAll(declared);
        if (d.isPub) pubNames.addAll(declared);
        if (d is FuncDeclNode && (d.isAsm || d.isExtern)) plainNames.add(d.name);
      }
    }

    final info = prefix == null
        ? null
        : PackageInfo(name!, prefix, importPath!, folder!, names, pubNames, plainNames);
    if (info != null) {
      packageDisplayNames[prefix!] = name!;
      packages[prefix] = info;
    }

    for (final f in files) {
      for (final as in f.imports.keys) {
        if (names.contains(as)) {
          throw CompileError("${f.importLocs[as]}: the import name '$as' is also declared in this package; "
              "use 'import \"${f.imports[as]!.path}\" as other;'");
        }
      }
      // Pass 2: a package's own names get their internal names
      final List<AstNode> fileDecls = prefix == null
          ? firstPass[f]!
          : Parser(
                  rewritePackageTokens(f.tokens,
                      imports: f.imports,
                      prefix: prefix,
                      own: names,
                      plain: plainNames,
                      used: f.used.add),
                  aliases: aliases)
              .parseProgram()
              .decls;
      if (prefix == null) {
        // The program's own files: the imports were used in pass 1
        rewritePackageTokens(f.tokens, imports: f.imports, used: f.used.add);
      }
      for (final d in fileDecls) {
        if (d is ImportNode || d is PackageNode) continue;
        _checkDecl(d, prefix, name!);
        _add(d, f.path);
      }
      for (final as in f.imports.keys) {
        if (!f.used.contains(as)) {
          warnings.add(("import '${f.imports[as]!.path}' is not used", f.importLocs[as]));
        }
      }
      fileImports[f.path] = f.imports;
      if (info != null) filePackages[f.path] = info;
    }
    if (info != null) _checkPubSignatures(info);
    return info;
  }

  /// The top-level names declaration [d] declares (not methods).
  static Set<String> _declaredNames(AstNode d) {
    if (d is FuncDeclNode) return d.name.contains('.') ? const {} : {d.name};
    if (d is TypeDefNode) return {d.name};
    if (d is TypeAliasNode) return {d.name};
    if (d is FnTypeNode) return {d.name};
    if (d is VarDeclNode) return {d.name};
    if (d is EnumDeclNode) return {d.name, for (final m in d.members) m.$1};
    return const {};
  }

  /// Rules for a declaration of the package with [prefix] (null for the
  /// program's own).
  void _checkDecl(AstNode d, String? prefix, String pkgName) {
    if (d is! FuncDeclNode) return;
    if (prefix != null && d.name == '$prefix$packageMark' 'main') {
      throw CompileError("package '$pkgName' cannot declare 'main': it belongs to the program").at(d.loc);
    }
    // A method is declared in its type's own package
    if (d.params.isNotEmpty && d.params.first.name == 'this' && d.name.contains('.')) {
      final type = d.params.first.type.toString();
      final typePrefix = type.contains(packageMark) ? type.substring(0, type.lastIndexOf(packageMark)) : null;
      if (typePrefix != prefix) {
        final owner = typePrefix == null ? 'the program' : "package '${packageDisplayNames[typePrefix]}'";
        throw CompileError("a method of '${sourceName(type)}' must be declared in $owner, "
                'where the type is declared')
            .at(d.loc);
      }
    }
  }

  /// A pub declaration of [info] cannot use a type of the package that is
  /// not pub: an importer could not name it.
  void _checkPubSignatures(PackageInfo info) {
    final mine = '${info.prefix}$packageMark';
    void check(Object? type, AstNode d, String what) {
      final names = type is List ? type.map((e) => e.toString()) : [type?.toString() ?? ''];
      for (var t in names) {
        t = t.replaceAll(RegExp(r'[\[\]]'), '').trim();
        if (!t.startsWith(mine)) continue;
        final base = t.substring(mine.length);
        if (!info.pubNames.contains(base)) {
          throw CompileError("pub $what uses '${sourceName(t)}', which is not pub; "
                  'make it pub too, or this declaration not pub')
              .at(d.loc);
        }
      }
    }

    for (final d in decls) {
      if (!d.isPub) continue;
      if (d is FuncDeclNode && d.name.startsWith(mine)) {
        final shown = sourceName(d.name);
        check(d.retType, d, "function '$shown'");
        for (final prm in d.params) {
          check(prm.type, d, "function '$shown'");
        }
      } else if (d is VarDeclNode && d.name.startsWith(mine)) {
        check(d.typeName, d, "'${sourceName(d.name)}'");
      } else if (d is TypeDefNode && d.name.startsWith(mine)) {
        for (final fd in d.fields) {
          check(fd.type, d, "type '${sourceName(d.name)}'");
        }
      } else if (d is FnTypeNode && d.name.startsWith(mine)) {
        for (final pt in d.paramTypes) {
          check(pt, d, "function type '${sourceName(d.name)}'");
        }
        check(d.retType, d, "function type '${sourceName(d.name)}'");
      } else if (d is TypeAliasNode && d.name.startsWith(mine)) {
        check(d.target, d, "alias '${sourceName(d.name)}'");
      }
    }
  }
}
