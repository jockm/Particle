/// The Action systems language compiler.
///
/// Compiles Action source files to Particle 32-bit RISC assembly ([CodeGen])
/// or to LLVM IR for a 64-bit host ([LlvmGen]). Both share one [Checker];
/// see src/compiler.dart for how the source is laid out.
library;

export 'src/ast.dart';
export 'src/target.dart';
export 'src/particle/backend.dart';
export 'src/particle/particle.dart';
export 'src/cli.dart' show runCli, parseArgs, CliArgs, UsageError, helpText, toolName, llvmHelpText, llvmToolName;
export 'src/analysis.dart';
export 'src/compiler.dart' show Checker, CodeGen, LlvmGen, LlvmTarget, StructInfo, FieldInfo, FuncSig, ParamSig, TypeInfo;
export 'src/driver.dart';
export 'src/errors.dart';
export 'src/lexer.dart' show Token, tokenize;
export 'src/parser.dart';
export 'src/scope_resolve.dart' show internalNameMark, sourceName;
