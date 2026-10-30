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

REG_MAP = {f"r{i}": i for i in range(16)}
REG_MAP["sp"] = 15

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

    def parse_expr(self, expr_str, symbols):
        tokens = re.split(r'([+\-*/%<>&|^~() ]|\b0x[0-9a-fA-F]+\b|\b\d+\b|\b[a-zA-Z_]\w*\b)', str(expr_str))
        substituted = []
        for token in tokens:
            token_clean = token.strip()
            if not token_clean:
                continue
            if token_clean in symbols:
                substituted.append(str(symbols[token_clean]))
            elif token_clean in self.defines:
                substituted.append(str(self.defines[token_clean]))
            else:
                substituted.append(token_clean)
        expr_eval = "".join(substituted)
        try:
            return int(eval(expr_eval, {"__builtins__": None}, {}))
        except Exception as e:
            raise ValueError(f"Cannot evaluate expression '{expr_str}': {e}")

    def _split_args(self, arg_str):
        if not arg_str:
            return []
        args = []
        cur = []
        depth = 0
        for ch in arg_str:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            elif ch == ',' and depth == 0:
                args.append("".join(cur).strip())
                cur = []
                continue
            cur.append(ch)
        if cur:
            args.append("".join(cur).strip())
        return args

    def _find_include(self, inc_name, current_file):
        if os.path.exists(inc_name):
            return os.path.abspath(inc_name)

        cur_dir = os.path.dirname(os.path.abspath(current_file))
        cand = os.path.normpath(os.path.join(cur_dir, inc_name))
        if os.path.exists(cand):
            return cand

        for d in self.include_dirs:
            cand1 = os.path.normpath(os.path.join(d, inc_name))
            if os.path.exists(cand1):
                return cand1
            cand2 = os.path.normpath(os.path.join(d, os.path.basename(inc_name)))
            if os.path.exists(cand2):
                return cand2

        return None

    def process_file(self, filename):
        with open(filename, 'r', encoding='utf-8') as f:
            raw_lines = f.readlines()
        tagged_lines = [(line, os.path.abspath(filename), i + 1) for i, line in enumerate(raw_lines)]
        return self._preprocess_stream(tagged_lines)

    def _preprocess_stream(self, tagged_lines):
        out_lines = []
        cond_stack = []
        in_macro = False
        current_macro = None

        idx = 0
        while idx < len(tagged_lines):
            raw_line, fname, lno = tagged_lines[idx]
            idx += 1

            line = raw_line.strip()

            comment_idx = -1
            in_quote = False
            for i, ch in enumerate(line):
                if ch == '"':
                    in_quote = not in_quote
                elif ch in (';', '#') and not in_quote:
                    comment_idx = i
                    break
            clean = line[:comment_idx].strip() if comment_idx >= 0 else line

            if clean.startswith(('.ifdef', '.ifndef', '.if', '.else', '.endif')):
                parts = clean.split(None, 1)
                directive = parts[0].lower()
                arg = parts[1].strip() if len(parts) > 1 else ""

                if directive == '.ifdef':
                    is_active = (cond_stack[-1] if cond_stack else True) and (arg in self.defines)
                    cond_stack.append(is_active)
                    continue
                elif directive == '.ifndef':
                    is_active = (cond_stack[-1] if cond_stack else True) and (arg not in self.defines)
                    cond_stack.append(is_active)
                    continue
                elif directive == '.if':
                    parent_active = cond_stack[-1] if cond_stack else True
                    cond_val = False
                    if parent_active:
                        try:
                            val = self.parse_expr(arg, self.defines)
                            cond_val = (val != 0)
                        except Exception:
                            cond_val = False
                    cond_stack.append(parent_active and cond_val)
                    continue
                elif directive == '.else':
                    if not cond_stack:
                        raise AssemblerError(".else without matching .if", fname, lno)
                    parent_active = cond_stack[-2] if len(cond_stack) > 1 else True
                    cond_stack[-1] = parent_active and (not cond_stack[-1])
                    continue
                elif directive == '.endif':
                    if not cond_stack:
                        raise AssemblerError(".endif without matching .if", fname, lno)
                    cond_stack.pop()
                    continue

            if cond_stack and not cond_stack[-1]:
                continue

            if in_macro:
                if clean.lower().startswith('.endmacro'):
                    in_macro = False
                    self.macros[current_macro.name] = current_macro
                    current_macro = None
                else:
                    current_macro.lines.append(raw_line)
                continue

            if clean.lower().startswith('.macro'):
                parts = clean[len('.macro'):].strip().split(None, 1)
                name = parts[0]
                params = [p.strip() for p in parts[1].split(',')] if len(parts) > 1 else []
                current_macro = Macro(name, params, [], fname, lno)
                in_macro = True
                continue

            if clean.lower().startswith('.define'):
                parts = clean[len('.define'):].strip().split(None, 1)
                sym = parts[0]
                val_expr = parts[1] if len(parts) > 1 else "1"
                try:
                    val = self.parse_expr(val_expr, self.defines)
                except Exception:
                    val = val_expr
                self.defines[sym] = val
                out_lines.append((raw_line, fname, lno))
                continue

            if clean.lower().startswith('.include'):
                inc_part = clean[len('.include'):].strip().strip('"\'')
                inc_path = self._find_include(inc_part, fname)
                if not inc_path:
                    raise AssemblerError(f"Include file '{inc_part}' not found", fname, lno)
                with open(inc_path, 'r', encoding='utf-8') as inc_f:
                    inc_lines = inc_f.readlines()
                inc_tagged = [(l, inc_path, i + 1) for i, l in enumerate(inc_lines)]
                tagged_lines[idx:idx] = inc_tagged
                continue

            first_word = clean.split()[0] if clean.split() else ""
            if first_word in self.macros:
                m = self.macros[first_word]
                arg_str = clean[len(first_word):].strip()
                args = self._split_args(arg_str)
                if len(args) != len(m.params):
                    raise AssemblerError(f"Macro '{m.name}' expects {len(m.params)} args, got {len(args)}", fname, lno)

                self.macro_counter += 1
                local_suffix = f"__m{self.macro_counter}"

                expanded_tagged = []
                for m_line in m.lines:
                    exp = m_line
                    for param, arg in zip(m.params, args):
                        exp = re.sub(rf"%{re.escape(param)}\b", arg, exp)
                    exp = exp.replace("._label_%", f"._l{local_suffix}")
                    expanded_tagged.append((exp, fname, lno))

                tagged_lines[idx:idx] = expanded_tagged
                continue

            out_lines.append((raw_line, fname, lno))

        return out_lines

