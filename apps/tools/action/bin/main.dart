// =============================================================================
// action - Action Systems Language Compiler
// Target: Particle 32-bit RISC Architecture (16-bit Compact Instruction Set)
// =============================================================================
//
// Compiles one or more Action (.act) source files to Particle assembly.
// Run `action --help` for the command-line options.

import 'dart:io';

import 'package:action/action.dart';

void main(List<String> arguments) {
  exitCode = runCli(arguments);
}
