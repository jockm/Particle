// ------------------------------------------------------------------------------
// Analysis for tools
// ------------------------------------------------------------------------------
//
// Runs the compiler's checks without writing any output and returns what an
// editor needs: the program's syntax tree, the first error (with its
// location taken apart), and what the checker learned about types,
// constants and functions.

import 'ast.dart';
import 'backend/particle.dart';
import 'codegen/codegen.dart';
import 'driver.dart';
import 'errors.dart';

/// An error at a place in the source. [line] counts from 1 and [column]
/// from 0, as in the compiler's messages.
class Diagnostic {
  /// [DiagnosticSeverity.error] for the error that stopped checking;
  /// warnings and information do not stop it.
  final DiagnosticSeverity severity;

  /// The file, or null when the message names no location.
  final String? path;
  final int line;
  final int column;
  final String message;
  const Diagnostic(this.path, this.line, this.column, this.message,
      [this.severity = DiagnosticSeverity.error]);

  static final _located = RegExp(r'^(.+?):(\d+):(\d+): (.*)$', dotAll: true);

  /// Splits a compiler message into its location and text.
  factory Diagnostic.fromError(CompileError e) => Diagnostic._parse(e.message, DiagnosticSeverity.error);

  /// A warning or information as a diagnostic.
  factory Diagnostic.fromNote(CompileNote n) => Diagnostic._parse(
      n.message,
      n.severity == NoteSeverity.warning ? DiagnosticSeverity.warning : DiagnosticSeverity.info);

  factory Diagnostic._parse(String text, DiagnosticSeverity severity) {
    final m = _located.firstMatch(text);
    if (m == null) return Diagnostic(null, 1, 0, text, severity);
    return Diagnostic(
        m.group(1), int.parse(m.group(2)!), int.parse(m.group(3)!), m.group(4)!, severity);
  }

  @override
  String toString() => path == null ? message : '$path:$line:$column: $message';
}

enum DiagnosticSeverity { error, warning, info }

/// What checking a program found.
class AnalysisResult {
  /// The syntax tree, or null if the program could not be parsed.
  final ProgramNode? program;

  /// The first error, or null if the program compiles.
  final Diagnostic? error;

  /// Types, constants and functions, as far as checking got. Null if the
  /// program could not be parsed.
  final ProgramInfo? info;

  /// Warnings and information, in order.
  final List<Diagnostic> notes;

  const AnalysisResult(this.program, this.error, this.info, [this.notes = const []]);
}

/// Read-only view of what checking worked out.
class ProgramInfo {
  final Checker _cg;
  ProgramInfo(this._cg);

  /// Layout of each user-defined type.
  Map<String, StructInfo> get types => _cg.structs;

  /// Each constant's value as a 32-bit pattern.
  Map<String, int> get constants => _cg.constants;

  /// Declared type of a constant, or null if it is untyped.
  String? constType(String name) => _cg.constTypeOf(name);

  /// Signatures of the functions, by their generated names (`Type_method`
  /// for methods).
  Map<String, FuncSig> get functions => _cg.funcSignatures;

  /// Function types (`type Name = fn(...) -> T`), as parameter types and
  /// return type.
  Map<String, (List<String>, String)> get functionTypes => _cg.fnTypes;
}

/// The targets a program can be checked for: Particle (the `action`
/// compiler) and LLVM (`action_llvm`).
const analysisTargets = ['particle', 'llvm'];

/// Checks [sources] (and what they import) as the compiler for [target]
/// (one of [analysisTargets]) would, without producing code.
AnalysisResult analyze(List<String> sources,
    {CompileOptions options = const CompileOptions(), String target = 'particle'}) {
  final ProgramNode program;
  final Map<String, int> defines;
  try {
    defines = parseDefines(options.defines);
    program = loadProgram(sources, options);
  } on CompileError catch (e) {
    return AnalysisResult(null, Diagnostic.fromError(e), null);
  }
  final cg = Checker(target == 'llvm' ? LlvmTarget() : ParticleAsmBackend(),
      predefinedConstants: defines);
  Diagnostic? error;
  try {
    cg.check(program);
  } on CompileError catch (e) {
    error = Diagnostic.fromError(e);
  }
  return AnalysisResult(
      program, error, ProgramInfo(cg), [for (final n in cg.notes) Diagnostic.fromNote(n)]);
}
