// A client that talks to the server in memory, for the tests.

import 'dart:async';
import 'dart:io';

import 'package:action_lsp/action_lsp.dart';
import 'package:action_lsp/src/documents.dart';

class TestClient {
  final _toServer = StreamController<List<int>>();
  final _fromServer = StreamController<List<int>>();
  late final Connection _conn = Connection(_fromServer.stream, _toServer.sink);
  late final ActionLanguageServer server =
      ActionLanguageServer(Connection(_toServer.stream, _fromServer.sink), debounce: Duration.zero);
  final _waiting = <int, Completer<Map<String, Object?>>>{};
  final _diagnostics = <String, List<Object?>>{};
  final _diagWaiters = <String, List<Completer<List<Object?>>>>{};
  var _nextId = 1;
  late final Future<int> exitCode;

  /// A temporary workspace with [files] (relative path to contents).
  final Directory root;

  TestClient._(this.root) {
    _conn.messages.listen((m) {
      if (m.containsKey('id') && !m.containsKey('method')) {
        _waiting.remove(m['id'])?.complete(m);
      } else if (m['method'] == 'textDocument/publishDiagnostics') {
        final p = m['params'] as Map<String, Object?>;
        final uri = p['uri'] as String;
        final d = p['diagnostics'] as List<Object?>;
        _diagnostics[uri] = d;
        for (final c in _diagWaiters.remove(uri) ?? const <Completer<List<Object?>>>[]) {
          c.complete(d);
        }
      }
    });
    exitCode = server.run();
  }

  static Future<TestClient> start(Map<String, String> files) async {
    final dir = Directory.systemTemp.createTempSync('action_lsp_test_');
    final root = Directory(canonicalPath(dir.path));
    for (final e in files.entries) {
      File('${root.path}/${e.key}')
        ..createSync(recursive: true)
        ..writeAsStringSync(e.value);
    }
    final c = TestClient._(root);
    await c.request('initialize', {
      'processId': null,
      'rootUri': Uri.directory(root.path).toString(),
      'capabilities': {},
    });
    c.notify('initialized', {});
    return c;
  }

  /// The last diagnostics published for [rel], if any.
  List<Object?>? lastDiagnostics(String rel) => _diagnostics[uri(rel)];

  String uri(String rel) => pathToUri('${root.path}/$rel');

  String text(String rel) => File('${root.path}/$rel').readAsStringSync();

  Future<Map<String, Object?>> request(String method, Object? params) {
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _waiting[id] = c;
    _conn.send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future.timeout(const Duration(seconds: 10));
  }

  Future<Object?> result(String method, Object? params) async {
    final r = await request(method, params);
    if (r.containsKey('error')) throw StateError('${r['error']}');
    return r['result'];
  }

  void notify(String method, Object? params) =>
      _conn.send({'jsonrpc': '2.0', 'method': method, 'params': params});

  /// The next diagnostics published for [rel].
  Future<List<Object?>> nextDiagnostics(String rel) {
    final c = Completer<List<Object?>>();
    (_diagWaiters[uri(rel)] ??= []).add(c);
    return c.future.timeout(const Duration(seconds: 10));
  }

  /// Opens [rel] (with [text], or its contents on disk) and returns the
  /// diagnostics published for it.
  Future<List<Object?>> open(String rel, [String? text]) {
    final f = nextDiagnostics(rel);
    notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri(rel),
        'languageId': 'action',
        'version': 1,
        'text': text ?? this.text(rel),
      }
    });
    return f;
  }

  Future<List<Object?>> change(String rel, String text, int version) {
    final f = nextDiagnostics(rel);
    notify('textDocument/didChange', {
      'textDocument': {'uri': uri(rel), 'version': version},
      'contentChanges': [
        {'text': text}
      ],
    });
    return f;
  }

  Map<String, Object?> at(String rel, int line, int character) => {
        'textDocument': {'uri': uri(rel)},
        'position': {'line': line, 'character': character},
      };

  Future<void> close() async {
    await request('shutdown', null);
    notify('exit', null);
    await exitCode;
    await _toServer.close();
    root.deleteSync(recursive: true);
  }
}

/// Line and character of the first [needle] in [text] (plus [offset]
/// characters).
(int, int) find(String text, String needle, [int offset = 0]) {
  final i = text.indexOf(needle);
  if (i < 0) throw ArgumentError('"$needle" not found');
  final before = text.substring(0, i);
  final line = '\n'.allMatches(before).length;
  final col = i - (before.lastIndexOf('\n') + 1);
  return (line, col + offset);
}
