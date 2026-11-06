; ==============================================================================
; Parcore RV32IM_Zbb: Core 2 (Execution, ALU, M-Ext, Zbb & Branch Unit)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core2_ex.asm
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LD      R1, 0               ; FIFO Ch0: Inbound from Core 1 (ID)
    LD      R2, 1               ; FIFO Ch1: Outbound to Core 3 (MEM)

; ==============================================================================
; Main Execution Loop
; ==============================================================================
_ex_main_loop:
    FIFO.R  R10, R1             ; Word 0: Control Word
    FIFO.R  R11, R1             ; Word 1: Operand A (Rs1 Value / PC)
    FIFO.R  R12, R1             ; Word 2: Operand B (Rs2 Value / Immediate)
    FIFO.R  R13, R1             ; Word 3: Base PC

    ; Test valid bit (bit 0)
    LD      R3, R10
    AND     R3, 1
    FBRA.NZ R3, _have_valid_packet
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_have_valid_packet:
    LD      R15, 0              ; Result register
    LD      R14, 0              ; Target / Effective Memory Address

    ; --------------------------------------------------------------------------
    ; 1. Branch / Jump Identification: Control Word [23:20]
    ; --------------------------------------------------------------------------
    LD      R3, R10
    SHIFTR  R3, 12
    SHIFTR  R3, 8
    LD      R4, 0x0F
    AND     R3, R4
    FBRA.Z  R3, _not_branch_op
    LOAD16  R14, _eval_branch
    JMP     R14, R0

_not_branch_op:
    LOAD16  R14, _dispatch_alu
    JMP     R14, R0

; ==============================================================================
; Branch & Jump Resolution Section
; ==============================================================================
_eval_branch:
    ; uop = funct3 + 1: 1=BEQ, 2=BNE, 5=BLT, 6=BGE, 7=BLTU, 8=BGEU, 9=JAL, 10=JALR
    ; R10 = Control Word, R11 = Rs1, R12 = Rs2, R13 = Target PC (or Base PC for JAL)

    ; 1: BEQ
    LD      R5, 1
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_beq
    LOAD16  R14, _chk_bne
    JMP     R14, R0
_do_beq:
    LD      R4, R11
    SUB     R4, R12
    FBRA.NZ R4, ._beq_not_taken
    LOAD16  R5, _b_taken
    JMP     R5, R0
._beq_not_taken:
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_chk_bne:
    ; 2: BNE
    LD      R5, 2
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_bne
    LOAD16  R14, _chk_blt
    JMP     R14, R0
_do_bne:
    LD      R4, R11
    SUB     R4, R12
    FBRA.Z  R4, ._bne_not_taken
    LOAD16  R5, _b_taken
    JMP     R5, R0
._bne_not_taken:
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_chk_blt:
    ; 5: BLT (Signed)
    LOAD16  R5, 5
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_blt
    LOAD16  R14, _chk_bge
    JMP     R14, R0
_do_blt:
    LD      R4, R11
    SSLT    R4, R12
    FBRA.Z  R4, ._blt_not_taken
    LOAD16  R5, _b_taken
    JMP     R5, R0
._blt_not_taken:
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_chk_bge:
    ; 6: BGE (Signed)
    LOAD16  R5, 6
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_bge
    LOAD16  R14, _chk_bltu
    JMP     R14, R0
_do_bge:
    LD      R4, R11
    SSLT    R4, R12
    FBRA.NZ R4, ._bge_not_taken
    LOAD16  R5, _b_taken
    JMP     R5, R0
._bge_not_taken:
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_chk_bltu:
    ; 7: BLTU (Unsigned)
    LOAD16  R5, 7
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_bltu
    LOAD16  R14, _chk_bgeu
    JMP     R14, R0
_do_bltu:
    LD      R4, R11
    SLT     R4, R12
    FBRA.Z  R4, ._bltu_not_taken
    LOAD16  R5, _b_taken
    JMP     R5, R0
