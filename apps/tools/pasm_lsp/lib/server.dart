// =============================================================================
// File: apps/tools/pasm_lsp/lib/server.dart
// Project: Particle RISC Architecture
// Description: JSON-RPC 2.0 Language Server Protocol (LSP) engine over stdio.
// =============================================================================

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";
import "analyzer.dart";

/// Language Server handling Content-Length framed JSON-RPC 2.0 messages.
class PasmLanguageServer {
  final ParticleAnalyzer analyzer = ParticleAnalyzer();
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int? _expectedLength;
  bool _shutdownRequested = false;

  Future<void> start() async {
    await for (final chunk in stdin) {
      _buffer.add(chunk);
      _processBuffer();
    }
  }

  void _processBuffer() {
    while (true) {
      final bytes = _buffer.toBytes();
      if (_expectedLength == null) {
        final headerEnd = _findHeaderEnd(bytes);
        if (headerEnd == -1) return;

        final headerStr = ascii.decode(bytes.sublist(0, headerEnd), allowInvalid: true);
        final match = RegExp(r"Content-Length:\s*(\d+)", caseSensitive: false).firstMatch(headerStr);
        if (match == null) {
          _buffer.clear();
          _buffer.add(bytes.sublist(headerEnd + 4));
          continue;
        }
        _expectedLength = int.parse(match.group(1)!);
        final remaining = bytes.sublist(headerEnd + 4);
        _buffer.clear();
        _buffer.add(remaining);
      }

      final currentBytes = _buffer.toBytes();
      final need = _expectedLength!;
      if (currentBytes.length < need) return;

      final payloadBytes = currentBytes.sublist(0, need);
      final leftover = currentBytes.sublist(need);
      _buffer.clear();
      _buffer.add(leftover);
      _expectedLength = null;

      try {
        final jsonStr = utf8.decode(payloadBytes);
        final msg = jsonDecode(jsonStr) as JsonMap;
        _handleMessage(msg);
      } catch (e) {
        stderr.writeln("[pasm_lsp] Failed to decode message: $e");
      }
    }
  }

