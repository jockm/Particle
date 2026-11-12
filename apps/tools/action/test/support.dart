// Shared helpers for the compiler unit tests.

import 'dart:io';

import 'package:action/action.dart';

/// Compiles [source] (written to a temporary `main.act`) and returns the
/// assembly. [extraFiles] are written next to it, by relative path, so that
/// imports can be tested.
String compileSource(String source,
    {List<String> defines = const [],
    Map<String, String> extraFiles = const {},
    bool boundsCheck = true,
    bool referenceCheck = true}) {
  final dir = Directory.systemTemp.createTempSync('action_test_');
  try {
    final main = File('${dir.path}/main.act')..writeAsStringSync(source);
    for (final e in extraFiles.entries) {
      File('${dir.path}/${e.key}')
        ..createSync(recursive: true)
        ..writeAsStringSync(e.value);
    }
    return compile([main.path],
        options: CompileOptions(
            includeDirs: [dir.path],
            defines: defines,
            boundsCheck: boundsCheck,
            referenceCheck: referenceCheck));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The message of the [CompileError] that compiling [source] throws, or
/// null if it compiles.
String? compileErrorOf(String source, {List<String> defines = const []}) {
  try {
    compileSource(source, defines: defines);
    return null;
  } on CompileError catch (e) {
    return e.message;
  }
}

/// The instruction mnemonics of [asm], one per code line, without operands
/// or comments.
List<String> mnemonics(String asm) => [
      for (final line in asm.split('\n'))
        if (line.startsWith('    ') && !line.trimLeft().startsWith(';'))
          line.trim().split(RegExp(r'\s+')).first
    ];

/// The code lines of the function [name] in [asm], from its label to the
/// next function header.
String functionBody(String asm, String name) {
  final start = asm.indexOf('\n_$name:');
  if (start < 0) throw StateError('no function $name');
  final end = asm.indexOf('; Function:', start);
  return asm.substring(start, end < 0 ? asm.length : end);
}
