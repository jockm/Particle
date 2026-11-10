#!/usr/bin/env bash
# Run every TableGen backend the Particle backend needs.
# Usage: ./check.sh [path-to-llvm/include] [llvm-tblgen]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INC="${1:-/usr/include}"
TBLGEN="${2:-llvm-tblgen}"
OUT="$HERE/gen"
mkdir -p "$OUT"

run() {
  local flag="$1" out="$2"
  printf '%-28s' "$flag"
  "$TBLGEN" "$flag" -I "$INC" -I "$HERE" "$HERE/Particle.td" -o "$OUT/$out"
  echo "ok -> gen/$out"
}

run -gen-register-info      ParticleGenRegisterInfo.inc
run -gen-instr-info         ParticleGenInstrInfo.inc
run -gen-emitter            ParticleGenMCCodeEmitter.inc
run -gen-asm-writer         ParticleGenAsmWriter.inc
run -gen-asm-matcher        ParticleGenAsmMatcher.inc
run -gen-disassembler       ParticleGenDisassemblerTables.inc
run -gen-dag-isel           ParticleGenDAGISel.inc
run -gen-callingconv        ParticleGenCallingConv.inc
run -gen-subtarget          ParticleGenSubtargetInfo.inc
run -gen-pseudo-lowering    ParticleGenMCPseudoLowering.inc
