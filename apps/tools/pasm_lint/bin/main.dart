// =============================================================================
// File: apps/tools/pasm_lint/bin/main.dart
// Project: Particle RISC Architecture
// Description: CLI entry point for pasm_lint (Static Assembly Linter).
// =============================================================================

import "dart:io";
import "package:pasm_lint/linter.dart";

void main(List<String> args) {
  String? source;
  final includes = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == "-I" || arg == "--include") {
      if (i + 1 < args.length) {
        includes.add(args[++i]);
      }
    } else if (arg.startsWith("-I")) {
      includes.add(arg.substring(2));
    } else if (!arg.startsWith("-")) {
      source = arg;
    }
  }

  if (source == null) {
    stderr.writeln("Usage: pasm_lint [options] <source.asm>");
    exit(1);
  }

  exit(lintFile(source, includes));
}
