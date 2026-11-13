// ------------------------------------------------------------------------------
// The language server
// ------------------------------------------------------------------------------
//
// Keeps the editor's open documents, checks the program each belongs to
// with the Action compiler (on open and save at once, and after typing
// pauses), publishes the first error, and answers hover, go to definition,
// completion and outline requests from the last program that parsed.

import 'dart:async';
import 'dart:io';

import 'package:action/action.dart';

import 'connection.dart';
import 'documents.dart';
import 'features.dart';
import 'project.dart';
import 'symbols.dart';

const serverVersion = '1.0.0';

/// The checks for one program (a set of files compiled together).
class _ProgramState {
  final List<String> sources;
  AnalysisResult? result;

  /// From the last check that parsed, so features keep working while the
  /// current text does not parse.
  ProgramIndex? index;

  /// Files this program has published errors for.
  final Set<String> published = {};

  _ProgramState(this.sources);

  String get key => sources.join('\u0000');

  /// Every file in the program, including imported ones, as last seen.
  Set<String> get files => {...sources, ...?index?.files};
}

class ActionLanguageServer {
  final Connection _conn;

  /// How long to wait after a change before checking.
  final Duration debounce;

  final SourceTexts _texts = SourceTexts();
  final Map<String, _ProgramState> _programs = {};
  final Map<String, Timer> _pending = {};
  Project _project = Project.defaults(null);
  String? _root;
  bool _initialized = false;
  bool _shutdown = false;
  bool _projectErrorShown = false;
  final Completer<int> _done = Completer<int>();

  ActionLanguageServer(this._conn, {this.debounce = const Duration(milliseconds: 300)});

  /// Serves until the editor sends `exit` or closes the connection. Gives
  /// the process exit code.
  Future<int> run() async {
    final sub = _conn.messages.listen(_handle, onError: (Object e) {
      _send({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': ErrorCodes.parseError, 'message': '$e'}
      });
    }, onDone: () {
      if (!_done.isCompleted) _done.complete(_shutdown ? 0 : 1);
    });
    final code = await _done.future;
    await sub.cancel();
    for (final t in _pending.values) {
      t.cancel();
    }
    return code;
  }

  void _send(Map<String, Object?> m) => _conn.send(m);

