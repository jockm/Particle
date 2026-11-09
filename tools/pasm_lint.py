#!/usr/bin/env python3
"""
Particle Assembly Linter (pasm_lint.py)
Pre-assembly static checker for Particle RISC ISA constraints.
"""

import sys
import os
import re
import argparse

REG_NAMES = {f"r{i}" for i in range(16)} | {"sp"}

ALL_VALID_MNEMONICS = {
    # ALU / Arithmetic / Logic
    'NOP', 'ADD', 'SUB', 'AND', 'OR', 'XOR', 'DIV', 'MOD',
    'SADD', 'SSUB', 'SDIV', 'SMOD', 'SLT', 'SSLT', 'SGT', 'SGE', 'SLE',
    'SEQ', 'SNE', 'SHIFTL', 'SHIFTR', 'ASHIFTR', 'REV32', 'NEG', 'NOT',
    'NEZ', 'CLZ', 'BEXTR', 'BSET', 'BCLR', 'SEXT8', 'SEXT16',
    'MULL', 'MULH', 'MULHU',

    # Data Transfer / Memory
    'LD', 'LD8', 'LD16', 'LD32', 'ST8', 'ST16', 'ST32',
    'LOAD16', 'LOAD32', 'PUSH8', 'PUSH16', 'PUSH32',
    'POP8', 'POP16', 'POP32',

    # Flow Control
    'FBRA', 'FBRA.Z', 'FBRA.NZ', 'FBRA.P', 'FBRA.N',
    'BBRA', 'BBRA.Z', 'BBRA.NZ', 'BBRA.P', 'BBRA.N',
    'RCALL', 'RRET', 'JMP', 'CALL', 'RET', 'TRAP',

    # FIFO / Inter-core
    'FIFO.W', 'FIFO.R', 'FIFO.STAT', 'FIFO.TRYW', 'FIFO.TRYR',

    # Assembler Directives
    '.BYTE', '.HALF', '.WORD', '.ORG', '.ALIGN', '.GLOBAL', '.EXTERN',
    '.DEFINE', '.EQU', '.INCLUDE', '.STRING', '.ASCII', '.ASCIZ', '.BLOCK'
,
    "ROTR", "MULHSU", "ROTL", "SMULH", "MBOX"
}

IMM4_ARITH_LOGIC = {
    'ADD', 'SUB', 'AND', 'OR', 'XOR', 'DIV', 'MOD',
    'SADD', 'SSUB', 'SDIV', 'SMOD', 'SLT', 'SSLT'
}
IMM4_SHIFTS = {'SHIFTL', 'SHIFTR', 'ASHIFTR'}
IMM4_BITOPS = {'BSET', 'BCLR'}

MEM_INDIRECT_DISALLOWED = {
    'FIFO.W', 'FIFO.R', 'FIFO.STAT', 'FIFO.TRYW', 'FIFO.TRYR',
    'LD', 'ADD', 'SUB', 'AND', 'OR', 'XOR', 'SHIFTL', 'SHIFTR', 'ASHIFTR',
    'REV32', 'NEG', 'NOT', 'NEZ', 'CLZ', 'BEXTR', 'SEXT8', 'SEXT16'
}

BRANCH_FORWARD = {'FBRA', 'FBRA.Z', 'FBRA.NZ', 'FBRA.P', 'FBRA.N'}
BRANCH_BACKWARD = {'BBRA', 'BBRA.Z', 'BBRA.NZ', 'BBRA.P', 'BBRA.N'}


def parse_numeric(val_str):
    try:
        return int(val_str, 0)
    except (ValueError, TypeError):
        return None