._bltu_not_taken:
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_chk_bgeu:
    ; 8: BGEU (Unsigned)
    LOAD16  R5, 8
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_bgeu
    LOAD16  R14, _chk_jal
    JMP     R14, R0
_do_bgeu:
    LD      R4, R11
    SLT     R4, R12
    FBRA.NZ R4, ._bgeu_not_taken
    LOAD16  R5, _b_taken
    JMP     R5, R0
._bgeu_not_taken:
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_b_taken:
    LOAD16  R5, _taken_branch
    LD      R14, R13           ; Set Target PC in R14 after LOAD16 expands
    JMP     R5, R0

_chk_jal:
    ; 9: JAL
    LOAD16  R5, 9
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_jal
    LOAD16  R14, _chk_jalr
    JMP     R14, R0
_do_jal:
    LD      R15, R13
    ADD     R15, 4             ; Link address = PC + 4
    LOAD16  R5, _taken_branch
    LD      R14, R13
    ADD     R14, R12           ; Target PC = Base PC + Jump Offset
    JMP     R5, R0

_chk_jalr:
    ; 10: JALR
    LOAD16  R5, 10
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _do_jalr
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0
_do_jalr:
    LD      R15, R13
    ADD     R15, 4             ; Link address = PC + 4
    LOAD16  R4, 0xFFFE
    LOAD16  R5, _taken_branch
    LD      R14, R11
    ADD     R14, R12           ; Target = Rs1 + Imm
    AND     R14, R4            ; Target & ~1 (R14 set after all LOAD16s)
    JMP     R5, R0

_taken_branch:
    ; Fire inter-core MBOX strobe (Vector 1) to Core 0 with redirect target in R14
    MBOX    R14, 1

    ; Check if destination register Rd != 0 (e.g. for JAL/JALR link writeback)
    LD      R4, R10
    SHIFTR  R4, 8
    LOAD16  R5, 0x1F
    AND     R4, R5
    FBRA.NZ R4, _branch_has_rd
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0
_branch_has_rd:
    LOAD16  R5, _forward_to_mem
    JMP     R5, R0

; ALU / Memory / Extension Dispatch Section
; ==============================================================================
_dispatch_alu:
    LD      R3, R10
    SHIFTR  R3, 12
    SHIFTR  R3, 12         ; Micro-op opcode [31:24]

    ; Check if Memory access instruction: Control Word [19:16] != 0
    LD      R4, R10
    SHIFTR  R4, 12
    SHIFTR  R4, 4
    LD      R5, 0x0F
    AND     R4, R5
    FBRA.Z  R4, _run_alu_lookup

    ; Effective memory address calculation: Base (Rs1) + Offset (Imm)
    LOAD16  R4, _forward_to_mem
    LD      R14, R11
    ADD     R14, R12
    JMP     R4, R0

_run_alu_lookup:
    ; RV32I Base ALU (Opcode 0x00..0x07)
    FBRA.NZ R3, _skip_add
    LOAD16  R14, _do_add
    JMP     R14, R0
_skip_add:
    LD      R4, R3
    SUB     R4, 1
    FBRA.NZ R4, _skip_sll
    LOAD16  R14, _do_sll
    JMP     R14, R0
_skip_sll:
    LD      R4, R3
    SUB     R4, 2
    FBRA.NZ R4, _skip_slt
    LOAD16  R14, _do_slt
    JMP     R14, R0
_skip_slt:
    LD      R4, R3
    SUB     R4, 3
    FBRA.NZ R4, _skip_sltu
    LOAD16  R14, _do_sltu
    JMP     R14, R0
_skip_sltu:
    LD      R4, R3
    SUB     R4, 4
    FBRA.NZ R4, _skip_xor
    LOAD16  R14, _do_xor
    JMP     R14, R0
