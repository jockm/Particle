//===-- ParticleInstrInfo.td - Particle instruction set ----*- tablegen -*-===//
//
// Conventions used below
//   * Two-address ALU ops (Rr <- Rr op Rl) are modelled with a tied input
//     "$rr_in" so the register allocator / TwoAddress pass handle them.
//   * "-Imm4" / "-Imm8" forms: the MC operand holds the real (negative)
//     value; C++ getNegImmOpValue / decodeNegImmOperand<N> convert to and
//     from the magnitude stored in the encoding. Assembly reads "ld r3, -5".
//   * Imm8 forms are written with an explicit R14C operand so assembly reads
//     "ld r14, 200" and the matcher rejects any other register. That operand
//     has no encoding bits, and LLVM 18's decoder generator drops such
//     operands, so these instructions use a whole-instruction C++ decoder,
//     decodeImplicitR14Insn (walks MCInstrDesc, adds R14 for R14C operands,
//     decodes Inst{7-0} for the immediate / branch operand).
//
//===----------------------------------------------------------------------===//

include "ParticleInstrFormats.td"

//===----------------------------------------------------------------------===//
// Tunables — see README.md, "Spec questions"
//===----------------------------------------------------------------------===//

// Trap vector used for llvm.trap (vectors 2-13 are software traps).
defvar LLVMTrapVector = 2;

//===----------------------------------------------------------------------===//
// Target-specific SelectionDAG nodes
//===----------------------------------------------------------------------===//

def SDT_PCallSeqStart : SDCallSeqStart<[SDTCisVT<0, i32>, SDTCisVT<1, i32>]>;
def SDT_PCallSeqEnd   : SDCallSeqEnd<[SDTCisVT<0, i32>, SDTCisVT<1, i32>]>;
def SDT_PCall         : SDTypeProfile<0, -1, [SDTCisVT<0, iPTR>]>;
def SDT_PWrapper      : SDTypeProfile<1, 1, [SDTCisSameAs<0, 1>,
                                             SDTCisPtrTy<0>]>;

def callseq_start : SDNode<"ISD::CALLSEQ_START", SDT_PCallSeqStart,
                           [SDNPHasChain, SDNPOutGlue]>;
def callseq_end   : SDNode<"ISD::CALLSEQ_END", SDT_PCallSeqEnd,
                           [SDNPHasChain, SDNPOptInGlue, SDNPOutGlue]>;

def ParticleCall    : SDNode<"ParticleISD::CALL", SDT_PCall,
                             [SDNPHasChain, SDNPOptInGlue, SDNPOutGlue,
                              SDNPVariadic]>;
def ParticleRetGlue : SDNode<"ParticleISD::RET_GLUE", SDTNone,
                             [SDNPHasChain, SDNPOptInGlue, SDNPVariadic]>;
// Wraps TargetGlobalAddress / ExternalSymbol / etc. so it can be matched.
def ParticleWrapper : SDNode<"ParticleISD::WRAPPER", SDT_PWrapper>;

//===----------------------------------------------------------------------===//
// Operands
//===----------------------------------------------------------------------===//

class ParticleImmAsmOperand<string name> : AsmOperandClass {
  let Name = name;
  let RenderMethod = "addImmOperands";
  let DiagnosticType = !strconcat("Invalid", name);
}

def UImm4AsmOperand  : ParticleImmAsmOperand<"UImm4">;
def UImm8AsmOperand  : ParticleImmAsmOperand<"UImm8">;
def NImm4AsmOperand  : ParticleImmAsmOperand<"NImm4">;   // -15 .. 0
def NImm8AsmOperand  : ParticleImmAsmOperand<"NImm8">;   // -255 .. 0
def BrTarget4AsmOperand : ParticleImmAsmOperand<"BrTarget4"> {
  let RenderMethod = "addExprOperands";
}
def BrTarget8AsmOperand : ParticleImmAsmOperand<"BrTarget8"> {
  let RenderMethod = "addExprOperands";
}

// Zero-extended immediates.
def uimm4 : Operand<i32>, ImmLeaf<i32, [{ return isUInt<4>(Imm); }]> {
  let ParserMatchClass = UImm4AsmOperand;
  let DecoderMethod = "decodeUImmOperand<4>";
}
def uimm8 : Operand<i32>, ImmLeaf<i32, [{ return isUInt<8>(Imm); }]> {
  let ParserMatchClass = UImm8AsmOperand;
  let DecoderMethod = "decodeUImmOperand<8>";
}

// Sign-extended 4/8-bit immediates (SADD/SSUB/SDIV/SMOD/SMULH/SSLT Imm forms).
def SImm4AsmOperand : ParticleImmAsmOperand<"SImm4">;
def SImm8AsmOperand : ParticleImmAsmOperand<"SImm8">;
def simm4 : Operand<i32>, ImmLeaf<i32, [{ return isInt<4>(Imm); }]> {
  let ParserMatchClass = SImm4AsmOperand;
  let DecoderMethod = "decodeSImmOperand<4>";
}
def simm8 : Operand<i32>, ImmLeaf<i32, [{ return isInt<8>(Imm); }]> {
  let ParserMatchClass = SImm8AsmOperand;
  let DecoderMethod = "decodeSImmOperand<8>";
}

// Negated immediates: operand value is -15..0 / -255..0.
def nimm4 : Operand<i32>, ImmLeaf<i32, [{ return Imm >= -15 && Imm < 0; }]> {
  let ParserMatchClass = NImm4AsmOperand;
  let EncoderMethod = "getNegImmOpValue";
  let DecoderMethod = "decodeNegImmOperand<4>";
}
def nimm8 : Operand<i32>, ImmLeaf<i32, [{ return Imm >= -255 && Imm < 0; }]> {
  let ParserMatchClass = NImm8AsmOperand;
  let EncoderMethod = "getNegImmOpValue";
  let DecoderMethod = "decodeNegImmOperand<8>";
}

