#!/usr/bin/env bash
set -e

echo "==> 1. Fixing rxBitIdx comparison in hdl/rohd/lib/uart.dart..."
python3 -c '
path = "hdl/rohd/lib/uart.dart"
with open(path, "r") as f:
    content = f.read()

bad = "If(rxBitIdx <= Const(8, width: 4), then: ["
good = "If(rxBitIdx.lte(Const(8, width: 4)), then: ["

if bad in content:
    content = content.replace(bad, good)
    with open(path, "w") as f:
        f.write(content)
    print("    [OK] Replaced with rxBitIdx.lte()")
else:
    print("    [INFO] Already patched or pattern differs.")
'

echo "==> 2. Fixing backward branches in firmware/parcore/riscv/core1_dispatch.asm..."
python3 -c '
path = "firmware/parcore/riscv/core1_dispatch.asm"
with open(path, "r") as f:
    content = f.read()

# Replace all backward branches to _dispatch_loop with BBRA
bad_branch = "FBRA    _dispatch_loop"
good_branch = "BBRA    _dispatch_loop"

if bad_branch in content:
    count = content.count(bad_branch)
    content = content.replace(bad_branch, good_branch)
    with open(path, "w") as f:
        f.write(content)
    print(f"    [OK] Replaced {count} instances of FBRA with BBRA")
else:
    print("    [INFO] No FBRA _dispatch_loop found.")
'

echo "==> 3. Re-assembling firmware..."
make firmware

echo "==> 4. Running Parcore top tests..."
cd hdl/parcore && dart test test/parcore_top_test.dart

