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
    ('PREPROC',   r'#(?:ifdef|ifndef|else|endif)\b[^\n]*'),
    ('COMMENT',   r'//[^\n]*|/\*[\s\S]*?\*/'),
    ('HEX',       r'0x[0-9a-fA-F]+'),
    ('INT',       r'\d+'),
    ('STRING',    r'"(?:\\.|[^"\\])*"'),
    ('KEYWORD',   r'\b(?:u8|s8|u16|s16|u32|s32|void|const|if|else|while|for|return|break|continue)\b'),
    ('IDENT',     r'[a-zA-Z_]\w*'),
    ('OP_EQ',     r'=='),
    ('OP_NE',     r'!='),
    ('OP_LE',     r'<='),
    ('OP_GE',     r'>='),
    ('OP_SHL',    r'<<'),
    ('OP_SHR',    r'>>'),
    ('OP_AND',    r'&&'),
    ('OP_OR',     r'\|\|'),
    ('OP',        r'[+\-*/%&|^~<>=!]'),
    ('PUNCT',     r'[;,(){}\[\]]'),
    ('SPACE',     r'\s+'),
]

TOKEN_REGEX = '|'.join(f'(?P<{name}>{pattern})' for name, pattern in TOKEN_TYPES)

class Token:
    def __init__(self, type_, val, lineno, col):
        self.type = type_
        self.val = val
        self.lineno = lineno
        self.col = col

def tokenize(source_text):
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
        tokens.append(Token(kind, val, lineno, col))
    tokens.append(Token('EOF', '', lineno, 0))
    return tokens

# ------------------------------------------------------------------------------
# Preprocessor (C-Style Conditionals: #ifdef, #ifndef, #else, #endif)
# ------------------------------------------------------------------------------

def run_preprocessor(tokens, defines):
    out = []
    cond_stack = []

    for t in tokens:
        if t.type == 'PREPROC':
            line = t.val.strip()
            parts = line.split(None, 1)
            directive = parts[0]
            arg = parts[1].strip() if len(parts) > 1 else ""

            if directive == '#ifdef':
                active = (cond_stack[-1] if cond_stack else True) and (arg in defines)
                cond_stack.append(active)
            elif directive == '#ifndef':
                active = (cond_stack[-1] if cond_stack else True) and (arg not in defines)
                cond_stack.append(active)
            elif directive == '#else':
                if not cond_stack:
                    raise SyntaxError(f"Line {t.lineno}: #else without matching #if block")
                parent = cond_stack[-2] if len(cond_stack) > 1 else True
                cond_stack[-1] = parent and (not cond_stack[-1])
            elif directive == '#endif':
                if not cond_stack:
                    raise SyntaxError(f"Line {t.lineno}: #endif without matching #if block")
                cond_stack.pop()
            continue

        if cond_stack and not cond_stack[-1]:
            continue

        out.append(t)

    return out

# ------------------------------------------------------------------------------
# AST Nodes
# ------------------------------------------------------------------------------

class ASTNode: pass

class ProgramNode(ASTNode):
    def __init__(self, decls):
        self.decls = decls

class VarDeclNode(ASTNode):
    def __init__(self, type_name, is_ptr, name, init_expr=None):
        self.type_name = type_name
        self.is_ptr = is_ptr
        self.name = name
        self.init_expr = init_expr

class FuncDeclNode(ASTNode):
    def __init__(self, ret_type, ret_ptr, name, params, body):
        self.ret_type = ret_type
        self.ret_ptr = ret_ptr
        self.name = name
        self.params = params
        self.body = body

class BlockNode(ASTNode):
    def __init__(self, stmts):
        self.stmts = stmts

class IfNode(ASTNode):
    def __init__(self, cond, then_body, else_body=None):
        self.cond = cond
        self.then_body = then_body
        self.else_body = else_body

class WhileNode(ASTNode):
    def __init__(self, cond, body):
        self.cond = cond
        self.body = body

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

