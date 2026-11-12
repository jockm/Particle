// ------------------------------------------------------------------------------
// Minimal POSIX path helpers (the equivalents of Python's os.path functions
// used by the compiler). Kept local so the tool has no package dependencies.
// ------------------------------------------------------------------------------

import 'dart:io';

/// `os.path.join`: joins [parts]; an absolute part discards what precedes it.
String join(String a, [String? b, String? c]) {
  var result = a;
  for (final part in [b, c]) {
    if (part == null) continue;
    if (part.startsWith('/')) {
      result = part;
    } else if (result.isEmpty || result.endsWith('/')) {
      result = '$result$part';
    } else {
      result = '$result/$part';
    }
  }
  return result;
}

/// `os.path.dirname`.
String dirname(String path) {
  final i = path.lastIndexOf('/');
  if (i < 0) return '';
  if (i == 0) return '/';
  return path.substring(0, i);
}

/// `os.path.basename`.
String basename(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// `os.path.splitext(...)[0]`: [path] without its final extension.
String withoutExtension(String path) {
  final base = basename(path);
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return path;
  return path.substring(0, path.length - (base.length - dot));
}

/// `os.path.normpath`: removes `.` and `..` segments and duplicate slashes.
String normalize(String path) {
  final isAbs = path.startsWith('/');
  final out = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!isAbs) {
        out.add('..');
      }
      continue;
    }
    out.add(seg);
  }
  final joined = out.join('/');
  if (isAbs) return '/$joined';
  return joined.isEmpty ? '.' : joined;
}

/// `os.path.abspath`.
String absolute(String path) =>
    normalize(path.startsWith('/') ? path : join(Directory.current.path, path));

/// `os.path.realpath`: absolute, with symbolic links resolved where the path
/// exists.
String realPath(String path) {
  final abs = absolute(path);
  try {
    return File(abs).resolveSymbolicLinksSync();
  } on FileSystemException {
    return abs;
  }
}
