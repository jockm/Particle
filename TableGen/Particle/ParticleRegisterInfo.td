//===-- ParticleRegisterInfo.td - Particle register definitions -*- tablegen -*-===//
//
// 16 architectural 32-bit GPRs. R0 reads as zero (reserved in C++
// getReservedRegs, like RISC-V x0), R15 is SP.
//
// Not modelled for code generation:
//   * the shadow bank S0-S15 (XCHG / XCHGALL / XCHGMOST),
//   * the 32-entry physical file reached through RBASE.
// The compiler always runs with rbase = 0 and never touches the shadow
// bank; those instructions are available to the assembler / inline asm.
//
//===----------------------------------------------------------------------===//

let Namespace = "Particle" in {
  def ABIRegAltName : RegAltNameIndex;

  class ParticleReg<bits<4> enc, string n, string abi>
      : Register<n> {
    let HWEncoding{3-0} = enc;
    let AltNames = [abi];
    let RegAltNameIndices = [ABIRegAltName];
  }

  def R0  : ParticleReg<0,  "r0",  "zero">, DwarfRegNum<[0]>;
  def R1  : ParticleReg<1,  "r1",  "r1">,   DwarfRegNum<[1]>;
  def R2  : ParticleReg<2,  "r2",  "r2">,   DwarfRegNum<[2]>;
  def R3  : ParticleReg<3,  "r3",  "r3">,   DwarfRegNum<[3]>;
  def R4  : ParticleReg<4,  "r4",  "r4">,   DwarfRegNum<[4]>;
  def R5  : ParticleReg<5,  "r5",  "r5">,   DwarfRegNum<[5]>;
  def R6  : ParticleReg<6,  "r6",  "r6">,   DwarfRegNum<[6]>;
  def R7  : ParticleReg<7,  "r7",  "r7">,   DwarfRegNum<[7]>;
  def R8  : ParticleReg<8,  "r8",  "r8">,   DwarfRegNum<[8]>;
  def R9  : ParticleReg<9,  "r9",  "r9">,   DwarfRegNum<[9]>;
  def R10 : ParticleReg<10, "r10", "r10">,  DwarfRegNum<[10]>;
  def R11 : ParticleReg<11, "r11", "r11">,  DwarfRegNum<[11]>;
  def R12 : ParticleReg<12, "r12", "r12">,  DwarfRegNum<[12]>;
  def R13 : ParticleReg<13, "r13", "r13">,  DwarfRegNum<[13]>;
  def R14 : ParticleReg<14, "r14", "lr">,   DwarfRegNum<[14]>;
  def R15 : ParticleReg<15, "r15", "sp">,   DwarfRegNum<[15]>;
}

// Allocation order: caller-saved first (args R1-R4, scratch R11-R13), then
// callee-saved R5-R10, then R14 (link / imm accumulator). R15 and R0 are
// reserved in C++ but must be in the class so they can be encoded.
def GPR : RegisterClass<"Particle", [i32], 32, (add
    (sequence "R%u", 1, 4),
    (sequence "R%u", 11, 13),
    (sequence "R%u", 5, 10),
    R14, R15, R0)>;

// Single-register class for the instructions whose destination / source is
// implicitly R14 (LD R14,Imm8; PUSH8; SLT R14,Imm8; FBRA.Z R14,Imm8 ...).
// Using a class rather than Defs=[R14] lets ISel patterns produce values in
// R14; the register allocator inserts the copies.
def R14C : RegisterClass<"Particle", [i32], 32, (add R14)>;

