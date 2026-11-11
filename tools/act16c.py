#!/usr/bin/env python3
"""
================================================================================
ACT16 Systems Compiler (act16c.py)
Target: Particle 32-bit RISC Architecture (16-bit Compact Instruction Set)
================================================================================
"""

import sys
import os
import re
import argparse

# ------------------------------------------------------------------------------
# Lexer & Tokenizer
# ------------------------------------------------------------------------------

TOKEN_TYPES = [
    ('PREPROC',   r'(?:[#.]\s*(?:define|include|ifdef|ifndef|if|else|endif)\b(?:[^\n\\]|\\.?)*)'),
    ('COMMENT',   r'//[^\n]*|/\*[\s\S]*?\*/'),
    ('HEX',       r'0x[0-9a-fA-F]+'),
    ('INT',       r'\d+'),
    ('STRING',    r'"(?:\\.|[^"\\])*"'),
    ('CHAR',      r"'(?:\\.|[^'\\])'"),
    ('KEYWORD',   r'\b(?:string|u8|s8|u16|s16|u32|s32|void|const|if|else|while|for|return|break|continue|asm|switch|case|default|type|fn|inline|yield|wait_until|import|enum|verify|volatile|sizeof)\b'),
    ('IDENT',     r'[a-zA-Z_]\w*'),
    ('OP_ARROW',  r'->'),
    ('OP_EQ',     r'=='),
    ('OP_NE',     r'!='),
    ('OP_LE',     r'<='),
    ('OP_GE',     r'>='),
    ('COMPOUND_ASSIGN', r'\+=|-=|\*=|/=|&=|\|=|\^=|<<=|>>='),
    ('OP_SHL',    r'<<'),
    ('OP_SHR',    r'>>'),
    ('OP_AND',    r'&&'),
    ('OP_OR',     r'\|\|'),
    ('OP_RANGE',  r'\.\.'),
    ('OP',        r'[+\-*/%&|^~<>=!]'),
    ('PUNCT',     r'[:;,(){}\[\]@.]'),
    ('SPACE',     r'\s+'),
]
TOKEN_REGEX = '|'.join(f'(?P<{name}>{pattern})' for name, pattern in TOKEN_TYPES)

class Token:
    def __init__(self, type_, val, lineno, col, fname="<stdin>"):
        self.type = type_
        self.val = val
        self.lineno = lineno
        self.col = col
        self.fname = fname

    def __repr__(self):
        return f"Token({self.type}, {repr(self.val)}, {self.fname}:{self.lineno}:{self.col})"

def tokenize(source_text, fname="<stdin>"):
    tokens = []
    lineno = 1
    line_start = 0
    for mo in re.finditer(TOKEN_REGEX, source_text):
        kind = mo.lastgroup
        val = mo.group()
        col = mo.start() - line_start
        if kind == 'SPACE':
            lineno += val.count('\n')
            if '\n' in val:
                line_start = mo.end() - (len(val) - val.rfind('\n') - 1)
            continue
        elif kind == 'COMMENT':
            lineno += val.count('\n')
            continue
        tokens.append(Token(kind, val, lineno, col, fname))
    tokens.append(Token('EOF', '', lineno, 0, fname))
    return tokens

# ------------------------------------------------------------------------------
# Preprocessor (Includes, Macros, Conditionals)
# ------------------------------------------------------------------------------

def eval_preproc_expr(expr_str, defines):
    tokens = re.split(r'([+\-*/%<>&|^~() ]|\b0x[0-9a-fA-F]+\b|\b\d+\b|\b[a-zA-Z_]\w*\b)', expr_str)
    substituted = []
    for tok in tokens:
        clean = tok.strip()
        if not clean:
            continue
        if clean in defines:
            substituted.append(str(defines[clean]))
        else:
            substituted.append(clean)
    expr_eval = "".join(substituted)
    try:
        return int(eval(expr_eval, {"__builtins__": None}, {})) != 0
    except Exception:
        return False

def run_preprocessor(tokens, defines, current_file="<stdin>", func_macros=None):
    if func_macros is None:
        func_macros = {}
    out = []
    cond_stack = []

    i = 0
    n = len(tokens)
    while i < n:
        t = tokens[i]

        if t.type == 'PREPROC':
            line = t.val.strip()
            if line.startswith(('.', '#')):
                line = line[1:].strip()

            parts = line.split(None, 1)
            directive = parts[0].lower()
            arg = parts[1].strip() if len(parts) > 1 else ""

            if directive == 'define':
                m_def = re.match(r'^([a-zA-Z_]\w*)(?:\(([^)]*)\))?(?:\s+([\s\S]+))?$', arg)
                if m_def:
                    d_name = m_def.group(1)
                    d_params = m_def.group(2)
                    d_val = m_def.group(3) or ""
                    d_val = re.sub(r'\\\s*\n?', ' ', d_val).strip()

                    if d_params is not None:
                        params = [p.strip() for p in d_params.split(',') if p.strip()]
                        func_macros[d_name] = (params, d_val)
                    else:
                        if d_val:
                            if d_val.startswith(('0x', '0X')):
                                try:
                                    defines[d_name] = int(d_val, 16)
                                except ValueError:
                                    defines[d_name] = d_val
                            elif d_val.lstrip('-').isdigit():
                                defines[d_name] = int(d_val)
                            else:
                                defines[d_name] = d_val
                        else:
                            defines[d_name] = 1
                i += 1
                continue

            elif directive == 'include':
                m = re.search(r'["<]([^">]+)[">]', arg)
                if not m:
                    raise SyntaxError(f"{t.fname}:{t.lineno}:{t.col}: Malformed #include directive '{line}'")
                inc_file = m.group(1)
                search_paths = [
                    inc_file,
                    os.path.join(os.path.dirname(t.fname), inc_file),
                    os.path.join("lib", inc_file),
                    os.path.join("..", inc_file)
                ]
                found_path = None
                for p in search_paths:
                    if os.path.isfile(p):
                        found_path = os.path.abspath(p)
                        break
                if not found_path:
                    raise FileNotFoundError(f"{t.fname}:{t.lineno}:{t.col}: Included file '{inc_file}' not found")
                with open(found_path, 'r', encoding='utf-8') as f_inc:
                    inc_text = f_inc.read()
                inc_tokens = tokenize(inc_text, fname=found_path)
                inc_filtered = run_preprocessor(inc_tokens, defines, current_file=found_path, func_macros=func_macros)
                if inc_filtered and inc_filtered[-1].type == 'EOF':
                    inc_filtered = inc_filtered[:-1]
                out.extend(inc_filtered)
                i += 1
                continue

            elif directive == 'ifdef':
                active = (cond_stack[-1] if cond_stack else True) and (arg in defines)
                cond_stack.append(active)
            elif directive == 'ifndef':
                active = (cond_stack[-1] if cond_stack else True) and (arg not in defines)
                cond_stack.append(active)
            elif directive == 'if':
                parent = cond_stack[-1] if cond_stack else True
                cond_val = eval_preproc_expr(arg, defines) if parent else False
                cond_stack.append(parent and cond_val)
            elif directive == 'else':
                if not cond_stack:
                    raise SyntaxError(f"{t.fname}:{t.lineno}:{t.col}: else without matching conditional block")
                parent = cond_stack[-2] if len(cond_stack) > 1 else True
                cond_stack[-1] = parent and (not cond_stack[-1])
            elif directive == 'endif':
                if not cond_stack:
                    raise SyntaxError(f"{t.fname}:{t.lineno}:{t.col}: endif without matching conditional block")
                cond_stack.pop()
            i += 1
            continue

        if cond_stack and not cond_stack[-1]:
            i += 1
            continue

        if t.type == 'IDENT' and t.val in func_macros and (i + 1 < n) and tokens[i+1].val == '(':
            macro_name = t.val
            params, body_template = func_macros[macro_name]
            j = i + 2
            paren_depth = 1
            arg_tokens = [[]]
            while j < n and paren_depth > 0:
                tk = tokens[j]
                if tk.val == '(':
                    paren_depth += 1
                    arg_tokens[-1].append(tk)
                elif tk.val == ')':
                    paren_depth -= 1
                    if paren_depth > 0:
                        arg_tokens[-1].append(tk)
                elif tk.val == ',' and paren_depth == 1:
                    arg_tokens.append([])
                else:
                    arg_tokens[-1].append(tk)
                j += 1

            args_map = {}
            for idx, p_name in enumerate(params):
                args_map[p_name] = "".join(tok.val for tok in arg_tokens[idx]) if idx < len(arg_tokens) else ""

            expanded_text = body_template
            for p_name, arg_val in args_map.items():
                expanded_text = re.sub(r'\b' + re.escape(p_name) + r'\b', arg_val, expanded_text)

            sub_tokens = tokenize(expanded_text, fname=t.fname)
            if sub_tokens and sub_tokens[-1].type == 'EOF':
                sub_tokens = sub_tokens[:-1]
            out.extend(sub_tokens)
            i = j
            continue

        if t.type == 'IDENT':
            if t.val in ('__LINE__', '__line__'):
                out.append(Token('INT', str(t.lineno), t.lineno, t.col, t.fname))
                i += 1
                continue
            elif t.val in ('__FILE__', '__file__'):
                out.append(Token('STRING', f'"{t.fname}"', t.lineno, t.col, t.fname))
                i += 1
                continue
            elif t.val in defines:
                val = defines[t.val]
                if isinstance(val, int):
                    out.append(Token('INT', str(val), t.lineno, t.col, t.fname))
                    i += 1
                    continue

        out.append(t)
        i += 1

    return out

# ------------------------------------------------------------------------------
# AST Nodes
# ------------------------------------------------------------------------------

class ASTNode: pass


class ImportNode(ASTNode):
    def __init__(self, path):
        self.path = path

class ArrayDeclNode(ASTNode):
    def __init__(self, elem_type, name, dim, bound_addr=None):
        self.elem_type = elem_type
        self.name = name
        self.dim = dim
        self.bound_addr = bound_addr

class ArrayAccessNode(ASTNode):
    def __init__(self, base, index):
        self.base = base
        self.index = index

class SliceNode(ASTNode):
    def __init__(self, base, start_expr, end_expr):
        self.base = base
        self.start_expr = start_expr
        self.end_expr = end_expr

class CompoundAssignNode(ASTNode):
    def __init__(self, op, lhs, rhs):
        self.op = op
        self.lhs = lhs
        self.rhs = rhs

class YieldNode(ASTNode):
    def __init__(self, task_ref, step_const):
        self.task_ref = task_ref
        self.step_const = step_const

class WaitUntilNode(ASTNode):
    def __init__(self, task_ref, step_const, cond):
        self.task_ref = task_ref
        self.step_const = step_const
        self.cond = cond

class FnTypeNode(ASTNode):
    def __init__(self, name, param_types, ret_type):
        self.name = name
        self.param_types = param_types
        self.ret_type = ret_type


class EnumDeclNode(ASTNode):
    def __init__(self, name, members):
        self.name = name
        self.members = members

class VerifyNode(ASTNode):
    def __init__(self, cond, msg, token=None):
        self.cond = cond
        self.msg = msg
        self.token = token

class SizeofNode(ASTNode):
    def __init__(self, target):
        self.target = target

class ProgramNode(ASTNode):
    def __init__(self, decls):
        self.decls = decls

class TypeDefNode(ASTNode):
    def __init__(self, name, fields):
        self.name = name
        self.fields = fields

StructDefNode = TypeDefNode

class VarDeclNode(ASTNode):
    def __init__(self, type_name, is_ptr, name, init_expr=None, is_const=False, is_volatile=False):
        self.type_name = type_name
        self.is_ptr = is_ptr
        self.name = name
        self.init_expr = init_expr
        self.is_const = is_const
        self.is_volatile = is_volatile

class FuncDeclNode(ASTNode):
    def __init__(self, ret_type, ret_ptr, name, params, body, is_inline=False):
        self.ret_type = ret_type
        self.ret_ptr = ret_ptr
        self.name = name
        self.params = params
        self.body = body
        self.is_inline = is_inline

class BlockNode(ASTNode):
    def __init__(self, stmts):
        self.stmts = stmts

class IfNode(ASTNode):
    def __init__(self, cond, then_body, else_body=None):
        self.cond = cond
        self.then_body = then_body
        self.else_body = else_body

class CaseLabelNode(ASTNode):
    def __init__(self, expr, label=None):
        self.expr = expr
        self.val = None
        self.label = label

class DefaultLabelNode(ASTNode):
    def __init__(self, label=None):
        self.label = label

class SwitchNode(ASTNode):
    def __init__(self, expr, body):
        self.expr = expr
        self.body = body

class WhileNode(ASTNode):
    def __init__(self, cond, body):
        self.cond = cond
        self.body = body

class ForRangeNode(ASTNode):
    def __init__(self, var_type, var_name, start_expr, end_expr, body):
        self.var_type = var_type
        self.var_name = var_name
        self.start_expr = start_expr
        self.end_expr = end_expr
        self.body = body

class BreakNode(ASTNode): pass

class AsmNode(ASTNode):
    def __init__(self, asm_text):
        self.asm_text = asm_text

class TupleTarget:
    def __init__(self, name=None, type_name=None, is_ptr=False, is_wildcard=False):
        self.name = name
        self.type_name = type_name
        self.is_ptr = is_ptr
        self.is_wildcard = is_wildcard

class TupleReturnNode(ASTNode):
    def __init__(self, exprs):
        self.exprs = exprs

class TupleAssignNode(ASTNode):
    def __init__(self, targets, expr):
        self.targets = targets
        self.expr = expr

class ReturnNode(ASTNode):
    def __init__(self, expr=None):
        self.expr = expr

class ExprStmtNode(ASTNode):
    def __init__(self, expr):
        self.expr = expr

class BinaryOpNode(ASTNode):
    def __init__(self, op, left, right):
        self.op = op
        self.left = left
        self.right = right

class UnaryOpNode(ASTNode):
    def __init__(self, op, operand):
        self.op = op
        self.operand = operand

class MemberAccessNode(ASTNode):
    def __init__(self, expr, member):
        self.expr = expr
        self.member = member

class StringLitNode(ASTNode):
    def __init__(self, val):
        self.val = val

class TrapNode(ASTNode):
    def __init__(self, trap_num):
        self.trap_num = trap_num

class CallNode(ASTNode):
    def __init__(self, name, args):
        self.name = name
        self.args = args

class VarAccessNode(ASTNode):
    def __init__(self, name):
        self.name = name

class IntLitNode(ASTNode):
    def __init__(self, val):
        self.val = val

class HeapAllocNode(ASTNode):
    def __init__(self, type_name, args=None):
        self.type_name = type_name
        self.args = args or []

class HeapArrayAllocNode(ASTNode):
    def __init__(self, type_name, count_expr):
        self.type_name = type_name
        self.count_expr = count_expr

class HeapStringAllocNode(ASTNode):
    def __init__(self, cap_expr):
        self.cap_expr = cap_expr

class HeapFreeNode(ASTNode):
    def __init__(self, expr):
        self.expr = expr

class HeapArrayFreeNode(ASTNode):
    def __init__(self, expr):
        self.expr = expr

class HeapArrayResizeNode(ASTNode):
    def __init__(self, expr, new_len_expr):
        self.expr = expr
        self.new_len_expr = new_len_expr

class ExistsNode(ASTNode):
    def __init__(self, expr):
        self.expr = expr

# ------------------------------------------------------------------------------
# Parser
# ------------------------------------------------------------------------------

