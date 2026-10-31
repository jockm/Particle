#!/usr/bin/env python3
"""
================================================================================
Particle Macro Assembler (pasm.py)
Architecture: Particle 32-bit RISC (16-bit compact instruction encoding)
================================================================================
"""

import sys
import os
import re
import argparse
from typing import List, Dict, Tuple, Optional, Any

REG_MAP = {f"r{i}": i for i in range(16)}
REG_MAP["sp"] = 15

class AssemblerError(Exception):
    def __init__(self, message: str, filename: Optional[str] = None, lineno: Optional[int] = None):
        loc = f"{filename or 'input'}:{lineno or '?'}: error: "
        super().__init__(f"{loc}{message}")
        self.message = message
        self.filename = filename
        self.lineno = lineno

class Macro:
    def __init__(self, name: str, params: List[str], lines: List[str], filename: str, lineno: int):
        self.name = name.upper()
        self.params = [p.strip() for p in params if p.strip()]
        self.lines = lines
        self.filename = filename
        self.lineno = lineno

class Preprocessor:
    def __init__(self, include_dirs: Optional[List[str]] = None, defines: Optional[Dict[str, int]] = None):
        self.include_dirs = include_dirs or ["."]
        self.defines: Dict[str, Any] = defines or {}
        self.macros: Dict[str, Macro] = {}
        self.macro_counter = 0

    def _split_args(self, arg_str: str) -> List[str]:
        tokens = []
        cur = []
        in_paren = 0
        in_quote = False
        for ch in arg_str:
            if ch == '"':
                in_quote = not in_quote
                cur.append(ch)
            elif ch == '(' and not in_quote:
                in_paren += 1
                cur.append(ch)
            elif ch == ')' and not in_quote:
                in_paren -= 1
                cur.append(ch)
            elif ch == ',' and in_paren == 0 and not in_quote:
                tokens.append("".join(cur).strip())
                cur = []
            else:
                cur.append(ch)
        if cur:
            tokens.append("".join(cur).strip())
        return [t for t in tokens if t]

    def _find_include(self, inc_name: str, current_file: str) -> Optional[str]:
        # 1. Check direct path / relative to current working directory
        if os.path.exists(inc_name):
            return os.path.abspath(inc_name)

        # 2. Check relative to current file directory
        cur_dir = os.path.dirname(os.path.abspath(current_file))
        cand = os.path.normpath(os.path.join(cur_dir, inc_name))
        if os.path.exists(cand):
            return cand

        # 3. Check include search directories (-I)
        for d in self.include_dirs:
            cand1 = os.path.normpath(os.path.join(d, inc_name))
            if os.path.exists(cand1):
                return cand1
            cand2 = os.path.normpath(os.path.join(d, os.path.basename(inc_name)))
            if os.path.exists(cand2):
                return cand2

        return None

    def parse_expr(self, expr_str: str, symbols: Optional[Dict[str, int]] = None) -> int:
        expr = expr_str.strip()
        context: Dict[str, Any] = {}
        context.update(self.defines)
        if symbols:
            context.update(symbols)

        # Replace hexadecimal 0x prefix if needed and handle logic operators
        # Create safe evaluation environment
        safe_dict = {
            "__builtins__": None,
            "abs": abs, "min": min, "max": max
        }
        safe_dict.update(context)

        # Protect against empty expression
        if not expr:
            raise ValueError("Empty expression")

        # Convert bitwise not if written as ~ or !
        cleaned = re.sub(r'\btrue\b', '1', expr, flags=re.IGNORECASE)
        cleaned = re.sub(r'\bfalse\b', '0', cleaned, flags=re.IGNORECASE)

        try:
            val = eval(cleaned, safe_dict)
            return int(val)
        except Exception as e:
            # Try evaluating simple integer conversion
            try:
                return int(expr, 0)
            except Exception:
                raise ValueError(f"Cannot evaluate '{expr_str}': {e}")

    def preprocess_file(self, filename: str) -> List[Tuple[str, str, int]]:
        abs_path = os.path.abspath(filename)
        if not os.path.exists(abs_path):
            raise AssemblerError(f"File not found: '{filename}'")

        with open(abs_path, "r", encoding="utf-8") as f:
            raw_lines = f.readlines()

        return self._preprocess_lines(raw_lines, abs_path)

    def _preprocess_lines(self, lines: List[str], current_file: str) -> List[Tuple[str, str, int]]:
        out_lines: List[Tuple[str, str, int]] = []
        cond_stack: List[Tuple[bool, bool]] = []  # (active, condition_met)
        in_macro_def: Optional[Macro] = None
        macro_body: List[str] = []
        macro_name = ""
        macro_params: List[str] = []
        macro_start_line = 0

        for lineno, line in enumerate(lines, start=1):
            sline = line.rstrip("\r\n")
            strip_line = sline.strip()

            # Handle comments for directive checks
            comment_idx = -1
            in_q = False
            for i, ch in enumerate(sline):
                if ch == '"':
                    in_q = not in_q
                elif ch in (';', '#') and not in_q:
                    comment_idx = i
                    break
            code_part = sline[:comment_idx].strip() if comment_idx >= 0 else strip_line

            # Check macro definition end
            if in_macro_def:
                if code_part.upper().startswith(".ENDMACRO") or code_part.upper().startswith(".ENDM"):
                    macro_obj = Macro(macro_name, macro_params, macro_body, current_file, macro_start_line)
                    self.macros[macro_name.upper()] = macro_obj
                    in_macro_def = None
                else:
                    macro_body.append(sline)
                continue

            # Directive matching
            if code_part.startswith("."):
                parts = code_part.split(None, 1)
                directive = parts[0].upper()
                args = parts[1].strip() if len(parts) > 1 else ""

                # Conditionals
                if directive == ".IFDEF":
                    is_active = (not cond_stack or cond_stack[-1][0])
                    cond = (args.split()[0] in self.defines) if args else False
                    cond_stack.append((is_active and cond, cond))
                    continue
                elif directive == ".IFNDEF":
                    is_active = (not cond_stack or cond_stack[-1][0])
                    cond = (args.split()[0] not in self.defines) if args else False
                    cond_stack.append((is_active and cond, cond))
                    continue
                elif directive == ".IF":
                    is_active = (not cond_stack or cond_stack[-1][0])
                    try:
                        cond = (self.parse_expr(args) != 0) if is_active else False
                    except Exception:
                        cond = False
                    cond_stack.append((is_active and cond, cond))
                    continue
                elif directive == ".ELSE":
                    if not cond_stack:
                        raise AssemblerError(".ELSE without .IF", current_file, lineno)
                    prev_active, prev_met = cond_stack.pop()
                    parent_active = (not cond_stack or cond_stack[-1][0])
                    cond_stack.append((parent_active and not prev_met, True))
                    continue
                elif directive == ".ENDIF":
                    if not cond_stack:
                        raise AssemblerError(".ENDIF without .IF", current_file, lineno)
                    cond_stack.pop()
                    continue

            # Check active conditional block
            if cond_stack and not cond_stack[-1][0]:
                continue

            if code_part.startswith("."):
                parts = code_part.split(None, 1)
                directive = parts[0].upper()
                args = parts[1].strip() if len(parts) > 1 else ""

                if directive == ".DEFINE":
                    def_parts = args.split(None, 1)
                    sym_name = def_parts[0]
                    val_str = def_parts[1].strip() if len(def_parts) > 1 else "1"
                    try:
                        val = self.parse_expr(val_str)
                    except Exception:
                        val = val_str
                    self.defines[sym_name] = val
                    continue

                elif directive in (".MACRO", ".MAC"):
                    def_parts = re.split(r"[\s,]+", args)
                    macro_name = def_parts[0]
                    macro_params = def_parts[1:]
                    macro_body = []
                    macro_start_line = lineno
                    in_macro_def = True
                    continue

                elif directive == ".INCLUDE":
                    inc_file = args.strip('"\'')
                    resolved = self._find_include(inc_file, current_file)
                    if not resolved:
                        raise AssemblerError(f"Include file '{inc_file}' not found", current_file, lineno)
                    inc_lines = self.preprocess_file(resolved)
                    out_lines.extend(inc_lines)
                    continue

            # Check for Macro Invocations
            first_tok = code_part.split(None, 1)[0] if code_part else ""
            # Strip trailing colon if label
            candidate_macro = first_tok.rstrip(":").upper()

            # Separate optional label from instruction
            label_prefix = ""
            active_stmt = code_part
            if ":" in code_part:
                lbl, remainder = code_part.split(":", 1)
                lbl = lbl.strip()
                if re.match(r'^[a-zA-Z_.$][a-zA-Z0-9_.$]*$', lbl):
                    label_prefix = f"{lbl}:\n"
                    active_stmt = remainder.strip()
                    if active_stmt:
                        first_tok = active_stmt.split(None, 1)[0]
                        candidate_macro = first_tok.upper()
                    else:
                        candidate_macro = ""

            if candidate_macro and candidate_macro in self.macros:
                macro = self.macros[candidate_macro]
                rest_args = active_stmt.split(None, 1)[1] if len(active_stmt.split(None, 1)) > 1 else ""
                call_args = self._split_args(rest_args)

                self.macro_counter += 1
                unique_suffix = f"_{candidate_macro.lower()}_{self.macro_counter}"

                # Parameter mapping
                subst: Dict[str, str] = {}
                for idx, p in enumerate(macro.params):
                    val = call_args[idx] if idx < len(call_args) else ""
                    subst[f"%{p}"] = val

                expanded_lines: List[str] = []
                for mline in macro.lines:
                    cur_line = mline
                    # Substitute parameters
                    for k, v in subst.items():
                        cur_line = cur_line.replace(k, v)
                    # Substitute local unique label
                    cur_line = cur_line.replace("._label_%", f"._L{unique_suffix}")
                    expanded_lines.append(cur_line)

                # Re-preprocess expanded macro lines recursively
                if label_prefix:
                    out_lines.append((label_prefix.strip(), current_file, lineno))
                re_expanded = self._preprocess_lines(expanded_lines, current_file)
                out_lines.extend(re_expanded)
                continue

            out_lines.append((sline, current_file, lineno))

        return out_lines


