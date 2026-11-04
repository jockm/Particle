#!/usr/bin/env python3
# ==============================================================================
# Particle Macro Assembler (pasm.py)
# Architecture: Particle 32-bit RISC (16-bit compact instruction encoding)
# ==============================================================================

import sys
import os
import re
import argparse

REG_MAP = {f"r{i}": i for i in range(16)}
REG_MAP["sp"] = 15

def split_label(line):
    """Splits line into (label, rest) at the first unquoted colon ':'.
    Returns (None, line) if no unquoted colon exists.
    """
    in_quote = False
    quote_char = None
    for idx, ch in enumerate(line):
        if ch in ('"', "'"):
            if not in_quote:
                in_quote = True
                quote_char = ch
            elif ch == quote_char and (idx == 0 or line[idx - 1] != '\\'):
                in_quote = False
        elif ch == ':' and not in_quote:
            return line[:idx].strip(), line[idx + 1:].strip()
    return None, line

class AssemblerError(Exception):
    def __init__(self, message, filename=None, lineno=None):
        super().__init__(f"{filename or 'input'}:{lineno or '?'}: error: {message}")
        self.message = message
        self.filename = filename
        self.lineno = lineno

class Macro:
    def __init__(self, name, params, lines, filename, lineno):
        self.name = name
        self.params = [p.strip() for p in params if p.strip()]
        self.lines = lines
        self.filename = filename
        self.lineno = lineno

class Preprocessor:
    def __init__(self, include_dirs=None, defines=None):
        self.include_dirs = include_dirs or ["."]
        self.defines = defines or {}
        self.macros = {}
        self.macro_counter = 0

    def resolve_include(self, current_file, inc_path):
        candidates = [
            os.path.join(os.path.dirname(current_file), inc_path),
            inc_path
        ]
        for idir in self.include_dirs:
            candidates.append(os.path.join(idir, inc_path))
            candidates.append(os.path.join(idir, os.path.basename(inc_path)))
        for c in candidates:
            if os.path.isfile(c):
                return os.path.abspath(c)
        raise FileNotFoundError(f"Include file not found: {inc_path}")

    def parse_expr(self, expr_str, symbols):
        expr_str = expr_str.strip()
        tokens = re.split(r'([+\-*/<>&|^~() ]+)', expr_str)
        resolved_tokens = []
        for t in tokens:
            ts = t.strip()
            if not ts:
                continue
            if ts in symbols:
                resolved_tokens.append(str(symbols[ts]))
            elif ts in self.defines:
                resolved_tokens.append(str(self.defines[ts]))
            elif ts.lower() in REG_MAP:
                resolved_tokens.append(str(REG_MAP[ts.lower()]))
            else:
                resolved_tokens.append(t)
        expr_eval = "".join(resolved_tokens)
        try:
            return int(eval(expr_eval, {"__builtins__": {}}, {}))
        except Exception as e:
            raise ValueError(f"Invalid expression '{expr_str}': {e}")

    def process(self, filename, lines=None, visited=None):
        if visited is None:
            visited = set()
        abs_path = os.path.abspath(filename)
        
        # Guard against cyclic includes, but allow macro body expansion
        if lines is None:
            if abs_path in visited:
                return []
            visited.add(abs_path)
            with open(abs_path, 'r', encoding='utf-8') as f:
                raw_lines = f.readlines()
        else:
            raw_lines = lines

        expanded = []
        cond_stack = []
        in_macro = None
        macro_name = ""
        macro_params = []
        macro_body = []

        for lno, raw in enumerate(raw_lines, 1):
            line = raw.split(';')[0].strip()
            if not line:
                continue

            active = all(cond_stack) if cond_stack else True

            if line.startswith('.'):
                parts = line.split(None, 1)
                directive = parts[0].lower()
                arg = parts[1].strip() if len(parts) > 1 else ""

                if directive == '.ifdef':
                    cond_stack.append(arg in self.defines)
                    continue
                elif directive == '.ifndef':
                    cond_stack.append(arg not in self.defines)
                    continue
                elif directive == '.if':
                    val = self.parse_expr(arg, self.defines)
                    cond_stack.append(bool(val))
                    continue
                elif directive == '.else':
                    if cond_stack:
                        cond_stack[-1] = not cond_stack[-1]
                    continue
                elif directive == '.endif':
                    if cond_stack:
                        cond_stack.pop()
                    continue

                if not active:
                    continue

                if directive == '.macro':
                    m_parts = arg.split(None, 1)
                    macro_name = m_parts[0]
                    macro_params = [p.strip() for p in m_parts[1].split(',')] if len(m_parts) > 1 else []
                    in_macro = True
                    macro_body = []
                    continue
                elif directive == '.endmacro':
                    self.macros[macro_name] = Macro(macro_name, macro_params, macro_body, abs_path, lno)
                    in_macro = False
                    continue
                elif directive == '.include':
                    inc_file = arg.strip(' "\'')
                    full_inc = self.resolve_include(abs_path, inc_file)
                    expanded.extend(self.process(full_inc, visited=visited))
                    continue
                elif directive == '.define':
                    def_parts = arg.split(None, 1)
                    val = self.parse_expr(def_parts[1], self.defines) if len(def_parts) > 1 else 1
                    self.defines[def_parts[0]] = val
                    continue

            if in_macro:
                macro_body.append(raw)
                continue

            if not active:
                continue

            first_word = line.split()[0]
            if first_word in self.macros:
                m = self.macros[first_word]
                arg_str = line[len(first_word):].strip()
                args = [a.strip() for a in arg_str.split(',')] if arg_str else []
                self.macro_counter += 1
                unique_suffix = f"_{self.macro_counter}"

                m_lines = []
                for ml in m.lines:
                    sub_l = ml
                    for param, val in zip(m.params, args):
                        sub_l = sub_l.replace(f"%{param}", val)
                    sub_l = sub_l.replace(".%", unique_suffix)
                    m_lines.append(sub_l)
                expanded.extend(self.process(abs_path, lines=m_lines, visited=visited))
                continue

            expanded.append((abs_path, lno, line))

        return expanded