def lint_file(filepath, include_dirs=None):
    if not os.path.exists(filepath):
        print(f"[ERROR] File not found: {filepath}", file=sys.stderr)
        return 1

    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    errors = []
    warnings = []

    # Search paths for .include files:
    # 1. Directory of the asm file
    # 2. Current working directory (.)
    # 3. Explicit -I directories
    # 4. Parent of file directory (common if file is in build/)
    inc_dirs = [os.path.dirname(filepath) or ".", "."]
    file_parent = os.path.dirname(os.path.abspath(filepath))
    inc_dirs.append(os.path.dirname(file_parent))
    if include_dirs:
        inc_dirs.extend(include_dirs)

    user_macros = set()

    def scan_macros_from_file(path, visited=None):
        if visited is None:
            visited = set()
        real_path = os.path.realpath(path)
        if real_path in visited or not os.path.exists(path):
            return
        visited.add(real_path)
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as pf:
                for pline in pf:
                    pclean = re.sub(r";.*", "", pline).strip()
                    m_m = re.match(r"^\.macro\s+([A-Za-z0-9_\.]+)", pclean, re.IGNORECASE)
                    if m_m:
                        user_macros.add(m_m.group(1).upper())
                    m_inc = re.match(r'^\.include\s+["\']([^"\']+)["\']', pclean, re.IGNORECASE)
                    if m_inc:
                        inc_target = m_inc.group(1)
                        for d in inc_dirs:
                            cand = os.path.join(d, inc_target)
                            if os.path.exists(cand):
                                scan_macros_from_file(cand, visited)
                                break
        except Exception:
            pass

    scan_macros_from_file(filepath)

    # Pass 1: Collect label positions (line indices) and user defines
    labels = {}
    defines = set()

    for lno, line in enumerate(lines, 1):
        cleaned = re.sub(r';.*', '', line).strip()
        if not cleaned:
            continue

        m_def = re.match(r'^\.(?:define|equ)\s+([A-Za-z0-9_]+)', cleaned, re.IGNORECASE)
        if m_def:
            defines.add(m_def.group(1))

        m_lbl = re.match(r'^([A-Za-z0-9_\.]+):', cleaned)
        if m_lbl:
            labels[m_lbl.group(1)] = lno

    # Pass 2: Verify instructions
    for lno, line in enumerate(lines, 1):
        cleaned = re.sub(r';.*', '', line).strip()
        if not cleaned:
            continue

        if ':' in cleaned:
            parts = cleaned.split(':', 1)
            cleaned = parts[1].strip()
            if not cleaned:
                continue

        tokens = re.split(r'[\s,]+', cleaned)
        mnem = tokens[0].upper()
        ops = [t for t in tokens[1:] if t]

        # 0. Check for valid mnemonic or user macro
        if mnem not in ALL_VALID_MNEMONICS and mnem not in user_macros and not mnem.startswith('.'):
            errors.append((lno, f"Unrecognized mnemonic '{mnem}'."))

        # 1. Check for illegal 3-operand forms on 2-operand instructions
        if mnem in (IMM4_SHIFTS | IMM4_ARITH_LOGIC | {'LD'}):
            if len(ops) > 2:
                errors.append(
                    (lno, f"{mnem} is strictly a 2-operand instruction in Particle RISC, but got {len(ops)} operands: '{', '.join(ops)}'")
                )

        # 2. Check illegal indirect parentheses operands
        for op in ops:
            if op.startswith('(') and op.endswith(')'):
                if mnem in MEM_INDIRECT_DISALLOWED:
                    errors.append(
                        (lno, f"Instruction '{mnem}' does not accept indirect memory operand '{op}'. Use plain register or direct channel ID.")
                    )

        # 3. Check LD immediate ranges
        if mnem == 'LD' and len(ops) >= 2:
            dest = ops[0].lower()
            val_str = ops[1]
            if val_str.lower() not in REG_NAMES and not (val_str.startswith('(') and val_str.endswith(')')):
                val = parse_numeric(val_str)
                if val is not None:
                    if dest == 'r14':
                        if not (0 <= val <= 255):
                            errors.append(
                                (lno, f"Immediate {val_str} ({val}) out of 8-bit unsigned range (0..255) for LD R14.")
                            )
                    else:
                        if not (0 <= val <= 15):
                            errors.append(
                                (lno, f"Immediate {val_str} ({val}) out of 4-bit unsigned range (0..15) for LD {ops[0].upper()}. Use LOAD16/LOAD32 or load via R14.")
                            )

        # 4. Check ALU arithmetic/logic Imm4 ranges
        if mnem in IMM4_ARITH_LOGIC and len(ops) >= 2:
            val_str = ops[1]
            if val_str.lower() not in REG_NAMES:
                val = parse_numeric(val_str)
                if val is not None:
                    if not (0 <= val <= 15):
                        errors.append(
                            (lno, f"Immediate {val_str} ({val}) out of 4-bit unsigned range (0..15) for {mnem}. Load into register first.")
                        )

        # 5. Check Shift Imm4 counts
        if mnem in IMM4_SHIFTS and len(ops) >= 2:
            val_str = ops[1]
            if val_str.lower() not in REG_NAMES:
                val = parse_numeric(val_str)
                if val is not None:
                    if not (0 <= val <= 15):
                        errors.append(
                            (lno, f"Shift count {val_str} ({val}) out of 4-bit range (0..15) for {mnem}. Shifting > 15 must use a register operand.")
                        )

        # 6. Check Bit manipulation Imm4 ranges
        if mnem in IMM4_BITOPS and len(ops) >= 2:
            val_str = ops[1]
            if val_str.lower() not in REG_NAMES:
                val = parse_numeric(val_str)
                if val is not None:
                    if not (0 <= val <= 15):
                        errors.append(
                            (lno, f"Bit position {val_str} ({val}) out of 4-bit range (0..15) for {mnem}.")
                        )

        # 7. Check Forward / Backward branch direction consistency
        target_label = None
        if mnem in BRANCH_FORWARD or mnem in BRANCH_BACKWARD:
            if len(ops) == 1 and ops[0].lower() not in REG_NAMES and parse_numeric(ops[0]) is None:
                target_label = ops[0]
            elif len(ops) == 2 and ops[1].lower() not in REG_NAMES and parse_numeric(ops[1]) is None:
                target_label = ops[1]

            if target_label and target_label in labels:
                tgt_lno = labels[target_label]
                if mnem in BRANCH_FORWARD and tgt_lno < lno:
                    errors.append(
                        (lno, f"Forward branch '{mnem} {target_label}' branches backward (target on line {tgt_lno}). Use BBRA/BBRA.* instead.")
                    )
                elif mnem in BRANCH_BACKWARD and tgt_lno > lno:
                    errors.append(
                        (lno, f"Backward branch '{mnem} {target_label}' branches forward (target on line {tgt_lno}). Use FBRA/FBRA.* instead.")
                    )

    if not errors and not warnings:
        return 0

    print(f"=== Particle Assembly Lint: {filepath} ===", file=sys.stderr)
    for lno, msg in errors:
        print(f"[ERROR] Line {lno:4d}: {msg}", file=sys.stderr)
    for lno, msg in warnings:
        print(f"[WARN]  Line {lno:4d}: {msg}", file=sys.stderr)

    print(f"\nResult: {len(errors)} error(s), {len(warnings)} warning(s).", file=sys.stderr)
    return 1 if errors else 0


def main():
    parser = argparse.ArgumentParser(description="Particle Assembly Linter")
    parser.add_argument("source", help="Assembly file to lint")
    parser.add_argument("-I", "--include", action="append", help="Include search path")
    args = parser.parse_args()

    sys.exit(lint_file(args.source, args.include))


if __name__ == "__main__":
    main()
