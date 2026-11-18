// ------------------------------------------------------------------------------
// Minimal path helpers (the equivalents of Python's os.path functions used by
// the compiler). Kept local so the tool has no package dependencies.
//
// Paths always use '/'. On Windows, '\' in a path given to these helpers is
// turned into '/', and a drive ('C:/...') or a share ('//server/...') starts
// an absolute path. Dart's file functions accept '/' on Windows.
// ------------------------------------------------------------------------------

import 'dart:io';

/// Whether paths are Windows paths: true on Windows. Tests set it to check
/// Windows paths on other systems.
bool windowsPaths = Platform.isWindows;

/// [path] with '/' between its parts: on Windows, '\' becomes '/'.
String slashes(String path) => windowsPaths ? path.replaceAll('\\', '/') : path;

/// The part of [path] (already with '/') that makes it absolute: '/', a
/// drive ('C:/') or the start of a share ('//'); '' for a relative path.
String _root(String path) {
  if (windowsPaths) {
    if (path.startsWith('//')) return '//';
    if (path.length >= 2 && path[1] == ':' && _isLetter(path.codeUnitAt(0))) {
      return path.length >= 3 && path[2] == '/' ? path.substring(0, 3) : path.substring(0, 2);
    }
  }
  return path.startsWith('/') ? '/' : '';
}

bool _isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Whether [path] is absolute.
bool isAbsolute(String path) {
  final root = _root(slashes(path));
  return root.isNotEmpty && root.endsWith('/');
}

/// `os.path.join`: joins [parts]; an absolute part discards what precedes it.
String join(String a, [String? b, String? c]) {
  var result = slashes(a);
  for (final raw in [b, c]) {
    if (raw == null) continue;
    final part = slashes(raw);
    if (isAbsolute(part)) {
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
  final s = slashes(path);
  final root = _root(s);
  final i = s.lastIndexOf('/');
  if (i < root.length) return root;
  if (i < 0) return '';
  return s.substring(0, i);
}

/// `os.path.basename`.
String basename(String path) {
  final s = slashes(path);
  final i = s.lastIndexOf('/');
  return i < 0 ? s : s.substring(i + 1);
}

/// `os.path.splitext(...)[0]`: [path] without its final extension.
String withoutExtension(String path) {
  final s = slashes(path);
  final base = basename(s);
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return s;
  return s.substring(0, s.length - (base.length - dot));
}

/// `os.path.normpath`: removes `.` and `..` segments and duplicate slashes.
String normalize(String path) {
  final s = slashes(path);
  final root = _root(s);
  final isAbs = root.isNotEmpty;
  final out = <String>[];
  for (final seg in s.substring(root.length).split('/')) {
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
  if (isAbs) return '$root$joined';
  return joined.isEmpty ? '.' : joined;
}

/// `os.path.abspath`.
String absolute(String path) =>
    normalize(isAbsolute(path) ? path : join(Directory.current.path, path));

/// `os.path.realpath`: absolute, with symbolic links resolved where the path
/// exists.
String realPath(String path) {
  final abs = absolute(path);
  try {
    return slashes(File(abs).resolveSymbolicLinksSync());
  } on FileSystemException {
    return abs;
  }
}