class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0
        self.known_types = set()

    def _forbid_aggregate_ptr(self, t_name):
        clean_t = t_name.strip()
        if clean_t in self.known_types:
            raise SyntaxError(f"act16c: aggregate types are implicit references; pointer syntax '*' is invalid for type '{clean_t}'")

    def peek(self):
        return self.tokens[self.pos]

    def consume(self, expected_type=None, expected_val=None):
        t = self.peek()
        if expected_type and t.type != expected_type:
            raise SyntaxError(f"{t.fname}:{t.lineno}:{t.col}: Expected {expected_type}, got {t.type} ('{t.val}')")
        if expected_val and t.val != expected_val:
            raise SyntaxError(f"{t.fname}:{t.lineno}:{t.col}: Expected '{expected_val}', got '{t.val}'")
        self.pos += 1
        return t

    def match(self, val):
        if self.peek().val == val:
            return self.consume()
        return None

    def parse_program(self):
        decls = []
        while self.peek().type != 'EOF':
            decls.append(self.parse_top_level())
        return ProgramNode(decls)

    def parse_type(self):
        t = self.peek()
        if t.val == 'type':
            self.consume()
            s_name = self.consume('IDENT').val
            return s_name
        elif t.val in ('u8', 's8', 'u16', 's16', 'u32', 's32', 'string', 'void'):
            return self.consume().val
        elif t.type == 'IDENT':
            return self.consume().val
        raise SyntaxError(f"{t.fname}:{t.lineno}:{t.col}: Expected type specifier, got '{t.val}'")

    def parse_import(self):
        self.consume('KEYWORD', 'import')
        tok = self.consume('STRING')
        raw_path = tok.val[1:-1]
        if self.peek().val == ';':
            self.consume('PUNCT', ';')
        return ImportNode(raw_path)

    def parse_enum(self):
        tok = self.consume('KEYWORD', 'enum')
        name = self.consume('IDENT').val
        self.consume('PUNCT', '{')
        members = []
        cur_val = 0
        while self.peek().val != '}' and self.peek().type != 'EOF':
            m_name = self.consume('IDENT').val
            if self.peek().val == '=':
                self.consume('OP', '=')
                expr = self.parse_expr()
                members.append((m_name, expr))
            else:
                members.append((m_name, None))
            if self.peek().val == ',':
                self.consume('PUNCT', ',')
        self.consume('PUNCT', '}')
        if self.peek().val == ';':
            self.consume('PUNCT', ';')
        return EnumDeclNode(name, members)

    def parse_verify(self):
        tok = self.consume('KEYWORD', 'verify')
        self.consume('PUNCT', '(')
        cond = self.parse_expr()
        self.consume('PUNCT', ',')
        msg_tok = self.consume('STRING')
        msg = msg_tok.val.strip('"\'')
        self.consume('PUNCT', ')')
        self.consume('PUNCT', ';')
        return VerifyNode(cond, msg, tok)

    def parse_top_level(self):
        if self.peek().val == 'import':
            return self.parse_import()
        if self.peek().val == 'enum':
            return self.parse_enum()
        if self.peek().val == 'verify':
            return self.parse_verify()
        is_volatile = False
        if self.peek().val == 'volatile':
            self.consume('KEYWORD', 'volatile')
            is_volatile = True
        is_inline = False
        if self.peek().val == 'inline':
            self.consume()
            is_inline = True

        # type Name { ... }; or type Name = fn(...) -> RetType;
        if self.peek().val == 'struct':
            t = self.peek()
            raise SyntaxError(f"{t.fname}:{t.lineno}:{t.col}: 'struct' is deprecated; use 'type {self.tokens[self.pos+1].val} {{ ... }}' instead")

        if self.peek().val == 'type' and self.tokens[self.pos+1].type == 'IDENT' and self.tokens[self.pos+2].val in ('{', '='):
            kind_tok = self.consume()
            t_name = self.consume('IDENT').val
            if self.peek().val == '=':
                self.consume()
                self.consume('KEYWORD', 'fn')
                self.consume('PUNCT', '(')
                fn_params = []
                if self.peek().val != ')':
                    while True:
                        fn_params.append(self.parse_type())
                        if self.peek().val == ',':
                            self.consume()
                        else:
                            break
                self.consume('PUNCT', ')')
                ret_t = 'void'
                if self.peek().val == '->':
                    self.consume('OP_ARROW', '->')
                    ret_t = self.parse_type()
                if self.peek().val == ';':
                    self.consume('PUNCT', ';')
                return FnTypeNode(t_name, fn_params, ret_t)
            elif self.peek().val == '{':
                self.consume('PUNCT', '{')
                fields = []
                while self.peek().val != '}' and self.peek().type != 'EOF':
                    f_type = self.parse_type()
                    if self.peek().val == ";":
                        self.consume("PUNCT", ";")
                        if f_type in ("u8", "s8", "u16", "s16", "u32", "s32", "void"):
                            raise SyntaxError(f"Cannot anonymously embed primitive scalar type '{f_type}'")
                        fields.append((f_type, False, f_type, None, True))
                        continue
                    f_ptr = False
                    if self.peek().val == '*':
                        self.consume()
                        f_ptr = True
                    f_name = self.consume('IDENT').val
                    f_dims = []
                    while self.peek().val == "[":
                        self.consume("PUNCT", "[")
                        f_dims.append(int(self.consume("INT").val, 0))
                        self.consume("PUNCT", "]")
                    f_dim = f_dims if len(f_dims) > 1 else (f_dims[0] if f_dims else None)
                    if self.peek().val == ";":
                        self.consume("PUNCT", ";")
                    fields.append((f_type, f_ptr, f_name, f_dim, False))
                self.consume('PUNCT', '}')
                if self.peek().val == ';':
                    self.consume('PUNCT', ';')
                self.known_types.add(t_name)
                return TypeDefNode(t_name, fields)

        is_const = False
        if self.peek().val == 'const':
            self.consume()
            is_const = True

        tuple_ret_types = None
        if self.peek().val == '(':
            self.consume('PUNCT', '(')
            tuple_ret_types = []
            while True:
                ret_elem_t = self.parse_type()
                ret_elem_ptr = False
                if self.peek().val == '*':
                    self._forbid_aggregate_ptr(ret_elem_t)
                    self.consume()
                    ret_elem_ptr = True
                tuple_ret_types.append((ret_elem_t, ret_elem_ptr))
                if self.peek().val == ',':
                    self.consume()
                else:
                    break
            self.consume('PUNCT', ')')
            if len(tuple_ret_types) > 4:
                raise SyntaxError(f"Maximum 4 scalar return values supported in Particle ABI, got {len(tuple_ret_types)}")
            t_name = tuple_ret_types
            is_ptr = False
        else:
            t_name = self.parse_type()
            is_ptr = False
            if self.peek().val == '*':
                self._forbid_aggregate_ptr(t_name)
                self.consume()
                is_ptr = True

        name = self.consume('IDENT').val

        bound_struct = None
        bound_type = None
        # Oberon-style type-bound procedure: void Point.move(...)
        bound_type = None
        if self.peek().val == '.':
            self.consume('PUNCT', '.')
            method_name = self.consume('IDENT').val
            bound_type = name
            bound_struct = bound_type
            name = f"{bound_type}_{method_name}"

        if self.peek().val == '(':
            self.consume('PUNCT', '(')
            params = []
            if bound_struct:
                # Automatically prepend receiver 'this' by reference
                params.append((bound_struct, False, 'this'))
            if self.peek().val != ')':
                while True:
                    if self.peek().val == 'void' and len(params) == (1 if bound_struct else 0):
                        self.consume()
                        break
                    p_type = self.parse_type()
                    p_ptr = False
                    if self.peek().val == '*':
                        self._forbid_aggregate_ptr(p_type)
                        self.consume()
                        p_ptr = True
                    p_name = self.consume('IDENT').val
                    is_open_arr = False
                    if self.peek().val == '[':
                        self.consume("PUNCT", "[")
                        self.consume("PUNCT", "]")
                        is_open_arr = True
                        p_ptr = True
                    params.append((p_type, p_ptr, p_name, is_open_arr))
                    if self.peek().val == ',':
                        self.consume()
                    else:
                        break
            self.consume('PUNCT', ')')
            if self.peek().val == ';':
                self.consume('PUNCT', ';')
                return FuncDeclNode(t_name, is_ptr, name, params, None, is_inline=is_inline)
            body = self.parse_block()
            return FuncDeclNode(t_name, is_ptr, name, params, body, is_inline=is_inline)
        else:
            array_dims = []
            bound_addr = None
            while self.peek().val == '[':
                self.consume("PUNCT", "[")
                dim_tok = self.consume()
                array_dims.append(int(dim_tok.val, 0))
                self.consume("PUNCT", "]")
            if self.peek().val == '@':
                self.consume('PUNCT', '@')
                addr_tok = self.consume()
                bound_addr = int(addr_tok.val, 0)
            init_expr = None
            if self.match('='):
                init_expr = self.parse_expr()
            self.consume('PUNCT', ';')
            if bound_addr is not None:
                is_volatile = True
            node = VarDeclNode(t_name, is_ptr, name, init_expr, is_const=is_const, is_volatile=is_volatile)
            node.array_dims = array_dims if array_dims else None
            node.array_dim = array_dims[0] if array_dims else None
            node.bound_addr = bound_addr
            return node

    def parse_block(self):
        self.consume('PUNCT', '{')
        stmts = []
        while self.peek().val != '}' and self.peek().type != 'EOF':
            stmts.append(self.parse_statement())
        self.consume('PUNCT', '}')
        return BlockNode(stmts)

    def parse_statement(self):
        tok = self.peek()
        if tok.val == 'verify':
            return self.parse_verify()
        if tok.val == ';':
            self.consume('PUNCT', ';')
            return BlockNode([])
        if tok.val == '{':
            return self.parse_block()
        if tok.val == 'if':
            self.consume()
            self.consume('PUNCT', '(')
            cond = self.parse_expr()
            self.consume('PUNCT', ')')
            then_body = self.parse_statement()
            else_body = None
            if self.peek().val == 'else':
                self.consume()
                else_body = self.parse_statement()
            return IfNode(cond, then_body, else_body)
        if tok.val == 'case':
            self.consume('KEYWORD', 'case')
            case_expr = self.parse_expr()
            self.consume('PUNCT', ':')
            return CaseLabelNode(case_expr)

        if tok.val == 'default':
            self.consume('KEYWORD', 'default')
            self.consume('PUNCT', ':')
            return DefaultLabelNode()

        if tok.val == 'switch':
            self.consume()
            self.consume('PUNCT', '(')
            expr = self.parse_expr()
            self.consume('PUNCT', ')')
            body = self.parse_statement()
            return SwitchNode(expr, body)

        if tok.val == 'for':
            self.consume('KEYWORD', 'for')
            self.consume('PUNCT', '(')
            var_type = self.parse_type()
            var_name = self.consume('IDENT').val
            self.consume('PUNCT', ':')
            start_expr = self.parse_expr()
            self.consume('OP_RANGE', '..')
            end_expr = self.parse_expr()
            self.consume('PUNCT', ')')
            body = self.parse_statement()
            return ForRangeNode(var_type, var_name, start_expr, end_expr, body)

        if tok.val == 'while':
            self.consume()
            self.consume('PUNCT', '(')
            cond = self.parse_expr()
            self.consume('PUNCT', ')')
            body = self.parse_statement()
            return WhileNode(cond, body)

        if tok.val == 'asm':
            self.consume()
            self.consume('PUNCT', '(')
            asm_tok = self.consume('STRING')
            self.consume('PUNCT', ')')
            self.consume('PUNCT', ';')
            raw_text = asm_tok.val[1:-1].encode().decode('unicode_escape')
            return AsmNode(raw_text)

        if tok.val == 'break':
            self.consume()
            self.consume('PUNCT', ';')
            return BreakNode()

        if tok.val == 'yield':
            self.consume()
            self.consume('PUNCT', '(')
            task_ref = self.parse_expr()
            self.consume('PUNCT', ',')
            step_tok = self.consume()
            step_val = int(step_tok.val, 0)
            self.consume('PUNCT', ')')
            self.consume('PUNCT', ';')
            return YieldNode(task_ref, step_val)

        if tok.val == 'wait_until':
            self.consume()
            self.consume('PUNCT', '(')
            task_ref = self.parse_expr()
            self.consume('PUNCT', ',')
            step_tok = self.consume()
            step_val = int(step_tok.val, 0)
            self.consume('PUNCT', ',')
            cond = self.parse_expr()
            self.consume('PUNCT', ')')
            self.consume('PUNCT', ';')
            return WaitUntilNode(task_ref, step_val, cond)

        if tok.val == 'return':
            self.consume()
            if self.peek().val == '(':
                # Check if this is a tuple return (e1, e2, ...) vs parenthesized single expression
                saved_pos = self.pos
                self.consume('PUNCT', '(')
                paren_depth = 1
                has_comma_at_depth1 = False
                cur_pos = self.pos
                while cur_pos < len(self.tokens) and paren_depth > 0:
                    t_val = self.tokens[cur_pos].val
                    if t_val == '(':
                        paren_depth += 1
                    elif t_val == ')':
                        paren_depth -= 1
                    elif t_val == ',' and paren_depth == 1:
                        has_comma_at_depth1 = True
                    cur_pos += 1
                self.pos = saved_pos

                if has_comma_at_depth1:
                    self.consume('PUNCT', '(')
                    ret_exprs = []
                    while True:
                        ret_exprs.append(self.parse_expr())
                        if self.peek().val == ',':
                            self.consume()
                        else:
                            break
                    self.consume('PUNCT', ')')
                    self.consume('PUNCT', ';')
                    if len(ret_exprs) > 4:
                        raise SyntaxError(f"Maximum 4 scalar return values supported in Particle ABI, got {len(ret_exprs)}")
                    return TupleReturnNode(ret_exprs)

            expr = None
            if self.peek().val != ';':
                expr = self.parse_expr()
            self.consume('PUNCT', ';')
            return ReturnNode(expr)

        # Destructuring assignment / tuple declaration: (u32 a, _) = fn(); or (a, b) = fn();
        if tok.val == '(':
            saved_pos = self.pos
            self.consume('PUNCT', '(')
            paren_depth = 1
            has_comma_or_wildcard = False
            cur_pos = self.pos
            while cur_pos < len(self.tokens) and paren_depth > 0:
                t_val = self.tokens[cur_pos].val
                if t_val == '(':
                    paren_depth += 1
                elif t_val == ')':
                    paren_depth -= 1
                elif (t_val == ',' or t_val == '_') and paren_depth == 1:
                    has_comma_or_wildcard = True
                cur_pos += 1
            self.pos = saved_pos

            if has_comma_or_wildcard:
                self.consume('PUNCT', '(')
                targets = []
                while True:
                    if self.peek().val == '_':
                        self.consume()
                        targets.append(TupleTarget(is_wildcard=True))
                    else:
                        # Could be: 'type name', 'type* name', or simply existing variable 'name'
                        p_tok = self.peek()
                        is_decl = False
                        if p_tok.val in ('u8', 's8', 'u16', 's16', 'u32', 's32', 'string') or p_tok.val in self.known_types:
                            is_decl = True
                        elif p_tok.type == 'IDENT' and self.tokens[self.pos+1].type == 'IDENT':
                            is_decl = True
                        elif p_tok.type == 'IDENT' and self.tokens[self.pos+1].val == '*':
                            is_decl = True

                        if is_decl:
                            t_n = self.parse_type()
                            is_p = False
                            if self.peek().val == '*':
                                self._forbid_aggregate_ptr(t_n)
                                self.consume()
                                is_p = True
                            v_n = self.consume('IDENT').val
                            targets.append(TupleTarget(name=v_n, type_name=t_n, is_ptr=is_p, is_wildcard=False))
                        else:
                            v_n = self.consume('IDENT').val
                            targets.append(TupleTarget(name=v_n, is_wildcard=False))

                    if self.peek().val == ',':
                        self.consume()
                    else:
                        break
                self.consume('PUNCT', ')')
                self.consume('OP', '=')
                rhs_expr = self.parse_expr()
                self.consume('PUNCT', ';')
                if len(targets) > 4:
                    raise SyntaxError(f"Maximum 4 scalar return values supported in Particle ABI, got {len(targets)}")
                return TupleAssignNode(targets, rhs_expr)

        # Local Variable / Array Declaration
        is_volatile = False
        if tok.val == 'volatile':
            self.consume('KEYWORD', 'volatile')
            is_volatile = True
            tok = self.peek()

        is_const = False
        if tok.val == 'const':
            self.consume()
            is_const = True
            tok = self.peek()

        if tok.val in ('u8', 's8', 'u16', 's16', 'u32', 's32', 'string') or tok.val == 'type' or (tok.type == 'IDENT' and (self.tokens[self.pos+1].type == 'IDENT' or self.tokens[self.pos+1].val == '*')):
            t_name = self.parse_type()
            is_ptr = False
            if self.peek().val == '*':
                self._forbid_aggregate_ptr(t_name)
                self.consume()
                is_ptr = True
            name = self.consume('IDENT').val
            array_dims = []
            bound_addr = None
            while self.peek().val == '[':
                self.consume("PUNCT", "[")
                array_dims.append(int(self.consume().val, 0))
                self.consume("PUNCT", "]")
            if self.peek().val == '@':
                self.consume('PUNCT', '@')
                bound_addr = int(self.consume().val, 0)
            init_expr = None
            if self.match('='):
                init_expr = self.parse_expr()
            self.consume('PUNCT', ';')
            if bound_addr is not None:
                is_volatile = True
            node = VarDeclNode(t_name, is_ptr, name, init_expr, is_const=is_const, is_volatile=is_volatile)
            node.array_dims = array_dims if array_dims else None
            node.array_dim = array_dims[0] if array_dims else None
            node.bound_addr = bound_addr
            return node

        expr = self.parse_expr()
        self.consume('PUNCT', ';')
        return ExprStmtNode(expr)

    def parse_expr(self):
        return self.parse_assignment()

    def parse_assignment(self):
        node = self.parse_logical_or()
        tok = self.peek()
        if tok.val == '=':
            self.consume()
            rhs = self.parse_assignment()
            return BinaryOpNode('=', node, rhs)
        elif tok.type == 'COMPOUND_ASSIGN' or tok.val in ('+=', '-=', '*=', '/=', '&=', '|=', '^=', '<<=', '>>='):
            op = self.consume().val
            rhs = self.parse_assignment()
            return CompoundAssignNode(op, node, rhs)
        return node

    def parse_logical_or(self):
        node = self.parse_logical_and()
        while self.peek().val == '||':
            op = self.consume().val
            node = BinaryOpNode(op, node, self.parse_logical_and())
        return node

    def parse_logical_and(self):
        node = self.parse_relational()
        while self.peek().val == '&&':
            op = self.consume().val
            node = BinaryOpNode(op, node, self.parse_relational())
        return node

    def parse_relational(self):
        node = self.parse_bitwise()
        while self.peek().val in ('==', '!=', '<', '<=', '>', '>='):
            op = self.consume().val
            node = BinaryOpNode(op, node, self.parse_bitwise())
        return node

    def parse_bitwise(self):
        node = self.parse_shift()
        while self.peek().val in ('&', '|', '^'):
            op = self.consume().val
            node = BinaryOpNode(op, node, self.parse_shift())
        return node

    def parse_shift(self):
        node = self.parse_additive()
        while self.peek().val in ('<<', '>>'):
            op = self.consume().val
            node = BinaryOpNode(op, node, self.parse_additive())
        return node

    def parse_additive(self):
        node = self.parse_multiplicative()
        while self.peek().val in ('+', '-'):
            op = self.consume().val
            node = BinaryOpNode(op, node, self.parse_multiplicative())
        return node

    def parse_multiplicative(self):
        node = self.parse_unary()
        while self.peek().val in ('*', '/', '%'):
            op = self.consume().val
            node = BinaryOpNode(op, node, self.parse_unary())
        return node

    def parse_unary(self):
        if self.peek().val in ('-', '~', '!', '*', '&'):
            op = self.consume().val
            return UnaryOpNode(op, self.parse_unary())
        return self.parse_postfix()


    def parse_array_access(self, base_node):
        self.consume("PUNCT", "[")
        idx = self.parse_expr()
        self.consume("PUNCT", "]")
        return ArrayAccessNode(base_node, idx)

    def parse_postfix(self):
        node = self.parse_primary()
        while True:
            if self.peek().val in ('.', '->'):
                self.consume()
                member = self.consume('IDENT').val
                if self.peek().val == '(':
                    self.consume('PUNCT', '(')
                    args = []
                    if self.peek().val != ')':
                        while True:
                            args.append(self.parse_expr())
                            if self.peek().val == ',':
                                self.consume()
                            else:
                                break
                    self.consume('PUNCT', ')')

                    # Intercept dynamic allocation pseudo-constructors
                    # Receiver node is a VarAccessNode naming a type, or identifier 'string'
                    rcv_name = node.name if isinstance(node, VarAccessNode) else None

                    if member == 'create':
                        if rcv_name == 'string':
                            if len(args) != 1:
                                raise SyntaxError("string.create(capacity) requires exactly 1 argument (capacity)")
                            node = HeapStringAllocNode(args[0])
                        elif rcv_name:
                            node = HeapAllocNode(rcv_name, args)
                        else:
                            node = CallNode(f"__METHOD__{member}", [node] + args)
                    elif member == 'createArray':
                        if not rcv_name:
                            raise SyntaxError("createArray(N) must be called on a type identifier (e.g. Type.createArray(N))")
                        if len(args) != 1:
                            raise SyntaxError("createArray(N) requires exactly 1 argument (element count)")
                        node = HeapArrayAllocNode(rcv_name, args[0])
                    elif member in ('destroy', 'destroyArray'):
                        if len(args) != 0:
                            raise SyntaxError(f"{member}() takes no arguments")
                        node = HeapFreeNode(node)
                    elif member == 'resize':
                        if len(args) != 1:
                            raise SyntaxError("resize(N) requires exactly 1 argument (new element count)")
                        node = HeapArrayResizeNode(node, args[0])
                    elif member == 'exists':
                        if len(args) != 0:
                            raise SyntaxError("exists() takes no arguments")
                        node = ExistsNode(node)
                    else:
                        node = CallNode(f"__METHOD__{member}", [node] + args)
                else:
                    node = MemberAccessNode(node, member)
            elif self.peek().val == '[':
                self.consume("PUNCT", "[")
                if self.peek().val == '..':
                    self.consume("OP_RANGE", "..")
                    end_expr = None
                    if self.peek().val != ']':
                        end_expr = self.parse_expr()
                    self.consume("PUNCT", "]")
                    node = SliceNode(node, None, end_expr)
                else:
                    start_expr = self.parse_expr()
                    if self.peek().val == '..':
                        self.consume("OP_RANGE", "..")
                        end_expr = None
                        if self.peek().val != ']':
                            end_expr = self.parse_expr()
                        self.consume("PUNCT", "]")
                        node = SliceNode(node, start_expr, end_expr)
                    else:
                        self.consume("PUNCT", "]")
                        node = ArrayAccessNode(node, start_expr)
            else:
                break
        return node

    def parse_primary(self):
        tok = self.peek()
        if tok.val == 'sizeof':
            self.consume('KEYWORD', 'sizeof')
            self.consume('PUNCT', '(')
            arg_tok = self.peek()
            if arg_tok.val in ('u8', 's8', 'u16', 's16', 'u32', 's32', 'void', 'string'):
                t_arg = self.consume().val
                self.consume('PUNCT', ')')
                sz = 1 if t_arg in ('u8', 's8', 'string') else (2 if t_arg in ('u16', 's16') else 4)
                return IntLitNode(sz)
            elif arg_tok.type == 'IDENT' and self.tokens[self.pos+1].val == ')':
                t_arg = self.consume('IDENT').val
                self.consume('PUNCT', ')')
                return SizeofNode(t_arg)
            else:
                expr = self.parse_expr()
                self.consume('PUNCT', ')')
                return SizeofNode(expr)
        if tok.type in ('INT', 'HEX'):
            self.consume()
            return IntLitNode(int(tok.val, 0))
        if tok.type == 'CHAR':
            self.consume()
            raw = bytes(tok.val[1:-1], 'utf-8').decode('unicode_escape')
            val = ord(raw) if len(raw) > 0 else 0
            return IntLitNode(val)
        if tok.type == 'STRING':
            self.consume()
            raw = bytes(tok.val[1:-1], 'utf-8').decode('unicode_escape')
            return StringLitNode(raw)
        if tok.type == 'IDENT' or ((tok.val in ('string', 'u8', 's8', 'u16', 's16', 'u32', 's32')) and self.pos + 1 < len(self.tokens) and self.tokens[self.pos+1].val == '.'):
            name = self.consume().val
            if self.peek().val == '(':
                self.consume('PUNCT', '(')
                args = []
                if self.peek().val != ')':
                    while True:
                        args.append(self.parse_expr())
                        if self.peek().val == ',':
                            self.consume()
                        else:
                            break
                self.consume('PUNCT', ')')
                if name == 'trap' and len(args) == 1 and isinstance(args[0], IntLitNode):
                    return TrapNode(args[0].val)
                return CallNode(name, args)
            return VarAccessNode(name)
        if tok.val == '(':
            self.consume('PUNCT', '(')
            node = self.parse_expr()
            if self.peek().val == ',':
                raise SyntaxError(f"{tok.fname}:{tok.lineno}:{tok.col}: Bare tuple expression not permitted in scalar expression context")
            self.consume('PUNCT', ')')
            return node
        raise SyntaxError(f"{tok.fname}:{tok.lineno}:{tok.col}: Unexpected token '{tok.val}'")

