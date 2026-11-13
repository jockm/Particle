part of '../compiler.dart';

/// The run-time null checks code generation emits for references the flow
/// analysis does not follow.
extension _RefTraps on CodeGen {
  /// With `-freference-check`, traps if the stored reference [e] (a `ref`
  /// field or an element of an array of references), whose value is in
  /// [reg], is null.
  void _checkStoredRef(AstNode e, int reg) {
    final what = _storedRefName(e);
    if (what != null && referenceCheck) backend.genNullTrap(reg, what);
  }

  /// With `-freference-check`, traps if the reference in [reg], read from
  /// field [field], is null.
  void _checkFieldRef(String field, int reg) {
    if (referenceCheck) backend.genNullTrap(reg, "field '$field'");
  }

  /// With `-freference-check`, traps if [base], a reference held in a
  /// global (which the flow analysis does not follow), is null; its value
  /// is in [reg].
  void _checkGlobalRef(AstNode base, int reg) {
    if (!referenceCheck) return;
    if (base is VarAccessNode &&
        globals.contains(base.name) &&
        !locals.containsKey(base.name)) {
      backend.genNullTrap(reg, "global '${base.name}'");
    }
  }
}