// Pattern-only leaves (disjoint ranges so pattern priority is unambiguous).
def uimm4nz    : ImmLeaf<i32, [{ return Imm >= 1 && Imm <= 15; }]>;
def simm4nz    : ImmLeaf<i32, [{ return isInt<4>(Imm) && Imm != 0; }]>;
def simm8wide  : ImmLeaf<i32, [{ return isInt<8>(Imm) && !isInt<4>(Imm); }]>;
def uimm8hi    : ImmLeaf<i32, [{ return Imm >= 16 && Imm <= 255; }]>;
def nimm8lo    : ImmLeaf<i32, [{ return Imm >= -255 && Imm <= -16; }]>;

// Branch displacements: unsigned halfword counts; direction is in the opcode.
// getBranchTargetOpValue emits the fixup (fwd/back x 4/8-bit) from the opcode.
def brtarget4 : Operand<OtherVT> {
  let ParserMatchClass = BrTarget4AsmOperand;
  let EncoderMethod = "getBranchTargetOpValue";
  let PrintMethod = "printBranchOperand";
  let OperandType = "OPERAND_PCREL";
}
def brtarget8 : Operand<OtherVT> {
  let ParserMatchClass = BrTarget8AsmOperand;
  let EncoderMethod = "getBranchTargetOpValue";
  let PrintMethod = "printBranchOperand";
  let OperandType = "OPERAND_PCREL";
}

def call_symbol : Operand<iPTR>;

//===----------------------------------------------------------------------===//
// SDNodeXForms
//===----------------------------------------------------------------------===//

def NegImm : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant(-N->getSExtValue(), SDLoc(N), MVT::i32);
}]>;
def Byte0 : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant(N->getZExtValue() & 0xFF, SDLoc(N), MVT::i32);
}]>;
def Byte1 : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant((N->getZExtValue() >> 8) & 0xFF, SDLoc(N), MVT::i32);
}]>;
def Byte2 : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant((N->getZExtValue() >> 16) & 0xFF, SDLoc(N), MVT::i32);
}]>;
def Byte3 : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant((N->getZExtValue() >> 24) & 0xFF, SDLoc(N), MVT::i32);
}]>;
// Arithmetic shifts for the negative-prefix forms (result is -255..-1).
def SHi8 : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant(N->getSExtValue() >> 8, SDLoc(N), MVT::i32);
}]>;
def SHi16 : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant(N->getSExtValue() >> 16, SDLoc(N), MVT::i32);
}]>;
def BitIndex : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant(Log2_32((uint32_t)N->getZExtValue()),
                                   SDLoc(N), MVT::i32);
}]>;
def BitIndexInv : SDNodeXForm<imm, [{
  return CurDAG->getTargetConstant(Log2_32(~(uint32_t)N->getZExtValue()),
                                   SDLoc(N), MVT::i32);
}]>;
def to_tframeindex : SDNodeXForm<frameindex, [{
  return CurDAG->getTargetFrameIndex(N->getIndex(), N->getValueType(0));
}]>;

//===----------------------------------------------------------------------===//
// Instruction classes
//===----------------------------------------------------------------------===//

// Rr <- Rr op Rl
class ALU_rr<bits<8> op, string mn, SDPatternOperator node = null_frag,
             bit comm = 0>
    : FRR<op, (outs GPR:$rr), (ins GPR:$rr_in, GPR:$rl), mn # " $rr, $rl",
          [(set GPR:$rr, (node GPR:$rr_in, GPR:$rl))]> {
  let Constraints = "$rr = $rr_in";
  let isCommutable = comm;
}

// Rr <- Rr op Imm4
class ALU_ri<bits<8> op, string mn, SDPatternOperator node = null_frag,
             Operand immop = uimm4>
    : FRI4<op, (outs GPR:$rr), (ins GPR:$rr_in, immop:$imm),
           mn # " $rr, $imm",
           [(set GPR:$rr, (node GPR:$rr_in, immop:$imm))]> {
  let Constraints = "$rr = $rr_in";
}

// Rr <- op Rr
class ALU_r<bits<8> op, string mn, list<dag> pat = []>
    : FR<op, (outs GPR:$rr), (ins GPR:$rr_in), mn # " $rr", pat> {
  let Constraints = "$rr = $rr_in";
}

// R14 <- R14 op Imm8
class ALU_r14i<bits<8> op, string mn, Operand immop>
    : FI8<op, (outs R14C:$rd), (ins R14C:$rd_in, immop:$imm),
          mn # " $rd, $imm", []> {
  let Constraints = "$rd = $rd_in";
  let DecoderMethod = "decodeImplicitR14Insn";
}

//===----------------------------------------------------------------------===//
// 4.1 Loads & immediates (0x00 - 0x06)
//===----------------------------------------------------------------------===//

let isMoveReg = 1, isAsCheapAsAMove = 1 in
def LDrr : FRR<0x00, (outs GPR:$rr), (ins GPR:$rl), "ld $rr, $rl", []>;

let isReMaterializable = 1, isAsCheapAsAMove = 1 in {
def LDI4 : FRI4<0x01, (outs GPR:$rr), (ins uimm4:$imm), "ld $rr, $imm",
                [(set GPR:$rr, uimm4:$imm)]>;
let DecoderMethod = "decodeImplicitR14Insn" in
def LDI8 : FI8<0x02, (outs R14C:$rd), (ins uimm8:$imm), "ld $rd, $imm", []>;
def LDN4 : FRI4<0x03, (outs GPR:$rr), (ins nimm4:$imm), "ld $rr, $imm",
                [(set GPR:$rr, nimm4:$imm)]>;
let DecoderMethod = "decodeImplicitR14Insn" in
def LDN8 : FI8<0x04, (outs R14C:$rd), (ins nimm8:$imm), "ld $rd, $imm", []>;
}

