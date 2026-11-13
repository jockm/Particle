// ------------------------------------------------------------------------------
// Target: what the checker needs to know about a machine
// ------------------------------------------------------------------------------

/// What the checker needs to know about the machine a program is for: the
/// size of a pointer, how values align, how many trap vectors there are and
/// which integer types it has.
abstract class Target {
  /// Short name used in diagnostics (for example `particle`).
  String get name;

  /// Size in bytes of a pointer (an address or reference) on this target.
  int get pointerSize;

  /// Alignment, in bytes, of a primitive value or reference [size] bytes
  /// wide. Record fields are placed at a multiple of it, a record aligns
  /// to its most-aligned field, and a record's size is a multiple of its
  /// alignment so that arrays of records stay aligned.
  int alignOf(int size);

  /// Number of trap vectors (trap numbers are 0 to vectorCount - 1).
  int get vectorCount;

  /// Return true if the target supports integer/scalar type [tName].
  bool supportsType(String tName);

  /// True for a program that runs under an operating system (LLVM): there
  /// is no Particle hardware (FIFOs, trap vectors, Particle assembly), and
  /// C functions can be declared `extern`.
  bool get isHosted;

  /// Width of the values expressions are computed in, at the widest.
  int get registerBits;
}