# ------------------------------------------------------------------------------
# Parser
# ------------------------------------------------------------------------------

class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def peek(self):
        return self.tokens[self.pos]

    def consume(self, expected_type=None, expected_val=None):
        t = self.peek()
        if expected_type and t.type != expected_type:
            raise SyntaxError(f"Line {t.lineno}: Expected {expected_type}, got {t.type} ('{t.val}')")
        if expected_val and t.val != expected_val:
            raise SyntaxError(f"Line {t.lineno}: Expected '{expected_val}', got '{t.val}'")
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

    def parse_top_level(self):
        if self.peek().val == 'const':
            self.consume()
        t_name = self.consume('KEYWORD').val
        is_ptr = False
        if self.peek().val == '*':
            self.consume()
            is_ptr = True
        name = self.consume('IDENT').val

        if self.peek().val == '(':
            self.consume('PUNCT', '(')
            params = []
            if self.peek().val != ')':
                while True:
                    if self.peek().val == 'void' and len(params) == 0:
                        self.consume()
                        break
                    p_type = self.consume('KEYWORD').val
                    p_ptr = False
                    if self.peek().val == '*':
                        self.consume()
                        p_ptr = True
                    p_name = self.consume('IDENT').val
                    params.append((p_type, p_ptr, p_name))
                    if self.peek().val == ',':
                        self.consume()
                    else:
                        break
            self.consume('PUNCT', ')')
            body = self.parse_block()
            return FuncDeclNode(t_name, is_ptr, name, params, body)
        else:
            init_expr = None
            if self.match('='):
                init_expr = self.parse_expr()
            self.consume('PUNCT', ';')
            return VarDeclNode(t_name, is_ptr, name, init_expr)

    def parse_block(self):
        self.consume('PUNCT', '{')
        stmts = []
        while self.peek().val != '}' and self.peek().type != 'EOF':
            stmts.append(self.parse_statement())
        self.consume('PUNCT', '}')
        return BlockNode(stmts)

    def parse_statement(self):
        tok = self.peek()
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
        if tok.val == 'while':
            self.consume()
            self.consume('PUNCT', '(')
            cond = self.parse_expr()
            self.consume('PUNCT', ')')
            body = self.parse_statement()
            return WhileNode(cond, body)
        if tok.val == 'return':
            self.consume()
            expr = None
            if self.peek().val != ';':
                expr = self.parse_expr()
            self.consume('PUNCT', ';')
            return ReturnNode(expr)

        if tok.val in ('u8', 's8', 'u16', 's16', 'u32', 's32'):
            t_name = self.consume().val
            is_ptr = False
            if self.peek().val == '*':
                self.consume()
                is_ptr = True
            name = self.consume('IDENT').val
            init_expr = None
            if self.match('='):
                init_expr = self.parse_expr()
            self.consume('PUNCT', ';')
            return VarDeclNode(t_name, is_ptr, name, init_expr)

        expr = self.parse_expr()
        self.consume('PUNCT', ';')
        return ExprStmtNode(expr)

    def parse_expr(self):
        return self.parse_assignment()

    def parse_assignment(self):
        node = self.parse_logical_or()
        if self.peek().val == '=':
            self.consume()
            rhs = self.parse_assignment()
            return BinaryOpNode('=', node, rhs)
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
        return self.parse_primary()

    def parse_primary(self):
        tok = self.peek()
        if tok.type in ('INT', 'HEX'):
            self.consume()
            return IntLitNode(int(tok.val, 0))
        if tok.type == 'IDENT':
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
                return CallNode(name, args)
            return VarAccessNode(name)
        if tok.val == '(':
            self.consume('PUNCT', '(')
            node = self.parse_expr()
            self.consume('PUNCT', ')')
            return node
        raise SyntaxError(f"Line {tok.lineno}: Unexpected token '{tok.val}'")

# ------------------------------------------------------------------------------
# Code Generator (Emits Particle Assembly)
# ------------------------------------------------------------------------------