_skip_xor:
    LD      R4, R3
    SUB     R4, 5
    FBRA.NZ R4, _skip_srl
    LOAD16  R14, _do_srl
    JMP     R14, R0
_skip_srl:
    LD      R4, R3
    SUB     R4, 6
    FBRA.NZ R4, _skip_or
    LOAD16  R14, _do_or
    JMP     R14, R0
_skip_or:
    LD      R4, R3
    SUB     R4, 7
    FBRA.NZ R4, _skip_and
    LOAD16  R14, _do_and
    JMP     R14, R0
_skip_and:

    ; High / Alternate Base Operations
    LOAD16  R5, 0x10
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_sub
    LOAD16  R14, _do_sub
    JMP     R14, R0
_skip_sub:
    LOAD16  R5, 0x15
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_sra
    LOAD16  R14, _do_sra
    JMP     R14, R0
_skip_sra:
    LOAD16  R5, 0x30            ; LUI
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_lui
    LOAD16  R14, _do_lui
    JMP     R14, R0
_skip_lui:
    LOAD16  R5, 0x31            ; AUIPC
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_auipc
    LOAD16  R14, _do_auipc
    JMP     R14, R0
_skip_auipc:

    ; RV32M Extension Operations (0x20..0x27)
    LOAD16  R5, 0x20
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_mul
    LOAD16  R14, _do_mul
    JMP     R14, R0
_skip_mul:
    LOAD16  R5, 0x21
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_mulh
    LOAD16  R14, _do_mulh
    JMP     R14, R0
_skip_mulh:
    LOAD16  R5, 0x22
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_mulhsu
    LOAD16  R14, _do_mulhsu
    JMP     R14, R0
_skip_mulhsu:
    LOAD16  R5, 0x23
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_mulhu
    LOAD16  R14, _do_mulhu
    JMP     R14, R0
_skip_mulhu:
    LOAD16  R5, 0x24
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_div
    LOAD16  R14, _do_div
    JMP     R14, R0
_skip_div:
    LOAD16  R5, 0x25
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_divu
    LOAD16  R14, _do_divu
    JMP     R14, R0
_skip_divu:
    LOAD16  R5, 0x26
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_rem
    LOAD16  R14, _do_rem
    JMP     R14, R0
_skip_rem:
    LOAD16  R5, 0x27
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_remu
    LOAD16  R14, _do_remu
    JMP     R14, R0
_skip_remu:

    ; RV32_Zbb Bit-manipulation Extension (0x40..0x50)
    LOAD16  R5, 0x40
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_andn
    LOAD16  R14, _do_andn
    JMP     R14, R0
_skip_andn:
    LOAD16  R5, 0x41
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_orn
    LOAD16  R14, _do_orn
    JMP     R14, R0
_skip_orn:
    LOAD16  R5, 0x42
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_xnor
    LOAD16  R14, _do_xnor
    JMP     R14, R0
_skip_xnor:
    LOAD16  R5, 0x43
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_clz
    LOAD16  R14, _do_clz
    JMP     R14, R0
_skip_clz:
    LOAD16  R5, 0x44
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_ctz
    LOAD16  R14, _do_ctz
    JMP     R14, R0
_skip_ctz:
    LOAD16  R5, 0x45
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_cpop
    LOAD16  R14, _do_cpop
    JMP     R14, R0
_skip_cpop:
    LOAD16  R5, 0x46
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_max
    LOAD16  R14, _do_max
    JMP     R14, R0
_skip_max:
    LOAD16  R5, 0x47
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_maxu
    LOAD16  R14, _do_maxu
    JMP     R14, R0
_skip_maxu:
    LOAD16  R5, 0x48
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_min
    LOAD16  R14, _do_min
    JMP     R14, R0
_skip_min:
    LOAD16  R5, 0x49
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_minu
    LOAD16  R14, _do_minu
    JMP     R14, R0
_skip_minu:
    LOAD16  R5, 0x4A
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_sext_b
    LOAD16  R14, _do_sext_b
    JMP     R14, R0
