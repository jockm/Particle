// =============================================================================
// File: apps/tools/pasm_lsp/bin/main.dart
// Project: Particle RISC Architecture
// Description: CLI entry point for pasm_lsp (Particle Assembly Language Server).
// =============================================================================

import "dart:io";
import "package:pasm_lsp/server.dart";

Future<void> main(List<String> args) async {
  if (args.contains("--version") || args.contains("-v")) {
    stdout.writeln("pasm_lsp 0.1.0 (Particle RISC Assembly Language Server)");
    return;
  }
  if (args.contains("--help") || args.contains("-h")) {
    stdout.writeln("usage: pasm_lsp [--stdio]");
    stdout.writeln("Particle RISC Assembly Language Server (speaks JSON-RPC 2.0 over stdio)");
    return;
  }

  final server = PasmLanguageServer();
  await server.start();
}