def PUSH4 : FRI4<0x05, (outs GPR:$rr), (ins GPR:$rr_in, uimm4:$imm),
                 "push4 $rr, $imm", []> {
  let Constraints = "$rr = $rr_in";
}
def PUSH8 : ALU_r14i<0x06, "push8", uimm8>;

// LD R0, R0 (0x0000) is the canonical NOP.
def : InstAlias<"nop", (LDrr R0, R0)>;

//===----------------------------------------------------------------------===//
// 4.2 Memory loads & stores (0x10 - 0x39)
//
// Opcode map follows psim.py, which differs from the markdown spec:
//   +0 LD (Rl)    +1 LD (++Rl)   +2 LD (Rl++)   +3 LD (--Rl)   +4 LD (Rl--)
//   +5 ST (Rr)    +6 ST (++Rr)   +7 ST (Rr++)   +8 ST (--Rr)   +9 ST (Rr--)
// The pointer steps by the access size. There are no offset addressing modes;
// stack slots go through PseudoLDxFI / PseudoSTxFI (see eliminateFrameIndex).
// 16/32-bit accesses must be naturally aligned (misalignment traps).
//===----------------------------------------------------------------------===//

// Indexed load: Rr <- Mem[...], Rl updated. Rr and Rl must differ.
class IdxLoad<int op, string mn, string addr>
    : FRR<op, (outs GPR:$rr, GPR:$rl_wb), (ins GPR:$rl),
          mn # " $rr, " # addr, []> {
  let Constraints = "$rl = $rl_wb,@earlyclobber $rr";
  let mayLoad = 1;
}
// Indexed store: Mem[...] <- Rl, Rr updated. The hardware reads Rl after
// updating Rr, so Rl must not be the base register (earlyclobber on the wb).
class IdxStore<int op, string mn, string addr>
    : FRR<op, (outs GPR:$rr_wb), (ins GPR:$rr, GPR:$rl),
          mn # " " # addr # ", $rl", []> {
  let Constraints = "$rr = $rr_wb,@earlyclobber $rr_wb";
  let mayStore = 1;
}

