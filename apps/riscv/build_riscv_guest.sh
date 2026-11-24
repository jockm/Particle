#!/usr/bin/env bash
# =============================================================================
# File: apps/riscv/build_riscv_guest.sh
# Description: Builds a Parcore guest program (RV32) into a flat binary from
#              0x500 (.text, then .data), as the conductor's image expects.
# Usage: build_riscv_guest.sh <source.S> <output.bin>
# =============================================================================
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <source.S> <output.bin>" >&2
  exit 2
fi
SRC="$1"
OUT="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A RISC-V GCC or LLVM (RISCV_TOOLCHAIN=gcc or llvm to choose)
. "$SCRIPT_DIR/riscv_toolchain.sh"

mkdir -p "$(dirname "$OUT")"
ELF="${OUT%.bin}.elf"
"$RV_CC" "${RV_CFLAGS[@]}" -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
  -ffreestanding -T "$SCRIPT_DIR/link.ld" "$SRC" -o "$ELF"
"$RV_OBJCOPY" -O binary --only-section=.text --only-section=.data "$ELF" "$OUT"
echo "==> Guest program: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes from 0x500, built with $RV_KIND)"