  void _notify(String method, Object? params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  void _handle(Map<String, Object?> msg) {
    final method = msg['method'] as String?;
    final id = msg['id'];
    final params = msg['params'];
    if (method == null) return; // a response to something we did not send
    if (id == null) {
      _notification(method, params);
      return;
    }
    Object? result;
    try {
      result = _request(method, params);
    } on RpcError catch (e) {
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': e.code, 'message': e.message}
      });
      return;
    } catch (e, st) {
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': ErrorCodes.internalError, 'message': '$e\n$st'}
      });
      return;
    }
    _send({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  Object? _request(String method, Object? params) {
    if (method == 'initialize') return _initialize(params as Map<String, Object?>);
    if (!_initialized) {
      throw RpcError(ErrorCodes.serverNotInitialized, 'the server has not been initialized');
    }
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    switch (method) {
      case 'shutdown':
        _shutdown = true;
        return null;
      case 'textDocument/hover':
        return _features(p)?.hover(Pos.fromJson(p['position']));
      case 'textDocument/definition':
        return _features(p)?.definition(Pos.fromJson(p['position']));
      case 'textDocument/completion':
        return {
          'isIncomplete': false,
          'items': _features(p)?.completion(Pos.fromJson(p['position'])) ?? const [],
        };
      case 'textDocument/documentSymbol':
        return _features(p)?.documentSymbols() ?? const [];
    }
    throw RpcError(ErrorCodes.methodNotFound, 'unsupported request: $method');
  }

  void _notification(String method, Object? params) {
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    switch (method) {
      case 'initialized':
        _showProjectError();
      case 'exit':
        if (!_done.isCompleted) _done.complete(_shutdown ? 0 : 1);
      case 'textDocument/didOpen':
        final td = p['textDocument'] as Map<String, Object?>;
        final uri = td['uri'] as String;
        final doc = Document(
            uri, canonicalPath(uriToPath(uri)), td['text'] as String, td['version'] as int? ?? 0);
        _texts.add(doc);
        _checkNow(doc.path);
      case 'textDocument/didChange':
        final td = p['textDocument'] as Map<String, Object?>;
        final doc = _texts.openDocument(uriToPath(td['uri'] as String));
        if (doc == null) return;
        final changes = p['contentChanges'] as List;
        if (changes.isEmpty) return;
        // Full synchronization: the last change holds the whole text
        final last = changes.last as Map<String, Object?>;
        doc.update(last['text'] as String, td['version'] as int? ?? doc.version + 1);
        _checkLater(doc.path);
      case 'textDocument/didSave':
        final td = p['textDocument'] as Map<String, Object?>;
        final path = canonicalPath(uriToPath(td['uri'] as String));
        _texts.clearDiskCache();
        _checkNow(path);
      case 'textDocument/didClose':
        final td = p['textDocument'] as Map<String, Object?>;
        final path = canonicalPath(uriToPath(td['uri'] as String));
        _texts.remove(path);
        _pending.remove(path)?.cancel();
        _forgetIfUnused();
      case 'workspace/didChangeWatchedFiles':
        final changes = (p['changes'] as List?) ?? const [];
        var projectChanged = false;
        for (final c in changes) {
          final uri = (c as Map<String, Object?>)['uri'] as String;
          if (uri.endsWith('/$projectFileName')) projectChanged = true;
        }
        _texts.clearDiskCache();
        if (projectChanged) {
          _loadProject();
          _showProjectError();
        }
        _recheckAll();
      default:
        break; // $/cancelRequest, $/setTrace and others need nothing
    }
  }

  Map<String, Object?> _initialize(Map<String, Object?> p) {
    String? root;
    final folders = p['workspaceFolders'];
    if (folders is List && folders.isNotEmpty) {
      root = uriToPath((folders.first as Map<String, Object?>)['uri'] as String);
    } else if (p['rootUri'] is String) {
      root = uriToPath(p['rootUri'] as String);
    } else if (p['rootPath'] is String) {
      root = p['rootPath'] as String;
    }
    _root = root == null ? null : canonicalPath(root);
    _loadProject();
    _initialized = true;
    return {
      'capabilities': {
        'textDocumentSync': {
          'openClose': true,
          'change': 1, // the whole text on each change
          'save': {'includeText': false},
        },
        'hoverProvider': true,
        'definitionProvider': true,
        'documentSymbolProvider': true,
        'completionProvider': {
          'triggerCharacters': ['.'],
        },
      },
      'serverInfo': {'name': 'action_lsp', 'version': serverVersion},
    };
  }

  void _loadProject() {
    _project = Project.load(_root);
    _projectErrorShown = false;
    // Programs may have changed shape
    _programs.clear();
  }

  /// Reports a problem in action.json as an error on that file.
  void _showProjectError() {
    final file = _project.file;
    if (file == null) return;
    final e = _project.error;
    if (e == null && !_projectErrorShown) {
      _notify('textDocument/publishDiagnostics', {'uri': pathToUri(file), 'diagnostics': []});
      return;
    }
    if (e == null) return;
    _projectErrorShown = true;
    _notify('textDocument/publishDiagnostics', {
      'uri': pathToUri(e.path),
      'diagnostics': [
        {
          'range': rangeJson(Pos(e.line, 0), Pos(e.line, 1000)),
          'severity': 1,
          'source': 'action',
          'message': '${e.message} (using the default settings until it is fixed)',
        }
      ],
    });
  }

  // ------------------------------------------------------------- checking

  _ProgramState _programOf(String path) {
    final sources = _project.programFor(path);
    final key = sources.join('\u0000');
    return _programs.putIfAbsent(key, () => _ProgramState(sources));
  }

  void _checkLater(String path) {
    _pending.remove(path)?.cancel();
    _pending[path] = Timer(debounce, () {
      _pending.remove(path);
      _checkNow(path);
    });
  }

  /// Checks the program [path] belongs to, and every other program whose
  /// files include it (it may be imported).
  void _checkNow(String path) {
    final targets = <_ProgramState>{_programOf(path)};
    for (final st in _programs.values) {
      if (st.files.contains(path)) targets.add(st);
    }
    for (final st in targets) {
      _check(st);
    }
  }

  void _recheckAll() {
    final paths = [for (final d in _texts.open) d.path];
    final done = <String>{};
    for (final p in paths) {
      final st = _programOf(p);
      if (done.add(st.key)) _check(st);
    }
  }

  void _forgetIfUnused() {
    final open = {for (final d in _texts.open) d.path};
    _programs.removeWhere((_, st) => !st.files.any(open.contains) && !st.sources.any(open.contains));
  }

  void _check(_ProgramState st) {
    final options = CompileOptions(
        includeDirs: _project.includeDirs,
        defines: _project.defines,
        overlays: _texts.overlays);
    final builds = _buildsOf(st.sources);
    final targets = [for (final b in builds) b.$1];
    final results = [
      for (final b in builds)
        analyze(st.sources, options: options.forTarget(b.$1, b.$2), target: b.$1)
    ];
    // The first target's types and values are shown in the editor
    final result = results.first;
    st.result = result;
    final program = result.program;
    if (program != null) st.index = ProgramIndex(program, result.info, _texts);

    final byFile = <String, List<Map<String, Object?>>>{};
    void add(Diagnostic d, int severity, [String suffix = '', String prefix = '']) {
      final path = d.path == null ? st.sources.first : canonicalPath(d.path!);
      final lines = _texts.lines(path) ?? const <String>[];
      final line = (d.line - 1).clamp(0, lines.isEmpty ? 0 : lines.length - 1);
      final text = line < lines.length ? lines[line] : '';
      final col = d.column.clamp(0, text.length);
      var end = tokenEnd(text, col);
      if (end == col) end = text.length > col ? col + 1 : col;
      (byFile[path] ??= []).add({
        'range': rangeJson(Pos(line, col), Pos(line, end)),
        'severity': severity,
        'source': 'action',
        'message': '$prefix${d.message}$suffix',
      });
    }

    for (final n in result.notes) {
      add(n, n.severity == DiagnosticSeverity.warning ? 2 : 3);
    }
    for (final path in st.files) {
      final w = _nameWarning(path);
      if (w != null) add(w, 2);
    }
    void addError(Diagnostic err, int severity, [String prefix = '']) {
      if (!_project.isProgram(st.sources) && _mayBeElsewhere(err.message)) {
        // Checked without the rest of its program: the definition may be
        // in a file named only on the command line
        add(err, 3,
            ' (this file is checked on its own; put its program in a program folder or list it in $projectFileName to check it with the rest)',
            prefix);
      } else {
        add(err, severity, '', prefix);
      }
    }

    final errors = [for (final r in results) r.error];
    final first = errors.first;
    final same = errors.every((e) => _sameDiagnostic(e, first));
    if (same) {
      if (first != null) addError(first, 1);
    } else {
      // Found for some targets only: a warning naming the target, unless
      // the program fails for every target
      final allFail = errors.every((e) => e != null);
      for (var i = 0; i < targets.length; i++) {
        final e = errors[i];
        if (e != null) addError(e, allFail ? 1 : 2, 'for ${targets[i]}: ');
      }
    }
    final toPublish = {...st.sources, ...byFile.keys, ...st.published};
    st.published
      ..clear()
      ..addAll(byFile.keys);
    for (final path in toPublish) {
      _notify('textDocument/publishDiagnostics', {
        'uri': pathToUri(path),
        'diagnostics': byFile[path] ?? const [],
      });
    }
  }

  /// The file's build directive, or null when it has none or it is not
  /// valid (analysis then reports the error).
  BuildDirective? _directiveOf(String path) {
    final lines = _texts.lines(path);
    if (lines == null) return null;
    try {
      return readBuildDirective(lines.join('\n'), path);
    } on CompileError {
      return null;
    }
  }

  /// The builds (target and operating system) [sources] are checked for:
  /// the targets of the project file, unless the files' `//act:build`
  /// lines say otherwise. A target is checked when one of the files is
  /// built for it, on the operating system it has on this computer if a
  /// file is built for that one.
  List<(String, String?)> _buildsOf(List<String> sources) {
    final directives = [for (final path in sources) _directiveOf(path)];
    if (directives.every((d) => d == null)) {
      return [for (final t in _project.targets) (t, defaultOs(t))];
    }
    bool built(String target, String? os) =>
        directives.any((d) => d == null || d.matches(target, os));
    (String, String?)? buildFor(String target) {
      final usual = defaultOs(target);
      if (built(target, usual)) return (target, usual);
      for (final b in validBuilds) {
        if (b.$1 == target && built(b.$1, b.$2)) return b;
      }
      return null;
    }
    final inProject = [
      for (final t in _project.targets)
        if (buildFor(t) case final b?) b
    ];
    if (inProject.isNotEmpty) return inProject;
    return [
      for (final t in buildTargets)
        if (buildFor(t) case final b?) b
    ];
  }

  /// A warning when the name of [path] says it is for a target or
  /// operating system (`name_llvm.act`, `name_macos.act`,
  /// `name_llvm_macos.act`) that its `//act:build` line does not keep it to.
  Diagnostic? _nameWarning(String path) {
    final stem = path.split('/').last.replaceFirst(RegExp(r'\.act$'), '');
    final parts = stem.split('_');
    final named = <String>[];
    for (var k = parts.length - 1; k >= 1 && named.length < 2; k--) {
      if (!buildTargets.contains(parts[k]) && !buildOses.contains(parts[k])) break;
      named.insert(0, parts[k]);
    }
    if (named.isEmpty) return null;
    final namedTarget = named.where(buildTargets.contains).firstOrNull;
    final namedOs = named.where(buildOses.contains).firstOrNull;
    bool fits((String, String) b) =>
        (namedTarget == null || b.$1 == namedTarget) && (namedOs == null || b.$2 == namedOs);
    final expected = named.join(' && ');
    final lines = _texts.lines(path);
    if (lines == null) return null;
    final BuildDirective? d;
    try {
      d = readBuildDirective(lines.join('\n'), path);
    } on CompileError {
      return null;
    }
    final file = path.split('/').last;
    if (d == null) {
      return Diagnostic(path, 1, 0,
          "'$file' is named for $expected, but has no $buildDirectiveMark line; "
          "by convention it starts with '$buildDirectiveMark $expected'",
          DiagnosticSeverity.warning);
    }
    if (d.builds.every(fits)) return null;
    String show((String, String) b) => b.$2 == 'none' ? b.$1 : '${b.$1} on ${b.$2}';
    final others = d.builds.where((b) => !fits(b)).map(show).join(', ');
    return Diagnostic(path, d.line, 0,
        "'$file' is named for $expected, but '$buildDirectiveMark ${d.text}' "
        "builds it ${d.builds.any(fits) ? 'also ' : ''}for $others",
        DiagnosticSeverity.warning);
  }

  static bool _sameDiagnostic(Diagnostic? a, Diagnostic? b) =>
      (a == null && b == null) ||
      (a != null &&
          b != null &&
          a.path == b.path &&
          a.line == b.line &&
          a.column == b.column &&
          a.message == b.message);

  /// Errors about a definition that another file of the program may supply.
  static bool _mayBeElsewhere(String message) =>
      message.contains(' is not declared; ') ||
      message.contains(' is declared but never defined');

  // ------------------------------------------------------------- features

  Features? _features(Map<String, Object?> p) {
    final td = p['textDocument'] as Map<String, Object?>;
    final path = canonicalPath(uriToPath(td['uri'] as String));
    final doc = _texts.openDocument(path);
    var st = _programOf(path);
    if (st.result == null) _check(st);
    var index = st.index;
    if (index == null) {
      // Not part of a program that parsed: try any program that has it
      for (final other in _programs.values) {
        if (other.index != null && other.files.contains(path)) {
          st = other;
          index = other.index;
          break;
        }
      }
    }
    if (index == null) return null;
    final lines = doc?.lines ?? _texts.lines(path) ?? const <String>[];
    return Features(index, path, lines, _resolveImport);
  }

  String? _resolveImport(String target, String fromFile) {
    final sep = Platform.pathSeparator;
    final dir = File(fromFile).parent.path;
    for (final base in [dir, ..._project.includeDirs]) {
      final cand = '$base$sep$target';
      if (File(cand).existsSync()) return canonicalPath(cand);
    }
    return null;
  }
}
