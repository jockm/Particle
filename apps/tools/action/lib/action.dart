/// The Action systems language compiler.
///
/// Compiles Action source files to assembly for a pluggable backend. The only
/// backend at present is the Particle 32-bit RISC assembly backend.
library;

export 'src/ast.dart';
export 'src/backend/backend.dart';
export 'src/backend/particle.dart';
export 'src/cli.dart' show runCli, parseArgs, CliArgs, UsageError, helpText, toolName;
export 'src/analysis.dart';
export 'src/codegen/codegen.dart' show CodeGen, StructInfo, FieldInfo, FuncSig, ParamSig;
export 'src/driver.dart';
export 'src/errors.dart';
export 'src/lexer.dart' show Token, tokenize;
export 'src/parser.dart';
