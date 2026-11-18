#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RISCV_TESTS_DIR="${RISCV_TESTS_DIR:-$REPO_ROOT/third_party/riscv-tests}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/parcore/riscv_tests}"

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

CC="${PREFIX}gcc"
OBJCOPY="${PREFIX}objcopy"

if [ ! -d "$RISCV_TESTS_DIR/isa" ]; then
  echo "Error: $RISCV_TESTS_DIR/isa not found." >&2
  echo "Run: git submodule update --init third_party/riscv-tests" >&2
  exit 1
fi

SUITES=("rv32ui" "rv32um" "rv32uzbb")
CFLAGS=(
  -march=rv32im_zbb_zicsr_zifencei
  -mabi=ilp32
  -nostdlib
  -nostartfiles
  -ffreestanding
  -I"$SCRIPT_DIR"
  -I"$RISCV_TESTS_DIR/isa/macros/scalar"
  -Wl,--no-warn-rwx-segments -Wl,--no-check-sections -T"$SCRIPT_DIR/link.ld"
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
    text_bin="$OUT_DIR/$suite/$name.text.bin"
    data_bin="$OUT_DIR/$suite/$name.data.bin"

    "$CC" "${CFLAGS[@]}" "$src" -o "$elf"
    "$OBJCOPY" -O binary --only-section=.text "$elf" "$text_bin"
    "$OBJCOPY" -O binary --only-section=.data "$elf" "$data_bin"
    total=$((total + 1))
  done
done

echo "Built $total official RISC-V ISA test binaries in $OUT_DIR"
