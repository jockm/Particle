#!/usr/bin/env bash
# Runs each pipeline test fixture on its own, runs them all even when one
# fails, and exits non-zero if any failed. PARCORE_FAST_SIM=1 uses Verilator.

TESTS=(
  "architectural registers"
  "Signed Division"
  "Multiply High"
  "Sub-word Memory"
  "Control Transfer"
  "System & CSR"
  "FENCE.I"
)

echo "===================================================="
echo "Starting Parcore RV32IM Pipeline Regression Suite"
echo "===================================================="

FAILED=()
for pattern in "${TESTS[@]}"; do
  echo ">>> Running test fixture: [$pattern]"
  if ! dart test --chain-stack-traces test/parcore_rv32_pipeline_test.dart -N "$pattern"; then
    FAILED+=("$pattern")
  fi
done

echo "===================================================="
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "All Parcore RV32IM pipeline tests passed cleanly!"
  echo "===================================================="
else
  echo "Failed fixtures (${#FAILED[@]} of ${#TESTS[@]}):"
  for pattern in "${FAILED[@]}"; do echo "  - $pattern"; done
  echo "===================================================="
  exit 1
fi
