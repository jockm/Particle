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

# The build stamp (BUILD_STAMP in the guest, if it uses it): UTC date and
# time, the git short hash, and "-dirty" when there are uncommitted changes
STAMP_TIME="$(date -u '+%Y-%m-%d %H:%MZ')"
if STAMP_HASH="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)"; then
  git -C "$SCRIPT_DIR" diff --quiet HEAD -- 2>/dev/null || STAMP_HASH="$STAMP_HASH-dirty"
else
  STAMP_HASH="no-git"
fi
BUILD_STAMP="$STAMP_TIME $STAMP_HASH"
ELF="${OUT%.bin}.elf"
"$RV_CC" "${RV_CFLAGS[@]}" -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
  -ffreestanding -DBUILD_STAMP="\"$BUILD_STAMP\"" -T "$SCRIPT_DIR/link.ld" "$SRC" -o "$ELF"
"$RV_OBJCOPY" -O binary --only-section=.text --only-section=.data "$ELF" "$OUT"
echo "==> Guest program: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes from 0x500, built with $RV_KIND)"
echo "==> Build stamp: $BUILD_STAMP"
