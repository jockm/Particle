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

if command -v riscv64-elf-gcc >/dev/null 2>&1; then
  PREFIX="riscv64-elf-"
elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
  PREFIX="riscv64-unknown-elf-"
elif command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
  PREFIX="riscv32-unknown-elf-"
elif command -v riscv-none-elf-gcc >/dev/null 2>&1; then
  PREFIX="riscv-none-elf-"
else
  echo "Error: RISC-V GCC toolchain not found (expected riscv64-elf-gcc, riscv64-unknown-elf-gcc or riscv-none-elf-gcc)." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
ELF="${OUT%.bin}.elf"
"${PREFIX}gcc" -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
  -ffreestanding -T "$SCRIPT_DIR/link.ld" -Wl,--no-warn-rwx-segments \
  "$SRC" -o "$ELF"
"${PREFIX}objcopy" -O binary --only-section=.text --only-section=.data "$ELF" "$OUT"
echo "==> Guest program: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes from 0x500)"
