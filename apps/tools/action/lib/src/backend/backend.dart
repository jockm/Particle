// ------------------------------------------------------------------------------
// Pluggable Backend Architecture
// ------------------------------------------------------------------------------

/// Abstract code generation backend interface.
///
/// The code generator drives a backend: it collects the emitted assembly
/// lines, hands out unique labels and knows how to materialise immediates and
/// call the target's heap runtime. A backend also describes the target: its
/// name, the scalar types it supports natively and the size of a pointer.
abstract class Backend {
  /// Assembly lines emitted so far.
  final List<String> asm = [];
  int labelCounter = 0;

  /// Short name used in diagnostics (for example `particle`).
  String get name => 'base';

  /// Size in bytes of a pointer (an address or reference) on this target.
  int get pointerSize;

  /// Alignment, in bytes, of a primitive value or reference [size] bytes
  /// wide. Record fields are placed at a multiple of it, a record aligns
  /// to its most-aligned field, and a record's size is a multiple of its
  /// alignment so that arrays of records stay aligned.
  int alignOf(int size);

  /// Trap vector table: address of vector 0, bytes per vector, and number
  /// of vectors. Vector N starts at `vectorBase + N * vectorStride`.
  int get vectorBase;
  int get vectorStride;
  int get vectorCount;

  /// Return true if backend natively supports integer/scalar type [tName].
  bool supportsType(String tName) => false;

  void emit(String line, [String comment = '']) {
    if (comment.isNotEmpty) {
      asm.add('    ${line.padRight(24)} ; $comment');
    } else {
      asm.add('    $line');
    }
  }

  void emitLabel(String label) {
    asm.add('$label:');
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
