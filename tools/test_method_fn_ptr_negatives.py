import subprocess
import sys
import tempfile
from pathlib import Path

BASE_HEADER = """
type Calculator {
    u32 base;
};

type CalcMethod = fn(Calculator, u32) -> u32;

u32 Calculator.add(u32 val) {
    return this.base + val;
}
"""

TESTS = [
    {
        "name": "Instance method extraction rejected",
        "code": BASE_HEADER + """
void main() {
    Calculator calc;
    calc.base = 10;
    CalcMethod op = calc.add;
}
""",
        "expected_err": "Cannot extract unbound method reference from instance 'calc'",
    },
    {
        "name": "Signature mismatch (missing receiver) rejected",
        "code": BASE_HEADER + """
type BadMethod = fn(u32, u32) -> u32;

void main() {
    BadMethod bad = Calculator.add;
}
""",
        "expected_err": "Function signature mismatch: cannot assign 'Calculator_add'",
    },
    {
        "name": "Untyped u32 assignment rejected",
        "code": BASE_HEADER + """
void main() {
    u32 raw_ptr = Calculator.add;
}
""",
        "expected_err": "Cannot implicitly convert function reference to non-function type 'u32'",
    },
    {
        "name": "Nonexistent method reference rejected",
        "code": BASE_HEADER + """
void main() {
    CalcMethod op = Calculator.nonexistent;
}
""",
        "expected_err": "Type 'Calculator' has no method 'nonexistent'",
    },
]

def run_tests():
    pbuild_path = Path("./pbuild").resolve()
    if not pbuild_path.is_file():
        print("Error: ./pbuild not found in current directory.", file=sys.stderr)
        sys.exit(1)

    passed = 0
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_act = Path(tmpdir) / "neg_test.act"
        for idx, t in enumerate(TESTS, 1):
            tmp_act.write_text(t["code"], encoding="utf-8")
            res = subprocess.run(
                ["./pbuild", str(tmp_act)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            combined_out = res.stdout + "\n" + res.stderr
            if res.returncode != 0 and t["expected_err"] in combined_out:
                print(f"[{idx}/{len(TESTS)}] PASS: {t['name']}")
                passed += 1
            else:
                print(f"[{idx}/{len(TESTS)}] FAIL: {t['name']}")
                if res.returncode == 0:
                    print("  Expected compilation to fail, but it succeeded.")
                else:
                    print(f"  Expected error substring: {t['expected_err']}")
                    print(f"  Got output:\n{combined_out.strip()}")

    print(f"\n{passed}/{len(TESTS)} negative compiler tests passed.")
    if passed != len(TESTS):
        sys.exit(1)

if __name__ == "__main__":
    run_tests()
