// ------------------------------------------------------------------------------
// JSON-RPC over a byte stream
// ------------------------------------------------------------------------------
//
// Each message is a header block ("Content-Length: N", then a blank line)
// followed by N bytes of UTF-8 JSON, as the Language Server Protocol
// specifies.

import 'dart:async';
import 'dart:convert';

/// Standard JSON-RPC and LSP error codes.
abstract final class ErrorCodes {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;
  static const serverNotInitialized = -32002;
}

/// An error to send back as a request's response.
class RpcError implements Exception {
  final int code;
  final String message;
  RpcError(this.code, this.message);

  @override
  String toString() => 'RpcError($code): $message';
}

/// Reads and writes framed JSON-RPC messages.
class Connection {
  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  Connection(this._input, this._output);

  /// The incoming messages, decoded. A message that is not valid JSON is
  /// reported as a [FormatException] on the stream.
  Stream<Map<String, Object?>> get messages => _frames(_input);

  /// Sends one message.
  void send(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    _output.add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'));
    _output.add(body);
  }

  Future<void> close() async {
    await _output.close();
  }

  static Stream<Map<String, Object?>> _frames(Stream<List<int>> input) async* {
    final buf = <int>[];
    int? contentLength;
    await for (final chunk in input) {
      buf.addAll(chunk);
      while (true) {
        if (contentLength == null) {
          final end = _headerEnd(buf);
          if (end < 0) break;
          final header = ascii.decode(buf.sublist(0, end), allowInvalid: true);
          buf.removeRange(0, end + 4);
          for (final line in header.split('\r\n')) {
            final colon = line.indexOf(':');
            if (colon < 0) continue;
            if (line.substring(0, colon).trim().toLowerCase() == 'content-length') {
              contentLength = int.tryParse(line.substring(colon + 1).trim());
            }
          }
          if (contentLength == null) {
            throw const FormatException('message header has no Content-Length');
          }
        }
        if (buf.length < contentLength) break;
        final body = utf8.decode(buf.sublist(0, contentLength));
        buf.removeRange(0, contentLength);
        contentLength = null;
        final decoded = jsonDecode(body);
        if (decoded is Map<String, Object?>) yield decoded;
      }
    }
  }

  /// Index of the "\r\n\r\n" ending the header block, or -1.
  static int _headerEnd(List<int> buf) {
    for (var i = 0; i + 3 < buf.length; i++) {
      if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}
