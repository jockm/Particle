/// Error raised for any problem in the user's program: syntax errors, type
/// errors, failed `verify` assertions, missing files and so on.
///
/// The Python compiler raised `SyntaxError`, `TypeError`, `ValueError` and
/// `FileNotFoundError`; all of them are reported the same way, so the port
/// uses a single exception type. The message text is kept as it was.
class CompileError implements Exception {
  final String message;

  CompileError(this.message);

  static final _locPrefix = RegExp(r'^\S+:\d+:\d+: ');

  /// True when the message already starts with `file:line:col: `.
  bool get hasLoc => _locPrefix.hasMatch(message);

  /// This error with [loc] (`file:line:col`) in front, unless it already
  /// names a location or [loc] is null.
  CompileError at(String? loc) {
    if (loc == null || hasLoc) return this;
    return withMessage('$loc: $message');
  }

  /// A copy of this error (of the same kind) with [msg] as its message.
  CompileError withMessage(String msg) => CompileError(msg);

  @override
  String toString() => message;
}

/// How serious a [CompileNote] is. Notes never stop compilation.
enum NoteSeverity { warning, info }

/// A warning or information about the program. Like [CompileError], its
/// message starts with `file:line:col: ` when it has a location.
class CompileNote {
  final NoteSeverity severity;
  final String message;
  const CompileNote(this.severity, this.message);

  /// How the command line prints it: `action: warning: …`.
  String format(String tool) => '$tool: ${severity.name}: $message';

  @override
  String toString() => '${severity.name}: $message';
}