_skip_sext_b:
    LOAD16  R5, 0x4B
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_sext_h
    LOAD16  R14, _do_sext_h
    JMP     R14, R0
_skip_sext_h:
    LOAD16  R5, 0x4C
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_zext_h
    LOAD16  R14, _do_zext_h
    JMP     R14, R0
_skip_zext_h:
    LOAD16  R5, 0x4D
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _skip_rol
    LOAD16  R14, _do_rol
    JMP     R14, R0
_skip_rol:
    LOAD16  R5, 0x4E
    LD      R4, R3
    SUB     R4, R5
    FBRA.NZ R4, _fallback_forward
    LOAD16  R14, _do_ror
    JMP     R14, R0

_fallback_forward:
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

; ------------------------------------------------------------------------------
; ALU Handler Implementations
; ------------------------------------------------------------------------------
_do_add:
    LD      R15, R11
    ADD     R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sub:
    LD      R15, R11
    SUB     R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sll:
    LOAD16  R5, 0x1F
    LD      R4, R12
    AND     R4, R5
    LD      R15, R11
    SHIFTL  R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_slt:
    LD      R15, R11
    SSLT    R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sltu:
    LD      R15, R11
    SLT     R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_xor:
    LD      R15, R11
    XOR     R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_srl:
    LOAD16  R5, 0x1F
    LD      R4, R12
    AND     R4, R5
    LD      R15, R11
    SHIFTR  R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sra:
    LOAD16  R5, 0x1F
    LD      R4, R12
    AND     R4, R5
    LD      R15, R11
    ASHIFTR R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_or:
    LD      R15, R11
    OR      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_and:
    LD      R15, R11
    AND     R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_lui:
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_auipc:
    LD      R15, R13
    ADD     R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mul:
    LD      R15, R11
    MULL    R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mulh:
    LD      R15, R11
    SMULH   R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mulhsu:
    LD      R15, R11
    MULHSU  R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mulhu:
    LD      R15, R11
    MULH    R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_div:
    ; RV32M DIV (Signed)
    FBRA.NZ R12, _div_nonzero
    LOAD32  R15, 0xFFFFFFFF     ; Division by zero -> -1
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_div_nonzero:
    ; Check overflow: -2147483648 / -1 = -2147483648
    LOAD32  R4, 0x80000000
    LD      R5, R11
    SUB     R5, R4
    FBRA.NZ R5, _div_check_signs
    LD      R5, R12
    ADD     R5, 1
    FBRA.NZ R5, _div_check_signs
    LD      R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_div_check_signs:
    ; R6 = sign of quotient = (R11 ^ R12) >> 31
    LD      R6, R11
    XOR     R6, R12
    SHIFTR  R6, 15
    SHIFTR  R6, 15
    SHIFTR  R6, 1

    ; R7 = abs(R11)
    LD      R7, R11
    LD      R4, R11
    SHIFTR  R4, 15
    SHIFTR  R4, 15
    SHIFTR  R4, 1
    FBRA.Z  R4, _div_abs_b
    NOT     R7
    LD      R5, 1
    ADD     R7, R5

_div_abs_b:
    ; R8 = abs(R12)
    LD      R8, R12
    LD      R4, R12
    SHIFTR  R4, 15
    SHIFTR  R4, 15
    SHIFTR  R4, 1
    FBRA.Z  R4, _div_run_calc
    NOT     R8
    LD      R5, 1
    ADD     R8, R5

_div_run_calc:
    LOAD16  R3, 0               ; mode 0 = DIV
    LOAD16  R14, _udiv_calc
    JMP     R14, R0

_div_finish:
    LD      R15, R9             ; Quotient
    FBRA.Z  R6, _div_exit
    NOT     R15
    LD      R5, 1
    ADD     R15, R5
