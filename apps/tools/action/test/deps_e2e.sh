#!/bin/sh
# End-to-end test of modules (make deps-tests): makes a library module as a
# git repository with two versions, and a program module that requires it,
# in a temporary folder; fetches, builds and runs on Particle and LLVM,
# vendors, builds again without the cache, and verifies.
# Usage: deps_e2e.sh REPO_ROOT

set -e
root=$(cd "$1" && pwd)
action="$root/build/tools/action"
tmp=$(mktemp -d)
export ACTION_CACHE="$tmp/cache"
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

fail() { echo "[FAIL] $1"; exit 1; }

lib="$tmp/repos/plib"
mkdir -p "$lib/console"
cd "$lib"
git init -q
git config user.email test@example.com
git config user.name test
cat > action.json <<'JSON'
{ "action": { "module": { "name": "example.com/test/plib" } } }
JSON
write_console() {
    cat > console/console.act <<ACT
package console;

pub const u32 VERSION = $1;

pub u32 twice(u32 x) {
    return x * 2;
}
ACT
}
write_console 1
git add -A && git commit -qm v1.0.0 && git tag v1.0.0
write_console 2
git commit -qam v1.1.0 && git tag v1.1.0

app="$tmp/app"
mkdir -p "$app"
cd "$app"
cat > action.json <<JSON
{ "action": {
    "module": { "name": "example.com/test/app" },
    "requires": { "example.com/test/plib": { "version": "v1.1.0", "git": "$lib" } }
} }
JSON
cat > main.act <<'ACT'
package main;
import "example.com/test/plib/console";

void main() {
    if (console.twice(21) == 42 && console.VERSION == 2) {
        trap(0);
    }
    trap(15);
}
ACT

# pbuild and llbuild run from the repository root (the assembly includes
# lib/common.inc); the module is found from the source file's folder
run_both() {
    (cd "$root" && ./pbuild "$app/main.act" -o "$tmp/out.bin" --sim) > "$tmp/sim.log" 2>&1 || true
    grep -q "Trap 0 triggered" "$tmp/sim.log" || { cat "$tmp/sim.log"; fail "Particle run ($1)"; }
    (cd "$root" && ./llbuild "$app/main.act" -o "$tmp/out" --run) || fail "LLVM run ($1)"
    echo "[PASS] built and ran on Particle and LLVM ($1)"
}

"$action" main.act -I "$root/lib" -o "$tmp/x.asm" 2> "$tmp/err.log" && fail "built before fetching"
grep -q "is not fetched; run 'action --fetch'" "$tmp/err.log" || { cat "$tmp/err.log"; fail "message before fetching"; }
echo "[PASS] not fetched: the message says to run 'action --fetch'"

"$action" --fetch
grep -q "^example.com/test/plib v1.1.0 sha256:" action.sum || fail "action.sum"
run_both "from the cache"

"$action" --vendor
chmod -R u+w "$ACTION_CACHE"
rm -rf "$ACTION_CACHE"
run_both "from vendor/"

"$action" --verify > /dev/null || fail "verify"
echo "[PASS] verify"
echo "==> [PASS] Module tests passed."
