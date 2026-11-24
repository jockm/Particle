; ==============================================================================
; Parcore: core 2's operation numbers
; File: firmware/parcore/riscv/parcore_ops.inc
; ==============================================================================
;
; Core 1 puts one of these in bits 31:24 of every packet's control word, and
; core 2 dispatches on it with one JTBL, so the order here is the order of
; core 2's jump table. The rest of the control word: bits 19:16 the memory
; operation (OP_MEM only), 15:8 Rd, bit 1 the epoch, bit 0 valid.
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
