// ------------------------------------------------------------------------------
// Open documents, paths and positions
// ------------------------------------------------------------------------------

import 'dart:io';

/// A position in a document: [line] and [character] both count from 0, as
/// in LSP. (The compiler counts lines from 1 and columns from 0.)
class Pos {
  final int line;
  final int character;
  const Pos(this.line, this.character);

  Map<String, Object?> toJson() => {'line': line, 'character': character};

  static Pos fromJson(Object? json) {
    final m = json as Map<String, Object?>;
    return Pos(m['line'] as int, m['character'] as int);
  }

  bool operator <(Pos o) => line < o.line || (line == o.line && character < o.character);
  bool operator <=(Pos o) => !(o < this);

  @override
  String toString() => '$line:$character';
}

Map<String, Object?> rangeJson(Pos start, Pos end) =>
    {'start': start.toJson(), 'end': end.toJson()};

/// A file path for a `file:` URI.
String uriToPath(String uri) => Uri.parse(uri).toFilePath();

/// The `file:` URI of [path].
String pathToUri(String path) => Uri.file(path).toString();

/// [path] made absolute with symbolic links resolved when it exists, so it
/// matches the paths the compiler records.
String canonicalPath(String path) {
  final abs = File(path).absolute.path;
  try {
    return File(abs).resolveSymbolicLinksSync();
  } on FileSystemException {
    return abs;
  }
}

/// The text of a document the editor has open.
class Document {
  final String uri;
  final String path;
  String text;
  int version;
  List<String>? _lines;

  Document(this.uri, this.path, this.text, this.version);

  List<String> get lines => _lines ??= text.split('\n');

  void update(String newText, int newVersion) {
    text = newText;
    version = newVersion;
    _lines = null;
  }
}

/// Source text by path: open documents first, then the file on disk.
class SourceTexts {
  final Map<String, Document> _open = {}; // by canonical path
  final Map<String, List<String>> _diskCache = {};

  Iterable<Document> get open => _open.values;

  Document? openDocument(String path) => _open[canonicalPath(path)];

  void add(Document d) {
    _open[d.path] = d;
    _diskCache.remove(d.path);
  }

  void remove(String path) => _open.remove(path);

  /// The unsaved texts, for the compiler.
  Map<String, String> get overlays => {for (final d in _open.values) d.path: d.text};

  /// Lines of [path], or null if it cannot be read.
  List<String>? lines(String path) {
    final p = canonicalPath(path);
    final d = _open[p];
    if (d != null) return d.lines;
    final cached = _diskCache[p];
    if (cached != null) return cached;
    try {
      final l = File(p).readAsStringSync().split('\n');
      _diskCache[p] = l;
      return l;
    } on FileSystemException {
      return null;
    }
  }

  /// Forgets cached disk contents (after files change on disk).
  void clearDiskCache() => _diskCache.clear();
}

final _wordChar = RegExp(r'[A-Za-z0-9_]');

bool isWordChar(String c) => _wordChar.hasMatch(c);

/// The end of the word, number or symbol starting at [start] on [line].
int tokenEnd(String line, int start) {
  if (start >= line.length) return start;
  if (line[start] == '"') {
    final close = line.indexOf('"', start + 1);
    return close < 0 ? line.length : close + 1;
  }
  if (!isWordChar(line[start])) return start + 1;
  var i = start;
  while (i < line.length && isWordChar(line[i])) {
    i++;
  }
  return i;
}