_div_exit:
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_divu:
    ; RV32M DIVU (Unsigned)
    FBRA.NZ R12, _divu_nonzero
    LOAD32  R15, 0xFFFFFFFF     ; Division by zero -> 0xFFFFFFFF
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_divu_nonzero:
    LD      R7, R11             ; N
    LD      R8, R12             ; D
    LOAD16  R3, 1               ; mode 1 = DIVU
    LOAD16  R14, _udiv_calc
    JMP     R14, R0

_divu_finish:
    LD      R15, R9             ; Unsigned quotient
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_rem:
    ; RV32M REM (Signed)
    FBRA.NZ R12, _rem_nonzero
    LD      R15, R11            ; Remainder by zero -> dividend
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_rem_nonzero:
    ; Check overflow: -2147483648 % -1 = 0
    LOAD32  R4, 0x80000000
    LD      R5, R11
    SUB     R5, R4
    FBRA.NZ R5, _rem_check_signs
    LD      R5, R12
    ADD     R5, 1
    FBRA.NZ R5, _rem_check_signs
    LOAD16  R15, 0
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_rem_check_signs:
    ; Remainder sign matches dividend (R11) sign
    LD      R6, R11
    SHIFTR  R6, 15
    SHIFTR  R6, 15
    SHIFTR  R6, 1              ; R6 = sign of R11

    ; R7 = abs(R11)
    LD      R7, R11
    FBRA.Z  R6, _rem_abs_b
    NOT     R7
    LD      R5, 1
    ADD     R7, R5

_rem_abs_b:
    ; R8 = abs(R12)
    LD      R8, R12
    LD      R4, R12
    SHIFTR  R4, 15
    SHIFTR  R4, 15
    SHIFTR  R4, 1
    FBRA.Z  R4, _rem_run_calc
    NOT     R8
    LD      R5, 1
    ADD     R8, R5

_rem_run_calc:
    LOAD16  R3, 2               ; mode 2 = REM
    LOAD16  R14, _udiv_calc
    JMP     R14, R0

_rem_finish:
    LD      R15, R11            ; Remainder in R11
    FBRA.Z  R6, _rem_exit
    NOT     R15
    LD      R5, 1
    ADD     R15, R5
_rem_exit:
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_remu:
    ; RV32M REMU (Unsigned)
    FBRA.NZ R12, _remu_nonzero
    LD      R15, R11            ; Remainder by zero -> dividend
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_remu_nonzero:
    LD      R7, R11             ; N
    LD      R8, R12             ; D
    LOAD16  R3, 3               ; mode 3 = REMU
    LOAD16  R14, _udiv_calc
    JMP     R14, R0

_remu_finish:
    LD      R15, R11            ; Unsigned remainder in R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

; ------------------------------------------------------------------------------
; _udiv_calc: 32-bit Restoring Division
; Inputs:  R7 = N, R8 = D, R3 = mode (0: DIV, 1: DIVU, 2: REM, 3: REMU)
; Outputs: R9 = Quotient, R11 = Remainder
; Preserves: R10 (Control Word), R13 (Word 3)
; Scratch: R4 (Loop counter), R5 (temp)
; ------------------------------------------------------------------------------
_udiv_calc:
    LOAD16  R9, 0               ; Q = 0
    LOAD16  R11, 0              ; Remainder = 0 (using R11 to preserve R10!)
    LOAD16  R4, 32              ; 32 iterations

_udiv_step:
    ; Remainder = (Remainder << 1) | (N >> 31)
    SHIFTL  R11, 1
    LD      R5, R7
    SHIFTR  R5, 15
    SHIFTR  R5, 15
    SHIFTR  R5, 1
    OR      R11, R5

    SHIFTL  R7, 1               ; N <<= 1
    SHIFTL  R9, 1               ; Q <<= 1

    ; If Remainder >= D: Remainder -= D, Q |= 1
    LD      R5, R11
    SLT     R5, R8              ; R5 = (Remainder < D) ? 1 : 0 (SLT is unsigned)
    FBRA.NZ R5, _udiv_next
    SUB     R11, R8
    OR      R9, 1