class ParticleAssembler:
    def __init__(self, preprocessor):
        self.prep = preprocessor
        self.symbols = {}
        self.pc = 0

    def parse_reg(self, token, fname, lno):
        t = token.strip().lower()
        if t in REG_MAP:
            return REG_MAP[t]
        raise AssemblerError(f"Unknown register '{token}'", fname, lno)

    def assemble(self, src_file):
        processed_lines = self.prep.process(src_file)

        # ----------------- PASS 1: Symbol Calculation -----------------
        self.pc = 0x00000100
        for fname, lno, line in processed_lines:
            while True:
                label_part, rest = split_label(line)
                if label_part is None:
                    break
                if label_part:
                    self.symbols[label_part] = self.pc
                line = rest

                if not line:
                    break

            if not line:
                continue

            if line.startswith('.'):
                parts = line.split(None, 1)
                d = parts[0].lower()
                arg = parts[1].strip() if len(parts) > 1 else ""
                if d == '.org':
                    self.pc = self.prep.parse_expr(arg, self.symbols)
                elif d == '.align':
                    boundary = self.prep.parse_expr(arg, self.symbols)
                    rem = self.pc % boundary
                    if rem != 0:
                        self.pc += (boundary - rem)
                elif d == '.byte':
                    self.pc += len(arg.split(','))
                elif d == '.half':
                    self.pc += len(arg.split(',')) * 2
                elif d == '.word':
                    self.pc += len(arg.split(',')) * 4
                elif d == '.asciz':
                    match = re.search(r'"(.*)"', arg)
                    raw_str = match.group(1) if match else ""
                    decoded_bytes = bytes(raw_str, 'utf-8').decode('unicode_escape').encode('latin1') + b'\x00'
                    self.pc += len(decoded_bytes)

            else:
                self.pc += 2

        # ----------------- PASS 2: Code Emission & Listing -----------------
        self.pc = 0x00000100
        binary_data = {}
        listing_lines = []
        max_addr = self.pc

        for fname, lno, orig_line in processed_lines:
            line = orig_line
            while True:
                lbl, rest = split_label(line)
                if lbl is None:
                    break
                if lbl:
                    listing_lines.append(f"                 {lbl}:")
                line = rest

            if not line:
                continue

            start_pc = self.pc
            emitted_bytes = []

            if line.startswith('.'):
                parts = line.split(None, 1)
                d = parts[0].lower()
                arg = parts[1].strip() if len(parts) > 1 else ""
                if d == '.org':
                    self.pc = self.prep.parse_expr(arg, self.symbols)
                elif d == '.align':
                    boundary = self.prep.parse_expr(arg, self.symbols)
                    rem = self.pc % boundary
                    if rem != 0:
                        pad = boundary - rem
                        for _ in range(pad):
                            binary_data[self.pc] = 0
                            emitted_bytes.append(0)
                            self.pc += 1
                elif d == '.byte':
                    for b in arg.split(','):
                        v = self.prep.parse_expr(b, self.symbols) & 0xFF
                        binary_data[self.pc] = v
                        emitted_bytes.append(v)
                        self.pc += 1
                elif d == '.half':
                    for h in arg.split(','):
                        v = self.prep.parse_expr(h, self.symbols) & 0xFFFF
                        binary_data[self.pc] = v & 0xFF
                        binary_data[self.pc + 1] = (v >> 8) & 0xFF
                        emitted_bytes.extend([v & 0xFF, (v >> 8) & 0xFF])
                        self.pc += 2
                elif d == '.word':
                    for w in arg.split(','):
                        v = self.prep.parse_expr(w, self.symbols) & 0xFFFFFFFF
                        for i in range(4):
                            b = (v >> (i * 8)) & 0xFF
                            binary_data[self.pc + i] = b
                            emitted_bytes.append(b)
                        self.pc += 4
                elif d == '.asciz':
                    match = re.search(r'"(.*)"', arg)
                    raw_str = match.group(1) if match else ""
                    s = bytes(raw_str, 'utf-8').decode('unicode_escape').encode('latin1') + b'\x00'
                    for ch in s:
                        binary_data[self.pc] = ch
                        emitted_bytes.append(ch)
                        self.pc += 1

            else:
                inst_word = self.encode_instruction(line, self.pc, fname, lno)
                b0 = inst_word & 0xFF
                b1 = (inst_word >> 8) & 0xFF
                binary_data[self.pc] = b0
                binary_data[self.pc + 1] = b1
                emitted_bytes.extend([b0, b1])
                self.pc += 2

            max_addr = max(max_addr, self.pc)

            # Format listing line
            if emitted_bytes:
                hex_str = "".join(f"{b:02X}" for b in emitted_bytes[:4])
                listing_lines.append(f"{start_pc:08X}  {hex_str:<12} {lno:<5} {orig_line}")
            else:
                listing_lines.append(f"{start_pc:08X}  {'':<12} {lno:<5} {orig_line}")

        return binary_data, max_addr, listing_lines

    def parse_mem_operand(self, op_str, fname, lno):
        s = op_str.strip()
        if not (s.startswith('(') and s.endswith(')')):
            return None
        inner = s[1:-1].strip()
        mode = 'standard'
        if inner.startswith('++'):
            mode = 'pre_inc'
            reg_name = inner[2:].strip()
        elif inner.startswith('--'):
            mode = 'pre_dec'
            reg_name = inner[2:].strip()
        elif inner.endswith('++'):
            mode = 'post_inc'
            reg_name = inner[:-2].strip()
        elif inner.endswith('--'):
            mode = 'post_dec'
            reg_name = inner[:-2].strip()
        else:
            reg_name = inner
        r = self.parse_reg(reg_name, fname, lno)
        return r, mode

    def encode_instruction(self, line, pc, fname, lno):
        tokens = line.split(None, 1)
        mnem = tokens[0].upper()
        op_str = tokens[1].strip() if len(tokens) > 1 else ""
        ops = [o.strip() for o in op_str.split(',')] if op_str else []

        def get_r(idx):
            if idx >= len(ops):
                raise AssemblerError(f"Missing register operand {idx+1}", fname, lno)
            return self.parse_reg(ops[idx], fname, lno)

        def get_v(idx):
            if idx >= len(ops):
                raise AssemblerError(f"Missing immediate or labelif operand {idx+1}", fname, lno)
            return self.prep.parse_expr(ops[idx], self.symbols)

        # ---------------- Control Flow: BRANCH & JTBL ----------------
        if mnem == 'BRANCH':
            if len(ops) != 1:
                raise AssemblerError("BRANCH expects 1 operand: BRANCH Rr", fname, lno)
            rr = get_r(0)
            return (0xA4 << 8) | (rr << 4)

        if mnem == 'JTBL':
            if len(ops) != 1:
                raise AssemblerError("JTBL expects 1 operand: JTBL Rr", fname, lno)
            rr = get_r(0)
            return (0x81 << 8) | (rr << 4)

        # ---------------- Forward / Backward Branches ----------------
        for branch_pfx, is_backward in (('FBRA', False), ('BBRA', True)):
            if mnem == branch_pfx or mnem.startswith(branch_pfx + '.'):
                cond = mnem[len(branch_pfx):]

                if cond == '':
                    if len(ops) != 1:
                        raise AssemblerError(f"{mnem} expects 1 operand: {mnem} <label>", fname, lno)
                    tgt = get_v(0)
                    diff = (pc - tgt) if is_backward else (tgt - pc)
                    offset = diff // 2
                    if not (0 <= offset <= 255):
                        raise AssemblerError(f"Branch out of 8-bit unsigned range ({offset})", fname, lno)
                    base_op = 0xC0 if is_backward else 0xB0
                    return (base_op << 8) | (offset & 0xFF)

                if cond not in ('.Z', '.N', '.P', '.NZ'):
                    raise AssemblerError(f"Invalid branch condition: {cond}", fname, lno)

                cond_idx = {'.Z': 1, '.N': 2, '.P': 3, '.NZ': 4}[cond]

                if len(ops) != 2:
                    raise AssemblerError(f"{mnem} expects 2 operands: {mnem} Rr, <label>", fname, lno)

                r = get_r(0)
                tgt = get_v(1)
                diff = (pc - tgt) if is_backward else (tgt - pc)
                offset = diff // 2

                if r == 14 and (offset > 15):
                    if not (0 <= offset <= 255):
                        raise AssemblerError(f"Branch out of 8-bit immediate range ({offset})", fname, lno)
                    if is_backward:
                        op = 0xCB if cond == '.NZ' else (0xC6 + cond_idx)
                    else:
                        op = 0xBB if cond == '.NZ' else (0xB6 + cond_idx)
                    return (op << 8) | (offset & 0xFF)

                if not (0 <= offset <= 15):
                    raise AssemblerError(f"Branch out of 4-bit immediate range ({offset})", fname, lno)

                if is_backward:
                    op = 0xCA if cond == '.NZ' else (0xC3 + cond_idx)
                else:
                    op = 0xBA if cond == '.NZ' else (0xB3 + cond_idx)
                return (op << 8) | (r << 4) | (offset & 0xF)

        # ---------------- Relational Comparisons: SLT / SSLT ----------------
        if mnem in ('SLT', 'SSLT'):
            base_op = 0x90 if mnem == 'SLT' else 0x95
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (base_op << 8) | (rr << 4) | rl
            except AssemblerError:
                val = get_v(1)
                if rr == 14:
                    if 0 <= val <= 255:
                        return ((base_op + 3) << 8) | (val & 0xFF)
                    elif -255 <= val < 0:
                        return ((base_op + 4) << 8) | ((-val) & 0xFF)
                if 0 <= val <= 15:
                    return ((base_op + 1) << 8) | (rr << 4) | (val & 0xF)
                elif -15 <= val < 0:
                    return ((base_op + 2) << 8) | (rr << 4) | ((-val) & 0xF)
                raise AssemblerError(f"Immediate value {val} out of range for {mnem}", fname, lno)

        # ---------------- Memory Operations ----------------
        for width_name, base_ld, base_st in (('8', 0x10, 0x15), ('16', 0x20, 0x25), ('32', 0x30, 0x35)):
            if mnem in (f'LD{width_name}', f'ST{width_name}'):
                if len(ops) != 2:
                    raise AssemblerError(f"{mnem} expects 2 operands", fname, lno)
                mem_left = self.parse_mem_operand(ops[0], fname, lno)
                mem_right = self.parse_mem_operand(ops[1], fname, lno)
                mode_offsets = {'standard': 0, 'pre_inc': 1, 'post_inc': 2, 'pre_dec': 3, 'post_dec': 4}

                if mem_right is not None:
                    rr = self.parse_reg(ops[0], fname, lno)
                    rl, mode = mem_right
                    op = base_ld + mode_offsets[mode]
                    return (op << 8) | (rr << 4) | rl
                elif mem_left is not None:
                    rr, mode = mem_left
                    rl = self.parse_reg(ops[1], fname, lno)
                    op = base_st + mode_offsets[mode]
                    return (op << 8) | (rr << 4) | rl
                else:
                    raise AssemblerError(f"Memory access syntax requires parentheses: {line}", fname, lno)

        # ---------------- Register Loads & Immediate Loads ----------------
        if mnem == 'NOP':
            return 0x0000
        elif mnem == 'LD':
            if len(ops) == 2:
                rr = get_r(0)
                try:
                    rl = self.parse_reg(ops[1], fname, lno)
                    return (0x00 << 8) | (rr << 4) | rl
                except AssemblerError:
                    val = get_v(1)
                    if rr == 14 and (0 <= val <= 255):
                        return (0x02 << 8) | (val & 0xFF)
                    elif rr == 14 and (-255 <= val < 0):
                        return (0x04 << 8) | ((-val) & 0xFF)
                    elif 0 <= val <= 15:
                        return (0x01 << 8) | (rr << 4) | (val & 0xF)
                    elif -15 <= val < 0:
                        return (0x03 << 8) | (rr << 4) | ((-val) & 0xF)
                    raise AssemblerError(f"Immediate value {val} out of range for LD", fname, lno)
        elif mnem == 'PUSH4':
            rr = get_r(0)
            v = get_v(1)
            return (0x05 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'PUSH8':
            rr = get_r(0)
            v = get_v(1)
            return (0x06 << 8) | (v & 0xFF)

        # ---------------- Multipliers (0x78 - 0x7F) ----------------
        elif mnem in ('MULL', 'MULH', 'SMULH', 'MULHSU'):
            rr = get_r(0)
            base_lut = {'MULL': 0x78, 'MULH': 0x79, 'SMULH': 0x7A, 'MULHSU': 0x7B}
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (base_lut[mnem] << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                if not (0 <= v <= 15):
                    raise AssemblerError(f"Immediate multiplier {v} out of 4-bit unsigned range (0-15)", fname, lno)
                return ((base_lut[mnem] + 4) << 8) | (rr << 4) | (v & 0xF)

        # ---------------- Bit Operations & Bitfield (0x80 - 0x8A) ----------------
        elif mnem == 'BEXTR':
            rr = get_r(0)
            rl = self.parse_reg(ops[1], fname, lno)
            return (0x80 << 8) | (rr << 4) | rl
        elif mnem in ('BSET', 'BCLR', 'BINV', 'BGET'):
            rr = get_r(0)
            reg_lut = {'BSET': 0x83, 'BCLR': 0x85, 'BINV': 0x87, 'BGET': 0x89}
            imm_lut = {'BSET': 0x84, 'BCLR': 0x86, 'BINV': 0x88, 'BGET': 0x8A}
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (reg_lut[mnem] << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                if not (0 <= v <= 15):
                    raise AssemblerError(f"Bit index {v} out of 4-bit immediate range (0-15)", fname, lno)
                return (imm_lut[mnem] << 8) | (rr << 4) | (v & 0xF)

        # ---------------- Arithmetic & Logic ----------------
        elif mnem == 'ADD':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x40 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x44 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'SUB':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x41 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x45 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'DIV':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x42 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x46 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'MOD':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x43 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x47 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'SADD':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x50 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x54 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'SSUB':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x51 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x55 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'SDIV':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x52 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x56 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'SMOD':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x53 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x57 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'AND':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x66 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x6F << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'OR':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x67 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x70 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'XOR':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x68 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x71 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'SHIFTL':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x60 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x69 << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'SHIFTR':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x62 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x6B << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'ASHIFTR':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x63 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x6C << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'ROTL':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x64 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x6D << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'ROTR':
            rr = get_r(0)
            try:
                rl = self.parse_reg(ops[1], fname, lno)
                return (0x65 << 8) | (rr << 4) | rl
            except AssemblerError:
                v = get_v(1)
                return (0x6E << 8) | (rr << 4) | (v & 0xF)
        elif mnem == 'NOT':
            rr = get_r(0)
            return (0x72 << 8) | (rr << 4)
        elif mnem == 'NEZ':
            rr = get_r(0)
            return (0x73 << 8) | (rr << 4)
        elif mnem == 'SEXT8':
            rr = get_r(0)
            return (0x61 << 8) | (rr << 4)
        elif mnem == 'SEXT16':
            rr = get_r(0)
            return (0x6A << 8) | (rr << 4)
        elif mnem == 'CLZ':
            rr = get_r(0)
            return (0x82 << 8) | (rr << 4)
        elif mnem == 'TAS':
            if len(ops) != 2:
                raise AssemblerError("TAS expects 2 operands: TAS (Rr), Rl", fname, lno)
            mem_target = self.parse_mem_operand(ops[0], fname, lno)
            if mem_target is None:
                raise AssemblerError("TAS operand 1 must be (Rr)", fname, lno)
            rr, _ = mem_target
            rl = self.parse_reg(ops[1], fname, lno)
            return (0x8B << 8) | (rr << 4) | rl

        # ---------------- Extended Native ISA ----------------
        elif mnem == 'NEG':
            return (0x48 << 8) | (get_r(0) << 4)
        elif mnem == 'REV32':
            return (0x8C << 8) | (get_r(0) << 4)
        elif mnem in ('SEQ', 'SNE', 'SLE', 'SSLE'):
            lut = {'SEQ': 0x9A, 'SNE': 0x9B, 'SLE': 0x9C, 'SSLE': 0x9D}
            return (lut[mnem] << 8) | (get_r(0) << 4) | get_r(1)

        # ---------------- Control Flow: JMP, RJUMP, TRAP ----------------
        elif mnem == 'JMP':
            rr = get_r(0)
            rl = get_r(1) if len(ops) > 1 else 0
            return (0xA0 << 8) | (rr << 4) | rl
        elif mnem == 'RJUMP':
            rr = get_r(0)
            rl = get_r(1) if len(ops) > 1 else 0
            return (0xA1 << 8) | (rr << 4) | rl
        elif mnem == 'TRAP':
            try:
                rr = self.parse_reg(ops[0], fname, lno)
                return (0xA2 << 8) | (rr << 4)
            except AssemblerError:
                v = get_v(0)
                return (0xA3 << 8) | (v & 0xF)

        # ---------------- Context Exchange ----------------
        elif mnem == 'XCHG':
            rr = get_r(0)
            return (0xD0 << 8) | (rr << 4)
        elif mnem == 'XCHGALL':
            return 0xD100
        elif mnem == 'XCHGMOST':
            return 0xD200
        elif mnem == 'RBASE':
            # Support both immediate offset (RBASE <imm8>) and register (RBASE <Rr>)
            op0 = ops[0].strip().lower()
            if op0 in REG_MAP:
                rr = get_r(0)
                return (0xD4 << 8) | ((rr & 0xF) << 4)
            else:
                imm = get_v(0)
                return (0xD3 << 8) | (imm & 0xFF)

        # ---------------- FIFOs & MBOX ----------------
        elif mnem == 'FIFO.W':
            rr = get_r(0)
            chan = 0
            if len(ops) > 1:
                op1 = ops[1].strip().lower()
                chan = REG_MAP[op1] if op1 in REG_MAP else int(ops[1], 0)
            return (0xE1 << 8) | (rr << 4) | (chan & 0x0F)
        elif mnem == 'FIFO.R':
            rr = get_r(0)
            chan = 0
            if len(ops) > 1:
                op1 = ops[1].strip().lower()
                chan = REG_MAP[op1] if op1 in REG_MAP else int(ops[1], 0)
            return (0xE0 << 8) | (rr << 4) | (chan & 0x0F)
        elif mnem == 'FIFO.STAT':
            rr = get_r(0)
            rl = self.parse_reg(ops[1], fname, lno) if len(ops) > 1 else 0
            return (0xE2 << 8) | (rr << 4) | rl
        elif mnem == 'FIFO.TRYR':
            rr = get_r(0)
            rl = self.parse_reg(ops[1], fname, lno) if len(ops) > 1 else 0
            return (0xE3 << 8) | (rr << 4) | rl
        elif mnem == 'FIFO.TRYW':
            rr = get_r(0)
            rl = self.parse_reg(ops[1], fname, lno) if len(ops) > 1 else 0
            return (0xE4 << 8) | (rr << 4) | rl
        elif mnem == 'MBOX':
            rr = get_r(0)
            vec = 0
            if len(ops) > 1:
                op1 = ops[1].strip().lower()
                if op1 in REG_MAP:
                    vec = self.parse_reg(ops[1], fname, lno)
                else:
                    vec = int(ops[1], 0)
            return (0xE5 << 8) | (rr << 4) | (vec & 0x0F)

        raise AssemblerError(f"Unimplemented instruction mnemonic '{mnem}'", fname, lno)

def main():
    parser = argparse.ArgumentParser(description="Particle Two-Pass Macro Assembler")
    parser.add_argument("source", help="Source assembly file (.asm)")
    parser.add_argument("-I", "--include", action="append", default=[], help="Include directory")
    parser.add_argument("-o", "--output", default="a.out", help="Output file")
    parser.add_argument("-D", "--define", action="append", default=[], help="Define symbol")
    parser.add_argument("--format", choices=["bin", "hex"], default="bin", help="Output format")
    args = parser.parse_args()

    defines = {}
    for d in args.define:
        if '=' in d:
            k, v = d.split('=', 1)
            try:
                defines[k] = int(v, 0)
            except ValueError:
                defines[k] = v
        else:
            defines[d] = 1

    try:
        prep = Preprocessor(include_dirs=args.include, defines=defines)
        asm = ParticleAssembler(prep)
        bin_data, max_addr, listing_lines = asm.assemble(args.source)
    except AssemblerError as e:
        sys.stderr.write(f"\n[ERROR] {e}\n\n")
        sys.exit(1)
    except FileNotFoundError as e:
        sys.stderr.write(f"\n[ERROR] File not found: {e}\n\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"\n[INTERNAL ERROR] {e}\n\n")
        sys.exit(1)

    start_addr = 0x00000100
    size = max(0, max_addr - start_addr)
    out_bytes = bytearray(size)
    for addr, val in bin_data.items():
        if addr >= start_addr:
            out_bytes[addr - start_addr] = val

    out_dir = os.path.dirname(args.output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output, "wb") as f:
        f.write(out_bytes)

    # Automatic .lst listing generation
    lst_path = os.path.splitext(args.output)[0] + ".lst"
    with open(lst_path, "w", encoding="utf-8") as f:
        f.write(f"; Listing for {args.source}\n")
        f.write(f"; Total Emitted: {len(out_bytes)} bytes [{start_addr:08X}..{max_addr:08X}]\n\n")
        for ll in listing_lines:
            f.write(ll + "\n")
        f.write("\n; ------------------------------------------------------------------------------\n")
        f.write("; SYMBOL TABLE\n")
        f.write("; ------------------------------------------------------------------------------\n")
        for sym, addr in sorted(asm.symbols.items()):
            f.write(f"; {sym:<32} = 0x{addr:08X}\n")

    print(f"Assembly succeeded: {len(out_bytes)} bytes emitted [{start_addr:08X}..{max_addr:08X}]. Listing emitted to: {lst_path}")

if __name__ == "__main__":
    main()