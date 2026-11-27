// A serial port as a PmonLink: set up with stty (raw, 8N1, no flow
// control), read and written as files. Works on macOS and Linux.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'protocol.dart';

class SerialLink implements PmonLink {
  SerialLink._(this.port, this._out, this._sub);

  final String port;
  final RandomAccessFile _out;
  final StreamSubscription<List<int>> _sub;
  final _pending = Queue<int>();
  Completer<void>? _arrived;

  /// Bytes as they arrive, for the console (instead of readByte).
  void Function(List<int> bytes)? onData;

  /// Opens [port] at [baud]. The port is opened before stty runs, so that
  /// its settings hold while it stays open (macOS puts them back when the
  /// last user closes it).
  static Future<SerialLink> open(String port, {int baud = 115200}) async {
    if (!File(port).existsSync()) {
      throw PmonException('no serial port $port');
    }
    final out = await File(port).open(mode: FileMode.writeOnly);
    final flag = Platform.isMacOS ? '-f' : '-F';
    final stty = await Process.run('stty', [
      flag, port, '$baud', 'raw', '-echo', 'cs8', '-cstopb', '-parenb',
      '-crtscts', '-ixon', '-ixoff', 'clocal', 'min', '1', 'time', '0',
    ]);
    if (stty.exitCode != 0) {
      await out.close();
      throw PmonException('stty $port: ${stty.stderr}'.trim());
    }
    late SerialLink link;
    final sub = File(port).openRead().listen((data) {
      final cb = link.onData;
      if (cb != null) {
        cb(data);
        return;
      }
      link._pending.addAll(data);
      link._arrived?.complete();
      link._arrived = null;
    }, onError: (Object e) {
      stderr.writeln('pmon: reading $port: $e');
    });
    link = SerialLink._(port, out, sub);
    return link;
  }

  /// Writes go straight to the port (no flush: fsync fails on a tty).
  @override
  void write(List<int> bytes) => _out.writeFromSync(bytes);

  @override
  Future<int?> readByte(Duration timeout) async {
    final until = DateTime.now().add(timeout);
    while (_pending.isEmpty) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      _arrived ??= Completer<void>();
      await _arrived!.future.timeout(left, onTimeout: () {});
    }
    return _pending.removeFirst();
  }

  @override
  void discardInput() => _pending.clear();

  /// Closes the port. The read under way may not end until a byte comes,
  /// so this doesn't wait for it: the tool exits after.
  @override
  Future<void> close() async {
    unawaited(_sub.cancel());
    await _out.close();
  }
}
