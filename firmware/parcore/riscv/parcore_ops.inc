; ==============================================================================
; Parcore: core 2's operation numbers
; File: firmware/parcore/riscv/parcore_ops.inc
; ==============================================================================
;
; Core 0 decodes each instruction into a control word, and core 2 dispatches
; on the operation number in its bits 31:24 with one JTBL, so the order here
; is the order of core 2's jump table. The control word:
;   31:24  the operation number (OP_*)
;   23:20  core 1's class (CLASS_*): which registers it reads and what it
;          sends; cores 2 and 3 ignore it
;   19:16  the memory operation (OP_MEM only)
;   15:8   Rd (0: none)
;   3      predicted taken (branches): core 0 fetched the target
;   2      cancel (core 2 to core 3 only)
;   1      the epoch
;   0      valid
;
; Some groups are numbered so core 1 can add a field to a base:
;   OP_ADD + funct3     the RV32I register and immediate ALU operations
;   OP_MUL + funct3     RV32M
;   OP_BEQ + funct3     branches (funct3 2 and 3 are illegal: core 1 never
;                       sends OP_BEQ + 2 or + 3)
;   OP_MRET + funct3&3  CSRRW, CSRRS, CSRRC and their immediate forms

.define OP_ADD      0
.define OP_SLL      1
.define OP_SLT      2
.define OP_SLTU     3
.define OP_XOR      4
.define OP_SRL      5
.define OP_OR       6
.define OP_AND      7
.define OP_SUB      8
.define OP_SRA      9
.define OP_MUL      10
.define OP_MULH     11
.define OP_MULHSU   12
.define OP_MULHU    13
.define OP_DIV      14
.define OP_DIVU     15
.define OP_REM      16
.define OP_REMU     17
.define OP_ANDN     18
.define OP_ORN      19
.define OP_XNOR     20
.define OP_CLZ      21
.define OP_CTZ      22
.define OP_CPOP     23
.define OP_MAX      24
.define OP_MAXU     25
.define OP_MIN      26
.define OP_MINU     27
.define OP_SEXT_B   28
.define OP_SEXT_H   29
.define OP_ZEXT_H   30
.define OP_ROL      31
.define OP_ROR      32
.define OP_ORC_B    33
.define OP_REV8     34
.define OP_LUI      35
.define OP_AUIPC    36
.define OP_FENCE_I  37
.define OP_MEM      38  ; loads and stores: core 2 adds the address, core 3 does the access
.define OP_BEQ      39
.define OP_BNE      40
.define OP_BLT      43
.define OP_BGE      44
.define OP_BLTU     45
.define OP_BGEU     46
.define OP_JAL      47
.define OP_JALR     48
.define OP_ECALL    49
.define OP_EBREAK   50
.define OP_MRET     51
.define OP_CSRRW    52
.define OP_CSRRS    53
.define OP_CSRRC    54
.define OP_ILLEGAL  55
.define OP_COUNT    56

; Core 0 sends core 1 five words: [control word, w1, w2, B, W3]. Core 1 sends
; core 2 four: [control word, operand A, operand B, word 3]. By class:
;   CLASS_RS1_IMM  w1 rs1, w2 rd;  A = x(rs1), B = B, word 3 = W3 (the PC)
;   CLASS_RS1_RS2  w1 rs1, w2 rd, B rs2;  A = x(rs1), B = x(rs2), word 3 = W3
;   CLASS_STORE    w1 rs1, w2 rs2;  A = x(rs1), B = B (the offset),
;                  word 3 = x(rs2) (the data)
;   CLASS_BRANCH   w1 rs1, w2 rs2;  A = x(rs1), B = x(rs2), word 3 = W3 (the
;                  address to go to if the prediction is wrong)
;   CLASS_IMM      w2 rd;  A = 0, B = B, word 3 = W3 (the PC)
;   CLASS_ZIMM     w1 the immediate, w2 rd;  A = w1, B = B, word 3 = W3
; Core 1 counts rd (w2) as having a write in flight, for the classes with
; one. A word of all ones (CLASS_MARKER in bits 23:20) is a marker: core 0
; sends five after every redirect, so core 1 can tell where packets start
; again after a flush (W3 is never all ones).
.define CLASS_RS1_IMM  0
.define CLASS_RS1_RS2  1
.define CLASS_STORE    2
.define CLASS_BRANCH   3
.define CLASS_IMM      4
.define CLASS_ZIMM     5
.define CLASS_MARKER   15