class Assembler:
    def __init__(self):
        self.symbols = {}

    def parse_reg(self, token, filename=None, lineno=None):
        clean = token.strip().lower()
        if clean not in REG_MAP:
            raise AssemblerError(f"Invalid register operand '{token}'", filename, lineno)
        return REG_MAP[clean]

    def parse_val(self, token, symbols, preprocessor, filename=None, lineno=None):
        clean = token.strip()
        try:
            return preprocessor.parse_expr(clean, symbols)
        except Exception:
            if clean in symbols:
                return symbols[clean]
            raise AssemblerError(f"Undefined symbol or invalid expression '{token}'", filename, lineno)

    def assemble(self, preprocessed_lines, preprocessor):
        self.symbols = {}
        addr = 0
        items = []

        # Pass 1: Symbol resolution
        for raw_line, fname, lno in preprocessed_lines:
            line = raw_line.strip()
            c_idx = -1
            in_q = False
            for i, ch in enumerate(line):
                if ch == '"':
                    in_q = not in_q
                elif ch in (';', '#') and not in_q:
                    c_idx = i
                    break
            clean = line[:c_idx].strip() if c_idx >= 0 else line

            while ":" in clean:
                lbl_part, remainder = clean.split(":", 1)
                lbl = lbl_part.strip()
                if not re.match(r'^[a-zA-Z_.$][a-zA-Z0-9_.$]*$', lbl):
                    break
                self.symbols[lbl] = addr
                clean = remainder.strip()

            if not clean:
                items.append((addr, None, None, raw_line, fname, lno, 0))
                continue

            parts = clean.split(None, 1)
            mnemonic = parts[0].upper()
            operands = parts[1].strip() if len(parts) > 1 else ""

            if mnemonic == '.ORG':
                addr = preprocessor.parse_expr(operands, self.symbols)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, 0))
            elif mnemonic == '.ALIGN':
                align_val = preprocessor.parse_expr(operands, self.symbols)
                pad = 0
                if align_val > 0 and (addr % align_val) != 0:
                    pad = align_val - (addr % align_val)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, pad))
                addr += pad
            elif mnemonic == '.BYTE':
                split_items = preprocessor._split_args(operands)
                length = len(split_items)
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic == '.HALF':
                split_items = preprocessor._split_args(operands)
                length = len(split_items) * 2
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic == '.WORD':
                split_items = preprocessor._split_args(operands)
                length = len(split_items) * 4
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic == '.ASCIZ':
                s = operands.strip('"') + '\0'
                length = len(s.encode('utf-8'))
                items.append((addr, mnemonic, operands, raw_line, fname, lno, length))
                addr += length
            elif mnemonic.startswith('.'):
                items.append((addr, mnemonic, operands, raw_line, fname, lno, 0))
            else:
                items.append((addr, mnemonic, operands, raw_line, fname, lno, 2))
                addr += 2

        # Pass 2: Binary code emission & listing construction
        min_addr = min((item[0] for item in items if item[6] > 0), default=0)
        max_addr = max((item[0] + item[6] for item in items), default=addr)
        image = bytearray(max_addr)
        listing_entries = []

        for cur_addr, mnemonic, operands, raw_line, fname, lno, size in items:
            emitted_bytes = b""
            if mnemonic and size > 0:
                if mnemonic == '.ALIGN':
                    emitted_bytes = b"\x00" * size
                    image[cur_addr:cur_addr+size] = emitted_bytes
                elif mnemonic == '.BYTE':
                    b_vals = [self.parse_val(v, self.symbols, preprocessor, fname, lno) & 0xFF 
                              for v in preprocessor._split_args(operands)]
                    emitted_bytes = bytes(b_vals)
                    image[cur_addr:cur_addr+len(emitted_bytes)] = emitted_bytes
                elif mnemonic == '.HALF':
                    h_vals = [self.parse_val(v, self.symbols, preprocessor, fname, lno) & 0xFFFF 
                              for v in preprocessor._split_args(operands)]
                    b_list = bytearray()
                    for hv in h_vals:
                        b_list.extend(hv.to_bytes(2, byteorder='little'))
                    emitted_bytes = bytes(b_list)
                    image[cur_addr:cur_addr+len(emitted_bytes)] = emitted_bytes
                elif mnemonic == '.WORD':
                    w_vals = [self.parse_val(v, self.symbols, preprocessor, fname, lno) & 0xFFFFFFFF 
                              for v in preprocessor._split_args(operands)]
                    b_list = bytearray()
                    for wv in w_vals:
                        b_list.extend(wv.to_bytes(4, byteorder='little'))
                    emitted_bytes = bytes(b_list)
                    image[cur_addr:cur_addr+len(emitted_bytes)] = emitted_bytes
                elif mnemonic == '.ASCIZ':
                    s = operands.strip('"') + '\0'
                    emitted_bytes = s.encode('utf-8')
                    image[cur_addr:cur_addr+len(emitted_bytes)] = emitted_bytes
                else:
                    code = self._encode_instruction(cur_addr, mnemonic, operands, self.symbols, preprocessor, fname, lno)
                    emitted_bytes = code.to_bytes(2, byteorder='little')
                    image[cur_addr:cur_addr+2] = emitted_bytes

            listing_entries.append((cur_addr, emitted_bytes, lno, raw_line.rstrip('\r\n')))

        return image, min_addr, max_addr, listing_entries

    def _encode_instruction(self, pc, mnem, ops_str, symbols, prep, fname, lno):
        ops = prep._split_args(ops_str) if ops_str else []

        def get_r(idx):
            return self.parse_reg(ops[idx], fname, lno)

        def get_v(idx):
            return self.parse_val(ops[idx], symbols, prep, fname, lno)

        # Immediate Group (0x00 - 0x06)
        if mnem == 'LD':
            if len(ops) == 2:
                if ops[1].strip().lower() in REG_MAP:
                    return (0x00 << 8) | (get_r(0) << 4) | get_r(1)
                r = get_r(0)
                v = get_v(1)
                if r == 14 and not (-15 <= v <= 15):
                    if 0 <= v <= 255:
                        return (0x02 << 8) | (v & 0xFF)
                    elif -256 <= v < 0:
                        return (0x04 << 8) | ((-v) & 0xFF)
                if 0 <= v <= 15:
                    return (0x01 << 8) | (r << 4) | (v & 0x0F)
                elif -15 <= v < 0:
                    return (0x03 << 8) | (r << 4) | ((-v) & 0x0F)
                elif r == 14:
                    if 0 <= v <= 255:
                        return (0x02 << 8) | (v & 0xFF)
                    elif -256 <= v < 0:
                        return (0x04 << 8) | ((-v) & 0xFF)
                raise AssemblerError(f"Immediate {v} out of range for LD instruction", fname, lno)

        elif mnem == 'PUSH4':
            return (0x05 << 8) | (get_r(0) << 4) | (get_v(1) & 0x0F)

        elif mnem == 'PUSH8':
            if get_r(0) != 14:
                raise AssemblerError("PUSH8 only targets register R14", fname, lno)
            return (0x06 << 8) | (get_v(1) & 0xFF)

        # Memory Group (0x10 - 0x39)
        for width_pfx, base_op in (('LD8', 0x10), ('LD16', 0x20), ('LD32', 0x30)):
            if mnem == width_pfx:
                dst = ops[0].strip()
                src = ops[1].strip()

                if dst.lower() in REG_MAP and src.startswith('(') and src.endswith(')'):
                    r = self.parse_reg(dst, fname, lno)
                    inner = src[1:-1].strip()
                    if inner.startswith('++'):
                        return ((base_op + 3) << 8) | (r << 4) | self.parse_reg(inner[2:], fname, lno)
                    elif inner.startswith('--'):
                        return ((base_op + 5) << 8) | (r << 4) | self.parse_reg(inner[2:], fname, lno)
                    elif inner.endswith('++'):
                        return ((base_op + 2) << 8) | (r << 4) | self.parse_reg(inner[:-2], fname, lno)
                    elif inner.endswith('--'):
                        return ((base_op + 4) << 8) | (r << 4) | self.parse_reg(inner[:-2], fname, lno)
                    else:
                        return (base_op << 8) | (r << 4) | self.parse_reg(inner, fname, lno)

                if dst.startswith('(') and dst.endswith(')') and src.lower() in REG_MAP:
                    l = self.parse_reg(src, fname, lno)
                    inner = dst[1:-1].strip()
                    if inner.startswith('++'):
                        return ((base_op + 9) << 8) | (self.parse_reg(inner[2:], fname, lno) << 4) | l
                    elif inner.startswith('--'):
                        return ((base_op + 6) << 8) | (self.parse_reg(inner[2:], fname, lno) << 4) | l
                    elif inner.endswith('++'):
                        return ((base_op + 8) << 8) | (self.parse_reg(inner[:-2], fname, lno) << 4) | l
                    elif inner.endswith('--'):
                        return ((base_op + 7) << 8) | (self.parse_reg(inner[:-2], fname, lno) << 4) | l
                    else:
                        return ((base_op + 1) << 8) | (self.parse_reg(inner, fname, lno) << 4) | l

        # Arithmetic & Shifts (0x40 - 0x7F)
        arith_reg_imm = {
            'ADD': (0x40, 0x44), 'SUB': (0x41, 0x45), 'DIV': (0x42, 0x46), 'MOD': (0x43, 0x47),
            'SADD': (0x50, 0x54), 'SSUB': (0x51, 0x55), 'SDIV': (0x52, 0x56), 'SMOD': (0x53, 0x57),
            'SHIFTL': (0x60, 0x69), 'SHIFTR': (0x62, 0x6B), 'ASHIFTR': (0x63, 0x6C),
            'ROTL': (0x64, 0x6D), 'ROTR': (0x65, 0x6E),
            'AND': (0x66, 0x6F), 'OR': (0x70, 0x70), 'XOR': (0x68, 0x71),
            'MULL': (0x78, 0x7C), 'MULH': (0x79, 0x7D), 'SMULH': (0x7A, 0x7E), 'MULHSU': (0x7B, 0x7F)
        }

        if mnem in arith_reg_imm:
            r_op, imm_op = arith_reg_imm[mnem]
            r = get_r(0)
            if ops[1].strip().lower() in REG_MAP:
                return (r_op << 8) | (r << 4) | get_r(1)
            else:
                return (imm_op << 8) | (r << 4) | (get_v(1) & 0x0F)

        if mnem == 'SEXT8':
            return (0x61 << 8) | get_r(0)
        if mnem == 'SEXT16':
            return (0x6A << 8) | get_r(0)

        # Bit Operations & Miscellaneous (0x80 - 0x8B)
        bit_ops = {'BSET': (0x83, 0x84), 'BCLR': (0x85, 0x86), 'BINV': (0x87, 0x88), 'BGET': (0x89, 0x8A)}
        if mnem in bit_ops:
            r_op, imm_op = bit_ops[mnem]
            r = get_r(0)
            if ops[1].strip().lower() in REG_MAP:
                return (r_op << 8) | (r << 4) | get_r(1)
            else:
                return (imm_op << 8) | (r << 4) | (get_v(1) & 0x0F)

        if mnem == 'BEXTR':
            return (0x80 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem == 'JTBL':
            return (0x81 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem == 'CLZ':
            return (0x82 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem == 'TAS':
            dst = ops[0].strip()
            if dst.startswith('(') and dst.endswith(')'):
                r = self.parse_reg(dst[1:-1], fname, lno)
                l = get_r(1)
                return (0x8B << 8) | (r << 4) | l

        # Comparisons (0x90 - 0x99)
        if mnem in ('SLT', 'SSLT'):
            is_signed = (mnem == 'SSLT')
            r = get_r(0)
            if ops[1].strip().lower() in REG_MAP:
                op = 0x95 if is_signed else 0x90
                return (op << 8) | (r << 4) | get_r(1)
            v = get_v(1)
            if r == 14 and (v > 15 or v < -15):
                if v >= 0:
                    op = 0x98 if is_signed else 0x93
                    return (op << 8) | (v & 0xFF)
                else:
                    op = 0x99 if is_signed else 0x94
                    return (op << 8) | ((-v) & 0xFF)
            if v >= 0:
                op = 0x96 if is_signed else 0x91
                return (op << 8) | (r << 4) | (v & 0x0F)
            else:
                op = 0x97 if is_signed else 0x92
                return (op << 8) | (r << 4) | ((-v) & 0x0F)

        # Control Flow (0xA0 - 0xA3)
        if mnem == 'JMP':
            rr = get_r(0)
            rl = get_r(1) if len(ops) > 1 else 0
            return (0xA0 << 8) | (rr << 4) | rl

        if mnem == 'RJUMP':
            rr = get_r(0)
            rl = get_r(1) if len(ops) > 1 else 0
            return (0xA1 << 8) | (rr << 4) | rl

        if mnem == 'TRAP':
            if ops[0].strip().lower() in REG_MAP:
                return (0xA2 << 8) | get_r(0)
            else:
                return (0xA3 << 8) | (get_v(0) & 0x0F)

        # Branches (0xB0 - 0xC9)
        for branch_pfx, is_backward in (('FBRA', False), ('BBRA', True)):
            if mnem.startswith(branch_pfx):
                cond = mnem[len(branch_pfx):]
                if cond == '':
                    tgt = get_v(0)
                    diff = (pc - tgt) if is_backward else (tgt - pc)
                    offset = diff // 2
                    if not (0 <= offset <= 255):
                        raise AssemblerError(f"Branch target out of 8-bit displacement range (offset={offset})", fname, lno)
                    op = 0xC0 if is_backward else 0xB0
                    return (op << 8) | (offset & 0xFF)
                
                cond_idx = {'.Z': 1, '.N': 2, '.P': 3}[cond]
                r = get_r(0)
                if ops[1].strip().lower() in REG_MAP:
                    base_op = 0xC0 if is_backward else 0xB0
                    return ((base_op + cond_idx) << 8) | (r << 4) | get_r(1)
                else:
                    tgt = get_v(1)
                    diff = (pc - tgt) if is_backward else (tgt - pc)
                    offset = diff // 2
                    if r == 14 and (offset > 15):
                        if not (0 <= offset <= 255):
                            raise AssemblerError(f"R14 branch out of 8-bit range ({offset})", fname, lno)
                        base_op = 0xC6 if is_backward else 0xB6
                        return ((base_op + cond_idx) << 8) | (offset & 0xFF)
                    if not (0 <= offset <= 15):
                        raise AssemblerError(f"Branch out of 4-bit immediate range ({offset})", fname, lno)
                    base_op = 0xC3 if is_backward else 0xB3
                    return ((base_op + cond_idx) << 8) | (r << 4) | (offset & 0x0F)

        # Shadow Banks (0xD0 - 0xD2)
        if mnem == 'XCHG':
            return (0xD0 << 8) | get_r(0)
        if mnem == 'XCHGALL':
            return (0xD1 << 8)
        if mnem == 'XCHGMOST':
            return (0xD2 << 8)

        # FIFO & MBOX Group (0xE0 - 0xE9)
        fifo_map = {'FIFO.R': (0xE0, 0xE1), 'FIFO.W': (0xE2, 0xE3), 'FIFO.STAT': (0xE4, 0xE5)}
        if mnem in fifo_map:
            r_op, imm_op = fifo_map[mnem]
            r = get_r(0)
            if ops[1].strip().lower() in REG_MAP:
                return (r_op << 8) | (r << 4) | get_r(1)
            else:
                return (imm_op << 8) | (r << 4) | (get_v(1) & 0x0F)

        if mnem == 'FIFO.TRYR':
            return (0xE6 << 8) | (get_r(0) << 4) | get_r(1)
        if mnem == 'FIFO.TRYW':
            return (0xE7 << 8) | (get_r(0) << 4) | get_r(1)

        if mnem == 'MBOX':
            r = get_r(0)
            if ops[1].strip().lower() in REG_MAP:
                return (0xE8 << 8) | (r << 4) | get_r(1)
            else:
                return (0xE9 << 8) | (r << 4) | (get_v(1) & 0x0F)

        raise AssemblerError(f"Unknown or unencodable mnemonic '{mnem}'", fname, lno)


def write_listing(lst_filename, listing_entries, symbols):
    with open(lst_filename, "w", encoding="utf-8") as f:
        f.write("; ==============================================================================\n")
        f.write(f"; Particle Assembler Listing File: {os.path.basename(lst_filename)}\n")
        f.write("; ==============================================================================\n")
        f.write("; ADDR      HEX CODE     LINE  SOURCE\n")
        f.write("; ------------------------------------------------------------------------------\n")

        for addr, b_data, lno, src in listing_entries:
            if b_data:
                words = []
                for i in range(0, len(b_data), 2):
                    if i + 1 < len(b_data):
                        hw = b_data[i] | (b_data[i+1] << 8)
                        words.append(f"{hw:04X}")
                    else:
                        words.append(f"{b_data[i]:02X}  ")
                hex_str = " ".join(words[:2])
                addr_str = f"{addr:08X}"
            else:
                hex_str = ""
                addr_str = "        "

            f.write(f"{addr_str}  {hex_str:<12} {lno:5d}  {src}\n")

        f.write("\n; ------------------------------------------------------------------------------\n")
        f.write("; SYMBOL TABLE\n")
        f.write("; ------------------------------------------------------------------------------\n")
        for sym, s_addr in sorted(symbols.items()):
            f.write(f"; {sym:<32} = 0x{s_addr:08X}\n")


def main():
    parser = argparse.ArgumentParser(description="Particle Two-Pass Macro Assembler")
    parser.add_argument("source", help="Input assembly file (.asm / .s)")
    parser.add_argument("-o", "--output", default="a.out", help="Output file")
    parser.add_argument("-I", "--include", action="append", default=[], help="Additional include directory")
    parser.add_argument("-D", "--define", action="append", default=[], help="Predefine symbol (KEY[=VALUE])")
    parser.add_argument("--format", choices=["bin", "hex", "c"], default="bin", help="Output emission format")
    args = parser.parse_args()

    out_dir = os.path.dirname(args.output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    defs = {}
    for d in args.define:
        if "=" in d:
            k, v = d.split("=", 1)
            defs[k.strip()] = int(v.strip(), 0) if v.strip().isdigit() else v.strip()
        else:
            defs[d.strip()] = 1

    prep = Preprocessor(include_dirs=args.include, defines=defs)
    asm = Assembler()

    try:
        lines = prep.process_file(args.source)
        image, min_addr, max_addr, listing_entries = asm.assemble(lines, prep)
        
        trimmed = image[min_addr:max_addr]
        if args.format == "bin":
            with open(args.output, "wb") as f:
                f.write(trimmed)
        elif args.format == "hex":
            with open(args.output, "w") as f:
                for i in range(0, len(trimmed), 2):
                    hw = int.from_bytes(trimmed[i:i+2], byteorder='little')
                    f.write(f"{hw:04X}\n")
        elif args.format == "c":
            with open(args.output, "w") as f:
                f.write(f"const uint16_t particle_rom[{len(trimmed)//2}] = {{\n  ")
                for i in range(0, len(trimmed), 2):
                    hw = int.from_bytes(trimmed[i:i+2], byteorder='little')
                    f.write(f"0x{hw:04x}, ")
                    if (i // 2 + 1) % 8 == 0:
                        f.write("\n  ")
                f.write("\n};\n")

        base_name, _ = os.path.splitext(args.output)
        lst_path = base_name + ".lst"
        write_listing(lst_path, listing_entries, asm.symbols)

        print(f"Assembly succeeded: {len(trimmed)} bytes emitted [{hex(min_addr)}..{hex(max_addr)}].")
        print(f"Listing emitted to: {lst_path}")
    except AssemblerError as e:
        print(e, file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()