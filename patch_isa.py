#!/usr/bin/env python3
"""
Robust, idempotent patch script for Particle Extended ISA:
  - NEG (0x48)
  - REV32 (0x8C)
  - SEQ (0x9A), SNE (0x9B), SLE (0x9C), SSLE (0x9D)
"""

import os
import re
import sys

def read_file(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def write_file(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

# ==============================================================================
# 1. hdl/rohd/lib/alu.dart
# ==============================================================================
def patch_alu():
    path = "hdl/rohd/lib/alu.dart"
    content = read_file(path)
    if not content:
        print(f"[SKIP] {path} not found")
        return

    if "Const(20, width: 5)" in content:
        print(f"[ALREADY PATCHED] {path}")
        return

    # Look for defaultItem: in the main Case block
    match = re.search(r'(\s*)(defaultItem\s*:\s*\[)', content)
    if not match:
        print(f"[FAIL] Could not find 'defaultItem:' in {path}")
        return

    indent = match.group(1)
    alu_cases = (
        f"{indent}// 20: NEG (0 - operandA)\n"
        f"{indent}CaseItem(Const(20, width: 5), [\n"
        f"{indent}  result < (Const(0, width: ParticleWidths.word) - operandA),\n"
        f"{indent}]),\n"
        f"{indent}// 21: REV32 (Byte-swap 32-bit)\n"
        f"{indent}CaseItem(Const(21, width: 5), [\n"
        f"{indent}  result < [operandA.slice(7, 0), operandA.slice(15, 8), operandA.slice(23, 16), operandA.slice(31, 24)].swizzle(),\n"
        f"{indent}]),\n"
        f"{indent}// 22: SEQ (operandA == operandB)\n"
        f"{indent}CaseItem(Const(22, width: 5), [\n"
        f"{indent}  result < mux(operandA.eq(operandB), Const(1, width: ParticleWidths.word), Const(0, width: ParticleWidths.word)),\n"
        f"{indent}]),\n"
        f"{indent}// 23: SNE (operandA != operandB)\n"
        f"{indent}CaseItem(Const(23, width: 5), [\n"
        f"{indent}  result < mux(operandA.neq(operandB), Const(1, width: ParticleWidths.word), Const(0, width: ParticleWidths.word)),\n"
        f"{indent}]),\n"
        f"{indent}// 24: SLE (operandA <= operandB, Unsigned)\n"
        f"{indent}CaseItem(Const(24, width: 5), [\n"
        f"{indent}  result < mux(operandA.lte(operandB), Const(1, width: ParticleWidths.word), Const(0, width: ParticleWidths.word)),\n"
        f"{indent}]),\n"
        f"{indent}// 25: SSLE (operandA <= operandB, Signed)\n"
        f"{indent}CaseItem(Const(25, width: 5), [\n"
        f"{indent}  result < mux(operandA.lte(operandB), Const(1, width: ParticleWidths.word), Const(0, width: ParticleWidths.word)),\n"
        f"{indent}]),\n"
    )

    pos = match.start()
    new_content = content[:pos] + alu_cases + content[pos:]
    write_file(path, new_content)
    print(f"[OK] Patched {path}")

# ==============================================================================
# 2. hdl/rohd/lib/cpu_core.dart
# ==============================================================================
def patch_cpu_core():
    path = "hdl/rohd/lib/cpu_core.dart"
    content = read_file(path)
    if not content:
        print(f"[SKIP] {path} not found")
        return

    if "ParticleOpcodes.neg" in content:
        print(f"[ALREADY PATCHED] {path}")
        return

    # Find the CaseItem for nez
    pattern = r'(CaseItem\s*\(\s*Const\s*\(\s*ParticleOpcodes\.nez[^)]*\)\s*,\s*\[[^\]]*\]\s*\)\s*,?)'
    match = re.search(pattern, content)
    if not match:
        print(f"[FAIL] Could not locate ParticleOpcodes.nez CaseItem in {path}")
        return

    new_cases = (
        "\n      CaseItem(Const(ParticleOpcodes.neg, width: 8), [\n"
        "        aluOp < Const(AluOps.neg, width: 5),\n"
        "      ]),\n"
        "      CaseItem(Const(ParticleOpcodes.rev32, width: 8), [\n"
        "        aluOp < Const(AluOps.rev32, width: 5),\n"
        "      ]),\n"
        "      CaseItem(Const(ParticleOpcodes.seq, width: 8), [\n"
        "        aluOp < Const(AluOps.seq, width: 5),\n"
        "      ]),\n"
        "      CaseItem(Const(ParticleOpcodes.sne, width: 8), [\n"
        "        aluOp < Const(AluOps.sne, width: 5),\n"
        "      ]),\n"
        "      CaseItem(Const(ParticleOpcodes.sle, width: 8), [\n"
        "        aluOp < Const(AluOps.sle, width: 5),\n"
        "      ]),\n"
        "      CaseItem(Const(ParticleOpcodes.ssle, width: 8), [\n"
        "        aluOp < Const(AluOps.ssle, width: 5),\n"
        "      ]),"
    )

    pos = match.end()
    new_content = content[:pos] + new_cases + content[pos:]
    write_file(path, new_content)
    print(f"[OK] Patched {path}")

# ==============================================================================
# 3. tools/pasm.py
# ==============================================================================
def patch_pasm():
    path = "tools/pasm.py"
    content = read_file(path)
    if not content:
        print(f"[SKIP] {path} not found")
        return

    if "'NEG'" in content or '"NEG"' in content:
        print(f"[ALREADY PATCHED] {path}")
        return

    # Locate NOT or NEZ handler
    pattern = r'(\s*if\s+mnem\s*==\s*[\'"](?:NOT|NEZ)[\'"]\s*:.*?\n\s*return\s+[^\n]+)'
    match = re.search(pattern, content)
    if not match:
        # Fallback to JMP / RJUMP block
        match = re.search(r'(\s*if\s+mnem\s*==\s*[\'"]JMP[\'"]\s*:)', content)

    if not match:
        print(f"[FAIL] Could not locate instruction dispatch insertion point in {path}")
        return

    insert_code = (
        "\n        if mnem == 'NEG':\n"
        "            return (0x48 << 8) | (get_r(0) << 4)\n"
        "        if mnem == 'REV32':\n"
        "            return (0x8C << 8) | (get_r(0) << 4)\n"
        "        if mnem in ('SEQ', 'SNE', 'SLE', 'SSLE'):\n"
        "            lut = {'SEQ': 0x9A, 'SNE': 0x9B, 'SLE': 0x9C, 'SSLE': 0x9D}\n"
        "            return (lut[mnem] << 8) | (get_r(0) << 4) | get_r(1)\n"
    )

    pos = match.end()
    new_content = content[:pos] + insert_code + content[pos:]
    write_file(path, new_content)
    print(f"[OK] Patched {path}")

# ==============================================================================
# 4. tools/psim.py
# ==============================================================================
def patch_psim():
    path = "tools/psim.py"
    content = read_file(path)
    if not content:
        print(f"[SKIP] {path} not found")
        return

    if "opcode == 0x48" in content:
        print(f"[ALREADY PATCHED] {path}")
        return

    # 1. Insert NEG before opcode == 0x40
    m_add = re.search(r'(\s*elif\s+opcode\s*==\s*0x40\s*:)', content)
    if not m_add:
        print(f"[FAIL] Could not locate opcode 0x40 in {path}")
        return

    neg_code = (
        "        elif opcode == 0x48:  # NEG Rr\n"
        "            self.set_reg(rr, to_unsigned32(-to_signed32(self.r[rr])))\n"
    )
    pos1 = m_add.start()
    content = content[:pos1] + neg