# ------------------------------------------------------------------------------
# Pluggable Backend Architecture
# ------------------------------------------------------------------------------

class BackendBase:
    """Abstract code generation backend interface."""
    def __init__(self):
        self.asm = []
        self.label_counter = 0

    def emit(self, line: str, comment: str = ""):
        if comment:
            self.asm.append(f"    {line:<24} ; {comment}")
        else:
            self.asm.append(f"    {line}")

    def emit_label(self, label: str):
        self.asm.append(f"{label}:")

    def new_label(self, prefix: str = "L") -> str:
        self.label_counter += 1
        return f"._{prefix}_{self.label_counter}"

    def emit_immediate(self, reg: int, val: int):
        raise NotImplementedError

    def gen_heap_alloc(self, dst_reg: int, size_bytes: int):
        """Allocate size_bytes on heap; return base pointer in dst_reg."""
        raise NotImplementedError

    def gen_heap_free(self, addr_reg: int):
        """Free memory block at addr_reg."""
        raise NotImplementedError

    def gen_array_alloc(self, dst_reg: int, elem_size: int, count_reg: int):
        """Allocate dynamic array with 4-byte count header; return payload pointer in dst_reg."""
        raise NotImplementedError

    def gen_array_free(self, addr_reg: int):
        """Free dynamic array given its payload pointer."""
        raise NotImplementedError

    def gen_array_resize(self, dst_reg: int, addr_reg: int, elem_size: int, count_reg: int):
        """Resize dynamic array with 4-byte count header; return updated payload pointer in dst_reg."""
        raise NotImplementedError

    def gen_string_alloc(self, dst_reg: int, cap_reg: int):
        """Allocate dynamic string with 4-byte capacity header and null byte; return payload pointer."""
        raise NotImplementedError


class ParticleAsmBackend(BackendBase):
    """Particle 32-bit RISC Bare-Metal Assembly Backend."""

    def emit_immediate(self, reg: int, val: int):
        v = val & 0xFFFFFFFF
        if 0 <= val <= 15:
            self.emit(f"LD      R{reg}, {val}", f"Imm4 load ({val})")
        elif -15 <= val < 0:
            self.emit(f"LD      R{reg}, -{abs(val)}", f"-Imm4 load ({val})")
        elif v <= 0xFFFF:
            self.emit(f"LOAD16  R{reg}, 0x{v:04X}", f"LOAD16 tiered ({val})")
        elif v <= 0xFFFFFF:
            self.emit(f"LOAD24  R{reg}, 0x{v:06X}", f"LOAD24 tiered ({val})")
        else:
            self.emit(f"LOAD32  R{reg}, 0x{v:08X}", f"LOAD32 full word ({val})")

    def gen_heap_alloc(self, dst_reg: int, size_bytes: int):
        self.emit_immediate(1, size_bytes)
        self.emit("RCALL   _rt_alloc", f"Heap alloc {size_bytes} bytes")
        if dst_reg != 1:
            self.emit(f"LD      R{dst_reg}, R1")

    def gen_heap_free(self, addr_reg: int):
        if addr_reg != 1:
            self.emit(f"LD      R1, R{addr_reg}")
        self.emit("RCALL   _rt_free", "Heap free block")

    def gen_array_alloc(self, dst_reg: int, elem_size: int, count_reg: int):
        # Calculate total = 4 + (count * elem_size)
        # Preserve count across _rt_alloc on hardware stack
        self.emit(f"PUSH32  R{count_reg}", "Preserve count for header")
        self.emit(f"LD      R1, R{count_reg}")
        if elem_size == 2:
            self.emit("SHIFTL  R1, 1")
        elif elem_size == 4:
            self.emit("SHIFTL  R1, 2")
        elif elem_size != 1:
            self.emit_immediate(2, elem_size)
            self.emit("MUL     R1, R2")
        self.emit("ADD     R1, 4", "Include 4-byte length prefix header")
        self.emit("RCALL   _rt_alloc", "Allocate dynamic array")
        self.emit("POP32   R2", "Restore count for header")
        # Store count in prefix header [Offset 0: count]
        self.emit("ST32    (R1), R2", "Store array length header")
        # Advance pointer to payload [Offset 4: elements]
        self.emit("ADD     R1, 4", "Point to array payload")
        if dst_reg != 1:
            self.emit(f"LD      R{dst_reg}, R1")

    def gen_array_free(self, addr_reg: int):
        # Adjust backwards to include length header
        self.emit(f"SUB     R{addr_reg}, 4", "Adjust pointer to array header")
        if addr_reg != 1:
            self.emit(f"LD      R1, R{addr_reg}")
        self.emit("RCALL   _rt_free", "Free dynamic array block")

    def gen_array_resize(self, dst_reg: int, addr_reg: int, elem_size: int, count_reg: int):
        # 1. Preserve new element count across _rt_realloc
        self.emit(f"PUSH32  R{count_reg}", "Preserve new count for header")
        # 2. Calculate new raw byte payload: 4 + (count * elem_size)
        self.emit(f"LD      R2, R{count_reg}")
        if elem_size == 2:
            self.emit("SHIFTL  R2, 1")
        elif elem_size == 4:
            self.emit("SHIFTL  R2, 2")
        elif elem_size != 1:
            self.emit_immediate(13, elem_size)
            self.emit("MUL     R2, R13")
        self.emit("ADD     R2, 4", "Include 4-byte length prefix header")
        # 3. Adjust existing payload pointer backwards by 4 to point to raw chunk header
        if addr_reg != 1:
            self.emit(f"LD      R1, R{addr_reg}")
        self.emit("SUB     R1, 4", "Adjust pointer to raw chunk header")
        # 4. Invoke runtime allocator realloc
        self.emit("RCALL   _rt_realloc", "Resize dynamic memory chunk")
        # 5. Restore new element count and update length header
        self.emit("POP32   R2", "Restore new count for header")
        self.emit("ST32    (R1), R2", "Update array length header")
        # 6. Advance pointer back to user payload
        self.emit("ADD     R1, 4", "Point to resized array payload")
        if dst_reg != 1:
            self.emit(f"LD      R{dst_reg}, R1")

    def gen_string_alloc(self, dst_reg: int, cap_reg: int):
        # Total size = 4 (capacity header) + capacity bytes
        self.emit(f"PUSH32  R{cap_reg}", "Preserve capacity for header")
        self.emit(f"LD      R1, R{cap_reg}")
        self.emit("ADD     R1, 4", "Include 4-byte capacity prefix header")
        self.emit("RCALL   _rt_alloc", "Allocate dynamic string")
        self.emit("POP32   R2", "Restore capacity for header")
        # Store capacity header
        self.emit("LD32    (R1), R2", "Store string capacity header")
        self.emit("ADD     R1, 4", "Point to string buffer payload")
        # Null terminate initially
        self.emit("LD8     (R1), R0", "Null terminate empty dynamic string")
        if dst_reg != 1:
            self.emit(f"LD      R{dst_reg}, R1")

# ------------------------------------------------------------------------------
# Code Generator (Frontend & AST Lowering)
# ------------------------------------------------------------------------------