class Assembler:
    def __init__(self):
        self.symbols: Dict[str, int] = {}

    def parse_reg(self, token: str, filename: Optional[str] = None, lineno: Optional[int] = None) -> int:
        clean = token.strip().lower()
        if clean not in REG_MAP:
            raise AssemblerError(f"Invalid register operand '{token}'", filename, lineno)
        return REG_MAP[clean]

    def parse_val(self, token: str, symbols: Dict[str, int], preprocessor: Preprocessor,
                  filename: Optional[str] = None, lineno: Optional[int] = None) -> int:
        clean = token.strip()
        try:
            return preprocessor.parse_expr(clean, symbols)
        except Exception:
            if clean in symbols:
                return symbols[clean]
            raise AssemblerError(f"Undefined symbol or invalid expression '{token}'", filename, lineno)

    def assemble(self, preprocessed_lines: List[Tuple[str, str, int]], preprocessor: Preprocessor):
        self.symbols = {}
        addr = 0x00000100
        items: List[Tuple[int, Optional[str], str, str, str, int, int]] = []

        # ======================================================================
        # Pass 1: Symbol resolution & instruction length computation
        # ======================================================================
        for raw_line, fname, lno in preprocessed_lines:
            line = raw_line.strip()
            # Strip comments
            c_idx = -1
            in_q = False
            for i, ch in enumerate(line):
                if ch == '"':
                    in_q = not in_q
                elif ch in (';', '#') and not in_q:
                    c_idx = i
                    break
            clean = line[:c_idx].strip() if c_idx >= 0 else line

            # Collect labels
            while ":" in clean:
                lbl_part, remainder = clean.split(":", 1)
                lbl = lbl_part.strip()
                if not re.match(r'^[a-zA-Z_.$][a-zA-Z0-9_.$]*$', lbl):
                    break
                self.symbols[lbl] = addr
                clean = remainder.strip()

            if not clean:
                items.append((addr, None, "", raw_line, fname, lno, 0))
                continue

            parts = clean.split(None, 1)
            mnemonic = parts[0].upper()
            operands = parts[1].strip() if len(parts) > 1 else ""

            if mnemonic == ".ORG":
                addr = preprocessor.parse_expr(operands, self.symbols)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, 0))
            elif mnemonic == ".ALIGN":
                align_val = preprocessor.parse_expr(operands, self.symbols)
                pad = 0
                if align_val > 0 and (addr % align_val) != 0:
                    pad = align_val - (addr % align_val)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, pad))
                addr += pad
            elif mnemonic == ".BYTE":
                split_items = preprocessor._split_args(operands)
                length = len(split_items)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic == ".HALF":
                split_items = preprocessor._split_args(operands)
                length = len(split_items) * 2
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic == ".WORD":
                split_items = preprocessor._split_args(operands)
                length = len(split_items) * 4
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic == ".ASCIZ":
                s = operands.strip('"') + "\0"
                encoded = s.encode('utf-8')
                length = len(encoded)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic.startswith("."):
                items.append((addr, mnemonic, operands, raw_line, fname, lno, 0))
            else:
                # All Particle instructions are exactly 16 bits (2 bytes)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, 2))
                addr += 2

        # ======================================================================
        # Pass 2: Binary code emission & listing construction
        # ======================================================================
        min_addr = min((item[0] for item in items if item[6] > 0), default=0x00000100)
        max_addr = max((item[0] + item[6] for item in items), default=addr)
        image = bytearray(max_addr)
        listing_entries: List[Tuple[int, bytes, int, str]] = []

        for cur_addr, mnemonic, operands, raw_line, fname, lno, size in items:
            emitted_bytes = b""
            if mnemonic and size > 0:
                if mnemonic == ".ALIGN":
                    emitted_bytes = b"\x00" * size
                elif mnemonic == ".BYTE":
                    b_vals = [self.parse_val(v, self.symbols, preprocessor, fname, lno) & 0xFF
                              for v in preprocessor._split_args(operands)]
                    emitted_bytes = bytes(b_vals)
                elif mnemonic == ".HALF":
                    h_bytes = bytearray()
                    for v in preprocessor._split_args(operands):
                        val = self.parse_val(v, self.symbols, preprocessor, fname, lno) & 0xFFFF
                        h_bytes.extend([val & 0xFF, (val >> 8) & 0xFF])
                    emitted_bytes = bytes(h_bytes)
                elif mnemonic == ".WORD":
                    w_bytes = bytearray()
                    for v in preprocessor._split_args(operands):
                        val = self.parse_val(v, self.symbols, preprocessor, fname, lno) & 0xFFFFFFFF
                        w_bytes.extend([val & 0xFF, (val >> 8) & 0xFF, (val >> 16) & 0xFF, (val >> 24) & 0xFF])
                    emitted_bytes = bytes(w_bytes)
                elif mnemonic == ".ASCIZ":
                    s = operands.strip('"') + "\0"
                    emitted_bytes = s.encode('utf-8')
                else:
                    code = self._encode_instruction(cur_addr, mnemonic, operands, self.symbols, preprocessor, fname, lno)
                    emitted_bytes = bytes([code & 0xFF, (code >> 8) & 0xFF])

                image[cur_addr:cur_addr + len(emitted_bytes)] = emitted_bytes

            listing_entries.append((cur_addr, emitted_bytes, lno, raw_line))

        return image, min_addr, max_addr, listing_entries

    def _encode_instruction(self, pc: int, mnem: str, op_str: str,
                            symbols: Dict[str, int], preprocessor: Preprocessor,
                            fname: str, lno: int) -> int:
        mnem = mnem.upper()
        ops = preprocessor._split_args(op_str)

        def get_r(idx: int) -> int:
            if idx >= len(ops):
                raise AssemblerError(f"Missing register operand #{idx+1}", fname, lno)
            return self.parse_reg(ops[idx], fname, lno)

        def get_v(idx: int) -> int:
            if idx >= len(ops):
                raise AssemblerError(f"Missing value operand #{idx+1}", fname, lno)
            return self.parse_val(ops[idx], symbols, preprocessor, fname, lno)

        # ---------------- 1. Loads & Immediates (0x00 - 0x06) ----------------
        if mnem == "LD":
            if len(ops) < 2:
                raise AssemblerError("LD requires 2 operands", fname, lno)
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x00 << 8) | (rr << 4) | rl
            except AssemblerError:
                pass

            # Immediate format
            val = get_v(1)
            if rr == 14:
                if 0 <= val <= 255:
                    return (0x02 << 8) | (val & 0xFF)
                elif -256 <= val < 0:
                    return (0x04 << 8) | ((-val) & 0xFF)
            if 0 <= val <= 15:
                return (0x01 << 8) | (rr << 4) | (val & 0x0F)
            elif -15 <= val < 0:
                return (0x03 << 8) | (rr << 4) | ((-val) & 0x0F)
            raise AssemblerError(f"Immediate value {val} out of range for LD", fname, lno)

        if mnem == "PUSH4":
            return (0x05 << 8) | (get_r(0) << 4) | (get_v(1) & 0x0F)
        if mnem == "PUSH8":
            rr = get_r(0)
            if rr != 14:
                raise AssemblerError("PUSH8 destination must be R14", fname, lno)
            return (0x06 << 8) | (get_v(1) & 0xFF)

        # ---------------- 2. Memory Loads & Stores (0x10 - 0x39) -------------
        mem_match = re.match(r'^LD(8|16|32)$', mnem)
        if mem_match:
            width_sz = int(mem_match.group(1))
            base_op = 0x10 if width_sz == 8 else (0x20 if width_sz == 16 else 0x30)
            opA, opB = ops[0], ops[1]

            # Store: LDx (Rr), Rl or variants
            if opA.startswith("(") and opA.endswith(")"):
                inner = opA[1:-1].strip()
                rl = self.parse_reg(opB, fname, lno)
                if inner.startswith("--"):
                    rr = self.parse_reg(inner[2:], fname, lno)
                    return ((base_op + 6) << 8) | (rr << 4) | rl
                elif inner.endswith("--"):
                    rr = self.parse_reg(inner[:-2], fname, lno)
                    return ((base_op + 7) << 8) | (rr << 4) | rl
                elif inner.endswith("++"):
                    rr = self.parse_reg(inner[:-2], fname, lno)
                    return ((base_op + 8) << 8) | (rr << 4) | rl
                elif inner.startswith("++"):
                    rr = self.parse_reg(inner[2:], fname, lno)
                    return ((base_op + 9) << 8) | (rr << 4) | rl
                else:
                    rr = self.parse_reg(inner, fname, lno)
                    return ((base_op + 1) << 8) | (rr << 4) | rl

            # Load: LDx Rr, (Rl) or variants
            elif opB.startswith("(") and opB.endswith(")"):
                inner = opB[1:-1].strip()
                rr = self.parse_reg(opA, fname, lno)
                if inner.endswith("++"):
                    rl = self.parse_reg(inner[:-2], fname, lno)
                    return ((base_op + 2) << 8) | (rr << 4) | rl
                elif inner.startswith("++"):
                    rl = self.parse_reg(inner[2:], fname, lno)
                    return ((base_op + 3) << 8) | (rr << 4) | rl
                elif inner.endswith("--"):
                    rl = self.parse_reg(inner[:-2], fname, lno)
                    return ((base_op + 4) << 8) | (rr << 4) | rl
                elif inner.startswith("--"):
                    rl = self.parse_reg(inner[2:], fname, lno)
                    return ((base_op + 5) << 8) | (rr << 4) | rl
                else:
                    rl = self.parse_reg(inner, fname, lno)
                    return (base_op << 8) | (rr << 4) | rl

        # ---------------- 3. Unsigned & Signed Math (0x40 - 0x57) ------------
        math_map = {
            "ADD": 0x40, "SUB": 0x41, "DIV": 0x42, "MOD": 0x43,
            "SADD": 0x50, "SSUB": 0x51, "SDIV": 0x52, "SMOD": 0x53,
        }
        if mnem in math_map:
            rr = get_r(0)
            base_op = math_map[mnem]
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (base_op << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                return ((base_op + 4) << 8) | (rr << 4) | (val & 0x0F)

        # ---------------- 4. Shifts, Logic & Sign-Ext (0x60 - 0x77) ----------
        logic_map = {
            "SHIFTL": 0x60, "SHIFTR": 0x62, "ASHIFTR": 0x63,
            "ROTL": 0x64, "ROTR": 0x65, "AND": 0x66, "OR": 0x67, "XOR": 0x68
        }
        if mnem in logic_map:
            rr = get_r(0)
            base_op = logic_map[mnem]
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (base_op << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                imm_op = (0x69 if mnem == "SHIFTL" else
                          (0x6B if mnem == "SHIFTR" else
                           (0x6C if mnem == "ASHIFTR" else
                            (0x6D if mnem == "ROTL" else
                             (0x6E if mnem == "ROTR" else
                              (0x6F if mnem == "AND" else
                               (0x70 if mnem == "OR" else 0x71)))))))
                return (imm_op << 8) | (rr << 4) | (val & 0x0F)

        if mnem == "SEXT8":
            return (0x61 << 8) | (get_r(0) << 4)
        if mnem == "SEXT16":
            return (0x6A << 8) | (get_r(0) << 4)

        # ---------------- 5. Newly Added Inversion & Boolean (0x72 - 0x73) ----
        if mnem == "NOT":
            return (0x72 << 8) | (get_r(0) << 4)
        if mnem == "NEZ":
            return (0x73 << 8) | (get_r(0) << 4)

        # ---------------- 6. Multipliers (0x78 - 0x7F) -----------------------
        mul_map = {"MULL": 0x78, "MULH": 0x79, "SMULH": 0x7A, "MULHSU": 0x7B}
        if mnem in mul_map:
            rr = get_r(0)
            base_op = mul_map[mnem]
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (base_op << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                return ((base_op + 4) << 8) | (rr << 4) | (val & 0x0F)

        # ---------------- 7. Bit Manipulation & System (0x80 - 0x8B) ---------
        if mnem == "BEXTR":
            return (0x80 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem == "JTBL":
            return (0x81 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem == "CLZ":
            return (0x82 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem in ("BSET", "BCLR", "BINV", "BGET"):
            rr = get_r(0)
            base_op = 0x83 if mnem == "BSET" else (0x85 if mnem == "BCLR" else (0x87 if mnem == "BINV" else 0x89))
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (base_op << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                return ((base_op + 1) << 8) | (rr << 4) | (val & 0x0F)

        if mnem == "TAS":
            op0 = ops[0].strip("()")
            return (0x8B << 8) | (self.parse_reg(op0, fname, lno) << 4) | get_r(1)

        # ---------------- 8. Comparisons (0x90 - 0x99) -----------------------
        if mnem in ("SLT", "SSLT"):
            base_op = 0x90 if mnem == "SLT" else 0x95
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (base_op << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                if rr == 14:
                    if 0 <= val <= 255:
                        return ((base_op + 3) << 8) | (val & 0xFF)
                    elif -256 <= val < 0:
                        return ((base_op + 4) << 8) | ((-val) & 0xFF)
                if 0 <= val <= 15:
                    return ((base_op + 1) << 8) | (rr << 4) | (val & 0x0F)
                elif -15 <= val < 0:
                    return ((base_op + 2) << 8) | (rr << 4) | ((-val) & 0x0F)
                raise AssemblerError(f"Immediate {val} out of range for {mnem}", fname, lno)

        # ---------------- 9. Control Flow & Sync (0xA0 - 0xA4) ---------------
        if mnem == "JMP":
            rr = get_r(0)
            rl = get_r(1) if len(ops) > 1 else 0  # Default to R0
            return (0xA0 << 8) | (rr << 4) | rl

        if mnem == "RJUMP":
            rr = get_r(0)
            rl = get_r(1) if len(ops) > 1 else 0  # Default to R0
            return (0xA1 << 8) | (rr << 4) | rl

        if mnem == "TRAP":
            try:
                rr = self.parse_reg(ops[0], fname, lno)
                return (0xA2 << 8) | (rr << 4)
            except AssemblerError:
                val = get_v(0)
                return (0xA3 << 8) | (val & 0x0F)

        if mnem == "WAIT":
            return 0xA4 << 8

        # ---------------- 10. Branches (0xB0 - 0xC9) -------------------------
        for branch_pfx, is_backward in (("FBRA", False), ("BBRA", True)):
            if mnem == branch_pfx:
                # Unconditional Branch: FBRA / BBRA target
                tgt = get_v(0)
                diff = (pc - tgt) if is_backward else (tgt - pc)
                offset = diff // 2
                if not (0 <= offset <= 255):
                    raise AssemblerError(f"Branch out of 8-bit immediate range ({offset})", fname, lno)
                op = 0xC0 if is_backward else 0xB0
                return (op << 8) | (offset & 0xFF)

            elif mnem.startswith(f"{branch_pfx}."):
                cond = mnem[len(branch_pfx)+1:]
                base_op = 0xC0 if is_backward else 0xB0
                cond_idx = 0 if cond == "Z" else (1 if cond == "N" else (2 if cond == "P" else -1))
                if cond_idx < 0:
                    break

                rr = get_r(0)
                # Form 1: Condition with R14 and Imm8
                if rr == 14 and len(ops) == 2:
                    tgt = get_v(1)
                    diff = (pc - tgt) if is_backward else (tgt - pc)
                    offset = diff // 2
                    if not (0 <= offset <= 255):
                        raise AssemblerError(f"Branch out of 8-bit immediate range ({offset})", fname, lno)
                    return ((base_op + 7 + cond_idx) << 8) | (offset & 0xFF)

                # Form 2: Register comparison or Imm4 branch
                try:
                    rl = self.parse_reg(ops[1], fname, lno)
                    return ((base_op + 1 + cond_idx) << 8) | (rr << 4) | rl
                except AssemblerError:
                    tgt = get_v(1)
                    diff = (pc - tgt) if is_backward else (tgt - pc)
                    offset = diff // 2
                    if not (0 <= offset <= 15):
                        raise AssemblerError(f"Branch out of 4-bit immediate range ({offset})", fname, lno)
                    return ((base_op + 4 + cond_idx) << 8) | (rr << 4) | (offset & 0x0F)

        # ---------------- 11. Shadow Banks (0xD0 - 0xD2) ---------------------
        if mnem == "XCHG":
            return (0xD0 << 8) | (get_r(0) << 4)
        if mnem == "XCHGALL":
            return 0xD1 << 8
        if mnem == "XCHGMOST":
            return 0xD2 << 8

        # ---------------- 12. Streaming FIFOs & MBOX (0xE0 - 0xE9) -----------
        if mnem == "FIFO.R":
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0xE0 << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                return (0xE1 << 8) | (rr << 4) | (val & 0x0F)

        if mnem == "FIFO.W":
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0xE2 << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                return (0xE3 << 8) | (rr << 4) | (val & 0x0F)

        if mnem == "FIFO.STAT":
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0xE4 << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                return (0xE5 << 8) | (rr << 4) | (val & 0x0F)

        if mnem == "FIFO.TRYR":
            return (0xE6 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem == "FIFO.TRYW":
            return (0xE7 << 8) | (get_r(0) << 4) | get_r(1)

        if mnem == "MBOX":
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0xE8 << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                return (0xE9 << 8) | (rr << 4) | (val & 0x0F)

        raise AssemblerError(f"Unknown or unencodable mnemonic '{mnem}'", fname, lno)


def write_listing(lst_path: str, listing_entries: List[Tuple[int, bytes, int, str]], symbols: Dict[str, int]):
    with open(lst_path, "w", encoding="utf-8") as f:
        for addr, b_data, lno, src_line in listing_entries:
            hex_bytes = b_data.hex().upper() if b_data else ""
            # Format: ADDR  HEX_CODE  LINE_NO  SRC
            if hex_bytes:
                # Group bytes by halfwords
                h_str = " ".join(hex_bytes[i:i+4] for i in range(0, len(hex_bytes), 4))
                f.write(f"{addr:08X}  {h_str:<12}  {lno:4d}      {src_line}\n")
            else:
                f.write(f"                        {lno:4d}  {src_line}\n")

        # Symbol table dump at end of listing
        f.write("\n; " + "-" * 78 + "\n")
        f.write("; SYMBOL TABLE\n")
        f.write("; " + "-" * 78 + "\n")
        for sym, val in sorted(symbols.items()):
            f.write(f"; {sym:<32} = 0x{val:08X}\n")


def main():
    parser = argparse.ArgumentParser(description="Particle Two-Pass Macro Assembler (pasm.py)")
    parser.add_argument("source", help="Source assembly (.asm) file")
    parser.add_argument("-o", "--output", default="a.out", help="Output binary/hex file")
    parser.add_argument("-I", "--include", action="append", default=[], help="Include directory search paths")
    parser.add_argument("-D", "--define", action="append", default=[], help="Predefine symbols (NAME or NAME=VAL)")
    parser.add_argument("--format", choices=["bin", "hex", "c"], default="bin", help="Output format (default: bin)")
    args = parser.parse_args()

    # Process command line defines
    defines: Dict[str, Any] = {}
    for d in args.define:
        if "=" in d:
            k, v = d.split("=", 1)
            try:
                defines[k.strip()] = int(v.strip(), 0)
            except Exception:
                defines[k.strip()] = v.strip()
        else:
            defines[d.strip()] = 1

    include_dirs = args.include or ["."]

    preprocessor = Preprocessor(include_dirs=include_dirs, defines=defines)
    assembler = Assembler()

    try:
        lines = preprocessor.preprocess_file(args.source)
        image, min_addr, max_addr, listing_entries = assembler.assemble(lines, preprocessor)
    except AssemblerError as e:
        print(e, file=sys.stderr)
        sys.exit(1)

    # Ensure output directory exists
    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    # Write binary / hex output
    payload = image[min_addr:max_addr]
    if args.format == "bin":
        with open(args.output, "wb") as f:
            f.write(payload)
    elif args.format == "hex":
        with open(args.output, "w", encoding="utf-8") as f:
            for i in range(0, len(payload), 2):
                hw = payload[i] | ((payload[i+1] if i+1 < len(payload) else 0) << 8)
                f.write(f"{hw:04X}\n")
    elif args.format == "c":
        with open(args.output, "w", encoding="utf-8") as f:
            f.write("/* Particle Assembled ROM Header */\n")
            f.write("#include <stdint.h>\n\n")
            f.write(f"const uint16_t particle_rom[{len(payload)//2}] = {{\n")
            for i in range(0, len(payload), 16):
                chunk = []
                for j in range(i, min(i+16, len(payload)), 2):
                    hw = payload[j] | ((payload[j+1] if j+1 < len(payload) else 0) << 8)
                    chunk.append(f"0x{hw:04X}")
                f.write("    " + ", ".join(chunk) + ",\n")
            f.write("};\n")

    # Write listing (.lst) in the same directory as output binary
    base_name, _ = os.path.splitext(args.output)
    lst_path = f"{base_name}.lst"
    write_listing(lst_path, listing_entries, assembler.symbols)

    print(f"Assembly succeeded: {len(payload)} bytes emitted [0x{min_addr:X}..0x{max_addr:X}]. Listing emitted to: {lst_path}")

if __name__ == "__main__":
    main()