multiclass MemOps<int base, string sz> {
  let mayLoad = 1 in
  def LD # sz : FRR<base, (outs GPR:$rr), (ins GPR:$rl),
                    "ld" # sz # " $rr, (${rl})", []>;
  def LD # sz # _PREINC  : IdxLoad<!add(base, 1), "ld" # sz, "(++${rl})">;
  def LD # sz # _POSTINC : IdxLoad<!add(base, 2), "ld" # sz, "(${rl}++)">;
  def LD # sz # _PREDEC  : IdxLoad<!add(base, 3), "ld" # sz, "(--${rl})">;
  def LD # sz # _POSTDEC : IdxLoad<!add(base, 4), "ld" # sz, "(${rl}--)">;

  let mayStore = 1 in
  def ST # sz : FRR<!add(base, 5), (outs), (ins GPR:$rr, GPR:$rl),
                    "st" # sz # " (${rr}), $rl", []>;
  def ST # sz # _PREINC  : IdxStore<!add(base, 6), "st" # sz, "(++${rr})">;
  def ST # sz # _POSTINC : IdxStore<!add(base, 7), "st" # sz, "(${rr}++)">;
  def ST # sz # _PREDEC  : IdxStore<!add(base, 8), "st" # sz, "(--${rr})">;
  def ST # sz # _POSTDEC : IdxStore<!add(base, 9), "st" # sz, "(${rr}--)">;

  // pasm.py also accepts stores spelled with the load mnemonic.
  def : InstAlias<"ld" # sz # " (${rr}), $rl",
                  (!cast<Instruction>("ST" # sz) GPR:$rr, GPR:$rl), 0>;

  // Frame-index access; expanded in eliminateFrameIndex.
  let mayLoad = 1 in
  def PseudoLD # sz # FI : Pseudo<(outs GPR:$rd), (ins i32imm:$fi), []>;
  let mayStore = 1 in
  def PseudoST # sz # FI : Pseudo<(outs), (ins GPR:$rs, i32imm:$fi), []>;
}

defm "" : MemOps<0x10, "8">;
defm "" : MemOps<0x20, "16">;
defm "" : MemOps<0x30, "32">;

//===----------------------------------------------------------------------===//
// 4.3 Arithmetic (0x40 - 0x57)
//===----------------------------------------------------------------------===//

def ADD   : ALU_rr<0x40, "add",  add,  1>;
def SUB   : ALU_rr<0x41, "sub",  sub>;
def DIV   : ALU_rr<0x42, "div",  udiv>;
def MOD   : ALU_rr<0x43, "mod",  urem>;
def ADDI  : ALU_ri<0x44, "add",  add>;
def SUBI  : ALU_ri<0x45, "sub",  sub>;
def DIVI  : ALU_ri<0x46, "div">;
def MODI  : ALU_ri<0x47, "mod">;
def NEG   : ALU_r<0x48, "neg", [(set GPR:$rr, (ineg GPR:$rr_in))]>;

// SADD/SSUB produce the same 32-bit result as ADD/SUB (no trap, per psim.py),
// so they get no patterns. Their Imm4 is sign-extended (-8..7).
def SADD  : ALU_rr<0x50, "sadd">;
def SSUB  : ALU_rr<0x51, "ssub">;
def SDIV  : ALU_rr<0x52, "sdiv", sdiv>;
def SMOD  : ALU_rr<0x53, "smod", srem>;
def SADDI : ALU_ri<0x54, "sadd", null_frag, simm4>;
def SSUBI : ALU_ri<0x55, "ssub", null_frag, simm4>;
def SDIVI : ALU_ri<0x56, "sdiv", null_frag, simm4>;
def SMODI : ALU_ri<0x57, "smod", null_frag, simm4>;

//===----------------------------------------------------------------------===//
// 4.4 Logic, shifts, sign-extension (0x60 - 0x73)
//===----------------------------------------------------------------------===//

def SHL    : ALU_rr<0x60, "shiftl",  shl>;
def SEXT8  : ALU_r<0x61, "sext8",  [(set GPR:$rr, (sext_inreg GPR:$rr_in, i8))]>;
def SHR    : ALU_rr<0x62, "shiftr",  srl>;
def ASHR   : ALU_rr<0x63, "ashiftr", sra>;
def ROTL   : ALU_rr<0x64, "rotl",    rotl>;
def ROTR   : ALU_rr<0x65, "rotr",    rotr>;
def AND    : ALU_rr<0x66, "and",     and, 1>;
def OR     : ALU_rr<0x67, "or",      or,  1>;
def XOR    : ALU_rr<0x68, "xor",     xor, 1>;
def SHLI   : ALU_ri<0x69, "shiftl",  shl>;
def SEXT16 : ALU_r<0x6A, "sext16", [(set GPR:$rr, (sext_inreg GPR:$rr_in, i16))]>;
def SHRI   : ALU_ri<0x6B, "shiftr",  srl>;
def ASHRI  : ALU_ri<0x6C, "ashiftr", sra>;
def ROTLI  : ALU_ri<0x6D, "rotl",    rotl>;
def ROTRI  : ALU_ri<0x6E, "rotr",    rotr>;
def ANDI   : ALU_ri<0x6F, "and",     and>;
def ORI    : ALU_ri<0x70, "or",      or>;
def XORI   : ALU_ri<0x71, "xor",     xor>;
def NOT    : ALU_r<0x72, "not", [(set GPR:$rr, (not GPR:$rr_in))]>;
def NEZ    : ALU_r<0x73, "nez", [(set GPR:$rr, (setne GPR:$rr_in, 0))]>;

//===----------------------------------------------------------------------===//
// 4.5 Multipliers (0x78 - 0x7F)
//===----------------------------------------------------------------------===//

def MULL    : ALU_rr<0x78, "mull",   mul,   1>;
def MULH    : ALU_rr<0x79, "mulh",   mulhu, 1>;
def SMULH   : ALU_rr<0x7A, "smulh",  mulhs, 1>;
def MULHSU  : ALU_rr<0x7B, "mulhsu">;          // no generic ISD node
def MULLI   : ALU_ri<0x7C, "mull",   mul>;
def MULHI   : ALU_ri<0x7D, "mulh",   mulhu>;
def SMULHI  : ALU_ri<0x7E, "smulh",  mulhs, simm4>;
def MULHSUI : ALU_ri<0x7F, "mulhsu">;

//===----------------------------------------------------------------------===//
// 4.6 Bit manipulation, system, byte swap (0x80 - 0x8C)
//===----------------------------------------------------------------------===//

// BEXTR: field extract. Rl[4:0] = position, Rl[9:5] = length;
// Rr <- (Rr >> pos) & ((1 << len) - 1). (The spec's one-bit description is
// out of date.) No pattern yet; a DAG combine for (and (srl x, c1), mask)
// could use it.
def BEXTR : ALU_rr<0x80, "bextr">;

let isBranch = 1, isIndirectBranch = 1, isTerminator = 1, isBarrier = 1 in
def JTBL : FRR<0x81, (outs), (ins GPR:$rr, GPR:$rl), "jtbl $rr, $rl", []>;

// Rr <- clz(Rl); clz(0) = 32 (psim.py).
def CLZ : FRR<0x82, (outs GPR:$rr), (ins GPR:$rl), "clz $rr, $rl",
              [(set GPR:$rr, (ctlz GPR:$rl))]>;

def BSET  : ALU_rr<0x83, "bset">;
def BSETI : ALU_ri<0x84, "bset">;
def BCLR  : ALU_rr<0x85, "bclr">;
def BCLRI : ALU_ri<0x86, "bclr">;
def BINV  : ALU_rr<0x87, "binv">;
def BINVI : ALU_ri<0x88, "binv">;
def BGET  : ALU_rr<0x89, "bget">;
def BGETI : ALU_ri<0x8A, "bget">;

// Atomic 32-bit swap: Mem32[Rr] <- Rl, Rl <- old Mem32[Rr] (psim.py).
let mayLoad = 1, mayStore = 1, hasSideEffects = 1 in
def TAS : FRR<0x8B, (outs GPR:$rl), (ins GPR:$rr, GPR:$rl_in),
              "tas (${rr}), $rl",
              [(set GPR:$rl, (atomic_swap_32 GPR:$rr, GPR:$rl_in))]> {
  let Constraints = "$rl = $rl_in";
}

def REV32 : ALU_r<0x8C, "rev32", [(set GPR:$rr, (bswap GPR:$rr_in))]>;

//===----------------------------------------------------------------------===//
// 4.7 Relational comparisons (0x90 - 0x9D) — results are 0 / 1
//===----------------------------------------------------------------------===//

def SLT    : ALU_rr<0x90, "slt">;
def SLTI   : ALU_ri<0x91, "slt",  setult, uimm4>;
def SLTNI  : ALU_ri<0x92, "slt",  setult, nimm4>;
def SLTI8  : ALU_r14i<0x93, "slt",  uimm8>;
def SLTNI8 : ALU_r14i<0x94, "slt",  nimm8>;
def SSLT   : ALU_rr<0x95, "sslt">;
def SSLTI  : ALU_ri<0x96, "sslt", setlt, simm4>;
def SSLTNI : ALU_ri<0x97, "sslt", setlt, nimm4>;
def SSLTI8 : ALU_r14i<0x98, "sslt", simm8>;
def SSLTNI8: ALU_r14i<0x99, "sslt", nimm8>;
def SEQ    : ALU_rr<0x9A, "seq",  seteq, 1>;
def SNE    : ALU_rr<0x9B, "sne",  setne, 1>;
def SLE    : ALU_rr<0x9C, "sle">;
def SSLE   : ALU_rr<0x9D, "ssle">;

//===----------------------------------------------------------------------===//
// 4.8 Control flow (0xA0 - 0xA4)
//===----------------------------------------------------------------------===//

// JMP Rr, Rl :  Rl <- PC + 2 ; PC <- Rr
// Rr is read before Rl is written (psim.py), so "jmp r14, r14" works; the
// direct-call sequence relies on it.
let hasSideEffects = 1 in {
def JMP   : FRR<0xA0, (outs GPR:$rl), (ins GPR:$rr), "jmp $rr, $rl", []>;
def RJUMP : FRR<0xA1, (outs GPR:$rl), (ins GPR:$rr), "rjump $rr, $rl", []>;
}
def : InstAlias<"rret", (JMP R0, R14), 1>;
def : InstAlias<"rcall $rr", (JMP R14, GPR:$rr), 1>;

// TRAP writes the return address (PC + 2) into R14.
let hasSideEffects = 1, isTrap = 1, Defs = [R14] in {
def TRAPR : FR<0xA2, (outs), (ins GPR:$rr), "trap $rr", []>;
def TRAPI : FI4<0xA3, (outs), (ins uimm4:$imm), "trap $imm", []>;
}

let isBranch = 1, isIndirectBranch = 1, isTerminator = 1, isBarrier = 1 in
def BRANCHR : FR<0xA4, (outs), (ins GPR:$rr), "branch $rr", []>;

//===----------------------------------------------------------------------===//
// 4.9 Relative branches (0xB0 - 0xCB)
// Real encodings. ISel emits the direction-agnostic Pseudo* branches below;
// a pre-emit pass picks FBRA/BBRA and the 4/8-bit form once layout is known.
// Displacements are relative to the address of the branch itself
// (target = PC_branch +/- disp*2), per psim.py. RJUMP and BRANCH likewise.
//===----------------------------------------------------------------------===//

let isBranch = 1, isTerminator = 1 in {
  let isBarrier = 1 in {
    def FBRA : FI8<0xB0, (outs), (ins brtarget8:$imm), "fbra $imm", []>;
    def BBRA : FI8<0xC0, (outs), (ins brtarget8:$imm), "bbra $imm", []>;
  }

  multiclass CondBranch<int op4, int op8, string mn> {
    def NAME : FRI4<op4, (outs), (ins GPR:$rr, brtarget4:$imm),
                    mn # " $rr, $imm", []>;
    def NAME # 8 : FI8<op8, (outs), (ins R14C:$rd, brtarget8:$imm),
                       mn # " $rd, $imm", []> {
      let DecoderMethod = "decodeImplicitR14Insn";
    }
  }
}

let isBranch = 1, isTerminator = 1 in {
defm FBRA_Z  : CondBranch<0xB4, 0xB7, "fbra.z">;
defm FBRA_N  : CondBranch<0xB5, 0xB8, "fbra.n">;
defm FBRA_P  : CondBranch<0xB6, 0xB9, "fbra.p">;
defm FBRA_NZ : CondBranch<0xBA, 0xBB, "fbra.nz">;
defm BBRA_Z  : CondBranch<0xC4, 0xC7, "bbra.z">;
defm BBRA_N  : CondBranch<0xC5, 0xC8, "bbra.n">;
defm BBRA_P  : CondBranch<0xC6, 0xC9, "bbra.p">;
defm BBRA_NZ : CondBranch<0xCA, 0xCB, "bbra.nz">;
}

// Register-displacement conditional branches (in psim.py, not in the spec):
// if cond(Rr): PC <- PC_branch +/- Rl*2
let isBranch = 1, isIndirectBranch = 1, isTerminator = 1 in {
def FBRA_Zr : FRR<0xB1, (outs), (ins GPR:$rr, GPR:$rl), "fbra.z $rr, $rl", []>;
def FBRA_Nr : FRR<0xB2, (outs), (ins GPR:$rr, GPR:$rl), "fbra.n $rr, $rl", []>;
def FBRA_Pr : FRR<0xB3, (outs), (ins GPR:$rr, GPR:$rl), "fbra.p $rr, $rl", []>;
def BBRA_Zr : FRR<0xC1, (outs), (ins GPR:$rr, GPR:$rl), "bbra.z $rr, $rl", []>;
def BBRA_Nr : FRR<0xC2, (outs), (ins GPR:$rr, GPR:$rl), "bbra.n $rr, $rl", []>;
def BBRA_Pr : FRR<0xC3, (outs), (ins GPR:$rr, GPR:$rl), "bbra.p $rr, $rl", []>;
}

//===----------------------------------------------------------------------===//
// 4.10 Context, windowing, FIFO interconnect (0xD0 - 0xE7)
// Not used by codegen; available to inline asm / the assembler.
//===----------------------------------------------------------------------===//

let hasSideEffects = 1 in {
def XCHG : FR<0xD0, (outs GPR:$rr), (ins GPR:$rr_in), "xchg $rr", []> {
  let Constraints = "$rr = $rr_in";
}
def XCHGALL  : FN<0xD1, (outs), (ins), "xchgall", []>;
def XCHGMOST : FN<0xD2, (outs), (ins), "xchgmost", []>;
def RBASEI   : FI8<0xD3, (outs), (ins uimm8:$imm), "rbase $imm", []>;
def RBASER   : FR<0xD4, (outs), (ins GPR:$rr), "rbase $rr", []>;

// FIFO opcode map follows psim.py (differs from the spec):
//   E0 fifo.r Rr, chan      blocking read (stalls while empty)
//   E1 fifo.w Rr, chan      write
//   E4 fifo.stat Rr, Rl     status, channel in Rl
//   E5 fifo.stat Rr, chan   status: [0]=empty [1]=full [15:8]=count
//   E6 fifo.tryr Rr, Rl     non-blocking read, channel in Rl; R14 <- 1 ok / 0
//   E7 fifo.tryw Rr, Rl     non-blocking write, channel in Rl; R14 <- 1 ok / 0
let mayLoad = 1, mayStore = 1 in {
def FIFO_R     : FRI4<0xE0, (outs GPR:$rr), (ins uimm4:$imm), "fifo.r $rr, $imm", []>;
def FIFO_W     : FRI4<0xE1, (outs), (ins GPR:$rr, uimm4:$imm), "fifo.w $rr, $imm", []>;
def FIFO_STATr : FRR<0xE4, (outs GPR:$rr), (ins GPR:$rl), "fifo.stat $rr, $rl", []>;
def FIFO_STAT  : FRI4<0xE5, (outs GPR:$rr), (ins uimm4:$imm), "fifo.stat $rr, $imm", []>;
let Defs = [R14] in {
def FIFO_TRYR  : FRR<0xE6, (outs GPR:$rr), (ins GPR:$rl), "fifo.tryr $rr, $rl", []>;
def FIFO_TRYW  : FRR<0xE7, (outs), (ins GPR:$rr, GPR:$rl), "fifo.tryw $rr, $rl", []>;
}
}
}

//===----------------------------------------------------------------------===//
// Pseudo instructions
//===----------------------------------------------------------------------===//

let Defs = [R15], Uses = [R15], hasSideEffects = 1 in {
def ADJCALLSTACKDOWN : Pseudo<(outs), (ins i32imm:$amt1, i32imm:$amt2),
                              [(callseq_start timm:$amt1, timm:$amt2)]>;
def ADJCALLSTACKUP   : Pseudo<(outs), (ins i32imm:$amt1, i32imm:$amt2),
                              [(callseq_end timm:$amt1, timm:$amt2)]>;
}

// Address of a symbol in R14:
//   ld r14, b3(sym) ; push8 r14, b2(sym) ; push8 r14, b1(sym) ; push8 r14, b0(sym)
// Expanded in MCInstLower / AsmPrinter with four byte-select fixups.
let isReMaterializable = 1, Size = 8 in
def PseudoLA : Pseudo<(outs R14C:$rd), (ins i32imm:$addr), []>;

// Frame address: replaced in eliminateFrameIndex (ld rd, sp ; add rd, off ...)
def PseudoFRAMEADDR : Pseudo<(outs GPR:$rd), (ins i32imm:$fi), []>;

// Calls. Direct: PseudoLA-style sequence into r14, then "jmp r14, r14".
let isCall = 1, Defs = [R14], Uses = [R15] in {
  let Size = 10 in
  def PseudoCALL : Pseudo<(outs), (ins call_symbol:$func), []>;
  def PseudoCALLIndirect : Pseudo<(outs), (ins GPR:$rr),
                                  [(ParticleCall GPR:$rr)]>,
                           PseudoInstExpansion<(JMP R14, GPR:$rr)>;
}

let isReturn = 1, isTerminator = 1, isBarrier = 1, Uses = [R14] in
def PseudoRET : Pseudo<(outs), (ins), [(ParticleRetGlue)]>,
                PseudoInstExpansion<(JMP R0, R14)>;

let isBranch = 1, isIndirectBranch = 1, isTerminator = 1, isBarrier = 1 in
def PseudoBRIND : Pseudo<(outs), (ins GPR:$rr), [(brind GPR:$rr)]>,
                  PseudoInstExpansion<(JMP R0, GPR:$rr)>;

// Direction-agnostic branches (see 4.9). Size 2 is the optimistic size;
// getInstSizeInBytes / branch relaxation take care of long forms.
let isBranch = 1, isTerminator = 1 in {
  let isBarrier = 1 in
  def PseudoBR  : Pseudo<(outs), (ins brtarget8:$dst), [(br bb:$dst)]>;
  def PseudoBRZ  : Pseudo<(outs), (ins GPR:$rr, brtarget8:$dst), []>;
  def PseudoBRNZ : Pseudo<(outs), (ins GPR:$rr, brtarget8:$dst), []>;
  def PseudoBRN  : Pseudo<(outs), (ins GPR:$rr, brtarget8:$dst), []>;
  def PseudoBRP  : Pseudo<(outs), (ins GPR:$rr, brtarget8:$dst), []>;
}

//===----------------------------------------------------------------------===//
// Selection patterns
//===----------------------------------------------------------------------===//

// ---- Constants -----------------------------------------------------------
// 1 insn : 0..15 (LDI4), -15..-1 (LDN4)                    [in instr defs]
// 1 insn : 16..255 / -255..-16 via R14
def : Pat<(i32 uimm8hi:$i), (LDI8 uimm8hi:$i)>;
def : Pat<(i32 nimm8lo:$i), (LDN8 nimm8lo:$i)>;

// 2 insns
def imm16u : ImmLeaf<i32, [{ return Imm > 255 && Imm <= 0xFFFF; }]>;
def imm16n : ImmLeaf<i32, [{ return Imm >= -65280 && Imm < -255; }]>;
def : Pat<(i32 imm16u:$i), (PUSH8 (LDI8 (Byte1 imm:$i)), (Byte0 imm:$i))>;
def : Pat<(i32 imm16n:$i), (PUSH8 (LDN8 (SHi8 imm:$i)), (Byte0 imm:$i))>;

// 3 insns
def imm24u : ImmLeaf<i32, [{ return Imm > 0xFFFF && Imm <= 0xFFFFFF; }]>;
def imm24n : ImmLeaf<i32, [{ return Imm >= -16711680 && Imm < -65280; }]>;
def : Pat<(i32 imm24u:$i),
          (PUSH8 (PUSH8 (LDI8 (Byte2 imm:$i)), (Byte1 imm:$i)), (Byte0 imm:$i))>;
def : Pat<(i32 imm24n:$i),
          (PUSH8 (PUSH8 (LDN8 (SHi16 imm:$i)), (Byte1 imm:$i)), (Byte0 imm:$i))>;

// 4 insns: everything else
def immOther : ImmLeaf<i32, [{
  return !(Imm >= -16711680 && Imm <= 0xFFFFFF);
}]>;
def : Pat<(i32 immOther:$i),
          (PUSH8 (PUSH8 (PUSH8 (LDI8 (Byte3 imm:$i)), (Byte2 imm:$i)),
                        (Byte1 imm:$i)), (Byte0 imm:$i))>;

// Symbols
def : Pat<(ParticleWrapper tglobaladdr:$a),   (PseudoLA tglobaladdr:$a)>;
def : Pat<(ParticleWrapper texternalsym:$a),  (PseudoLA texternalsym:$a)>;
def : Pat<(ParticleWrapper tblockaddress:$a), (PseudoLA tblockaddress:$a)>;
def : Pat<(ParticleWrapper tjumptable:$a),    (PseudoLA tjumptable:$a)>;
def : Pat<(ParticleWrapper tconstpool:$a),    (PseudoLA tconstpool:$a)>;

// Frame indices
def : Pat<(i32 frameindex:$fi), (PseudoFRAMEADDR (to_tframeindex $fi))>;

// ---- Arithmetic with immediates -----------------------------------------
def : Pat<(add GPR:$a, nimm4:$i),   (SUBI GPR:$a, (NegImm imm:$i))>;
def : Pat<(udiv GPR:$a, uimm4nz:$i), (DIVI GPR:$a, uimm4nz:$i)>;
def : Pat<(urem GPR:$a, uimm4nz:$i), (MODI GPR:$a, uimm4nz:$i)>;
def : Pat<(sdiv GPR:$a, simm4nz:$i), (SDIVI GPR:$a, simm4nz:$i)>;
def : Pat<(srem GPR:$a, simm4nz:$i), (SMODI GPR:$a, simm4nz:$i)>;

// ---- Bit manipulation ----------------------------------------------------
def : Pat<(or  GPR:$a, (shl 1, GPR:$b)),       (BSET GPR:$a, GPR:$b)>;
def : Pat<(and GPR:$a, (not (shl 1, GPR:$b))), (BCLR GPR:$a, GPR:$b)>;
def : Pat<(xor GPR:$a, (shl 1, GPR:$b)),       (BINV GPR:$a, GPR:$b)>;
def : Pat<(and (srl GPR:$a, GPR:$b), 1),       (BGET GPR:$a, GPR:$b)>;
def : Pat<(and (srl GPR:$a, uimm4:$i), 1),     (BGETI GPR:$a, uimm4:$i)>;

// Single-bit masks for bits 4..15 (bits 0..3 are covered by ORI/XORI).
def bitmask16 : ImmLeaf<i32, [{
  uint32_t V = (uint32_t)Imm;
  return isPowerOf2_32(V) && V >= 16 && V <= 0x8000;
}]>;
def notbitmask16 : ImmLeaf<i32, [{
  uint32_t V = ~(uint32_t)Imm;
  return isPowerOf2_32(V) && V <= 0x8000;
}]>;
def : Pat<(or  GPR:$a, bitmask16:$m),    (BSETI GPR:$a, (BitIndex imm:$m))>;
def : Pat<(xor GPR:$a, bitmask16:$m),    (BINVI GPR:$a, (BitIndex imm:$m))>;
def : Pat<(and GPR:$a, notbitmask16:$m), (BCLRI GPR:$a, (BitIndexInv imm:$m))>;

// ---- Comparisons ---------------------------------------------------------
// The ops are two-address (Rr <- Rr cmp Rl); ">" forms swap operands.
def : Pat<(setult GPR:$a, GPR:$b), (SLT  GPR:$a, GPR:$b)>;
def : Pat<(setugt GPR:$a, GPR:$b), (SLT  GPR:$b, GPR:$a)>;
def : Pat<(setule GPR:$a, GPR:$b), (SLE  GPR:$a, GPR:$b)>;
def : Pat<(setuge GPR:$a, GPR:$b), (SLE  GPR:$b, GPR:$a)>;
def : Pat<(setlt  GPR:$a, GPR:$b), (SSLT GPR:$a, GPR:$b)>;
def : Pat<(setgt  GPR:$a, GPR:$b), (SSLT GPR:$b, GPR:$a)>;
def : Pat<(setle  GPR:$a, GPR:$b), (SSLE GPR:$a, GPR:$b)>;
def : Pat<(setge  GPR:$a, GPR:$b), (SSLE GPR:$b, GPR:$a)>;

let AddedComplexity = 10 in
def : Pat<(seteq GPR:$a, 0), (SEQ GPR:$a, (i32 R0))>;

// R14 imm8 compare forms (16..255 and -255..-16)
def : Pat<(setult GPR:$a, uimm8hi:$i), (SLTI8   GPR:$a, uimm8hi:$i)>;
def : Pat<(setult GPR:$a, nimm8lo:$i), (SLTNI8  GPR:$a, nimm8lo:$i)>;
def : Pat<(setlt  GPR:$a, simm8wide:$i), (SSLTI8 GPR:$a, simm8wide:$i)>;
def : Pat<(setlt  GPR:$a, nimm8lo:$i), (SSLTNI8 GPR:$a, nimm8lo:$i)>;

// ---- Select (branchless; cond is 0/1 under ZeroOrOneBooleanContent) -------
//   f ^ ((t ^ f) & -c)
def : Pat<(select GPR:$c, GPR:$t, GPR:$f),
          (XOR (AND (XOR GPR:$t, GPR:$f), (NEG GPR:$c)), GPR:$f)>;

// ---- Branches ------------------------------------------------------------
def : Pat<(brcond (i32 (seteq GPR:$a, 0)), bb:$t), (PseudoBRZ  GPR:$a, bb:$t)>;
def : Pat<(brcond (i32 (setne GPR:$a, 0)), bb:$t), (PseudoBRNZ GPR:$a, bb:$t)>;
def : Pat<(brcond (i32 (setlt GPR:$a, 0)), bb:$t), (PseudoBRN  GPR:$a, bb:$t)>;
def : Pat<(brcond (i32 (setgt GPR:$a, 0)), bb:$t), (PseudoBRP  GPR:$a, bb:$t)>;
def : Pat<(brcond GPR:$c, bb:$t),                  (PseudoBRNZ GPR:$c, bb:$t)>;

// ---- Calls ---------------------------------------------------------------
def : Pat<(ParticleCall tglobaladdr:$f),  (PseudoCALL tglobaladdr:$f)>;
def : Pat<(ParticleCall texternalsym:$f), (PseudoCALL texternalsym:$f)>;

// ---- Loads / stores ------------------------------------------------------
multiclass LdPat<PatFrag ld, Instruction Inst, Instruction InstSP> {
  def : Pat<(i32 (ld GPR:$a)), (Inst GPR:$a)>;
  let AddedComplexity = 10 in
  def : Pat<(i32 (ld frameindex:$fi)), (InstSP (to_tframeindex $fi))>;
}
multiclass StPat<PatFrag st, Instruction Inst, Instruction InstSP> {
  def : Pat<(st GPR:$v, GPR:$a), (Inst GPR:$a, GPR:$v)>;
  let AddedComplexity = 10 in
  def : Pat<(st GPR:$v, frameindex:$fi), (InstSP GPR:$v, (to_tframeindex $fi))>;
  let AddedComplexity = 5 in
  def : Pat<(st (i32 0), GPR:$a), (Inst GPR:$a, (i32 R0))>;
}

defm : LdPat<zextloadi8, LD8, PseudoLD8FI>;
defm : LdPat<extloadi8, LD8, PseudoLD8FI>;
defm : LdPat<zextloadi16, LD16, PseudoLD16FI>;
defm : LdPat<extloadi16, LD16, PseudoLD16FI>;
defm : LdPat<load, LD32, PseudoLD32FI>;
def : Pat<(i32 (sextloadi8  GPR:$a)), (SEXT8  (LD8  GPR:$a))>;
def : Pat<(i32 (sextloadi16 GPR:$a)), (SEXT16 (LD16 GPR:$a))>;
def : Pat<(i32 (sextloadi8  frameindex:$fi)), (SEXT8  (PseudoLD8FI (to_tframeindex $fi)))>;
def : Pat<(i32 (sextloadi16 frameindex:$fi)), (SEXT16 (PseudoLD16FI (to_tframeindex $fi)))>;

defm : StPat<truncstorei8, ST8, PseudoST8FI>;
defm : StPat<truncstorei16, ST16, PseudoST16FI>;
defm : StPat<store, ST32, PseudoST32FI>;

// Indexed stores (enable with setIndexedStoreAction in C++).
multiclass IdxStPat<PatFrag post, PatFrag pre, string sz, int n> {
  def : Pat<(post GPR:$v, GPR:$a, n),
            (!cast<Instruction>("ST" # sz # "_POSTINC") GPR:$a, GPR:$v)>;
  def : Pat<(post GPR:$v, GPR:$a, !sub(0, n)),
            (!cast<Instruction>("ST" # sz # "_POSTDEC") GPR:$a, GPR:$v)>;
  def : Pat<(pre GPR:$v, GPR:$a, n),
            (!cast<Instruction>("ST" # sz # "_PREINC") GPR:$a, GPR:$v)>;
  def : Pat<(pre GPR:$v, GPR:$a, !sub(0, n)),
            (!cast<Instruction>("ST" # sz # "_PREDEC") GPR:$a, GPR:$v)>;
}
defm : IdxStPat<post_truncsti8,  pre_truncsti8,  "8",  1>;
defm : IdxStPat<post_truncsti16, pre_truncsti16, "16", 2>;
defm : IdxStPat<post_store,      pre_store,      "32", 4>;
// Indexed *loads* have no generic PatFrag; select them in C++ (Select()).

// ---- Misc ----------------------------------------------------------------
def : Pat<(trap), (TRAPI LLVMTrapVector)>;
