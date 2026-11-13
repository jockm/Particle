// ------------------------------------------------------------------------------
// Pluggable Backend Architecture
// ------------------------------------------------------------------------------

import '../scope_resolve.dart' show internalNameMark, sourceName;

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

/// Abstract code generation backend interface.
///
/// The code generator drives a backend: it collects the emitted assembly
/// lines, hands out unique labels and knows how to materialise immediates and
/// call the target's heap runtime. A backend also describes the target: its
/// name, the scalar types it supports natively and the size of a pointer.
abstract class Backend implements Target {
  /// Assembly lines emitted so far.
  final List<String> asm = [];
  int labelCounter = 0;

  @override
  String get name => 'base';

  /// Trap vector table: address of vector 0, bytes per vector, and number
  /// of vectors. Vector N starts at `vectorBase + N * vectorStride`.
  int get vectorBase;
  int get vectorStride;

  @override
  bool supportsType(String tName) => false;

  @override
  bool get isHosted => false;

  @override
  int get registerBits => 32;

  void emit(String line, [String comment = '']) {
    if (comment.isNotEmpty) {
      asm.add('    ${_label(line).padRight(24)} ; ${sourceName(comment)}');
    } else {
      asm.add('    ${_label(line)}');
    }
  }

  /// [text] with the internal names of block-scoped symbols made into
  /// valid labels (`T~3` becomes `T.3`).
  String _label(String text) => text.replaceAll(internalNameMark, '.');

  void emitLabel(String label) {
    asm.add('${_label(label)}:');
  }

  String newLabel([String prefix = 'L']) {
    labelCounter++;
    return '._${prefix}_$labelCounter';
  }

  void emitImmediate(int reg, int val);

  /// Like [emitImmediate], for use while R14 holds a live value: any
  /// scratch register the load needs is preserved.
  void emitImmediateKeepR14(int reg, int val);

  /// Allocate [sizeBytes] on heap; return base pointer in [dstReg].
  void genHeapAlloc(int dstReg, int sizeBytes);

  /// When true, a failed allocation (the allocator returns 0) traps instead
  /// of giving a null reference (`-freference-check`, the default).
  bool referenceCheck = true;

  /// Emits a trap (TRAP 15 on Particle) taken when [reg] holds 0, a null
  /// reference; [what] names it in the listing.
  void genNullTrap(int reg, String what);

  /// Free memory block at [addrReg].
  void genHeapFree(int addrReg);

  /// Allocate dynamic array with 4-byte count header; return payload pointer in [dstReg].
  void genArrayAlloc(int dstReg, int elemSize, int countReg);

  /// Free dynamic array given its payload pointer.
  void genArrayFree(int addrReg);

  /// Resize dynamic array with 4-byte count header; return updated payload pointer in [dstReg].
  void genArrayResize(int dstReg, int addrReg, int elemSize, int countReg);

  /// Allocate dynamic string with 4-byte capacity header and null byte; return payload pointer.
  void genStringAlloc(int dstReg, int capReg);
}
