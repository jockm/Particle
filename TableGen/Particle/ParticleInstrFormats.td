//===-- ParticleInstrFormats.td - Particle instruction formats -*- tablegen -*-===//
//
// Every instruction is 16 bits:  [15:8] opcode | [7:4] Rr | [3:0] Rl/Imm4
// Imm8 forms use [7:0] for the immediate and have an implicit R14 operand.
//
//===----------------------------------------------------------------------===//

class ParticleInst<dag outs, dag ins, string asmstr, list<dag> pattern>
    : Instruction {
  field bits<16> Inst;
  field bits<16> SoftFail = 0;

  let Namespace = "Particle";
  let DecoderNamespace = "Particle";
  let Size = 2;

  let OutOperandList = outs;
  let InOperandList  = ins;
  let AsmString      = asmstr;
  let Pattern        = pattern;

  // guessInstructionProperties = 0, so set conservative defaults here and
  // override per instruction.
  let hasSideEffects = 0;
  let mayLoad        = 0;
  let mayStore       = 0;
}

// [15:8] op | [7:4] rr | [3:0] rl
class FRR<bits<8> op, dag outs, dag ins, string asmstr, list<dag> pat>
    : ParticleInst<outs, ins, asmstr, pat> {
  bits<4> rr;
  bits<4> rl;
  let Inst{15-8} = op;
  let Inst{7-4}  = rr;
  let Inst{3-0}  = rl;
}

// [15:8] op | [7:4] rr | [3:0] imm4
class FRI4<bits<8> op, dag outs, dag ins, string asmstr, list<dag> pat>
    : ParticleInst<outs, ins, asmstr, pat> {
  bits<4> rr;
  bits<4> imm;
  let Inst{15-8} = op;
  let Inst{7-4}  = rr;
  let Inst{3-0}  = imm;
}

// [15:8] op | [7:4] rr | [3:0] 0000      (unary register ops)
class FR<bits<8> op, dag outs, dag ins, string asmstr, list<dag> pat>
    : ParticleInst<outs, ins, asmstr, pat> {
  bits<4> rr;
  let Inst{15-8} = op;
  let Inst{7-4}  = rr;
  let Inst{3-0}  = 0;
}

// [15:8] op | [7:4] 0000 | [3:0] imm4    (TRAP Imm4)
class FI4<bits<8> op, dag outs, dag ins, string asmstr, list<dag> pat>
    : ParticleInst<outs, ins, asmstr, pat> {
  bits<4> imm;
  let Inst{15-8} = op;
  let Inst{7-4}  = 0;
  let Inst{3-0}  = imm;
}

// [15:8] op | [7:0] imm8                 (implicit R14, FBRA/BBRA Imm8, RBASE Imm8)
class FI8<bits<8> op, dag outs, dag ins, string asmstr, list<dag> pat>
    : ParticleInst<outs, ins, asmstr, pat> {
  bits<8> imm;
  let Inst{15-8} = op;
  let Inst{7-0}  = imm;
}

// [15:8] op | [7:0] 0                    (XCHGALL, XCHGMOST)
class FN<bits<8> op, dag outs, dag ins, string asmstr, list<dag> pat>
    : ParticleInst<outs, ins, asmstr, pat> {
  let Inst{15-8} = op;
  let Inst{7-0}  = 0;
}

// Codegen-only pseudo. Expanded in C++ (or via PseudoInstExpansion).
class Pseudo<dag outs, dag ins, list<dag> pattern, string asmstr = "">
    : ParticleInst<outs, ins, asmstr, pattern> {
  let isPseudo = 1;
  let isCodeGenOnly = 1;
}
