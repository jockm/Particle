# llvm/lib/Target/Particle/CMakeLists.txt  (TableGen part)
#
# Also needed outside this directory:
#   * add "Particle" to LLVM_EXPERIMENTAL_TARGETS_TO_BUILD at configure time
#   * add `particle` to Triple::ArchType (llvm/include/llvm/TargetParser/Triple.h
#     and llvm/lib/TargetParser/Triple.cpp)

add_llvm_component_group(Particle)

set(LLVM_TARGET_DEFINITIONS Particle.td)

tablegen(LLVM ParticleGenAsmMatcher.inc        -gen-asm-matcher)
tablegen(LLVM ParticleGenAsmWriter.inc         -gen-asm-writer)
tablegen(LLVM ParticleGenCallingConv.inc       -gen-callingconv)
tablegen(LLVM ParticleGenDAGISel.inc           -gen-dag-isel)
tablegen(LLVM ParticleGenDisassemblerTables.inc -gen-disassembler)
tablegen(LLVM ParticleGenInstrInfo.inc         -gen-instr-info)
tablegen(LLVM ParticleGenMCCodeEmitter.inc     -gen-emitter)
tablegen(LLVM ParticleGenMCPseudoLowering.inc  -gen-pseudo-lowering)
tablegen(LLVM ParticleGenRegisterInfo.inc      -gen-register-info)
tablegen(LLVM ParticleGenSubtargetInfo.inc     -gen-subtarget)

add_public_tablegen_target(ParticleCommonTableGen)

# add_llvm_target(ParticleCodeGen ...C++ sources... ) goes here once the
# C++ side exists; see README.md for the list of classes and hooks.