_udiv_next:
    LD      R5, 1
    SUB     R4, R5
    FBRA.Z  R4, _udiv_done
    LOAD16  R14, _udiv_step
    JMP     R14, R0

_udiv_done:
    ; Dispatch by mode in R3 (0: DIV, 1: DIVU, 2: REM, 3: REMU)
    FBRA.Z  R3, _route_div
    LD      R5, 1
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _route_divu
    LD      R5, 2
    LD      R4, R3
    SUB     R4, R5
    FBRA.Z  R4, _route_rem

    ; mode == 3 (REMU)
    LOAD16  R14, _remu_finish
    JMP     R14, R0

_route_div:
    LOAD16  R14, _div_finish
    JMP     R14, R0

_route_divu:
    LOAD16  R14, _divu_finish
    JMP     R14, R0

_route_rem:
    LOAD16  R14, _rem_finish
    JMP     R14, R0

_do_andn:
    LD      R15, R11
    NOT     R4, R12
    AND     R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_orn:
    LD      R15, R11
    NOT     R4, R12
    OR      R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_xnor:
    LD      R4, R11
    XOR     R4, R12
    NOT     R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_clz:
    CLZ     R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_ctz:
    FBRA.NZ R11, _calc_ctz
    LOAD16  R15, 32
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
_calc_ctz:
    LD      R4, R11
    SUB     R4, 1
    NOT     R5, R11
    AND     R4, R5
    CLZ     R5, R4
    LOAD16  R6, 31
    LD      R15, R6
    SUB     R15, R5
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_cpop:
    LD      R4, R11
    SHIFTR  R4, 1
    LOAD32  R5, 0x55555555
    AND     R4, R5
    LD      R6, R11
    SUB     R6, R4
    LOAD32  R5, 0x33333333
    LD      R4, R6
    AND     R4, R5
    SHIFTR  R6, 2
    AND     R6, R5
    ADD     R6, R4
    LD      R4, R6
    SHIFTR  R4, 4
    ADD     R6, R4
    LOAD32  R5, 0x0F0F0F0F
    AND     R6, R5
    LOAD32  R5, 0x01010101
    MULL    R6, R6, R5
    LD      R15, R6
    SHIFTR  R15, 12
    SHIFTR  R15, 12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_max:
    LD      R4, R11
    SSLT    R4, R12
    FBRA.Z  R4, _max_take_a
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
_max_take_a:
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_maxu:
    LD      R4, R11
    SLT     R4, R12
    FBRA.Z  R4, _maxu_take_a
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
_maxu_take_a:
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_min:
    LD      R4, R11
    SSLT    R4, R12
    FBRA.NZ R4, _min_take_a
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
_min_take_a:
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_minu:
    LD      R4, R11
    SLT     R4, R12
    FBRA.NZ R4, _minu_take_a
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
_minu_take_a:
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sext_b:
    SEXT8   R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sext_h:
    SEXT16  R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_zext_h:
    LOAD16  R4, 0xFFFF
    LD      R15, R11
    AND     R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_rol:
    LOAD16  R5, 0x1F
    LD      R4, R12
    AND     R4, R5
    LD      R15, R11
    ROTL    R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_ror:
    LOAD16  R5, 0x1F
    LD      R4, R12
    AND     R4, R5
    LD      R15, R11
    ROTR    R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

; ------------------------------------------------------------------------------
; Outbound Forwarding to Memory Stage (Core 3)
; ------------------------------------------------------------------------------
_forward_to_mem:
    FIFO.W  R10, R2             ; Word 0: Control Word
    FIFO.W  R15, R2             ; Word 1: Result Data
    FIFO.W  R14, R2             ; Word 2: Memory Effective Address / Target
    FIFO.W  R13, R2             ; Word 3: Store Data (Rs2 Value)
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0
