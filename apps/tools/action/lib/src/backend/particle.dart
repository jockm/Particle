import 'backend.dart';

String _hex(int v, int width) =>
    v.toRadixString(16).toUpperCase().padLeft(width, '0');

/// Particle 32-bit RISC Bare-Metal Assembly Backend.
class ParticleAsmBackend extends Backend {
  @override
  String get name => 'particle';

  /// Particle is a 32-bit CPU: addresses and references are 4 bytes.
  @override
  int get pointerSize => 4;

  /// Particle faults (vector 14) on a misaligned 16- or 32-bit access, so
  /// values are naturally aligned: u8 1, u16 2, u32 and references 4.
  @override
  int alignOf(int size) => size >= 4 ? 4 : (size >= 2 ? 2 : 1);

  /// Direct stride vector table (Particle spec section 3): 16 vectors of
  /// 64 bytes from 0x100. Vector 0 is reset, 1 the inbound MBOX, 2-13
  /// software traps, 14 a misaligned access and 15 an illegal opcode.
  @override
  int get vectorBase => 0x00000100;
  @override
  int get vectorStride => 64;
  @override
  int get vectorCount => 16;

  @override
  bool supportsType(String tName) {
    final clean = tName.trim();
    // Particle RISC is currently a 32-bit architecture; u64/s64 are not natively supported
    return ['u8', 's8', 'u16', 's16', 'u32', 's32', 'bool', 'string', 'void']
        .contains(clean);
  }

  @override
  void emitImmediate(int reg, int val) {
    final v = val & 0xFFFFFFFF;
    if (0 <= val && val <= 15) {
      emit('LD      R$reg, $val', 'Imm4 load ($val)');
    } else if (-15 <= val && val < 0) {
      emit('LD      R$reg, -${val.abs()}', '-Imm4 load ($val)');
    } else if (v <= 0xFFFF) {
      emit('LOAD16  R$reg, 0x${_hex(v, 4)}', 'LOAD16 tiered ($val)');
    } else if (v <= 0xFFFFFF) {
      emit('LOAD24  R$reg, 0x${_hex(v, 6)}', 'LOAD24 tiered ($val)');
    } else {
      emit('LOAD32  R$reg, 0x${_hex(v, 8)}', 'LOAD32 full word ($val)');
    }
  }

  /// The LOAD16/24/32 macros of common.inc build the value in R14, so R14
  /// is saved around them. Values that fit an Imm4 load need no macro.
  @override
  void emitImmediateKeepR14(int reg, int val) {
    final needsMacro = !(-15 <= val && val <= 15);
    if (needsMacro && reg != 14) {
      emit('PUSH32  R14', 'Keep R14 across LOAD macro');
      emitImmediate(reg, val);
      emit('POP32   R14');
    } else {
      emitImmediate(reg, val);
    }
  }

  @override
  void genHeapAlloc(int dstReg, int sizeBytes) {
    emitImmediate(1, sizeBytes);
    emit('RCALL   _rt_alloc_zero', 'Heap alloc $sizeBytes bytes (zeroed)');
    _checkAllocation();
    if (dstReg != 1) {
      emit('LD      R$dstReg, R1');
    }
  }

  @override
  void genNullTrap(int reg, String what) {
    final ok = newLabel('ref_ok');
    emit('FBRA.NZ R$reg, $ok', 'Reference is not null');
    emit('TRAP    15', 'Null reference trap ($what)');
    emitLabel(ok);
  }

  /// After an allocator call: traps if it failed (R1 = 0).
  void _checkAllocation() {
    if (referenceCheck) genNullTrap(1, 'allocation failed');
  }

  @override
  void genHeapFree(int addrReg) {
    if (addrReg != 1) {
      emit('LD      R1, R$addrReg');
    }
    emit('RCALL   _rt_free', 'Heap free block');
  }

  @override
  void genArrayAlloc(int dstReg, int elemSize, int countReg) {
    // Calculate total = 4 + (count * elem_size)
    // Preserve count across _rt_alloc on hardware stack
    emit('PUSH32  R$countReg', 'Preserve count for header');
    emit('LD      R1, R$countReg');
    if (elemSize == 2) {
      emit('SHIFTL  R1, 1');
    } else if (elemSize == 4) {
      emit('SHIFTL  R1, 2');
    } else if (elemSize != 1) {
      emitImmediate(2, elemSize);
      emit('MULL    R1, R2');
    }
    emit('ADD     R1, 4', 'Include 4-byte length prefix header');
    emit('RCALL   _rt_alloc_zero', 'Allocate dynamic array (zeroed)');
    _checkAllocation();
    emit('POP32   R2', 'Restore count for header');
    // Store count in prefix header [Offset 0: count]
    emit('ST32    (R1), R2', 'Store array length header');
    // Advance pointer to payload [Offset 4: elements]
    emit('ADD     R1, 4', 'Point to array payload');
    if (dstReg != 1) {
      emit('LD      R$dstReg, R1');
    }
  }

  @override
  void genArrayFree(int addrReg) {
    // Adjust backwards to include length header
    emit('SUB     R$addrReg, 4', 'Adjust pointer to array header');
    if (addrReg != 1) {
      emit('LD      R1, R$addrReg');
    }
    emit('RCALL   _rt_free', 'Free dynamic array block');
  }

  @override
  void genArrayResize(int dstReg, int addrReg, int elemSize, int countReg) {
    // 1. Preserve new element count across _rt_realloc
    emit('PUSH32  R$countReg', 'Preserve new count for header');
    // 2. Calculate new raw byte payload: 4 + (count * elem_size)
    emit('LD      R2, R$countReg');
    if (elemSize == 2) {
      emit('SHIFTL  R2, 1');
    } else if (elemSize == 4) {
      emit('SHIFTL  R2, 2');
    } else if (elemSize != 1) {
      emitImmediate(13, elemSize);
      emit('MULL    R2, R13');
    }
    emit('ADD     R2, 4', 'Include 4-byte length prefix header');
    // 3. Adjust existing payload pointer backwards by 4 to point to raw chunk header
    if (addrReg != 1) {
      emit('LD      R1, R$addrReg');
    }
    emit('SUB     R1, 4', 'Adjust pointer to raw chunk header');
    // 4. Invoke runtime allocator realloc
    emit('RCALL   _rt_realloc', 'Resize dynamic memory chunk');
    _checkAllocation();
    // 5. Restore new element count and update length header
    emit('POP32   R2', 'Restore new count for header');
    emit('ST32    (R1), R2', 'Update array length header');
    // 6. Advance pointer back to user payload
    emit('ADD     R1, 4', 'Point to resized array payload');
    if (dstReg != 1) {
      emit('LD      R$dstReg, R1');
    }
  }

  @override
  void genStringAlloc(int dstReg, int capReg) {
    // Total size = 4 (capacity header) + capacity bytes
    emit('PUSH32  R$capReg', 'Preserve capacity for header');
    emit('LD      R1, R$capReg');
    emit('ADD     R1, 4', 'Include 4-byte capacity prefix header');
    emit('RCALL   _rt_alloc_zero', 'Allocate dynamic string (zeroed)');
    _checkAllocation();
    emit('POP32   R2', 'Restore capacity for header');
    // Store capacity header
    emit('LD32    (R1), R2', 'Store string capacity header');
    emit('ADD     R1, 4', 'Point to string buffer payload');
    // Null terminate initially
    emit('LD8     (R1), R0', 'Null terminate empty dynamic string');
    if (dstReg != 1) {
      emit('LD      R$dstReg, R1');
    }
  }
}
