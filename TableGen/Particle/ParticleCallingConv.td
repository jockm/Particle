//===-- ParticleCallingConv.td - Particle calling convention -*- tablegen -*-===//
//
// R1-R4: arguments and return values (caller-saved)
// R5-R10: callee-saved
// R11-R13: scratch (caller-saved)
// R14: link register. It is listed as callee-saved so a function that
//      clobbers it (any call, or an Imm8 constant) saves/restores it in the
//      prologue/epilogue — the same trick RISC-V uses for ra.
// R15: SP, full-descending, 4-byte aligned.
//
//===----------------------------------------------------------------------===//

def CC_Particle : CallingConv<[
  CCIfType<[i1, i8, i16], CCPromoteToType<i32>>,
  // i64 arrives as two i32 halves; keep a split value together.
  CCIfType<[i32], CCAssignToReg<[R1, R2, R3, R4]>>,
  CCIfType<[i32], CCAssignToStack<4, 4>>
]>;

// Variadic arguments always go on the stack.
def CC_Particle_VarArg : CallingConv<[
  CCIfType<[i1, i8, i16], CCPromoteToType<i32>>,
  CCIfType<[i32], CCAssignToStack<4, 4>>
]>;

def RetCC_Particle : CallingConv<[
  CCIfType<[i1, i8, i16], CCPromoteToType<i32>>,
  CCIfType<[i32], CCAssignToReg<[R1, R2, R3, R4]>>
]>;

def CSR_Particle : CalleeSavedRegs<(add R14, (sequence "R%u", 5, 10))>;

// For interrupt handlers that do not use XCHGMOST: save everything but SP.
def CSR_Particle_Interrupt : CalleeSavedRegs<(add (sequence "R%u", 1, 14))>;

// For handlers entered via XCHGMOST: R1-R14 are already the shadow bank.
def CSR_Particle_Shadow : CalleeSavedRegs<(add)>;
