# =============================================================================
# File: apps/riscv/riscv_toolchain.sh
# Description: Finds a RISC-V toolchain for the Parcore guest builds. Sourced
#              by apps/riscv/build_riscv_guest.sh and
#              hdl/parcore/test/riscv_tests/build_riscv_tests.sh.
# =============================================================================
#
# Sets:
#   RV_KIND     gcc or llvm
#   RV_CC       the compiler driver
#   RV_OBJCOPY  objcopy
#   RV_CFLAGS   an array: the target, and the linker flags for that toolchain
#
# RISCV_TOOLCHAIN=gcc or llvm chooses one; by default a RISC-V GCC is used if
# there is one, and otherwise LLVM: clang (with the RISC-V target), ld.lld
# and llvm-objcopy, found on the PATH or in RISCV_LLVM_BIN, or in Homebrew's
# llvm and lld (/opt/homebrew/opt/llvm/bin, /opt/homebrew/opt/lld/bin, and
# the same under /usr/local).

_rv_find_gcc() {
  local p
  for p in riscv64-elf- riscv64-unknown-elf- riscv32-unknown-elf- riscv-none-elf-; do
    if command -v "${p}gcc" >/dev/null 2>&1; then
      RV_KIND=gcc
      RV_CC="${p}gcc"
      RV_OBJCOPY="${p}objcopy"
      return 0
    fi
  done
  return 1
}

_rv_find_llvm() {
  local d dirs=()
  [ -n "${RISCV_LLVM_BIN:-}" ] && dirs+=("$RISCV_LLVM_BIN")
  dirs+=("")
  for d in /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
    [ -d "$d" ] && dirs+=("$d")
  done
  for d in "${dirs[@]}"; do
    local cc="clang" oc="llvm-objcopy"
    if [ -n "$d" ]; then cc="$d/clang"; oc="$d/llvm-objcopy"; fi
    command -v "$cc" >/dev/null 2>&1 || continue
    command -v "$oc" >/dev/null 2>&1 || continue
    "$cc" -print-targets 2>/dev/null | grep -q riscv32 || continue
    RV_KIND=llvm
    RV_CC="$cc"
    RV_OBJCOPY="$oc"
    # clang finds ld.lld beside itself or on the PATH; Homebrew keeps lld
    # in a formula of its own
    local lld
    for lld in /opt/homebrew/opt/lld/bin /usr/local/opt/lld/bin; do
      if [ -x "$lld/ld.lld" ] && ! command -v ld.lld >/dev/null 2>&1; then
        export PATH="$lld:$PATH"
      fi
    done
    return 0
  done
  return 1
}

case "${RISCV_TOOLCHAIN:-}" in
  gcc)  _rv_find_gcc ;;
  llvm) _rv_find_llvm ;;
  "")   _rv_find_gcc || _rv_find_llvm ;;
  *)    echo "Error: RISCV_TOOLCHAIN must be gcc or llvm, not '$RISCV_TOOLCHAIN'." >&2; exit 1 ;;
esac || {
  echo "Error: no RISC-V toolchain found. Install a RISC-V GCC (riscv64-elf-gcc or similar)," >&2
  echo "or LLVM with the RISC-V target, lld and llvm-objcopy (RISCV_LLVM_BIN=<dir> if they" >&2
  echo "are not on the PATH)." >&2
  exit 1
}

if [ "$RV_KIND" = gcc ]; then
  RV_CFLAGS=(-Wl,--no-warn-rwx-segments)
else
  RV_CFLAGS=(--target=riscv32-unknown-elf -fuse-ld=lld -Wno-unused-command-line-argument)
  if ! command -v ld.lld >/dev/null 2>&1 && [ ! -x "$(dirname "$(command -v "$RV_CC")")/ld.lld" ]; then
    echo "Error: ld.lld not found (it comes with LLVM's lld)." >&2
    exit 1
  fi
fi
