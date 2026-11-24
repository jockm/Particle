#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RISCV_TESTS_DIR="${RISCV_TESTS_DIR:-$REPO_ROOT/third_party/riscv-tests}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/parcore/riscv_tests}"

# A RISC-V GCC or LLVM (RISCV_TOOLCHAIN=gcc or llvm to choose)
. "$REPO_ROOT/apps/riscv/riscv_toolchain.sh"
CC="$RV_CC"
OBJCOPY="$RV_OBJCOPY"

if [ ! -d "$RISCV_TESTS_DIR/isa" ]; then
  echo "Error: $RISCV_TESTS_DIR/isa not found." >&2
  echo "Run: git submodule update --init third_party/riscv-tests" >&2
  exit 1
fi

SUITES=("rv32ui" "rv32um" "rv32uzbb")
CFLAGS=(
  "${RV_CFLAGS[@]}"
  -march=rv32im_zbb_zicsr_zifencei
  -mabi=ilp32
  -nostdlib
  -nostartfiles
  -ffreestanding
  -I"$SCRIPT_DIR"
  -I"$RISCV_TESTS_DIR/isa/macros/scalar"
  -Wl,--no-check-sections -T"$SCRIPT_DIR/link.ld"
)

# Skip ma_data (requires trap handler to emulate misaligned load/store in M-mode software)
SKIP_TESTS=("ma_data")

total=0
for suite in "${SUITES[@]}"; do
  mkdir -p "$OUT_DIR/$suite"
  for src in "$RISCV_TESTS_DIR/isa/$suite"/*.S; do
    name="$(basename "$src" .S)"
    skip=0
    for s in "${SKIP_TESTS[@]}"; do
      if [ "$name" = "$s" ]; then
        skip=1
        break
      fi
    done
    if [ "$skip" -eq 1 ]; then
      continue
    fi

    elf="$OUT_DIR/$suite/$name.elf"
    image_bin="$OUT_DIR/$suite/$name.image.bin"

    # One image from 0x500: .text, then .data (see link.ld)
    if [ "$RV_KIND" = llvm ]; then
      # LLVM's assembler rejects the 64-bit constants some RV32 tests load
      # with li (they come from the shared rv64 sources); GNU as keeps their
      # low 32 bits. Do the same: preprocess, then keep the last 8 hex digits
      # of any longer constant.
      pre="$OUT_DIR/$suite/$name.s"
      "$CC" "${CFLAGS[@]}" -E "$src" -o "$pre"
      perl -pi -e 's/\b0x([0-9a-fA-F]{9,16})\b/"0x".substr($1,-8)/ge' "$pre"
      "$CC" "${CFLAGS[@]}" -x assembler "$pre" -o "$elf"
      rm -f "$pre"
    else
      "$CC" "${CFLAGS[@]}" "$src" -o "$elf"
    fi
    "$OBJCOPY" -O binary --only-section=.text --only-section=.data "$elf" "$image_bin"
    rm -f "$OUT_DIR/$suite/$name.text.bin" "$OUT_DIR/$suite/$name.data.bin"
    total=$((total + 1))
  done
done

echo "Built $total official RISC-V ISA test binaries in $OUT_DIR (with $RV_KIND)"
