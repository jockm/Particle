/// Error raised for any problem in the user's program: syntax errors, type
/// errors, failed `verify` assertions, missing files and so on.
///
/// The Python compiler raised `SyntaxError`, `TypeError`, `ValueError` and
/// `FileNotFoundError`; all of them are reported the same way, so the port
/// uses a single exception type. The message text is kept as it was.
class CompileError implements Exception {
  final String message;

  CompileError(this.message);

  @override
  String toString() => message;
}