  /// Finds the index of CR LF CR LF separating LSP headers from the JSON body.
  int _findHeaderEnd(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  void _send(JsonMap packet) {
    final body = utf8.encode(jsonEncode(packet));
    final header = ascii.encode("Content-Length: ${body.length}\r\n\r\n");
    stdout.add(header);
    stdout.add(body);
  }

  void _sendResponse(dynamic id, dynamic result) {
    _send({
      "jsonrpc": "2.0",
      "id": id,
      "result": result,
    });
  }

  void _sendError(dynamic id, int code, String message) {
    _send({
      "jsonrpc": "2.0",
      "id": id,
      "error": {
        "code": code,
        "message": message,
      },
    });
  }

  void _sendNotification(String method, JsonMap params) {
    _send({
      "jsonrpc": "2.0",
      "method": method,
      "params": params,
    });
  }

  String _uriToPath(String uriStr) {
    final uri = Uri.parse(uriStr);
    if (uri.scheme == "file") {
      return uri.toFilePath();
    }
    return uriStr;
  }

  void _handleMessage(JsonMap msg) {
    final method = msg["method"] as String?;
    final id = msg["id"];
    final params = (msg["params"] as JsonMap?) ?? const <String, dynamic>{};

    if (method == null) return;

    try {
      switch (method) {
        case "initialize":
          final rootUri = params["rootUri"] as String?;
          final rootPath = params["rootPath"] as String?;
          if (rootUri != null && rootUri.startsWith("file://")) {
            analyzer.workspaceRoot = _uriToPath(rootUri);
          } else if (rootPath != null && rootPath.isNotEmpty) {
            analyzer.workspaceRoot = rootPath;
          }
          _sendResponse(id, {
            "capabilities": {
              "textDocumentSync": {
                "openClose": true,
                "change": 1,
                "save": {"includeText": true},
              },
              "hoverProvider": true,
              "definitionProvider": true,
              "referencesProvider": true,
              "renameProvider": {"prepareProvider": true},
              "documentSymbolProvider": true,
              "completionProvider": {
                "triggerCharacters": [".", " ", ","],
              },
            },
            "serverInfo": {
              "name": "pasm_lsp",
              "version": "0.1.0",
            },
          });
          break;

        case "initialized":
          break;

        case "shutdown":
          _shutdownRequested = true;
          _sendResponse(id, null);
          break;

        case "exit":
          exitCode = _shutdownRequested ? 0 : 1;
          stdin.listen(null).cancel();
          break;

        case "textDocument/didOpen":
          final doc = params["textDocument"] as JsonMap;
          final uri = doc["uri"] as String;
          final text = doc["text"] as String? ?? "";
          _analyzeAndPublish(uri, text);
          break;

        case "textDocument/didChange":
          final doc = params["textDocument"] as JsonMap;
          final uri = doc["uri"] as String;
          final changes = params["contentChanges"] as List<dynamic>? ?? const [];
          if (changes.isNotEmpty) {
            final lastChange = changes.last as JsonMap;
            final text = lastChange["text"] as String? ?? "";
            _analyzeAndPublish(uri, text);
          }
          break;

        case "textDocument/didSave":
          final doc = params["textDocument"] as JsonMap;
          final uri = doc["uri"] as String;
          final text = params["text"] as String?;
          if (text != null) {
            _analyzeAndPublish(uri, text);
          } else {
            final path = _uriToPath(uri);
            final analysis = analyzer.analyzeDocument(analyzer.canonicalize(path));
            _publishDiagnostics(uri, analysis);
          }
          break;

        case "textDocument/didClose":
          final doc = params["textDocument"] as JsonMap;
          final uri = doc["uri"] as String;
          final path = _uriToPath(uri);
          analyzer.closeDocument(path);
          _sendNotification("textDocument/publishDiagnostics", {
            "uri": uri,
            "diagnostics": const [],
          });
          break;

        case "textDocument/hover":
          final doc = params["textDocument"] as JsonMap;
          final pos = params["position"] as JsonMap;
          final path = _uriToPath(doc["uri"] as String);
          final line = pos["line"] as int;
          final character = pos["character"] as int;
          final hover = analyzer.getHover(path, line, character);
          _sendResponse(id, hover);
          break;

        case "textDocument/definition":
          final doc = params["textDocument"] as JsonMap;
          final pos = params["position"] as JsonMap;
          final path = _uriToPath(doc["uri"] as String);
          final line = pos["line"] as int;
          final character = pos["character"] as int;
          final def = analyzer.findDefinition(path, line, character);
          _sendResponse(id, def);
          break;

        case "textDocument/references":
          final doc = params["textDocument"] as JsonMap;
          final pos = params["position"] as JsonMap;
          final ctx = (params["context"] as JsonMap?) ?? const <String, dynamic>{};
          final incDecl = (ctx["includeDeclaration"] as bool?) ?? true;
          final path = _uriToPath(doc["uri"] as String);
          final line = pos["line"] as int;
          final character = pos["character"] as int;
          final refs = analyzer.findReferences(
            path,
            line,
            character,
            includeDeclaration: incDecl,
          );
          _sendResponse(id, refs);
          break;

        case "textDocument/prepareRename":
          final doc = params["textDocument"] as JsonMap;
          final pos = params["position"] as JsonMap;
          final path = _uriToPath(doc["uri"] as String);
          final line = pos["line"] as int;
          final character = pos["character"] as int;
          final prep = analyzer.prepareRename(path, line, character);
          if (prep == null) {
            _sendError(id, -32602, "Cannot rename built-in instruction, register, or literal.");
          } else {
            _sendResponse(id, prep);
          }
          break;

        case "textDocument/rename":
          final doc = params["textDocument"] as JsonMap;
          final pos = params["position"] as JsonMap;
          final newName = params["newName"] as String? ?? "";
          final path = _uriToPath(doc["uri"] as String);
          final line = pos["line"] as int;
          final character = pos["character"] as int;
          final edit = analyzer.renameSymbol(path, line, character, newName);
          _sendResponse(id, edit);
          break;

        case "textDocument/documentSymbol":
          final doc = params["textDocument"] as JsonMap;
          final path = _uriToPath(doc["uri"] as String);
          final symbols = analyzer.getDocumentSymbols(path);
          _sendResponse(id, symbols);
          break;

        case "textDocument/completion":
          final doc = params["textDocument"] as JsonMap;
          final path = _uriToPath(doc["uri"] as String);
          final items = analyzer.getCompletions(path);
          _sendResponse(id, items);
          break;

        default:
          if (id != null) {
            _sendResponse(id, null);
          }
          break;
      }
    } catch (e, st) {
      stderr.writeln("[pasm_lsp] Error handling $method: $e\n$st");
      if (id != null) {
        _sendError(id, -32603, e.toString());
      }
    }
  }

  void _analyzeAndPublish(String uri, String text) {
    final path = _uriToPath(uri);
    final analysis = analyzer.updateDocument(path, text);
    _publishDiagnostics(uri, analysis);
  }

  void _publishDiagnostics(String uri, DocumentAnalysis analysis) {
    _sendNotification("textDocument/publishDiagnostics", {
      "uri": uri,
      "diagnostics": analysis.diagnostics.map((d) => d.toJson()).toList(),
    });
  }
}