class CodeGen:
    def __init__(self):
        self.asm = []
        self.label_counter = 0
        self.locals = {}
        self.globals = set()
        self.types = {}
        self.stack_offset = 0
        self.current_func_name = ""

    def emit(self, line, comment=""):
        if comment:
            self.asm.append(f"    {line:<24} ; {comment}")
        else:
            self.asm.append(f"    {line}")

    def emit_label(self, label):
        self.asm.append(f"{label}:")

    def new_label(self, prefix="L"):
        self.label_counter += 1
        return f"._{prefix}_{self.label_counter}"

    def emit_immediate(self, reg, val):
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

    def emit_branch_if_zero(self, reg, target_label):
        """
        Emits an 8-bit forward branch to target_label if reg == 0.
        Uses a local skip label so pasm.py calculates the 4-bit offset correctly.
        """
        lbl_skip = self.new_label("skip_zero_branch")
        self.emit(f"FBRA.P  R{reg}, {lbl_skip}", "Skip wide branch if true")
        self.emit(f"FBRA    {target_label}", "Wide branch if false/zero")
        self.emit_label(lbl_skip)

    def generate(self, root):
        self.asm.append("; ==============================================================================")
        self.asm.append("; Compiled from ACT16 Source via act16c.py")
        self.asm.append("; Target Architecture: Particle 32-bit RISC")
        self.asm.append("; ==============================================================================\n")
        self.asm.append('.include "lib/common.inc"\n')

        data_decls = [d for d in root.decls if isinstance(d, VarDeclNode)]
        func_decls = [d for d in root.decls if isinstance(d, FuncDeclNode)]
        has_main = any(f.name == "main" for f in func_decls)

        if has_main:
            self.asm.append("; ------------------------------------------------------------------------------")
            self.asm.append("; Direct Stride Vector Table & Startup Code (Auto-generated)")
            self.asm.append("; ------------------------------------------------------------------------------")
            self.asm.append(".org 0x00000100")
            self.emit_label("_vector_reset")
            self.emit("LOAD32  R15, 0x00010000", "Initialize Stack Pointer (top of 64KB)")
            self.emit("LOAD32  R14, _main", "Load entry address")
            self.emit("JMP     R14, R0", "Jump to _main (R0 discards return link)")
            self.emit(".align  64")
            self.asm.append("")
            self.emit_label("_vector_mbox")
            self.emit("FAST_ENTER_TRAP")
            self.emit("FAST_EXIT_TRAP")
            self.emit(".align  64")
            self.asm.append("")

        if data_decls:
            self.asm.append("; ------------------------------------------------------------------------------")
            self.asm.append("; Global Variable Allocation")
            self.asm.append("; ------------------------------------------------------------------------------")
            for d in data_decls:
                self.globals.add(d.name)
                self.types[d.name] = (d.type_name, d.is_ptr)
                self.emit_label(f"_{d.name}")
                if d.init_expr and isinstance(d.init_expr, IntLitNode):
                    self.emit(f".word   {d.init_expr.val}")
                else:
                    self.emit(".word   0")
            self.asm.append("")

        for f in func_decls:
            self.gen_func(f)

        return "\n".join(self.asm)

    def gen_func(self, func):
        self.current_func_name = func.name
        self.asm.append("; ------------------------------------------------------------------------------")
        self.asm.append(f"; Function: {func.name}")
        self.asm.append("; ------------------------------------------------------------------------------")
        self.emit_label(f"_{func.name}")

        if func.name != "main":
            self.emit("PUSH32  R14", "Preserve return address link")
        
        self.locals = {}
        self.stack_offset = 0

        for i, (p_type, p_ptr, p_name) in enumerate(func.params):
            self.types[p_name] = (p_type, p_ptr)
            if i < 4:
                self.emit(f"PUSH32  R{i + 1}", f"Spill param '{p_name}'")
                self.stack_offset += 4
                self.locals[p_name] = self.stack_offset

        self.gen_block(func.body)

        self.emit_label(f"._epilogue_{func.name}")
        if self.stack_offset > 0:
            self.emit(f"LOAD16  R14, {self.stack_offset}")
            self.emit("ADD     R15, R14", "Deallocate stack frame")

        if func.name == "main":
            spin_lbl = f"._halt_{func.name}"
            self.emit_label(spin_lbl)
            self.emit(f"FBRA    {spin_lbl}", "Halt loop upon main completion")
        else:
            self.emit("POP32   R14", "Restore return address link")
            self.emit("RRET", "Return to caller")
        self.asm.append("")

    def gen_block(self, block):
        for stmt in block.stmts:
            self.gen_stmt(stmt)

    def gen_stmt(self, stmt):
        if isinstance(stmt, BlockNode):
            self.gen_block(stmt)
            return

        elif isinstance(stmt, VarDeclNode):
            self.types[stmt.name] = (stmt.type_name, stmt.is_ptr)
            if stmt.init_expr:
                self.gen_expr(stmt.init_expr, target_reg=1)
                self.emit("PUSH32  R1", f"Local '{stmt.name}' with initial value")
            else:
                self.emit("PUSH32  R0", f"Local '{stmt.name}' zero initialized")
            self.stack_offset += 4
            self.locals[stmt.name] = self.stack_offset

        elif isinstance(stmt, ExprStmtNode):
            self.gen_expr(stmt.expr, target_reg=1)

        elif isinstance(stmt, ReturnNode):
            if stmt.expr:
                self.gen_expr(stmt.expr, target_reg=1)
            self.emit(f"FBRA    ._epilogue_{self.current_func_name}")

        elif isinstance(stmt, IfNode):
            lbl_else = self.new_label("else")
            lbl_end = self.new_label("endif")
            self.gen_expr(stmt.cond, target_reg=1)
            if stmt.else_body:
                self.emit_branch_if_zero(1, lbl_else)
                self.gen_stmt(stmt.then_body)
                self.emit(f"FBRA    {lbl_end}")
                self.emit_label(lbl_else)
                self.gen_stmt(stmt.else_body)
            else:
                self.emit_branch_if_zero(1, lbl_end)
                self.gen_stmt(stmt.then_body)
            self.emit_label(lbl_end)

        elif isinstance(stmt, WhileNode):
            lbl_loop = self.new_label("while_start")
            lbl_end = self.new_label("while_end")
            self.emit_label(lbl_loop)
            self.gen_expr(stmt.cond, target_reg=1)
            self.emit_branch_if_zero(1, lbl_end)
            self.gen_stmt(stmt.body)
            self.emit(f"BBRA    {lbl_loop}", "Loop back (8-bit backward reach)")
            self.emit_label(lbl_end)

    def gen_expr(self, expr, target_reg=1):
        if isinstance(expr, IntLitNode):
            self.emit_immediate(target_reg, expr.val)

        elif isinstance(expr, VarAccessNode):
            name = expr.name
            t_name, is_ptr = self.types.get(name, ('u32', False))
            if name in self.locals:
                offset = self.stack_offset - self.locals[name]
                self.emit_immediate(14, offset)
                self.emit("ADD     R14, R15", "Compute local address")
                self._emit_load_typed(target_reg, 14, t_name, is_ptr)
            elif name in self.globals:
                self.emit(f"LOAD32  R14, _{name}", f"Address of global '{name}'")
                self._emit_load_typed(target_reg, 14, t_name, is_ptr)

        elif isinstance(expr, BinaryOpNode):
            if expr.op == '=':
                self.gen_expr(expr.right, target_reg=1)
                if isinstance(expr.left, VarAccessNode):
                    name = expr.left.name
                    t_name, is_ptr = self.types.get(name, ('u32', False))
                    if name in self.locals:
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
            elif expr.op in ('==', '!=', '<', '<=', '>', '>='):
                self._gen_relational(expr.op, target_reg)

        elif isinstance(expr, CallNode):
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

            for i, arg in enumerate(expr.args[:4]):
                self.gen_expr(arg, target_reg=i + 1)
            self.emit(f"RCALL   _{expr.name}")
            if target_reg != 1:
                self.emit(f"LD      R{target_reg}, R1")

    def _emit_load_typed(self, dst, addr_reg, t_name, is_ptr):
        if is_ptr or t_name in ('u32', 's32'):
            self.emit(f"LD32    R{dst}, (R{addr_reg})")
        elif t_name == 'u8':
            self.emit(f"LD8     R{dst}, (R{addr_reg})")
        elif t_name == 's8':
            self.emit(f"LD8     R{dst}, (R{addr_reg})")
            self.emit(f"SEXT8   R{dst}")
        elif t_name == 'u16':
            self.emit(f"LD16    R{dst}, (R{addr_reg})")
        elif t_name == 's16':
            self.emit(f"LD16    R{dst}, (R{addr_reg})")
            self.emit(f"SEXT16  R{dst}")

    def _emit_store_typed(self, addr_reg, src, t_name, is_ptr):
        if is_ptr or t_name in ('u32', 's32'):
            self.emit(f"LD32    (R{addr_reg}), R{src}")
        elif t_name in ('u8', 's8'):
            self.emit(f"LD8     (R{addr_reg}), R{src}")
        elif t_name in ('u16', 's16'):
            self.emit(f"LD16    (R{addr_reg}), R{src}")

    def _gen_relational(self, op, target_reg):
        lbl_true = self.new_label("rel_true")
        lbl_end = self.new_label("rel_end")
        
        if op == '==':
            self.emit("SUB     R1, R2")
            self.emit(f"FBRA.Z  R1, {lbl_true}")
        elif op == '!=':
            self.emit("SUB     R1, R2")
            lbl_skip = self.new_label("skip_neq")
            self.emit(f"FBRA.Z  R1, {lbl_skip}")
            self.emit(f"FBRA    {lbl_true}")
            self.emit_label(lbl_skip)
        elif op == '<':
            self.emit("SLT     R1, R2")
            self.emit(f"FBRA.P  R1, {lbl_true}")
        elif op == '>=':
            self.emit("SLT     R1, R2")
            self.emit(f"FBRA.Z  R1, {lbl_true}")
        elif op == '<=':
            self.emit("SLT     R2, R1")
            self.emit(f"FBRA.Z  R2, {lbl_true}")
        elif op == '>':
            self.emit("SLT     R2, R1")
            self.emit(f"FBRA.P  R2, {lbl_true}")

        # False path: load 0 and jump to end
        self.emit(f"LD      R{target_reg}, 0")
        self.emit(f"FBRA    {lbl_end}")
        # True path: load 1
        self.emit_label(lbl_true)
        self.emit(f"LD      R{target_reg}, 1")
        self.emit_label(lbl_end)


def main():
    parser = argparse.ArgumentParser(description="ACT16 Systems Language Compiler for Particle")
    parser.add_argument("source", help="Input ACT16 source file (.act / .c)")
    parser.add_argument("-o", "--output", default=None, help="Output assembly file (.asm)")
    parser.add_argument("-D", "--define", action="append", default=[], help="Predefine symbol for conditional compilation")
    args = parser.parse_args()

    if not args.output:
        base = os.path.splitext(os.path.basename(args.source))[0]
        args.output = os.path.join("build", f"{base}.asm")

    out_dir = os.path.dirname(args.output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    defs = set(args.define)

    with open(args.source, 'r', encoding='utf-8') as f:
        src = f.read()

    tokens = tokenize(src)
    filtered = run_preprocessor(tokens, defs)

    p = Parser(filtered)
    ast = p.parse_program()

    cg = CodeGen()
    asm_code = cg.generate(ast)

    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(asm_code)

    print(f"Compilation complete: Emitted Particle assembly to '{args.output}'.")

if __name__ == "__main__":
    main()