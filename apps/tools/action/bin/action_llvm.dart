// =============================================================================
// action_llvm - Action Systems Language Compiler for LLVM
// Target: a 64-bit host (macOS or Linux), through LLVM IR
// =============================================================================
//
// Compiles one or more Action (.act) source files to LLVM IR (.ll); llbuild
// compiles and links that with clang. Run `action_llvm --help` for the
// command-line options.

import 'dart:io';

import 'package:action/action.dart';

void main(List<String> arguments) {
  exitCode = runCli(arguments, llvm: true);
}