class CodeGen:
    
    def _emit_string_init(self, name, init_expr, capacity):
        if not (hasattr(init_expr, 'val') and isinstance(init_expr.val, str)):
            raise SyntaxError(f"String variable '{name}' must be initialized with a string literal")
        raw_str = init_expr.val
        if len(raw_str) > capacity:
            raise SyntaxError(
                f"String literal length ({len(raw_str)}) exceeds capacity ({capacity}) of string {name}[{capacity}]"
            )
        self.string_lens[name] = len(raw_str)
        lbl = self.new_label("str")
        self.strings.append((lbl, raw_str))

        self.emit(f"LOAD32  R13, {lbl}", f"Load address of string literal {repr(raw_str)}")
        offset = self.stack_offset - self.locals[name]
        if offset > 0:
            self.emit_immediate(14, offset)
            self.emit("ADD     R14, R15", f"Base address of local string '{name}'")
        else:
            self.emit("LD      R14, R15", f"Base address of local string '{name}'")
        lbl_loop = self.new_label("str_cpy")
        lbl_done = self.new_label("str_done")

        self.emit_label(lbl_loop)
        self.emit("LD8     R12, (R13)", "Fetch literal byte")
        self.emit(f"FBRA.Z  R12, {lbl_done}", "End of literal reached")
        self.emit("LD8     (R14), R12", "Store byte into string buffer")
        self.emit("ADD     R13, 1", "literal_ptr++")
        self.emit("ADD     R14, 1", "buffer_ptr++")
        self.emit(f"BBRA    {lbl_loop}", "Copy next byte")
        self.emit_label(lbl_done)
        self.emit("LD8     (R14), R12", "Store null terminator")

    def _emit_string_scan_len(self, arr_name, target_reg):
        if arr_name in self.bound_addrs:
            self.emit_immediate(14, self.bound_addrs[arr_name])
        elif arr_name in self.locals:
            offset = self.stack_offset - self.locals[arr_name]
            if offset > 0:
                self.emit_immediate(14, offset)
                self.emit("ADD     R14, R15")
            else:
                self.emit("LD      R14, R15")
            t_info = self.types.get(arr_name, ('u32', False, False))
            is_ptr = t_info[1] if len(t_info) > 1 else False
            is_ref = t_info[2] if len(t_info) > 2 else False
            is_local_fixed = arr_name in self.array_dims or arr_name in self.array_lens
            if is_ref or is_ptr or not is_local_fixed:
                self.emit(f"LD32    R14, (R14)", f"Dereference param/ptr string '{arr_name}'")
        elif arr_name in self.globals:
            self.emit(f"LOAD32  R14, _{arr_name}")
        else:
            self.emit_immediate(target_reg, 0)
            return

        lbl_scan = self.new_label("str_scan")
        lbl_done = self.new_label("str_scan_done")

        self.emit(f"LD      R{target_reg}, 0", f"Init .len scan counter for '{arr_name}'")
        self.emit_label(lbl_scan)
        self.emit("LD8     R13, (R14)", "Load byte from string buffer")
        self.emit(f"FBRA.Z  R13, {lbl_done}", "Null terminator reached")
        self.emit(f"ADD     R{target_reg}, 1", "len++")
        self.emit("ADD     R14, 1", "ptr++")
        self.emit(f"BBRA    {lbl_scan}", "Check next byte")
        self.emit_label(lbl_done)

    def _check_affine_access(self, name):
        if name in self.affine_state and self.affine_state[name] == 'MOVED':
            raise SyntaxError(f"act16c: use of moved or deallocated affine reference '{name}'")

    def _clean_type(self, t):
        if not t:
            return ""
        if isinstance(t, (list, tuple)):
            cleaned = []
            for item in t:
                if isinstance(item, tuple):
                    cleaned.append((self._clean_type(item[0]), item[1]))
                else:
                    cleaned.append(self._clean_type(item))
            return cleaned
        return t.replace("struct ", "").replace("type ", "").strip()
    def __init__(self, bounds_check: bool = True, backend=None):
        self.bounds_check = bounds_check
        self.backend = backend if backend is not None else ParticleAsmBackend()
        self.asm = self.backend.asm
        self.affine_state = {}
        self.dynamic_arrays = set()
        self.borrowed_params = set()
        self.locals = {}
        self.globals = set()
        self.types = {}
        self.type_records = {}
        self.structs = self.type_records
        self.array_lens = {}
        self.string_lens = {}
        self.array_dims = {}
        self.bound_addrs = {}
        self.volatiles = set()
        self.func_signatures = {}
        self.fn_types = {}
        self.stack_offset = 0
        self.current_func_name = ""
        self.strings = []
        self.break_stack = []
        self.constants = {}
        self.inline_funcs = {}
        self.inline_return_stack = []
        self.open_arrays = set()

    def emit(self, line, comment=""):
        self.backend.emit(line, comment)

    def emit_label(self, label):
        self.backend.emit_label(label)

    def new_label(self, prefix="L"):
        return self.backend.new_label(prefix)

    def emit_immediate(self, reg, val):
        self.backend.emit_immediate(reg, val)

    def _resolve_method(self, struct_name, method_name):
        direct = f"{struct_name}_{method_name}"
        if direct in self.func_signatures:
            return direct, 0
        s_info = self.structs.get(struct_name, {})
        for embed_type, embed_offset in s_info.get("__embedded__", []):
            sub_func, sub_off = self._resolve_method(embed_type, method_name)
            if sub_func:
                return sub_func, embed_offset + sub_off
        return None, 0

    def _get_expr_type(self, expr):
        if isinstance(expr, ExistsNode):
            return ('u32', False)
        elif isinstance(expr, HeapAllocNode):
            return (expr.type_name, True)
        elif isinstance(expr, HeapArrayAllocNode):
            return (expr.type_name, True)
        elif isinstance(expr, HeapStringAllocNode):
            return ('string', True)
        if isinstance(expr, UnaryOpNode) and expr.op == '&':
            return self._get_expr_type(expr.operand)
        while hasattr(expr, 'expr') and not isinstance(expr, (MemberAccessNode, UnaryOpNode)):
            expr = expr.expr
        if isinstance(expr, VarAccessNode):
            if expr.name in self.func_signatures:
                return (f"fn_{expr.name}", False)
            info = self.types.get(expr.name, ('u32', False, False))
            return (info[0], info[1])
        
        elif isinstance(expr, MemberAccessNode) and expr.member == 'len':
            return ('u32', False)

        elif isinstance(expr, MemberAccessNode):
            if isinstance(expr.expr, VarAccessNode) and expr.expr.name in self.structs and expr.expr.name not in self.locals and expr.expr.name not in self.globals and expr.expr.name not in self.bound_addrs:
                mangled = f"{expr.expr.name}_{expr.member}"
                if mangled in self.func_signatures:
                    return (f"fn_{mangled}", False)
                raise SyntaxError(f"Type '{expr.expr.name}' has no method '{expr.member}'")

            p_t, _ = self._get_expr_type(expr.expr)
            possible_type = self._clean_type(p_t)
            mangled = f"{possible_type}_{expr.member}"
            if mangled in self.func_signatures:
                base_name = getattr(expr.expr, "name", "instance")
                raise SyntaxError(
                    f"Cannot extract unbound method reference from instance '{base_name}'. "
                    f"Use '{possible_type}.{expr.member}' with signature fn({possible_type}, ...) instead."
                )

            _, m_type, m_ptr, *rest = self.structs.get(possible_type, {}).get(expr.member, (0, 'u32', False, None))
            return (m_type, m_ptr)

        elif isinstance(expr, ArrayAccessNode):
            curr = expr
            while isinstance(curr, ArrayAccessNode):
                curr = curr.base
            if isinstance(curr, VarAccessNode):
                t_name, is_ptr, *rest = self.types.get(curr.name, ("u32", False, False))
                return (t_name, False)
            elif isinstance(curr, MemberAccessNode):
                base_t, _ = self._get_expr_type(curr.expr)
                s_name = self._clean_type(base_t)
                _, m_type, m_ptr, *rest = self.structs.get(s_name, {}).get(curr.member, (0, "u32", False, None))
                return (m_type, False)
            return ("u32", False)

        elif isinstance(expr, CallNode):
            if expr.name.startswith("__METHOD__"):
                m_name = expr.name.replace("__METHOD__", "")
                rcv_t, _ = self._get_expr_type(expr.args[0])
                s_name = self._clean_type(rcv_t)
                fname, _ = self._resolve_method(s_name, m_name)
                if not fname:
                    fname = f"{s_name}_{m_name}"
            else:
                fname = expr.name
            if fname in self.func_signatures:
                ret_t, ret_ptr, _ = self.func_signatures[fname]
                return (ret_t, ret_ptr)
            return ('u32', False)
        return ('u32', False)

    def _eval_const_expr(self, expr):
        if expr is None:
            return 0
        if isinstance(expr, IntLitNode):
            return expr.val
        elif isinstance(expr, VarAccessNode):
            if expr.name in self.constants:
                return self.constants[expr.name]
            raise ValueError(f"Constant expression references non-constant symbol '{expr.name}'")
        elif isinstance(expr, SizeofNode):
            if isinstance(expr.target, str):
                t_clean = self._clean_type(expr.target)
                if t_clean in ('u8', 's8', 'string'): return 1
                elif t_clean in ('u16', 's16'): return 2
                elif t_clean in ('u32', 's32', 'void') or t_clean in self.fn_types: return 4
                elif t_clean in self.structs: return self.structs[t_clean].get('__size__', 4)
            else:
                t_name, _ = self._get_expr_type(expr.target)
                t_clean = self._clean_type(t_name)
                if t_clean in ('u8', 's8', 'string'): return 1
                elif t_clean in ('u16', 's16'): return 2
                elif t_clean in ('u32', 's32', 'void') or t_clean in self.fn_types: return 4
                elif t_clean in self.structs: return self.structs[t_clean].get('__size__', 4)
            return 4
        elif isinstance(expr, UnaryOpNode):
            val = self._eval_const_expr(expr.operand)
            if expr.op == '-':
                return (-val) & 0xFFFFFFFF
            elif expr.op == '~':
                return (~val) & 0xFFFFFFFF
            elif expr.op == '!':
                return 1 if val == 0 else 0
        elif isinstance(expr, BinaryOpNode):
            left = self._eval_const_expr(expr.left)
            right = self._eval_const_expr(expr.right)
            if expr.op == '+': return (left + right) & 0xFFFFFFFF
            elif expr.op == '-': return (left - right) & 0xFFFFFFFF
            elif expr.op == '*': return (left * right) & 0xFFFFFFFF
            elif expr.op == '/': return (left // right) & 0xFFFFFFFF if right != 0 else 0
            elif expr.op == '%': return (left % right) & 0xFFFFFFFF if right != 0 else 0
            elif expr.op == '&': return (left & right) & 0xFFFFFFFF
            elif expr.op == '|': return (left | right) & 0xFFFFFFFF
            elif expr.op == '^': return (left ^ right) & 0xFFFFFFFF
            elif expr.op == '<<': return (left << (right & 31)) & 0xFFFFFFFF
            elif expr.op == '>>': return (left >> (right & 31)) & 0xFFFFFFFF
            elif expr.op == '==': return 1 if left == right else 0
            elif expr.op == '!=': return 1 if left != right else 0
            elif expr.op == '<': return 1 if left < right else 0
            elif expr.op == '<=': return 1 if left <= right else 0
            elif expr.op == '>': return 1 if left > right else 0
            elif expr.op == '>=': return 1 if left >= right else 0
            elif expr.op == '&&': return 1 if (left != 0 and right != 0) else 0
            elif expr.op == '||': return 1 if (left != 0 or right != 0) else 0
        raise ValueError(f"Expression cannot be evaluated as constant: {type(expr).__name__}")

    def _escape_asm_string(self, s):
        out = []
        for ch in s:
            code = ord(ch)
            if ch == '\\':
                out.append('\\\\')
            elif ch == '"':
                out.append('\\"')
            elif ch == '\n':
                out.append('\\n')
            elif ch == '\r':
                out.append('\\r')
            elif ch == '\t':
                out.append('\\t')
            elif ch == '\0':
                out.append('\\0')
            elif 32 <= code <= 126:
                out.append(ch)
            else:
                out.append(f"\\x{code:02x}")
        return "".join(out)

    def generate(self, root):
        self.asm.append("; ==============================================================================")
        self.asm.append("; Compiled from ACT16 Source via act16c.py")
        self.asm.append("; Target Architecture: Particle 32-bit RISC")
        self.asm.append("; ==============================================================================\n")
        self.asm.append('.include "lib/common.inc"\n')

        struct_defs = [d for d in root.decls if isinstance(d, StructDefNode)]
        remaining = list(struct_defs)
        max_iters = len(remaining) + 1
        for _ in range(max_iters):
            progress = False
            next_remaining = []
            for d in remaining:
                can_resolve = True
                for field_tuple in d.fields:
                    f_type = field_tuple[0].replace("struct ", "").replace("type ", "").strip()
                    f_ptr = field_tuple[1]
                    if not f_ptr and f_type not in ('u8', 's8', 'u16', 's16', 'u32', 's32', 'string', 'void'):
                        if f_type not in self.structs:
                            can_resolve = False
                            break
                if can_resolve:
                    offset = 0
                    fields = {}
                    embedded_list = []
                    for field_tuple in d.fields:
                        f_type = field_tuple[0].replace("struct ", "").replace("type ", "").strip()
                        f_ptr = field_tuple[1]
                        f_name = field_tuple[2]
                        f_dim = field_tuple[3] if len(field_tuple) > 3 else None
                        is_embedded = field_tuple[4] if len(field_tuple) > 4 else False
                        if is_embedded:
                            embed_sz = self.structs[f_type].get("__size__", 4)
                            embed_base_off = offset
                            embedded_list.append((f_type, embed_base_off))
                            fields[f_name] = (embed_base_off, f_type, False, None)
                            for sub_k, sub_v in self.structs[f_type].items():
                                if sub_k.startswith("__"):
                                    continue
                                sub_off, sub_t, sub_p, sub_d = sub_v
                                if sub_k not in fields:
                                    fields[sub_k] = (embed_base_off + sub_off, sub_t, sub_p, sub_d)
                            offset += embed_sz
                            continue
                        if f_ptr:
                            elem_sz = 4
                        elif f_type in ('u32', 's32'):
                            elem_sz = 4
                        elif f_type in ('u16', 's16'):
                            elem_sz = 2
                        elif f_type in self.structs:
                            elem_sz = self.structs[f_type].get('__size__', 4)
                        elif f_type in ('u8', 's8', 'string'):
                            elem_sz = 1
                        else:
                            elem_sz = 4
                        if isinstance(f_dim, list):
                            total_elems = 1
                            for dm in f_dim:
                                total_elems *= dm
                            f_size = elem_sz * total_elems
                        elif f_dim is not None:
                            f_size = elem_sz * f_dim
                        else:
                            f_size = elem_sz
                        fields[f_name] = (offset, f_type, f_ptr, f_dim)
                        offset += f_size
                    fields['__size__'] = offset
                    fields['__embedded__'] = embedded_list
                    self.structs[d.name] = fields
                    progress = True
                else:
                    next_remaining.append(d)
            remaining = next_remaining
            if not remaining or not progress:
                break

        if remaining:
            unresolved = ", ".join(d.name for d in remaining)
            raise SyntaxError(f"Circular dependency or unknown type in struct/type definition: {unresolved}")

        for d in root.decls:
            if isinstance(d, FnTypeNode):
                self.fn_types[d.name] = (d.param_types, d.ret_type)
        data_decls = [d for d in root.decls if isinstance(d, VarDeclNode)]
        raw_func_decls = [d for d in root.decls if isinstance(d, FuncDeclNode)]
        for f in raw_func_decls:
            self.func_signatures[f.name] = (
                self._clean_type(f.ret_type),
                f.ret_ptr,
                [(p[0].replace("struct ", "").replace("type ", "").strip(), p[1], len(p) > 3 and p[3]) for p in f.params]
            )
        has_main = any(f.name == "main" for f in raw_func_decls)
        func_decls = raw_func_decls

        if has_main:
            self.asm.append("; ------------------------------------------------------------------------------")
            self.asm.append("; Direct Stride Vector Table & Startup Code (Auto-generated)")
            self.asm.append("; ------------------------------------------------------------------------------")
            self.asm.append(".org 0x00000100")
            self.emit_label("_vector_reset")
            self.emit("LOAD32  R15, 0x00010000", "Initialize stack pointer SP")
            self.emit("LOAD32  R14, _main", "Load main entry address")
            self.emit("JMP     R14, R0", "Jump to _main (discard link)")
            self.emit(".align  64")
            self.asm.append("")
            self.emit_label("_vector_mbox")
            self.emit("FAST_ENTER_TRAP")
            self.emit("FAST_EXIT_TRAP")
            self.emit(".align  64")
            self.asm.append("")

                # Process Enum declarations into compile-time constants (zero memory allocated)
        for d in root.decls:
            if isinstance(d, EnumDeclNode):
                cur_val = 0
                for m_name, m_expr in d.members:
                    if m_expr is not None:
                        cur_val = self._eval_const_expr(m_expr)
                    self.constants[m_name] = cur_val
                    cur_val += 1

        # Register global constants upfront (before verify evaluation)
        for d in data_decls:
            if getattr(d, 'is_const', False):
                self.constants[d.name] = self._eval_const_expr(d.init_expr)

        # Evaluate top-level verify assertions
        for d in root.decls:
            if isinstance(d, VerifyNode):
                res = self._eval_const_expr(d.cond)
                if not res:
                    tok = d.token
                    loc = f"{tok.fname}:{tok.lineno}:{tok.col}" if tok else "verify"
                    raise SyntaxError(f"{loc}: Compile-time verification failed: '{d.msg}'")

        # Register global types and dims
        for d in data_decls:
            if getattr(d, 'is_const', False):
                continue
            if getattr(d, 'is_volatile', False) or getattr(d, 'bound_addr', None) is not None:
                self.volatiles.add(d.name)
            self.types[d.name] = (d.type_name, d.is_ptr, False)
            dims = getattr(d, 'array_dims', None)
            if not dims and getattr(d, 'array_dim', None):
                dims = [d.array_dim]
            if dims:
                self.array_dims[d.name] = dims
                self.array_lens[d.name] = dims[0]
            if getattr(d, 'bound_addr', None) is not None:
                self.bound_addrs[d.name] = d.bound_addr
            else:
                self.globals.add(d.name)

        for f in func_decls:
            if getattr(f, 'is_inline', False):
                self.inline_funcs[f.name] = f
                continue
            if f.body is not None:
                self.gen_func(f)

        # Emit global variable data section AFTER all code
        emit_globals = [d for d in data_decls if not getattr(d, 'is_const', False) and getattr(d, 'bound_addr', None) is None]
        if emit_globals:
            self.asm.append("; ------------------------------------------------------------------------------")
            self.asm.append("; Global Variable Allocation")
            self.asm.append("; ------------------------------------------------------------------------------")
            self.emit(".align  4")
            for d in emit_globals:
                dims = getattr(d, 'array_dims', None)
                if not dims and getattr(d, 'array_dim', None):
                    dims = [d.array_dim]
                self.emit_label(f"_{d.name}")
                if dims:
                    elem_sz = 1 if d.type_name in ('u8', 's8', 'string') else (2 if d.type_name in ('u16', 's16') else 4)
                    total_elems = 1
                    for dm in dims:
                        total_elems *= dm
                    total_words = (elem_sz * total_elems + 3) // 4
                    for _ in range(total_words):
                        self.emit(".word   0")
                else:
                    if d.init_expr and isinstance(d.init_expr, IntLitNode):
                        self.emit(f".word   {d.init_expr.val}")
                    else:
                        self.emit(".word   0")
            self.asm.append("")

        if self.strings:
            self.asm.append("; ------------------------------------------------------------------------------")
            self.asm.append("; String Literal Table")
            self.asm.append("; ------------------------------------------------------------------------------")
            for lbl, s in self.strings:
                escaped = self._escape_asm_string(s)
                self.emit_label(lbl)
                self.emit(f'.asciz  "{escaped}"')
            self.asm.append("")

        self.asm.append('; ------------------------------------------------------------------------------')
        self.asm.append('; Runtime Memory Allocator')
        self.asm.append('; ------------------------------------------------------------------------------')
        self.asm.append('.include "lib/alloc.asm"\n')
        return "\n".join(self.asm)

    def gen_func(self, func):
        self.current_func_name = func.name
        self.current_func_ret = (self._clean_type(func.ret_type), func.ret_ptr)
        self.asm.append("; ------------------------------------------------------------------------------")
        self.asm.append(f"; Function: {func.name}")
        self.asm.append("; ------------------------------------------------------------------------------")
        self.emit_label(f"_{func.name}")

        self.locals = {}
        self.stack_offset = 0

        if func.name == "main":
            self.emit("LD      R14, 1", "Accumulate 0x00010000 into R14")
            self.emit("PUSH8   R14, 0")
            self.emit("PUSH8   R14, 0")
            self.emit("LD      R15, R14", "Initialize Stack Pointer (SP = 0x00010000)")
        else:
            self.emit("PUSH32  R14", "Preserve return address link")
            self.stack_offset = 4

        self.open_arrays.clear()
        self.dynamic_arrays.clear()
        self.borrowed_params.clear()
        self.affine_state = {}
        r_idx = 1
        for p in func.params:
            p_type, p_ptr, p_name = p[0], p[1], p[2]
            is_open_arr = p[3] if len(p) > 3 else False
            clean_pt = self._clean_type(p_type)
            is_ref = (clean_pt in self.structs and not p_ptr) or is_open_arr
            self.types[p_name] = (p_type, p_ptr, is_ref)
            self.borrowed_params.add(p_name)
            if is_open_arr:
                self.open_arrays.add(p_name)
                self.emit(f"PUSH32  R{r_idx}", f"Spill open array ptr '{p_name}'")
                self.stack_offset += 4
                self.locals[p_name] = self.stack_offset
                r_idx += 1
                self.emit(f"PUSH32  R{r_idx}", f"Spill open array len '{p_name}'")
                self.stack_offset += 4
                self.locals[f"{p_name}__len"] = self.stack_offset
                r_idx += 1
            else:
                if r_idx <= 4:
                    self.emit(f"PUSH32  R{r_idx}", f"Spill param '{p_name}'")
                    self.stack_offset += 4
                    self.locals[p_name] = self.stack_offset
                    r_idx += 1

        # Pre-scan and allocate function-level local stack frame
        local_decls = []
        if func.body is not None:
            self._collect_local_decls(func.body, local_decls)

        total_frame_words = 0
        for d in local_decls:
            self.types[d.name] = (d.type_name, d.is_ptr, False)
            elem_size = 4
            clean_type = self._clean_type(d.type_name)
            if d.type_name in ("u8", "s8", "string"):
                elem_size = 1
            elif d.type_name in ("u16", "s16"):
                elem_size = 2
            elif not d.is_ptr and clean_type in self.structs:
                elem_size = self.structs[clean_type].get("__size__", 4)

            dims = getattr(d, "array_dims", None)
            if not dims and getattr(d, "array_dim", None):
                dims = [d.array_dim]
            if dims:
                self.array_dims[d.name] = dims
                self.array_lens[d.name] = dims[0]
                total_elems = 1
                for dm in dims:
                    total_elems *= dm
                var_size = elem_size * total_elems
            else:
                var_size = elem_size

            words = (var_size + 3) // 4
            self.stack_offset += words * 4
            self.locals[d.name] = self.stack_offset
            total_frame_words += words

        if total_frame_words > 0:
            frame_bytes = total_frame_words * 4
            self.emit_immediate(14, frame_bytes)
            self.emit("SUB     R15, R14", f"Allocate local stack frame ({frame_bytes} bytes)")
            # Efficient zero-initialization of local frame
            if total_frame_words <= 4:
                for w_idx in range(total_frame_words):
                    off = w_idx * 4
                    if off == 0:
                        self.emit("ST32    (R15), R0", "Zero-init local frame word")
                    else:
                        self.emit_immediate(14, off)
                        self.emit("ADD     R14, R15")
                        self.emit("ST32    (R14), R0", "Zero-init local frame word")
            else:
                lbl_clr_loop = self.new_label("frame_clr")
                lbl_clr_done = self.new_label("frame_clr_done")
                self.emit_immediate(13, total_frame_words)
                self.emit("LD      R14, R15", "Base of local frame for zero-init")
                self.emit_label(lbl_clr_loop)
                self.emit("ST32    (R14), R0", "Clear frame word")
                self.emit("ADD     R14, 4")
                self.emit("SUB     R13, 1")
                self.emit(f"BBRA.NZ R13, {lbl_clr_loop}")

        coro_steps = []
        if func.body is not None:
            self._collect_coroutine_steps(func.body, coro_steps)

        if coro_steps:
            self.emit("; Coroutine entry continuation dispatch")
            task_ref = coro_steps[0][1]
            self._emit_lvalue_addr(task_ref, target_reg=14)
            self.emit("LD16     R1, (R14)", "Read continuation counter")
            lbl_entry_0 = f"._step_{func.name}_0"
            lbl_skip_0 = self.new_label("coro_skip")
            self.emit("LD       R3, R1", "Copy lc for check")
            self.emit("SEQ      R3, R0", "Check if initial entry (lc == 0)")
            self.emit(f"FBRA.Z   R3, {lbl_skip_0}", "Hop if not lc == 0")
            self.emit(f"FBRA     {lbl_entry_0}", "Wide branch to initial entry (8-bit)")
            self.emit_label(lbl_skip_0)
            seen = set()
            for s_val, _ in coro_steps:
                if s_val not in seen:
                    seen.add(s_val)
                    lbl_s = f"._step_{func.name}_{s_val}"
                    lbl_skip_s = self.new_label("coro_skip")
                    self.emit_immediate(2, s_val)
                    self.emit("LD       R3, R1", "Copy lc for check")
                    self.emit("SEQ      R3, R2", f"Check step {s_val}")
                    self.emit(f"FBRA.Z   R3, {lbl_skip_s}", "Hop if not matched")
                    self.emit(f"FBRA     {lbl_s}", f"Wide branch to step {s_val} (8-bit)")
                    self.emit_label(lbl_skip_s)
            self.emit_label(lbl_entry_0)

        self.gen_block(func.body)

        if coro_steps:
            self.emit("; Coroutine fallthrough completion (PK_ENDED)")
            task_ref = coro_steps[0][1]
            self._emit_lvalue_addr(task_ref, target_reg=14)
            self.emit("LD16     (R14), R0", "Reset continuation counter (lc = 0)")
            self.emit("LD       R1, 3", "Status PK_ENDED (3)")

        self.emit_label(f"._epilogue_{func.name}")
        if func.name == "main":
            if self.stack_offset > 0:
                self.emit_immediate(14, self.stack_offset)
                self.emit("ADD     R15, R14", "Deallocate stack frame")
            spin_lbl = f"._halt_{func.name}"
            self.emit_label(spin_lbl)
            self.emit(f"BBRA    {spin_lbl}", "Halt loop upon main completion")
        else:
            frame_locals = self.stack_offset - 4
            if frame_locals > 0:
                self.emit_immediate(14, frame_locals)
                self.emit("ADD     R15, R14", "Deallocate locals and spilled params")
            self.emit("POP32   R14", "Restore return address link")
            self.emit("RRET", "Return to caller")
        self.asm.append("")

    def gen_block(self, block):
        for stmt in block.stmts:
            self.gen_stmt(stmt)


    def _collect_local_decls(self, node, decls):
        if node is None:
            return
        if isinstance(node, BlockNode):
            for s in node.stmts:
                self._collect_local_decls(s, decls)
        elif isinstance(node, IfNode):
            self._collect_local_decls(node.then_body, decls)
            if node.else_body:
                self._collect_local_decls(node.else_body, decls)
        elif isinstance(node, WhileNode):
            self._collect_local_decls(node.body, decls)
        elif isinstance(node, ForRangeNode):
            decls.append(VarDeclNode(node.var_type, False, node.var_name, None))
            decls.append(VarDeclNode("u32", False, f"{node.var_name}__end", None))
            self._collect_local_decls(node.body, decls)
        elif isinstance(node, SwitchNode):
            self._collect_local_decls(node.body, decls)
        elif isinstance(node, VarDeclNode):
            if not getattr(node, "is_const", False) and getattr(node, "bound_addr", None) is None:
                decls.append(node)
        elif isinstance(node, TupleAssignNode):
            for t in node.targets:
                if not t.is_wildcard and t.type_name is not None:
                    decls.append(VarDeclNode(t.type_name, t.is_ptr, t.name))

    def _collect_coroutine_steps(self, node, steps):
        if isinstance(node, (YieldNode, WaitUntilNode)):
            steps.append((node.step_const, node.task_ref))
        elif isinstance(node, BlockNode):
            for s in node.stmts:
                self._collect_coroutine_steps(s, steps)
        elif isinstance(node, IfNode):
            self._collect_coroutine_steps(node.then_body, steps)
            if node.else_body:
                self._collect_coroutine_steps(node.else_body, steps)
        elif isinstance(node, WhileNode):
            self._collect_coroutine_steps(node.body, steps)

    def _collect_switch_labels(self, node, cases, default_holder):
        if isinstance(node, CaseLabelNode):
            if isinstance(node.expr, int):
                node.val = node.expr
            elif isinstance(node.expr, IntLitNode):
                node.val = node.expr.val
            else:
                node.val = self._eval_const_expr(node.expr)
            node.label = self.new_label(f"case_{node.val}")
            cases.append((node.val, node.label))
        elif isinstance(node, DefaultLabelNode):
            node.label = self.new_label("default")
            default_holder[0] = node.label
        elif isinstance(node, BlockNode):
            for s in node.stmts:
                self._collect_switch_labels(s, cases, default_holder)
        elif isinstance(node, IfNode):
            self._collect_switch_labels(node.then_body, cases, default_holder)
            if node.else_body:
                self._collect_switch_labels(node.else_body, cases, default_holder)
        elif isinstance(node, WhileNode):
            self._collect_switch_labels(node.body, cases, default_holder)

    def _validate_fn_type_assignment(self, target_type, rhs_expr):
        if target_type in self.fn_types:
            exp_params, exp_ret = self.fn_types[target_type]
            rhs_t, _ = self._get_expr_type(rhs_expr)
            if rhs_t.startswith("fn_"):
                fn_name = rhs_t[3:]
                sig = self.func_signatures.get(fn_name)
                if not sig:
                    raise TypeError(f"Unknown function '{fn_name}' in function pointer assignment")
                act_ret, _, act_params_raw = sig
                act_params = [self._clean_type(p[0]) for p in act_params_raw]
                exp_params_clean = [self._clean_type(p) for p in exp_params]
                if len(exp_params_clean) != len(act_params) or exp_params_clean != act_params or exp_ret != act_ret:
                    exp_sig = f"fn({list(exp_params_clean)}) -> {exp_ret}"
                    act_sig = f"fn({list(act_params)}) -> {act_ret}"
                    raise TypeError(f"Function signature mismatch: cannot assign '{fn_name}' ({act_sig}) to type '{target_type}' ({exp_sig})")
            elif rhs_t in self.fn_types:
                if self.fn_types[target_type] != self.fn_types[rhs_t]:
                    raise TypeError(f"Function type mismatch: cannot assign '{rhs_t}' to '{target_type}'")
            else:
                raise TypeError(f"Cannot assign non-function value of type '{rhs_t}' to function pointer '{target_type}'")
        else:
            rhs_t, _ = self._get_expr_type(rhs_expr)
            if rhs_t.startswith("fn_") or rhs_t in self.fn_types:
                raise TypeError(f"Cannot implicitly convert function reference to non-function type '{target_type}'")

    def gen_stmt(self, stmt):
        if isinstance(stmt, BlockNode):
            self.gen_block(stmt)
            return

        elif isinstance(stmt, AsmNode):
            for l in stmt.asm_text.splitlines():
                if l.strip():
                    self.asm.append(f"    {l.strip()}")
            return

        elif isinstance(stmt, BreakNode):
            if not self.break_stack:
                raise SyntaxError("act16c: 'break' outside of loop or switch block")
            self.emit(f"FBRA    {self.break_stack[-1]}", "Break jump")
            return

        elif isinstance(stmt, CaseLabelNode):
            if stmt.label:
                self.emit_label(stmt.label)
            return

        elif isinstance(stmt, DefaultLabelNode):
            if stmt.label:
                self.emit_label(stmt.label)
            return

        elif isinstance(stmt, SwitchNode):
            lbl_end = self.new_label("switch_end")
            self.break_stack.append(lbl_end)

            cases = []
            default_holder = [None]
            self._collect_switch_labels(stmt.body, cases, default_holder)

            # Evaluate switch discriminant into R1
            self.gen_expr(stmt.expr, target_reg=1)

            # Generate dispatch checks without modifying stack
            for val, c_lbl in cases:
                lbl_match = self.new_label("case_match")
                lbl_skip = self.new_label("case_skip")
                self.emit("LD      R3, R1", "Copy discriminant for comparison")
                self.emit_immediate(2, val)
                self.emit("SUB     R3, R2")
                self.emit(f"FBRA.Z  R3, {lbl_match}", "Hop if matched (1 instruction)")
                self.emit(f"FBRA    {lbl_skip}", "Skip to next case check (8-bit)")
                self.emit_label(lbl_match)
                self.emit(f"FBRA    {c_lbl}", f"Wide dispatch to case {val} (8-bit)")
                self.emit_label(lbl_skip)

            # Default or exit branch
            target_default = default_holder[0] if default_holder[0] else lbl_end
            self.emit(f"FBRA    {target_default}", "Dispatch default or exit")

            # Emit nested body (which contains the CaseLabelNodes and code)
            self.gen_stmt(stmt.body)

            self.emit_label(lbl_end)
            self.break_stack.pop()
            return

        elif isinstance(stmt, VarDeclNode):
            if getattr(stmt, 'is_const', False):
                self.constants[stmt.name] = self._eval_const_expr(stmt.init_expr)
                return
            if getattr(stmt, 'bound_addr', None) is not None:
                self.bound_addrs[stmt.name] = stmt.bound_addr
                return

            if stmt.init_expr:
                if stmt.type_name == 'string' and isinstance(stmt.init_expr, StringLitNode):
                    cap = getattr(stmt, 'array_dim', self.array_lens.get(stmt.name, 0))
                    self._emit_string_init(stmt.name, stmt.init_expr, cap)
                    return
                self._validate_fn_type_assignment(stmt.type_name, stmt.init_expr)
                self.gen_expr(stmt.init_expr, target_reg=1)
                name = stmt.name
                if isinstance(stmt.init_expr, VarAccessNode) and stmt.init_expr.name in self.borrowed_params:
                    # Borrowed reference cannot be moved into an owning handle
                    pass
                if isinstance(stmt.init_expr, (HeapAllocNode, HeapArrayAllocNode, HeapStringAllocNode)):
                    self.affine_state[name] = 'VALID'
                if isinstance(stmt.init_expr, HeapArrayAllocNode):
                    self.dynamic_arrays.add(name)
                t_name, is_ptr, *rest = self.types.get(name, ('u32', False, False))
                offset = self.stack_offset - self.locals[name]
                self.emit_immediate(14, offset)
                self.emit("ADD     R14, R15")
                self._emit_store_typed(14, 1, t_name, is_ptr)

        
        elif isinstance(stmt, CompoundAssignNode):
            # Compound assignment: lhs op= rhs
            op_char = stmt.op[:-1] # Remove trailing '='
            self.gen_expr(stmt.rhs, target_reg=2)
            self.emit("PUSH32  R2", "Save compound RHS")
            self.stack_offset += 4

            # Evaluate LHS address
            if isinstance(stmt.lhs, VarAccessNode):
                name = stmt.lhs.name
                t_name, is_ptr, *rest = self.types.get(name, ('u32', False, False))
                if name in self.locals:
                    offset = self.stack_offset - self.locals[name]
                    self.emit_immediate(14, offset)
                    self.emit("ADD     R14, R15")
                elif name in self.globals:
                    self.emit(f"LOAD32  R14, _{name}")
                self._emit_load_typed(1, 14, t_name, is_ptr)
                self.emit("POP32   R2", "Restore compound RHS")
                self.stack_offset -= 4
                self._emit_binary_calc(op_char, 1, 2)
                self._emit_store_typed(14, 1, t_name, is_ptr)

            elif isinstance(stmt.lhs, ArrayAccessNode):
                t_name, _ = self._emit_array_elem_addr(stmt.lhs, addr_reg=14, idx_scratch=3, is_write=True)
                self._emit_load_typed(1, 14, t_name, False)
                self.emit("POP32   R2", "Restore compound RHS")
                self.stack_offset -= 4
                self._emit_binary_calc(op_char, 1, 2)
                self._emit_store_typed(14, 1, t_name, False)
                return
            elif isinstance(stmt.lhs, MemberAccessNode):
                base_expr = stmt.lhs.expr
                member = stmt.lhs.member
                t_name, is_ptr = self._get_expr_type(base_expr)
                s_name = self._clean_type(t_name)
                m_offset, m_type, m_ptr, *rest = self.structs.get(s_name, {}).get(member, (0, 'u32', False, None))
                self._emit_lvalue_addr(base_expr, target_reg=14)
                if m_offset > 0:
                    self.emit_immediate(3, m_offset)
                    self.emit("ADD     R14, R3")
                self._emit_load_typed(1, 14, m_type, m_ptr)
                self.emit("POP32   R2", "Restore compound RHS")
                self.stack_offset -= 4
                self._emit_binary_calc(op_char, 1, 2)
                self._emit_store_typed(14, 1, m_type, m_ptr)
            return

        elif isinstance(stmt, ExprStmtNode):
            self.gen_expr(stmt.expr, target_reg=1)

        elif isinstance(stmt, YieldNode):
            # yield(task, step): task.lc = step; return PK_YIELDED; case step:
            self._emit_lvalue_addr(stmt.task_ref, target_reg=14)
            self.emit_immediate(1, stmt.step_const)
            self.emit("LD16     (R14), R1", "Set continuation counter")
            self.emit("LD       R1, 1", "PK_YIELDED status (1)")
            self.emit(f"FBRA     ._epilogue_{self.current_func_name}")
            self.emit_label(f"._step_{self.current_func_name}_{stmt.step_const}")
            return

        elif isinstance(stmt, WaitUntilNode):
            # wait_until(task, step, cond): case step: if (!cond) { task.lc = step; return PK_WAITING; }
            self.emit_label(f"._step_{self.current_func_name}_{stmt.step_const}")
            lbl_continue = self.new_label("wait_cont")
            self.gen_expr(stmt.cond, target_reg=1)
            self.emit(f"FBRA.NZ  R1, {lbl_continue}", "Condition satisfied, proceed")
            self._emit_lvalue_addr(stmt.task_ref, target_reg=14)
            self.emit_immediate(1, stmt.step_const)
            self.emit("LD16     (R14), R1", "Set continuation counter")
            self.emit("LD       R1, 0", "PK_WAITING status (0)")
            self.emit(f"FBRA     ._epilogue_{self.current_func_name}")
            self.emit_label(lbl_continue)
            return

        elif isinstance(stmt, VerifyNode):
            res = self._eval_const_expr(stmt.cond)
            if not res:
                tok = stmt.token
                loc = f"{tok.fname}:{tok.lineno}:{tok.col}" if tok else "verify"
                raise SyntaxError(f"{loc}: Compile-time verification failed: '{stmt.msg}'")
            return
        elif isinstance(stmt, TupleReturnNode):
            # Strict callee return validation
            ret_type_info = getattr(self, 'current_func_ret', (None, False))
            if not isinstance(ret_type_info[0], list):
                raise SyntaxError(f"Function '{self.current_func_name}' has scalar return type '{ret_type_info[0]}', cannot return tuple")
            expected_arity = len(ret_type_info[0])
            if len(stmt.exprs) != expected_arity:
                raise SyntaxError(f"Tuple return arity mismatch in '{self.current_func_name}': expected {expected_arity}, got {len(stmt.exprs)}")

            num_returns = len(stmt.exprs)
            # Check if all return expressions are simple leaves (IntLitNode or VarAccessNode)
            # which can safely be placed directly into R1..Rn without evaluation clobbering
            all_simple = all(isinstance(e, (IntLitNode, VarAccessNode)) for e in stmt.exprs)
            if all_simple:
                for i, e in enumerate(stmt.exprs):
                    self.gen_expr(e, target_reg=i + 1)
            else:
                for i, e in enumerate(stmt.exprs):
                    self.gen_expr(e, target_reg=1)
                    self.emit("PUSH32  R1", f"Save tuple return elem {i+1}")
                    self.stack_offset += 4
                for i in reversed(range(num_returns)):
                    target_r = i + 1
                    self.emit(f"POP32   R{target_r}", f"Restore tuple return into R{target_r}")
                    self.stack_offset -= 4
            self.emit(f"FBRA    ._epilogue_{self.current_func_name}")

        elif isinstance(stmt, TupleAssignNode):
            # Save return registers if RHS is evaluated
            self.gen_expr(stmt.expr, target_reg=1)
            for i, target in enumerate(stmt.targets):
                if target.is_wildcard:
                    continue
                reg_src = i + 1
                name = target.name
                if target.type_name is not None:
                    self.types[name] = (target.type_name, target.is_ptr, False)
                t_name, is_ptr, *rest = self.types.get(name, ('u32', False, False))
                if name in self.locals:
                    offset = self.stack_offset - self.locals[name]
                    if offset > 0:
                        self.emit_immediate(14, offset)
                        self.emit("ADD     R14, R15")
                    else:
                        self.emit("LD      R14, R15")
                    self._emit_store_typed(14, reg_src, t_name, is_ptr)
                elif name in self.globals:
                    self.emit(f"LOAD32  R14, _{name}")
                    self._emit_store_typed(14, reg_src, t_name, is_ptr)

        elif isinstance(stmt, ReturnNode):
            ret_type_info = getattr(self, 'current_func_ret', (None, False))
            if isinstance(ret_type_info[0], list):
                raise SyntaxError(f"Function '{self.current_func_name}' declared with tuple return of arity {len(ret_type_info[0])}, cannot return scalar or void")
            if stmt.expr:
                self.gen_expr(stmt.expr, target_reg=1)
            if self.inline_return_stack:
                lbl_inline_end, initial_offset = self.inline_return_stack[-1]
                frame_extra = self.stack_offset - initial_offset
                if frame_extra > 0:
                    self.emit_immediate(14, frame_extra)
                    self.emit("ADD     R15, R14", "Unwind inline stack frame on return")
                self.emit(f"FBRA    {lbl_inline_end}", "Return from inline function")
            else:
                self.emit(f"FBRA    ._epilogue_{self.current_func_name}")

        elif isinstance(stmt, IfNode):
            # Attempt compile-time constant branch pruning (replaces preprocessor #if/#ifdef)
            is_const_cond = False
            const_val = 0
            try:
                const_val = self._eval_const_expr(stmt.cond)
                is_const_cond = True
            except ValueError:
                is_const_cond = False

            if is_const_cond:
                if const_val != 0:
                    self.gen_stmt(stmt.then_body)
                elif stmt.else_body:
                    self.gen_stmt(stmt.else_body)
                return

            lbl_else = self.new_label("else")
            lbl_end = self.new_label("endif")
            target = lbl_else if stmt.else_body else lbl_end

            self._gen_cond_jump(stmt.cond, target)

            self.gen_stmt(stmt.then_body)
            if stmt.else_body:
                self.emit(f"FBRA     {lbl_end}")
                self.emit_label(lbl_else)
                self.gen_stmt(stmt.else_body)
            self.emit_label(lbl_end)

        elif isinstance(stmt, WhileNode):
            lbl_loop = self.new_label("while_start")
            lbl_end = self.new_label("while_end")
            self.break_stack.append(lbl_end)

            self.emit_label(lbl_loop)
            self._gen_cond_jump(stmt.cond, lbl_end)

            self.gen_stmt(stmt.body)
            self.emit(f"BBRA     {lbl_loop}", "Loop back")
            self.emit_label(lbl_end)
            self.break_stack.pop()

        elif isinstance(stmt, ForRangeNode):
            lbl_loop = self.new_label("for_start")
            lbl_body = self.new_label("for_body")
            lbl_end = self.new_label("for_end")
            self.break_stack.append(lbl_end)

            end_var_name = f"{stmt.var_name}__end"

            # 1. Initialize induction variable
            self.gen_expr(stmt.start_expr, target_reg=1)
            var_off = self.stack_offset - self.locals[stmt.var_name]
            self.emit_immediate(14, var_off)
            self.emit("ADD     R14, R15")
            self.emit("ST32    (R14), R1", f"Init for-loop var '{stmt.var_name}'")

            # 2. Evaluate upper bound once and store into pre-allocated slot
            self.gen_expr(stmt.end_expr, target_reg=1)
            end_off = self.stack_offset - self.locals[end_var_name]
            self.emit_immediate(14, end_off)
            self.emit("ADD     R14, R15")
            self.emit("ST32    (R14), R1", f"Cache upper bound for loop '{stmt.var_name}'")

            # 3. Trampoline condition check
            self.emit_label(lbl_loop)
            var_off = self.stack_offset - self.locals[stmt.var_name]
            self.emit_immediate(14, var_off)
            self.emit("ADD     R14, R15")
            self.emit("LD32    R1, (R14)", f"Load induction var '{stmt.var_name}'")

            end_off = self.stack_offset - self.locals[end_var_name]
            self.emit_immediate(14, end_off)
            self.emit("ADD     R14, R15")
            self.emit("LD32    R2, (R14)", f"Load cached upper bound for '{stmt.var_name}'")

            self.emit("SLT     R1, R2", "Loop condition i < end")
            self.emit(f"FBRA.NZ R1, {lbl_body}", "Enter for body if true")
            self.emit(f"FBRA    {lbl_end}", "Exit for loop if false")

            # 4. Body
            self.emit_label(lbl_body)
            self.gen_stmt(stmt.body)

            # 5. Unit stride step (+1)
            var_off = self.stack_offset - self.locals[stmt.var_name]
            self.emit_immediate(14, var_off)
            self.emit("ADD     R14, R15")
            self.emit("LD32    R1, (R14)")
            self.emit("ADD     R1, 1", f"Step '{stmt.var_name}' +1")
            self.emit("ST32    (R14), R1")

            # 6. Branch back
            self.emit(f"BBRA    {lbl_loop}", "Loop back")

            # 7. Epilogue
            self.emit_label(lbl_end)
            self.break_stack.pop()

    def _gen_cond_jump(self, cond_expr, false_target):
        # Optimized control-flow branch fusion for relational comparisons
        lbl_hop = self.new_label("hop_false")
        lbl_cont = self.new_label("hop_cont")

        if isinstance(cond_expr, BinaryOpNode) and cond_expr.op in ('==', '!=', '<=', '>=', '<', '>'):
            self.gen_expr(cond_expr.left, target_reg=1)
            self.emit("PUSH32  R1", "Save LHS for comparison branch")
            self.stack_offset += 4
            self.gen_expr(cond_expr.right, target_reg=2)
            self.emit("POP32   R1", "Restore LHS for comparison branch")
            self.stack_offset -= 4

            op = cond_expr.op
            l_t, _ = self._get_expr_type(cond_expr.left)
            r_t, _ = self._get_expr_type(cond_expr.right)
            is_signed = (l_t in ('s8', 's16', 's32') or r_t in ('s8', 's16', 's32'))
            sle_op = "SSLE" if is_signed else "SLE"

            if op == '==':
                self.emit("SEQ      R1, R2", "Single-cycle equal")
                self.emit(f"FBRA.Z   R1, {lbl_hop}", "Hop if condition false (not equal)")
            elif op == '!=':
                self.emit("SNE      R1, R2", "Single-cycle not-equal")
                self.emit(f"FBRA.Z   R1, {lbl_hop}", "Hop if condition false (equal)")
            elif op == '<=':
                self.emit(f"{sle_op:<8} R1, R2", f"Single-cycle {'signed' if is_signed else 'unsigned'} less-equal")
                self.emit(f"FBRA.Z   R1, {lbl_hop}", "Hop if condition false (!(L <= R))")
            elif op == '>=':
                self.emit(f"{sle_op:<8} R2, R1", f"Single-cycle {'signed' if is_signed else 'unsigned'} greater-equal (swapped <=)")
                self.emit(f"FBRA.Z   R2, {lbl_hop}", "Hop if condition false (!(R <= L))")
            elif op == '<':
                self.emit(f"{sle_op:<8} R2, R1", f"Single-cycle {'signed' if is_signed else 'unsigned'} less check via inverted SLE")
                self.emit(f"FBRA.NZ  R2, {lbl_hop}", "Hop if condition false (R <= L)")
            elif op == '>':
                self.emit(f"{sle_op:<8} R1, R2", f"Single-cycle {'signed' if is_signed else 'unsigned'} greater check via inverted SLE")
                self.emit(f"FBRA.NZ  R1, {lbl_hop}", "Hop if condition false (L <= R)")
        else:
            self.gen_expr(cond_expr, target_reg=1)
            self.emit(f"FBRA.Z   R1, {lbl_hop}", "Hop if condition false")

        self.emit(f"FBRA     {lbl_cont}", "Enter body")
        self.emit_label(lbl_hop)
        self.emit(f"FBRA     {false_target}", "Wide branch to target (8-bit)")
        self.emit_label(lbl_cont)

    def _emit_lvalue_addr(self, node, target_reg=14):
        if isinstance(node, VarAccessNode):
            name = node.name
            t_info = self.types.get(name, ('u32', False, False))
            is_ref = t_info[2] if len(t_info) > 2 else False
            if name in self.bound_addrs:
                self.emit_immediate(target_reg, self.bound_addrs[name])
            elif name in self.locals:
                offset = self.stack_offset - self.locals[name]
                self.emit_immediate(target_reg, offset)
                self.emit(f"ADD     R{target_reg}, R15", f"Address of local '{name}'")
                if is_ref:
                    self.emit(f"LD32    R{target_reg}, (R{target_reg})", f"Dereference ref param '{name}'")
            elif name in self.globals:
                self.emit(f"LOAD32  R{target_reg}, _{name}")
        elif isinstance(node, MemberAccessNode):
            base_expr = node.expr
            member = node.member
            t_name, base_is_ptr = self._get_expr_type(base_expr)
            s_name = self._clean_type(t_name)
            m_offset, m_type, m_ptr, *rest = self.structs.get(s_name, {}).get(member, (0, 'u32', False, None))
            self._emit_lvalue_addr(base_expr, target_reg=target_reg)
            if base_is_ptr:
                self.emit(f"LD32    R{target_reg}, (R{target_reg})", f"Dereference pointer base '{getattr(base_expr, 'name', '')}'")
            if m_offset > 0:
                self.emit_immediate(2, m_offset)
                self.emit(f"ADD     R{target_reg}, R2", f"Offset {m_offset} for field '{member}'")
        elif isinstance(node, ArrayAccessNode):
            self._emit_array_elem_addr(node, addr_reg=target_reg, idx_scratch=2)
        elif isinstance(node, UnaryOpNode) and node.op == '*':
            self.gen_expr(node.operand, target_reg=target_reg)
        else:
            self.gen_expr(node, target_reg=target_reg)

    def _get_elem_size(self, t_name, is_ptr):
        if is_ptr:
            return 4
        clean = self._clean_type(t_name)
        if clean in ('u8', 's8', 'string'):
            return 1
        elif clean in ('u16', 's16'):
            return 2
        elif clean in self.structs:
            return self.structs[clean].get('__size__', 4)
        return 4

    def _emit_array_elem_addr(self, node, addr_reg=14, idx_scratch=2, is_write=False):
        # 1. Flatten nested ArrayAccessNodes from outermost to innermost
        indices = []
        curr = node
        while isinstance(curr, ArrayAccessNode):
            indices.append(curr.index)
            curr = curr.base
        indices.reverse()
        base_node = curr
        base_name = getattr(base_node, 'name', None)
        is_open = base_name and (base_name in self.open_arrays)

        dims = self.array_dims.get(base_name, [])
        if not dims and base_name and base_name in self.array_lens:
            dims = [self.array_lens[base_name]]
        elif not dims and isinstance(base_node, MemberAccessNode):
            p_t, _ = self._get_expr_type(base_node.expr)
            s_name = self._clean_type(p_t)
            _, m_type, _, m_dim, *rest = self.structs.get(s_name, {}).get(base_node.member, (0, "u32", False, None))
            if isinstance(m_dim, list):
                dims = m_dim
            elif m_dim is not None:
                dims = [m_dim]

        # 2. Evaluate flat offset across indices
        # We accumulate into R{idx_scratch}
        for dim_idx, idx_expr in enumerate(indices):
            if dim_idx > 0:
                self.emit(f"PUSH32  R{idx_scratch}", "Preserve accumulated flat index")
                self.stack_offset += 4

            # Evaluate current index into R3
            self.gen_expr(idx_expr, target_reg=3)

            # Runtime Bounds Check with TRAP 15 (use R13 to avoid clobbering)
            if self.bounds_check:
                lbl_in_bounds = self.new_label("in_bounds")
                if is_open and dim_idx == 0:
                    len_off = self.stack_offset - self.locals[f"{base_name}__len"]
                    self.emit_immediate(14, len_off)
                    self.emit("ADD     R14, R15")
                    self.emit("LD32    R14, (R14)", f"Load dynamic length for '{base_name}'")
                    self.emit("LD      R13, R3", "Preserve index for bounds check")
                    self.emit("SLT     R13, R14", f"Check {base_name}[i] < dynamic length")
                    self.emit(f"FBRA.NZ R13, {lbl_in_bounds}", "Branch if within array bounds")
                    self.emit("TRAP    15", f"Open array out-of-bounds trap ({base_name})")
                    self.emit_label(lbl_in_bounds)
                elif base_name and (base_name in self.affine_state) and dim_idx == 0:
                    # Dynamic heap array / string bounds check via prefix header at (base - 4)
                    len_off = self.stack_offset - self.locals[base_name]
                    self.emit_immediate(14, len_off)
                    self.emit("ADD     R14, R15")
                    self.emit("LD32    R14, (R14)", f"Load heap pointer for '{base_name}'")
                    self.emit("SUB     R14, 4", "Point to prefix header")
                    self.emit("LD32    R14, (R14)", "Read dynamic bound from prefix header")
                    base_t, _ = self._get_expr_type(base_node)
                    if is_write and self._clean_type(base_t) == 'string':
                        self.emit("SUB     R14, 1", "Reserve null terminator for dynamic string write")
                    self.emit("LD      R13, R3", "Preserve index for bounds check")
                    self.emit("SLT     R13, R14", f"Check dynamic {base_name}[i] < bound")
                    self.emit(f"FBRA.NZ R13, {lbl_in_bounds}", "Branch if within array bounds")
                    self.emit("TRAP    15", f"Dynamic heap out-of-bounds trap ({base_name})")
                    self.emit_label(lbl_in_bounds)
                elif dim_idx < len(dims):
                    arr_dim = dims[dim_idx]
                    bnd = arr_dim
                    base_t, _ = self._get_expr_type(base_node)
                    if is_write and self._clean_type(base_t) == 'string' and dim_idx == len(indices) - 1:
                        bnd = max(0, arr_dim - 1)
                    self.emit_immediate(14, bnd)
                    self.emit("LD      R13, R3", "Preserve index for bounds check")
                    self.emit("SLT     R13, R14", f"Check index < {bnd}")
                    self.emit(f"FBRA.NZ R13, {lbl_in_bounds}", "Branch if within array bounds")
                    self.emit("TRAP    15", f"Array out-of-bounds trap ({base_name})")
                    self.emit_label(lbl_in_bounds)

            if dim_idx == 0:
                self.emit(f"LD      R{idx_scratch}, R3", "Initialize flat index")
            else:
                self.emit(f"POP32   R{idx_scratch}", "Restore accumulated flat index")
                self.stack_offset -= 4
                next_dim = dims[dim_idx] if dim_idx < len(dims) else 1
                self.emit_immediate(14, next_dim)
                self.emit(f"MULL    R{idx_scratch}, R14", f"Multiply by dimension {next_dim}")
                self.emit(f"ADD     R{idx_scratch}, R3", "Add current dimension index")

        # Save accumulated index before computing base address (which may clobber scratch registers like R2)
        self.emit(f"PUSH32  R{idx_scratch}", "Save flat index across base address computation")
        self.stack_offset += 4

        # 3. Compute Base Address into addr_reg
        if is_open:
            offset = self.stack_offset - self.locals[base_name]
            self.emit_immediate(addr_reg, offset)
            self.emit(f"ADD     R{addr_reg}, R15")
            self.emit(f"LD32    R{addr_reg}, (R{addr_reg})", f"Dereference open array base '{base_name}'")
        elif base_name and base_name in self.bound_addrs:
            self.emit_immediate(addr_reg, self.bound_addrs[base_name])
        elif base_name and base_name in self.locals:
            offset = self.stack_offset - self.locals[base_name]
            self.emit_immediate(addr_reg, offset)
            self.emit(f"ADD     R{addr_reg}, R15", f"Base of local array '{base_name}'")
            t_info = self.types.get(base_name, ('u32', False, False))
            is_ptr = t_info[1] if len(t_info) > 1 else False
            is_ref = t_info[2] if len(t_info) > 2 else False
            is_local_fixed = base_name in self.array_dims or base_name in self.array_lens
            if is_ref or is_ptr or not is_local_fixed:
                self.emit(f"LD32    R{addr_reg}, (R{addr_reg})", f"Dereference pointer/param base '{base_name}'")
        elif base_name and base_name in self.globals:
            self.emit(f"LOAD32  R{addr_reg}, _{base_name}", f"Base of global array '{base_name}'")
        elif isinstance(base_node, MemberAccessNode):
            self._emit_lvalue_addr(base_node, target_reg=addr_reg)
        else:
            self.gen_expr(base_node, target_reg=addr_reg)

        # Restore accumulated index
        self.emit(f"POP32   R{idx_scratch}", "Restore flat index")
        self.stack_offset -= 4

        # 4. Scale index by remaining element/slice size
        base_type, _ = self._get_expr_type(base_node)
        leaf_elem_sz = self._get_elem_size(base_type, False)
        remaining_stride = 1
        for d in dims[len(indices):]:
            remaining_stride *= d
        stride = leaf_elem_sz * remaining_stride

        if stride == 2:
            self.emit(f"SHIFTL  R{idx_scratch}, 1", "Scale index by 2")
        elif stride == 4:
            self.emit(f"SHIFTL  R{idx_scratch}, 2", "Scale index by 4")
        elif stride == 8:
            self.emit(f"SHIFTL  R{idx_scratch}, 3", "Scale index by 8")
        elif stride != 1:
            stride_reg = 13 if addr_reg == 14 else 14
            self.emit_immediate(stride_reg, stride)
            self.emit(f"MULL    R{idx_scratch}, R{stride_reg}", f"Scale index by stride {stride}")

        # 5. Add offset to base address
        self.emit(f"ADD     R{addr_reg}, R{idx_scratch}", "Indexed element address")
        return base_type, leaf_elem_sz

    def gen_expr(self, expr, target_reg=1):
        if isinstance(expr, HeapAllocNode):
            clean_type = self._clean_type(expr.type_name)
            sz = self.structs.get(clean_type, {}).get('__size__', 4)
            self.backend.gen_heap_alloc(target_reg, sz)
            return

        elif isinstance(expr, HeapArrayAllocNode):
            clean_type = self._clean_type(expr.type_name)
            elem_sz = self._get_elem_size(clean_type, False)
            self.gen_expr(expr.count_expr, target_reg=2)
            self.backend.gen_array_alloc(target_reg, elem_sz, count_reg=2)
            return

        elif isinstance(expr, HeapStringAllocNode):
            self.gen_expr(expr.cap_expr, target_reg=2)
            self.backend.gen_string_alloc(target_reg, cap_reg=2)
            return

        elif isinstance(expr, HeapFreeNode):
            target_var = expr.expr.name if isinstance(expr.expr, VarAccessNode) else None
            if target_var and target_var in self.borrowed_params:
                raise SyntaxError(f"act16c: cannot destroy borrowed reference parameter '{target_var}'")
            if target_var and target_var in self.affine_state:
                if self.affine_state[target_var] == 'MOVED':
                    raise SyntaxError(f"act16c: cannot destroy already moved/destroyed reference '{target_var}'")
            self.gen_expr(expr.expr, target_reg=1)
            if target_var and target_var in self.affine_state:
                self.affine_state[target_var] = 'MOVED'
            is_arr = target_var and (
                target_var in self.dynamic_arrays or
                target_var in self.array_dims or
                target_var in self.array_lens or
                target_var in self.open_arrays
            )
            if is_arr:
                self.backend.gen_array_free(1)
            else:
                self.backend.gen_heap_free(1)
            if target_var and target_var in self.locals:
                off = self.stack_offset - self.locals[target_var]
                self.emit_immediate(14, off)
                self.emit("ADD     R14, R15")
                self.emit("ST32    (R14), R0", f"Zero out destroyed affine reference '{target_var}'")
            return

        elif isinstance(expr, HeapArrayResizeNode):
            target_var = expr.expr.name if isinstance(expr.expr, VarAccessNode) else None
            if target_var and target_var in self.affine_state:
                if self.affine_state[target_var] == 'MOVED':
                    raise SyntaxError(f"act16c: cannot resize moved/destroyed reference '{target_var}'")
            # 1. Determine element size
            elem_t = 'u32'
            if target_var:
                t_info = self.types.get(target_var, ('u32', False, False))
                elem_t = t_info[0]
            elem_size = self._get_elem_size(elem_t, False)

            # 2. Evaluate new count into R2
            self.gen_expr(expr.new_len_expr, target_reg=2)

            # 3. Load current array pointer into R1
            self.gen_expr(expr.expr, target_reg=1)

            # 4. Invoke backend resize (returns updated payload in R1)
            self.backend.gen_array_resize(dst_reg=1, addr_reg=1, elem_size=elem_size, count_reg=2)

            # 5. Rebind local variable stack slot to new pointer
            if target_var and target_var in self.locals:
                off = self.stack_offset - self.locals[target_var]
                self.emit_immediate(14, off)
                self.emit("ADD     R14, R15")
                self.emit(f"ST32    (R14), R1", f"Update local reference '{target_var}' after resize")

            if target_reg != 1:
                self.emit(f"LD      R{target_reg}, R1")
            return

        elif isinstance(expr, HeapArrayFreeNode):
            target_var = expr.expr.name if isinstance(expr.expr, VarAccessNode) else None
            if target_var and target_var in self.affine_state:
                if self.affine_state[target_var] == 'MOVED':
                    raise SyntaxError(f"act16c: cannot destroy already moved/destroyed reference '{target_var}'")
            self.gen_expr(expr.expr, target_reg=1)
            if target_var and target_var in self.affine_state:
                self.affine_state[target_var] = 'MOVED'
            self.backend.gen_array_free(1)
            if target_var and target_var in self.locals:
                off = self.stack_offset - self.locals[target_var]
                self.emit_immediate(14, off)
                self.emit("ADD     R14, R15")
                self.emit("ST32    (R14), R0", f"Zero out destroyed affine array reference '{target_var}'")
            return

        elif isinstance(expr, ExistsNode):
            # Check liveness: if VarAccessNode and currently MOVED, we know it was destroyed -> evaluate to 0
            # Otherwise, read value from stack slot and check NEZ
            if isinstance(expr.expr, VarAccessNode):
                var_name = expr.expr.name
                if var_name in self.locals:
                    offset = self.stack_offset - self.locals[var_name]
                    self.emit_immediate(14, offset)
                    self.emit("ADD     R14, R15")
                    self.emit(f"LD32    R{target_reg}, (R14)", f"Read reference for .exists() ('{var_name}')")
                elif var_name in self.globals:
                    self.emit(f"LOAD32  R14, _{var_name}")
                    self.emit(f"LD32    R{target_reg}, (R14)", f"Read global reference for .exists() ('{var_name}')")
                else:
                    self.emit_immediate(target_reg, 0)
            else:
                self.gen_expr(expr.expr, target_reg=target_reg)
            self.emit(f"NEZ     R{target_reg}", "Check reference != 0 (.exists())")
            return

        elif isinstance(expr, IntLitNode):
            self.emit_immediate(target_reg, expr.val)

        elif isinstance(expr, MemberAccessNode):
            base_expr = expr.expr
            member = expr.member
            if member == "capacity":
                if isinstance(base_expr, VarAccessNode) and (base_expr.name in self.affine_state or self.types.get(base_expr.name, ('', False))[1]):
                    # Dynamic heap capacity header at base[-4]
                    self.gen_expr(base_expr, target_reg=14)
                    self.emit("SUB     R14, 4", "Point to prefix header")
                    self.emit(f"LD32    R{target_reg}, (R14)", "Read dynamic capacity header")
                    return
                if isinstance(base_expr, MemberAccessNode):
                    p_t, _ = self._get_expr_type(base_expr.expr)
                    s_name = self._clean_type(p_t)
                    _, _, _, f_dim, *rest = self.structs.get(s_name, {}).get(base_expr.member, (0, "u32", False, None))
                    arr_cap = f_dim[-1] if isinstance(f_dim, list) else (f_dim or 0)
                    self.emit_immediate(target_reg, arr_cap)
                    return
                arr_name = base_expr.name if hasattr(base_expr, 'name') else ""
                if arr_name in self.open_arrays:
                    len_off = self.stack_offset - self.locals[f"{arr_name}__len"]
                    self.emit_immediate(14, len_off)
                    self.emit("ADD     R14, R15")
                    self.emit(f"LD32    R{target_reg}, (R14)", f"Dynamic .capacity for open array \'{arr_name}\'")
                    return
                elif arr_name in self.array_dims:
                    arr_cap = self.array_dims[arr_name][-1]
                else:
                    arr_cap = self.array_lens.get(arr_name, 0)
                self.emit_immediate(target_reg, arr_cap)
                return
            elif member in ("len", "capacity"):
                arr_name = base_expr.name if hasattr(base_expr, 'name') else ""
                t_name = self.types.get(arr_name, ('', False, False))[0]
                is_p = self.types.get(arr_name, ('', False, False))[1]
                is_dynamic = is_p or (arr_name in self.affine_state)
                if is_dynamic and t_name != 'string':
                    # Dynamic heap array length header at base[-4]
                    self.gen_expr(base_expr, target_reg=14)
                    self.emit("SUB     R14, 4", "Point to prefix header")
                    self.emit(f"LD32    R{target_reg}, (R14)", "Read dynamic array length header")
                    return
                elif is_dynamic and t_name == 'string' and member == "capacity":
                    # Dynamic heap string capacity header at base[-4]
                    self.gen_expr(base_expr, target_reg=14)
                    self.emit("SUB     R14, 4", "Point to prefix header")
                    self.emit(f"LD32    R{target_reg}, (R14)", "Read dynamic string capacity header")
                    return
                arr_name = base_expr.name if hasattr(base_expr, 'name') else ""
                t_name = self.types.get(arr_name, ('', False, False))[0]
                if t_name == 'string':
                    self._emit_string_scan_len(arr_name, target_reg)
                    return
                if isinstance(base_expr, VarAccessNode):
                    arr_name = base_expr.name
                    if arr_name in self.open_arrays:
                        len_off = self.stack_offset - self.locals[f"{arr_name}__len"]
                        self.emit_immediate(14, len_off)
                        self.emit("ADD     R14, R15")
                        self.emit(f"LD32    R{target_reg}, (R14)", f"Dynamic .len for open array '{arr_name}'")
                    else:
                        arr_len = self.array_lens.get(arr_name, 0)
                        self.emit_immediate(target_reg, arr_len)
                    return
                elif isinstance(base_expr, MemberAccessNode):
                    parent_t, _ = self._get_expr_type(base_expr.expr)
                    s_name = self._clean_type(parent_t)
                    _, _, _, f_dim, *rest = self.structs.get(s_name, {}).get(base_expr.member, (0, "u32", False, None))
                    arr_len = f_dim[0] if isinstance(f_dim, list) else (f_dim or 0)
                    self.emit_immediate(target_reg, arr_len)
                    return

            # Method function pointer introspection (unbound Type.method only)
            if isinstance(base_expr, VarAccessNode) and base_expr.name in self.structs and base_expr.name not in self.locals and base_expr.name not in self.globals and base_expr.name not in self.bound_addrs:
                mangled_func = f"{base_expr.name}_{member}"
                if mangled_func in self.func_signatures:
                    self.emit(f"LOAD32  R{target_reg}, _{mangled_func}", f"Method function address '{mangled_func}'")
                    return
                raise SyntaxError(f"Type '{base_expr.name}' has no method '{member}'")

            t_n, _ = self._get_expr_type(base_expr)
            possible_type = self._clean_type(t_n)
            mangled_func = f"{possible_type}_{member}"
            if mangled_func in self.func_signatures:
                base_name = getattr(base_expr, "name", "instance")
                raise SyntaxError(
                    f"Cannot extract unbound method reference from instance '{base_name}'. "
                    f"Use '{possible_type}.{member}' with signature fn({possible_type}, ...) instead."
                )

            t_name, is_ptr = self._get_expr_type(base_expr)
            s_name = self._clean_type(t_name)
            m_offset, m_type, m_ptr, *rest = self.structs.get(s_name, {}).get(member, (0, 'u32', False, None))
            self._emit_lvalue_addr(expr, target_reg=14)
            self._emit_load_typed(target_reg, 14, m_type, m_ptr)

        elif isinstance(expr, ArrayAccessNode):
            t_name, elem_sz = self._emit_array_elem_addr(expr, addr_reg=14, idx_scratch=2)
            self._emit_load_typed(target_reg, 14, t_name, False)

        elif isinstance(expr, VarAccessNode):
            name = expr.name
            self._check_affine_access(name)
            if name in self.constants:
                self.emit_immediate(target_reg, self.constants[name])
                return
            if name in self.func_signatures:
                self.emit(f"LOAD32  R{target_reg}, _{name}", f"Function address '{name}'")
                return
            t_name, is_ptr, *rest = self.types.get(name, ('u32', False, False))
            if name in self.bound_addrs:
                self.emit_immediate(14, self.bound_addrs[name])
                if name in self.array_lens:
                    self.emit(f"LD      R{target_reg}, R14", f"Address of bound array '{name}'")
                else:
                    self._emit_load_typed(target_reg, 14, t_name, is_ptr)
            elif name in self.locals:
                offset = self.stack_offset - self.locals[name]
                self.emit_immediate(14, offset)
                self.emit("ADD     R14, R15", "Compute local address")
                if name in self.array_lens:
                    self.emit(f"LD      R{target_reg}, R14", f"Address of local array '{name}'")
                else:
                    self._emit_load_typed(target_reg, 14, t_name, is_ptr)
            elif name in self.globals:
                self.emit(f"LOAD32  R14, _{name}", f"Address of global '{name}'")
                if name in self.array_lens:
                    self.emit(f"LD      R{target_reg}, R14", f"Address of global array '{name}'")
                else:
                    self._emit_load_typed(target_reg, 14, t_name, is_ptr)

        elif isinstance(expr, UnaryOpNode):
            if expr.op == '*':
                self.gen_expr(expr.operand, target_reg=14)
                t_name, is_ptr = self._get_expr_type(expr.operand)
                self._emit_load_typed(target_reg, 14, t_name, False)
            elif expr.op == '&':
                if isinstance(expr.operand, VarAccessNode):
                    name = expr.operand.name
                    if name in self.locals:
                        offset = self.stack_offset - self.locals[name]
                        self.emit_immediate(target_reg, offset)
                        self.emit(f"ADD     R{target_reg}, R15", f"Address of local '{name}'")
                    elif name in self.bound_addrs:
                        self.emit_immediate(target_reg, self.bound_addrs[name])
                    elif name in self.globals:
                        self.emit(f"LOAD32  R{target_reg}, _{name}")
            elif expr.op == '-':
                self.gen_expr(expr.operand, target_reg=target_reg)
                self.emit(f"NEG     R{target_reg}")
            elif expr.op == '~':
                self.gen_expr(expr.operand, target_reg=target_reg)
                self.emit(f"NOT     R{target_reg}")
            elif expr.op == '!':
                lbl_true = self.new_label("not_true")
                lbl_done = self.new_label("not_done")
                self.gen_expr(expr.operand, target_reg=1)
                self.emit(f"FBRA.Z  R1, {lbl_true}")
                self.emit(f"LD      R{target_reg}, 0")
                self.emit(f"FBRA    {lbl_done}")
                self.emit_label(lbl_true)
                self.emit(f"LD      R{target_reg}, 1")
                self.emit_label(lbl_done)

        elif isinstance(expr, CompoundAssignNode):
            # Compound assignment: lhs op= rhs
            op_char = expr.op[:-1] # Strip trailing '='
            self.gen_expr(expr.rhs, target_reg=2)
            self.emit("PUSH32  R2", "Save compound RHS")
            self.stack_offset += 4

            if isinstance(expr.lhs, VarAccessNode):
                name = expr.lhs.name
                t_name, is_ptr, *rest = self.types.get(name, ('u32', False, False))
                if name in self.locals:
                    offset = self.stack_offset - self.locals[name]
                    self.emit_immediate(14, offset)
                    self.emit("ADD     R14, R15")
                elif name in self.globals:
                    self.emit(f"LOAD32  R14, _{name}")
                self._emit_load_typed(1, 14, t_name, is_ptr)
                self.emit("POP32   R2", "Restore compound RHS")
                self.stack_offset -= 4
                self._emit_binary_calc(op_char, 1, 2)
                self._emit_store_typed(14, 1, t_name, is_ptr)
                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")
            elif isinstance(expr.lhs, MemberAccessNode):
                base_expr = expr.lhs.expr
                member = expr.lhs.member
                t_name, is_ptr = self._get_expr_type(base_expr)
                s_name = self._clean_type(t_name)
                m_offset, m_type, m_ptr, *rest = self.structs.get(s_name, {}).get(member, (0, 'u32', False, None))
                self._emit_lvalue_addr(base_expr, target_reg=14)
                if m_offset > 0:
                    self.emit_immediate(3, m_offset)
                    self.emit("ADD     R14, R3")
                self._emit_load_typed(1, 14, m_type, m_ptr)
                self.emit("POP32   R2", "Restore compound RHS")
                self.stack_offset -= 4
                self._emit_binary_calc(op_char, 1, 2)
                self._emit_store_typed(14, 1, m_type, m_ptr)
                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")

        elif isinstance(expr, BinaryOpNode):
            if expr.op == '=':
                self.gen_expr(expr.right, target_reg=1)
                if isinstance(expr.left, MemberAccessNode):
                    # Compute lvalue address into R13 BEFORE evaluating RHS or altering stack offset
                    self._emit_lvalue_addr(expr.left, target_reg=13)
                    self.emit("PUSH32  R13", "Preserve lvalue address")
                    self.stack_offset += 4
                    self.gen_expr(expr.right, target_reg=1)
                    self.emit("POP32   R13", "Restore lvalue address")
                    self.stack_offset -= 4
                    t_name, is_ptr = self._get_expr_type(expr.left)
                    self._emit_store_typed(13, 1, t_name, is_ptr)
                    return
                elif isinstance(expr.left, UnaryOpNode) and expr.left.op == '*':
                    self.gen_expr(expr.left.operand, target_reg=14)
                    t_name, is_ptr = self._get_expr_type(expr.left.operand)
                    self._emit_store_typed(14, 1, t_name, False)
                    return
                elif isinstance(expr.left, ArrayAccessNode):
                    self.emit("PUSH32  R1", "Preserve RHS")
                    self.stack_offset += 4
                    t_name, _ = self._emit_array_elem_addr(expr.left, addr_reg=14, idx_scratch=2, is_write=True)
                    self.emit("POP32   R1", "Restore RHS")
                    self.stack_offset -= 4
                    self._emit_store_typed(14, 1, t_name, False)
                    return
                elif isinstance(expr.left, VarAccessNode):
                    name = expr.left.name
                    if isinstance(expr.right, (HeapAllocNode, HeapArrayAllocNode, HeapStringAllocNode)):
                        self.affine_state[name] = "VALID"
                        if isinstance(expr.right, HeapArrayAllocNode):
                            self.dynamic_arrays.add(name)
                    # Affine move semantics
                    if isinstance(expr.right, VarAccessNode):
                        rhs_name = expr.right.name
                        if rhs_name in self.borrowed_params and name in self.affine_state:
                            raise SyntaxError(f"act16c: cannot take ownership of borrowed parameter '{rhs_name}'")
                        if rhs_name in self.affine_state:
                            self._check_affine_access(rhs_name)
                            self.affine_state[rhs_name] = 'MOVED'
                            self.affine_state[name] = 'VALID'
                            if rhs_name in self.dynamic_arrays:
                                self.dynamic_arrays.add(name)
                    elif isinstance(expr.right, (HeapAllocNode, HeapArrayAllocNode, HeapStringAllocNode)):
                        self.affine_state[name] = 'VALID'
                    t_name, is_ptr, *rest = self.types.get(name, ('u32', False, False))
                    self._validate_fn_type_assignment(t_name, expr.right)
                    if name in self.bound_addrs:
                        self.emit_immediate(14, self.bound_addrs[name])
                        self._emit_store_typed(14, 1, t_name, is_ptr)
                    elif name in self.locals:
                        offset = self.stack_offset - self.locals[name]
                        self.emit_immediate(14, offset)
                        self.emit("ADD     R14, R15")
                        self._emit_store_typed(14, 1, t_name, is_ptr)
                    elif name in self.globals:
                        self.emit(f"LOAD32  R14, _{name}")
                        self._emit_store_typed(14, 1, t_name, is_ptr)
                return

            self.gen_expr(expr.left, target_reg=1)
            self.emit("PUSH32  R1", "Save LHS")
            self.stack_offset += 4
            self.gen_expr(expr.right, target_reg=2)
            self.emit("POP32   R1", "Restore LHS")
            self.stack_offset -= 4

            if expr.op == '+':
                self.emit(f"ADD     R{target_reg}, R2")
            elif expr.op == '-':
                self.emit(f"SUB     R{target_reg}, R2")
            elif expr.op == '*':
                self.emit(f"MULL    R{target_reg}, R2")
            elif expr.op == '/':
                self.emit(f"DIV     R{target_reg}, R2")
            elif expr.op == '%':
                self.emit(f"MOD     R{target_reg}, R2")
            elif expr.op == '&':
                self.emit(f"AND     R{target_reg}, R2")
            elif expr.op == '|':
                self.emit(f"OR      R{target_reg}, R2")
            elif expr.op == '^':
                self.emit(f"XOR     R{target_reg}, R2")
            elif expr.op == '<<':
                self.emit(f"SHIFTL  R{target_reg}, R2")
            elif expr.op == '>>':
                self.emit(f"SHIFTR  R{target_reg}, R2")
            elif expr.op == '&&':
                self.emit(f"AND     R1, R2")
                self.emit("NEZ     R1", "Logical AND boolean normalization")
                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")
            elif expr.op == '||':
                self.emit(f"OR      R1, R2")
                self.emit("NEZ     R1", "Logical OR boolean normalization")
                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")
            elif expr.op in ('==', '!=', '<', '<=', '>', '>='):
                l_t, _ = self._get_expr_type(expr.left)
                r_t, _ = self._get_expr_type(expr.right)
                is_signed = (l_t in ('s8', 's16', 's32') or r_t in ('s8', 's16', 's32'))
                self._gen_relational(expr.op, target_reg, is_signed=is_signed)

        elif isinstance(expr, StringLitNode):
            lbl = self.new_label("str")
            self.strings.append((lbl, expr.val))
            self.emit(f"LOAD32  R{target_reg}, {lbl}", "Load string address")

        elif isinstance(expr, TrapNode):
            self.emit(f"TRAP    {expr.trap_num}", f"Trigger Trap #{expr.trap_num}")
            self.emit(f"LD      R{target_reg}, 0")

        elif isinstance(expr, CallNode):
            if expr.name.startswith("__METHOD__"):
                m_name = expr.name.replace("__METHOD__", "")
                rcv_node = expr.args[0]
                if isinstance(rcv_node, UnaryOpNode) and rcv_node.op == '&':
                    rcv_node = rcv_node.operand
                t_name, _ = self._get_expr_type(rcv_node)
                s_name = self._clean_type(t_name)
                target_func, embed_offset = self._resolve_method(s_name, m_name)
                if not target_func:
                    target_func = f"{s_name}_{m_name}"
                
                if isinstance(rcv_node, CallNode):
                    # Evaluated receiver returned pointer in R1
                    self.gen_expr(rcv_node, target_reg=1)
                else:
                    # Pass receiver by reference into R1
                    self._emit_lvalue_addr(rcv_node, target_reg=1)
                    if embed_offset > 0:
                        self.emit_immediate(2, embed_offset)
                        self.emit("ADD     R1, R2", f"Adjust receiver for embedded type (+{embed_offset})")
                
                # Check if receiver parameter expects an open array (companion capacity register in R2)
                sig_info = self.func_signatures.get(target_func, (None, False, []))
                param_sigs = sig_info[2] if isinstance(sig_info, tuple) and len(sig_info) > 2 else []
                rcv_p_sig = param_sigs[0] if param_sigs else (None, False, False)
                rcv_is_open = rcv_p_sig[2] if len(rcv_p_sig) > 2 else False

                if rcv_is_open:
                    rcv_name = getattr(rcv_node, "name", None)
                    if rcv_name and rcv_name in self.open_arrays:
                        len_off = self.stack_offset - self.locals[f"{rcv_name}__len"]
                        self.emit_immediate(2, len_off)
                        self.emit("ADD     R2, R15")
                        self.emit(f"LD32    R2, (R2)", f"Dynamic capacity for open array receiver '{rcv_name}'")
                    elif rcv_name and rcv_name in self.array_dims:
                        self.emit_immediate(2, self.array_dims[rcv_name][-1])
                    else:
                        arr_sz = self.array_lens.get(rcv_name, 0)
                        self.emit_immediate(2, arr_sz)

                    method_param_sigs = param_sigs[1:] if len(param_sigs) > 1 else []
                    has_args = len(expr.args) > 1
                    if has_args:
                        self.emit("PUSH32   R1", "Preserve receiver pointer")
                        self.emit("PUSH32   R2", "Preserve receiver capacity")
                        self.stack_offset += 8
                        self._gen_call_arg_list(expr.args[1:], method_param_sigs, start_reg=3)
                        self.emit("POP32    R2", "Restore receiver capacity")
                        self.emit("POP32    R1", "Restore receiver pointer")
                        self.stack_offset -= 8
                else:
                    method_param_sigs = param_sigs[1:] if len(param_sigs) > 1 else []
                    has_args = len(expr.args) > 1
                    if has_args:
                        self.emit("PUSH32   R1", "Preserve receiver pointer")
                        self.stack_offset += 4
                        self._gen_call_arg_list(expr.args[1:], method_param_sigs, start_reg=2)
                        self.emit("POP32    R1", "Restore receiver pointer")
                        self.stack_offset -= 4
                
                self.emit(f"RCALL   _{target_func}")
                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")
                return

            if expr.name == 'readfifo':
                chan = expr.args[0].val if isinstance(expr.args[0], IntLitNode) else 0
                self.emit(f"FIFO.R  R{target_reg}, {chan}")
                return
            elif expr.name == 'writefifo':
                chan = expr.args[0].val if isinstance(expr.args[0], IntLitNode) else 0
                self.gen_expr(expr.args[1], target_reg=1)
                self.emit(f"FIFO.W  R1, {chan}")
                return
            elif expr.name == 'tryreadfifo':
                chan = expr.args[0].val if isinstance(expr.args[0], IntLitNode) else 0
                self.emit(f"FIFO.TRYR R2, {chan}")
                self.gen_expr(expr.args[1], target_reg=3)
                self.emit("LD32    (R3), R2")
                self.emit(f"LD      R{target_reg}, R14")
                return

            if expr.name in self.inline_funcs:
                func = self.inline_funcs[expr.name]
                lbl_inline_end = self.new_label(f"inline_end_{expr.name}")
                saved_locals = dict(self.locals)
                saved_types = dict(self.types)
                initial_offset = self.stack_offset

                # Evaluate parameters and spill onto caller stack frame
                for i, (p_type, p_ptr, p_name, *_) in enumerate(func.params):
                    arg_expr = expr.args[i]
                    clean_pt = self._clean_type(p_type)
                    is_ref = (clean_pt in self.structs and not p_ptr)
                    self.types[p_name] = (p_type, p_ptr, is_ref)
                    if is_ref:
                        self._emit_lvalue_addr(arg_expr, target_reg=1)
                    else:
                        self.gen_expr(arg_expr, target_reg=1)
                    self.emit("PUSH32  R1", f"Spill inline param '{p_name}'")
                    self.stack_offset += 4
                    self.locals[p_name] = self.stack_offset

                self.inline_return_stack.append((lbl_inline_end, self.stack_offset))
                self.gen_block(func.body)
                self.emit_label(lbl_inline_end)
                self.inline_return_stack.pop()

                # Deallocate pushed inline params
                param_bytes = len(func.params) * 4
                if param_bytes > 0:
                    self.emit_immediate(14, param_bytes)
                    self.emit("ADD     R15, R14", f"Deallocate inline '{expr.name}' parameters")
                self.stack_offset = initial_offset
                self.locals = saved_locals
                self.types = saved_types

                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")
                return

            is_fn_var = expr.name in self.locals or expr.name in self.globals or expr.name in self.bound_addrs
            if is_fn_var:
                t_info = self.types.get(expr.name, ("u32", False, False))
                fn_t = t_info[0]
                if fn_t in self.fn_types:
                    p_types, _ = self.fn_types[fn_t]
                    param_sigs = [(p, False, False) for p in p_types]
                    self._gen_call_arg_list(expr.args, param_sigs, start_reg=1)
                else:
                    for i, arg in enumerate(expr.args[:4]):
                        self.gen_expr(arg, target_reg=i + 1)
                # Load indirect target into R13 (uses only R14 for address calc, preserving R1-R4)
                self.gen_expr(VarAccessNode(expr.name), target_reg=13)
                self.emit("JMP     R13, R14", f"Indirect call through '{expr.name}'")
                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")
            else:
                sig_info = self.func_signatures.get(expr.name, (None, False, []))
                param_sigs = sig_info[2] if isinstance(sig_info, tuple) and len(sig_info) > 2 else []
                self._gen_call_arg_list(expr.args, param_sigs, start_reg=1)
                self.emit(f"RCALL   _{expr.name}")
                if target_reg != 1:
                    self.emit(f"LD      R{target_reg}, R1")

    def _emit_array_len(self, base_expr, target_reg=14):
        base_name = getattr(base_expr, "name", "")
        if base_name and base_name in self.open_arrays:
            len_off = self.stack_offset - self.locals[f"{base_name}__len"]
            self.emit_immediate(target_reg, len_off)
            self.emit(f"ADD     R{target_reg}, R15")
            self.emit(f"LD32    R{target_reg}, (R{target_reg})", f"Dynamic len for open array '{base_name}'")
        elif isinstance(base_expr, MemberAccessNode):
            parent_t, _ = self._get_expr_type(base_expr.expr)
            s_name = self._clean_type(parent_t)
            _, _, _, f_dim, *rest = self.structs.get(s_name, {}).get(base_expr.member, (0, "u32", False, None))
            arr_len = f_dim[0] if isinstance(f_dim, list) else (f_dim or 0)
            self.emit_immediate(target_reg, arr_len)
        elif self._clean_type(self._get_expr_type(base_expr)[0]) == 'string':
            self._emit_string_scan_len(base_name, target_reg)
        else:
            arr_len = self.array_lens.get(base_name, 0)
            self.emit_immediate(target_reg, arr_len)

    def _gen_call_arg_list(self, args, param_sigs, start_reg=1):
        cur_reg = start_reg
        for i, arg in enumerate(args):
            if cur_reg > 4:
                break
            p_sig = param_sigs[i] if i < len(param_sigs) else (None, False, False)
            p_type, p_is_ptr = p_sig[0], p_sig[1]
            p_open = p_sig[2] if len(p_sig) > 2 else False
            if p_open:
                if isinstance(arg, SliceNode):
                    base_expr = arg.base
                    base_name = getattr(base_expr, "name", None)
                    elem_t, _ = self._get_expr_type(base_expr)
                    elem_sz = self._get_elem_size(elem_t, False)
                    if base_name and base_name in self.open_arrays:
                        off = self.stack_offset - self.locals[base_name]
                        self.emit_immediate(cur_reg, off)
                        self.emit(f"ADD     R{cur_reg}, R15")
                        self.emit(f"LD32    R{cur_reg}, (R{cur_reg})", f"Base of open array slice '{base_name}'")
                    else:
                        self._emit_lvalue_addr(base_expr, target_reg=cur_reg)
                    if arg.start_expr is not None:
                        if isinstance(arg.start_expr, IntLitNode):
                            start_val = arg.start_expr.val
                            if start_val > 0:
                                self.emit_immediate(14, start_val * elem_sz)
                                self.emit(f"ADD     R{cur_reg}, R14", "Add slice start offset")
                        else:
                            self.gen_expr(arg.start_expr, target_reg=14)
                            if elem_sz == 2:
                                self.emit("SHIFTL  R14, 1")
                            elif elem_sz == 4:
                                self.emit("SHIFTL  R14, 2")
                            elif elem_sz == 8:
                                self.emit("SHIFTL  R14, 3")
                            elif elem_sz != 1:
                                self.emit_immediate(13, elem_sz)
                                self.emit("MULL    R14, R13")
                            self.emit(f"ADD     R{cur_reg}, R14", "Add dynamic slice start offset")
                    len_reg = cur_reg + 1
                    if arg.end_expr is None:
                        self._emit_array_len(base_expr, target_reg=len_reg)
                        if arg.start_expr is not None:
                            if isinstance(arg.start_expr, IntLitNode):
                                if arg.start_expr.val > 0:
                                    self.emit_immediate(14, arg.start_expr.val)
                                    self.emit(f"SUB     R{len_reg}, R14", "Slice len = total_len - const_start")
                            else:
                                self.gen_expr(arg.start_expr, target_reg=14)
                                self.emit(f"SUB     R{len_reg}, R14", "Slice len = total_len - dynamic_start")
                    elif arg.start_expr is None:
                        if isinstance(arg.end_expr, IntLitNode):
                            self.emit_immediate(len_reg, arg.end_expr.val)
                        else:
                            self.gen_expr(arg.end_expr, target_reg=len_reg)
                    else:
                        if isinstance(arg.start_expr, IntLitNode) and isinstance(arg.end_expr, IntLitNode):
                            slice_len = max(0, arg.end_expr.val - arg.start_expr.val)
                            self.emit_immediate(len_reg, slice_len)
                        else:
                            self.gen_expr(arg.end_expr, target_reg=len_reg)
                            self.gen_expr(arg.start_expr, target_reg=14)
                            self.emit(f"SUB     R{len_reg}, R14", "Slice length = end - start")
                else:
                    arg_name = getattr(arg, "name", None)
                    if arg_name and arg_name in self.open_arrays:
                        off = self.stack_offset - self.locals[arg_name]
                        self.emit_immediate(cur_reg, off)
                        self.emit(f"ADD     R{cur_reg}, R15")
                        self.emit(f"LD32    R{cur_reg}, (R{cur_reg})", f"Forward open array ptr '{arg_name}'")
                        len_off = self.stack_offset - self.locals[f"{arg_name}__len"]
                        self.emit_immediate(cur_reg + 1, len_off)
                        self.emit(f"ADD     R{cur_reg + 1}, R15")
                        self.emit(f"LD32    R{cur_reg + 1}, (R{cur_reg + 1})", f"Forward open array len '{arg_name}'")
                    else:
                        self._emit_lvalue_addr(arg, target_reg=cur_reg)
                        arg_t, _ = self._get_expr_type(arg)
                        if self._clean_type(arg_t) == 'string':
                            self._emit_string_scan_len(arg_name, cur_reg + 1)
                        else:
                            arr_sz = self.array_lens.get(arg_name, 0)
                            self.emit_immediate(cur_reg + 1, arr_sz)
                cur_reg += 2
            elif p_type and p_type in self.structs and not p_is_ptr:
                self._emit_lvalue_addr(arg, target_reg=cur_reg)
                cur_reg += 1
            else:
                self.gen_expr(arg, target_reg=cur_reg)
                cur_reg += 1

    def _emit_binary_calc(self, op, r_dst, r_src):
        if op == '+':
            self.emit(f"ADD     R{r_dst}, R{r_src}")
        elif op == '-':
            self.emit(f"SUB     R{r_dst}, R{r_src}")
        elif op == '*':
            self.emit(f"MULL    R{r_dst}, R{r_src}")
        elif op == '/':
            self.emit(f"DIV     R{r_dst}, R{r_src}")
        elif op == '&':
            self.emit(f"AND     R{r_dst}, R{r_src}")
        elif op == '|':
            self.emit(f"OR      R{r_dst}, R{r_src}")
        elif op == '^':
            self.emit(f"XOR     R{r_dst}, R{r_src}")
        elif op == '<<':
            self.emit(f"SHIFTL  R{r_dst}, R{r_src}")
        elif op == '>>':
            self.emit(f"SHIFTR  R{r_dst}, R{r_src}")

    def _emit_load_typed(self, dst, addr_reg, t_name, is_ptr):
        if is_ptr or t_name in ('u32', 's32', 'string') or t_name in self.fn_types or t_name in self.structs:
            self.emit(f"LD32     R{dst}, (R{addr_reg})")
        elif t_name == 'u8':
            self.emit(f"LD8      R{dst}, (R{addr_reg})")
        elif t_name == 's8':
            self.emit(f"LD8      R{dst}, (R{addr_reg})")
            self.emit(f"SEXT8   R{dst}")
        elif t_name == 'u16':
            self.emit(f"LD16     R{dst}, (R{addr_reg})")
        elif t_name == 's16':
            self.emit(f"LD16     R{dst}, (R{addr_reg})")
            self.emit(f"SEXT16  R{dst}")
        else:
            self.emit(f"LD32     R{dst}, (R{addr_reg})")
    def _emit_store_typed(self, addr_reg, src, t_name, is_ptr):
        if is_ptr or t_name in ('u32', 's32', 'string') or t_name in self.fn_types or t_name in self.structs:
            self.emit(f"ST32     (R{addr_reg}), R{src}")
        elif t_name in ('u8', 's8'):
            self.emit(f"ST8      (R{addr_reg}), R{src}")
        elif t_name in ('u16', 's16'):
            self.emit(f"ST16     (R{addr_reg}), R{src}")
        else:
            self.emit(f"ST32     (R{addr_reg}), R{src}")
    def _gen_relational(self, op, target_reg, is_signed=False):
        # Native single-cycle Particle comparisons (SEQ, SNE, SLE, SSLE)
        # R1 is LHS, R2 is RHS
        sle_op = "SSLE" if is_signed else "SLE"
        if op == '==':
            self.emit("SEQ     R1, R2", "Single-cycle equal")
        elif op == '!=':
            self.emit("SNE     R1, R2", "Single-cycle not-equal")
        elif op == '<=':
            self.emit(f"{sle_op:<7} R1, R2", f"Single-cycle {'signed' if is_signed else 'unsigned'} less-equal")
        elif op == '>=':
            self.emit(f"{sle_op:<7} R2, R1", f"Single-cycle {'signed' if is_signed else 'unsigned'} greater-equal (swapped)")
            self.emit("LD      R1, R2")
        elif op == '<':
            self.emit(f"{sle_op:<7} R2, R1", f"Single-cycle {'signed' if is_signed else 'unsigned'} less (< <=> !(R2 <= R1))")
            self.emit("XOR     R2, 1")
            self.emit("LD      R1, R2")
        elif op == '>':
            self.emit(f"{sle_op:<7} R1, R2", f"Single-cycle {'signed' if is_signed else 'unsigned'} greater (> <=> !(R1 <= R2))")
            self.emit("XOR     R1, 1")
        if target_reg != 1:
            self.emit(f"LD      R{target_reg}, R1")

def main():
    parser = argparse.ArgumentParser(description="ACT16 Systems Language Compiler for Particle")
    parser.add_argument("sources", nargs="+", help="Input ACT16 source file(s) (.act / .c)")
    parser.add_argument("-o", "--output", default=None, help="Output assembly file (.asm)")
    parser.add_argument("-D", "--define", action="append", default=[], help="Predefine symbol (KEY[=VALUE])")
    parser.add_argument("-I", "--include-dir", action="append", default=[], help="Add include search directory")
    parser.add_argument("-fbounds-check", dest="bounds_check", action="store_true", default=True, help="Enable runtime array bounds checking (default)")
    parser.add_argument("-fno-bounds-check", dest="bounds_check", action="store_false", help="Disable runtime array bounds checking")
    args = parser.parse_args()

    primary_source = args.sources[0]
    if not args.output:
        base = os.path.splitext(os.path.basename(primary_source))[0]
        args.output = os.path.join("build", f"{base}.asm")

    out_dir = os.path.dirname(args.output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    defs = {}
    for d in args.define:
        if "=" in d:
            k, v = d.split("=", 1)
            defs[k.strip()] = int(v.strip(), 0) if v.strip().lstrip('-').isdigit() or v.strip().startswith('0x') else v.strip()
        else:
            defs[d.strip()] = 1

    all_decls = []
    seen_funcs = {}
    seen_types = {}

    imported_files = set()
    search_dirs = list(args.include_dir) if args.include_dir else []
    if "lib" not in search_dirs:
        search_dirs.append("lib")
    if "." not in search_dirs:
        search_dirs.append(".")

    def resolve_path(target, current_file):
        candidates = [
            os.path.join(os.path.dirname(current_file), target),
            target,
            os.path.abspath(target)
        ]
        for sdir in search_dirs:
            candidates.append(os.path.join(sdir, target))
            candidates.append(os.path.join(os.getcwd(), sdir, target))
        for cand in candidates:
            if os.path.isfile(cand):
                return os.path.realpath(cand)
        return None

    def ingest_file(file_path):
        real_p = os.path.realpath(file_path)
        if real_p in imported_files:
            return
        imported_files.add(real_p)

        with open(real_p, 'r', encoding='utf-8') as f:
            content = f.read()

        file_tokens = tokenize(content, fname=real_p)
        filtered = run_preprocessor(file_tokens, defs, current_file=real_p)
        parser_inst = Parser(filtered)
        parsed_ast = parser_inst.parse_program()

        for decl in parsed_ast.decls:
            if isinstance(decl, ImportNode):
                res = resolve_path(decl.path, real_p)
                if not res:
                    raise FileNotFoundError(f"Imported file '{decl.path}' not found (referenced from {real_p})")
                ingest_file(res)
            else:
                if isinstance(decl, FuncDeclNode):
                    if decl.body is not None:
                        if decl.name in seen_funcs:
                            prev_f = seen_funcs[decl.name]
                            raise SyntaxError(f"Redefinition of function '{decl.name}' in {real_p} (previously defined in {prev_f})")
                        seen_funcs[decl.name] = real_p
                elif isinstance(decl, TypeDefNode):
                    seen_types[decl.name] = real_p
                all_decls.append(decl)

    for src_path in args.sources:
        ingest_file(src_path)
    if False:
        for decl in []:
            if isinstance(decl, FuncDeclNode):
                # Prototypes (decl.body is None) are permitted; only enforce single full definition
                if decl.body is not None:
                    if decl.name in seen_funcs:
                        prev_f = seen_funcs[decl.name]
                        raise SyntaxError(f"Redefinition of function '{decl.name}' in {src_path} (previously defined in {prev_f})")
                    seen_funcs[decl.name] = src_path
            elif isinstance(decl, TypeDefNode):
                # Allow duplicate type declarations if fields match (e.g., shared headers)
                if decl.name in seen_types:
                    prev_t = seen_types[decl.name]
                    if prev_t != src_path:
                        # Allow identical declarations across files
                        pass
                seen_types[decl.name] = src_path
            all_decls.append(decl)

    merged_ast = ProgramNode(all_decls)

    cg = CodeGen(bounds_check=args.bounds_check)
    asm_code = cg.generate(merged_ast)

    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(asm_code)


if __name__ == "__main__":
    try:
        main()
    except (SyntaxError, FileNotFoundError, ValueError) as e:
        sys.stderr.write(f"act16c: error: {e}\n")
        sys.exit(1)
