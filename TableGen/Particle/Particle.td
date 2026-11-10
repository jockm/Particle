//===-- Particle.td - Describe the Particle target ---------*- tablegen -*-===//
//
// Top-level TableGen file for the Particle 32-bit / 16-bit-instruction RISC.
//
//===----------------------------------------------------------------------===//

include "llvm/Target/Target.td"

include "ParticleRegisterInfo.td"
include "ParticleCallingConv.td"
include "ParticleInstrInfo.td"

def ParticleInstrInfo : InstrInfo {
  let guessInstructionProperties = 0;
}

def ParticleAsmParser : AsmParser {
  // Accept "sp", "lr", "zero" as register names.
  let ShouldEmitMatchRegisterAltName = 1;
}

def ParticleAsmWriter : AsmWriter;

//===----------------------------------------------------------------------===//
// Processors
//===----------------------------------------------------------------------===//

// Single-issue in-order core; no scheduling model yet.
def : ProcessorModel<"generic", NoSchedModel, []>;
def : ProcessorModel<"ulx3s",   NoSchedModel, []>;

def Particle : Target {
  let InstructionSet    = ParticleInstrInfo;
  let AssemblyParsers   = [ParticleAsmParser];
  let AssemblyWriters   = [ParticleAsmWriter];
  let AllowRegisterRenaming = 1;
}
