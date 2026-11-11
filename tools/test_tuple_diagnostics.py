#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import os

TEST_CASES = [
    {
        "name": "Bare tuple in scalar expression",
        "code": """
void main() {
    u32 x = 1 + (2, 3);
}
""",
        "expected_err": "Bare tuple expression not permitted in scalar expression context",
    },
    {
        "name": "Scalar function returning tuple",
        "code": """
u32 bad_scalar() {
    return (1, 2);
}
void main() {}
""",
        "expected_err": "has scalar return type 'u32', cannot return tuple",
    },
    {
        "name": "Tuple function returning scalar",
        "code": """
(u32, u32) bad_tuple() {
    return 42;
}
void main() {}
""",
        "expected_err": "declared with tuple return of arity 2, cannot return scalar or void",
    },
    {
        "name": "Tuple function returning void",
        "code": """
(u32, u32) bad_void() {
    return;
}
void main() {}
""",
        "expected_err": "declared with tuple return of arity 2, cannot return scalar or void",
    },
    {
        "name": "Tuple return arity mismatch (too few)",
        "code": """
(u32, u32, u32) bad_arity() {
    return (1, 2);
}
void main() {}
""",
        "expected_err": "Tuple return arity mismatch in 'bad_arity': expected 3, got 2",
    },
    {
        "name": "Tuple return arity mismatch (too many)",
        "code": """
(u32, u32) bad_arity_high() {
    return (1, 2, 3);
}
void main() {}
""",
        "expected_err": "Tuple return arity mismatch in 'bad_arity_high': expected 2, got 3",
    },
    {
        "name": "Exceeding ABI capacity (> 4 scalar return values)",
        "code": """
(u32, u32, u32, u32, u32) bad_abi() {
    return (1, 2, 3, 4, 5);
}
void main() {}
""",
        "expected_err": "Maximum 4 scalar return values supported in Particle ABI",
    },
]

def run_tests():
    passed = 0
    failed = 0

    print("==> Running ACT16 Tuple Negative & Diagnostic Tests...")
    print("-" * 65)

    for tc in TEST_CASES:
        name = tc["name"]
        code = tc["code"]
        expected = tc["expected_err"]

        with tempfile.NamedTemporaryFile("w", suffix=".act", delete=False) as f:
            f.write(code)
            temp_name = f.name

        try:
            proc = subprocess.run(
                [sys.executable, "tools/act16c.py", temp_name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            combined = proc.stdout + "\n" + proc.stderr
            if proc.returncode != 0 and expected in combined:
                print(f"[PASS] {name}")
                passed += 1
            else:
                print(f"[FAIL] {name}")
                print(f"       Expected error: '{expected}'")
                print(f"       Actual exit code: {proc.returncode}")
                print(f"       Actual output:\n{combined.strip()}\n")
                failed += 1
        finally:
            if os.path.exists(temp_name):
                os.remove(temp_name)

    print("-" * 65)
    if failed == 0:
        print(f"==> [PASS] All {passed} negative diagnostic tests passed successfully.")
        return 0
    else:
        print(f"==> [FAIL] {failed} test(s) failed out of {passed + failed}.")
        return 1

if __name__ == "__main__":
    sys.exit(run_tests())
