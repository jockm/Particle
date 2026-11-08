#!/usr/bin/env bash
set -e

TESTS=(
  "architectural registers"
  "Signed Division"
  "Multiply High"
  "Sub-word Memory"
  "Control Transfer"
)

echo "===================================================="
echo "Starting Parcore RV32IM Pipeline Regression Suite"
echo "===================================================="

for pattern in "${TESTS[@]}"; do
  echo ">>> Running test fixture: [$pattern]"
  dart test --run-skipped --chain-stack-traces test/parcore_rv32_pipeline_test.dart -N "$pattern"
done

echo "===================================================="
echo "All Parcore RV32IM pipeline tests passed cleanly!"
echo "===================================================="
