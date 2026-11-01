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

_ex_main_loop:
    FIFO.R  R10, R1             ; Word 0: Control Word
    FIFO.R  R11, R1             ; Word 1: Operand A (Rs1 Value / PC)
    FIFO.R  R12, R1             ; Word 2: Operand B (Rs2 Value / Immediate)
    FIFO.R  R13, R1             ; Word 3: Base PC

    AND     R3, R10, 1
    FBRA.NZ R3, ._valid_op
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

._valid_op:
    LD      R15, 0              ; Result
    LD      R14, 0              ; Target Address

    ; Branch evaluation
    SHIFTR  R3, R10, 20
    LD      R4, 0x0F
    AND     R3, R4
    FBRA.Z  R3, ._go_alu
    LOAD16  R14, ._eval_branch
    JMP     R14, R0

._go_alu:
    LOAD16  R14, _dispatch_alu
    JMP     R14, R0

._eval_branch:
    ADD     R14, R13, R12       ; Target = PC + Offset

    ; BEQ
    SUB     R4, R3, 1
    FBRA.NZ R4, ._chk_bne
    SUB     R4, R11, R12
    FBRA.Z  R4, ._fire_redirect
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

._chk_bne:
    SUB     R4, R3, 2
    FBRA.NZ R4, ._chk_blt
    SUB     R4, R11, R12
    FBRA.NZ R4, ._fire_redirect
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

._chk_blt:
    SUB     R4, R3, 3
    FBRA.NZ R4, ._chk_bge
    SSLT    R4, R11, R12
    FBRA.NZ R4, ._fire_redirect
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

._chk_bge:
    SUB     R4, R3, 4
    FBRA.NZ R4, ._chk_bltu
    SSLT    R4, R11, R12
    FBRA.Z  R4, ._fire_redirect
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

._chk_bltu:
    SUB     R4, R3, 5
    FBRA.NZ R4, ._chk_bgeu
    SLT     R4, R11, R12
    FBRA.NZ R4, ._fire_redirect
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

._chk_bgeu:
    SUB     R4, R3, 6
    FBRA.NZ R4, ._chk_jal
    SLT     R4, R11, R12
    FBRA.Z  R4, ._fire_redirect
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

._chk_jal:
    LOAD16  R5, 9
    SUB     R4, R3, R5
    FBRA.NZ R4, ._chk_jalr
    ADD     R15, R13, 4
    LOAD16  R14, _fire_branch_redirect
    JMP     R14, R0

._chk_jalr:
    LOAD16  R5, 10
    SUB     R4, R3, R5
    FBRA.NZ R4, ._drop_branch
    ADD     R14, R11, R12
    LOAD16  R4, 0xFFFE
    AND     R14, R4
    ADD     R15, R13, 4
    LOAD16  R14, _fire_branch_redirect
    JMP     R14, R0

._fire_redirect:
    LOAD16  R14, _fire_branch_redirect
    JMP     R14, R0

._drop_branch:
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0

_fire_branch_redirect:
    LOAD32  R4, 0xF0000020
    LD      R5, 0x01
    LD32    (R4), R5
    SHIFTR  R4, R10, 8
    LOAD16  R5, 0x1F
    AND     R4, R5
    FBRA.NZ R4, ._fwd_mem
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0
._fwd_mem:
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_dispatch_alu:
    SHIFTR  R3, R10, 24

    SHIFTR  R4, R10, 16
    LD      R5, 0x0F
    AND     R4, R5
    FBRA.Z  R4, _alu_operations
    ADD     R14, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_alu_operations:
    FBRA.NZ R3, ._t1
    LOAD16  R14, _do_add
    JMP     R14, R0
._t1:
    SUB     R4, R3, 1
    FBRA.NZ R4, ._t2
    LOAD16  R14, _do_sll
    JMP     R14, R0
._t2:
    SUB     R4, R3, 2
    FBRA.NZ R4, ._t3
    LOAD16  R14, _do_slt
    JMP     R14, R0
._t3:
    SUB     R4, R3, 3
    FBRA.NZ R4, ._t4
    LOAD16  R14, _do_sltu
    JMP     R14, R0
._t4:
    SUB     R4, R3, 4
    FBRA.NZ R4, ._t5
    LOAD16  R14, _do_xor
    JMP     R14, R0
._t5:
    SUB     R4, R3, 5
    FBRA.NZ R4, ._t6
    LOAD16  R14, _do_srl
    JMP     R14, R0
._t6:
    SUB     R4, R3, 6
    FBRA.NZ R4, ._t7
    LOAD16  R14, _do_or
    JMP     R14, R0
._t7:
    SUB     R4, R3, 7
    FBRA.NZ R4, ._t10
    LOAD16  R14, _do_and
    JMP     R14, R0
._t10:
    LOAD16  R5, 0x10
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t15
    LOAD16  R14, _do_sub
    JMP     R14, R0
._t15:
    LOAD16  R5, 0x15
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t30
    LOAD16  R14, _do_sra
    JMP     R14, R0
._t30:
    LOAD16  R5, 0x30
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t31
    LOAD16  R14, _do_lui
    JMP     R14, R0
._t31:
    LOAD16  R5, 0x31
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t20
    LOAD16  R14, _do_auipc
    JMP     R14, R0
._t20:
    LOAD16  R5, 0x20
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t21
    LOAD16  R14, _do_mul
    JMP     R14, R0
._t21:
    LOAD16  R5, 0x21
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t22
    LOAD16  R14, _do_mulh
    JMP     R14, R0
._t22:
    LOAD16  R5, 0x22
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t23
    LOAD16  R14, _do_mulhsu
    JMP     R14, R0
._t23:
    LOAD16  R5, 0x23
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t24
    LOAD16  R14, _do_mulhu
    JMP     R14, R0
._t24:
    LOAD16  R5, 0x24
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t25
    LOAD16  R14, _do_div
    JMP     R14, R0
._t25:
    LOAD16  R5, 0x25
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t26
    LOAD16  R14, _do_divu
    JMP     R14, R0
._t26:
    LOAD16  R5, 0x26
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t27
    LOAD16  R14, _do_rem
    JMP     R14, R0
._t27:
    LOAD16  R5, 0x27
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t40
    LOAD16  R14, _do_remu
    JMP     R14, R0
._t40:
    LOAD16  R5, 0x40
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t41
    LOAD16  R14, _do_andn
    JMP     R14, R0
._t41:
    LOAD16  R5, 0x41
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t42
    LOAD16  R14, _do_orn
    JMP     R14, R0
._t42:
    LOAD16  R5, 0x42
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t43
    LOAD16  R14, _do_xnor
    JMP     R14, R0
._t43:
    LOAD16  R5, 0x43
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t44
    LOAD16  R14, _do_clz
    JMP     R14, R0
._t44:
    LOAD16  R5, 0x44
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t45
    LOAD16  R14, _do_ctz
    JMP     R14, R0
._t45:
    LOAD16  R5, 0x45
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t46
    LOAD16  R14, _do_cpop
    JMP     R14, R0
._t46:
    LOAD16  R5, 0x46
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t47
    LOAD16  R14, _do_max
    JMP     R14, R0
._t47:
    LOAD16  R5, 0x47
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t48
    LOAD16  R14, _do_maxu
    JMP     R14, R0
._t48:
    LOAD16  R5, 0x48
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t49
    LOAD16  R14, _do_min
    JMP     R14, R0
._t49:
    LOAD16  R5, 0x49
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t4a
    LOAD16  R14, _do_minu
    JMP     R14, R0
._t4a:
    LOAD16  R5, 0x4A
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t4b
    LOAD16  R14, _do_sext_b
    JMP     R14, R0
._t4b:
    LOAD16  R5, 0x4B
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t4c
    LOAD16  R14, _do_sext_h
    JMP     R14, R0
._t4c:
    LOAD16  R5, 0x4C
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t4d
    LOAD16  R14, _do_zext_h
    JMP     R14, R0
._t4d:
    LOAD16  R5, 0x4D
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t4e
    LOAD16  R14, _do_rol
    JMP     R14, R0
._t4e:
    LOAD16  R5, 0x4E
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t4f
    LOAD16  R14, _do_ror
    JMP     R14, R0
._t4f:
    LOAD16  R5, 0x4F
    SUB     R4, R3, R5
    FBRA.NZ R4, ._t50
    LOAD16  R14, _do_rev8
    JMP     R14, R0
._t50:
    LOAD16  R5, 0x50
    SUB     R4, R3, R5
    FBRA.NZ R4, ._def_alu
    LOAD16  R14, _do_orc_b
    JMP     R14, R0
._def_alu:
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_add:
    ADD     R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sub:
    SUB     R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sll:
    LOAD16  R5, 0x1F
    AND     R4, R12, R5
    SHIFTL  R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_slt:
    SSLT    R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sltu:
    SLT     R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_xor:
    XOR     R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_srl:
    LOAD16  R5, 0x1F
    AND     R4, R12, R5
    SHIFTR  R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_sra:
    LOAD16  R5, 0x1F
    AND     R4, R12, R5
    ASHIFTR R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_or:
    OR      R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_and:
    AND     R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_lui:
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_auipc:
    ADD     R15, R13, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mul:
    MULL    R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mulh:
    SMULH   R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mulhsu:
    MULHSU  R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_mulhu:
    MULH    R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_div:
    FBRA.NZ R12, ._exec_sdiv
    LOAD32  R15, 0xFFFFFFFF
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._exec_sdiv:
    SDIV    R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_divu:
    FBRA.NZ R12, ._exec_udiv
    LOAD32  R15, 0xFFFFFFFF
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._exec_udiv:
    DIV     R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_rem:
    FBRA.NZ R12, ._exec_smod
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._exec_smod:
    SMOD    R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_remu:
    FBRA.NZ R12, ._exec_umod
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._exec_umod:
    MOD     R15, R11, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_andn:
    NOT     R4, R12
    AND     R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_orn:
    NOT     R4, R12
    OR      R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_xnor:
    XOR     R4, R11, R12
    NOT     R15, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_clz:
    CLZ     R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_ctz:
    FBRA.NZ R11, ._calc_ctz
    LOAD16  R15, 32
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._calc_ctz:
    SUB     R4, R11, 1
    NOT     R5, R11
    AND     R4, R5
    CLZ     R5, R4
    LOAD16  R6, 31
    SUB     R15, R6, R5
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_cpop:
    SHIFTR  R4, R11, 1
    LOAD32  R5, 0x55555555
    AND     R4, R4, R5
    SUB     R6, R11, R4
    LOAD32  R5, 0x33333333
    AND     R4, R6, R5
    SHIFTR  R6, R6, 2
    AND     R6, R6, R5
    ADD     R6, R4
    SHIFTR  R4, R6, 4
    ADD     R6, R6, R4
    LOAD32  R5, 0x0F0F0F0F
    AND     R6, R6, R5
    LOAD32  R5, 0x01010101
    MULL    R6, R6, R5
    SHIFTR  R15, R6, 24
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_max:
    SSLT    R4, R11, R12
    FBRA.NZ R4, ._max_b
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._max_b:
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_maxu:
    SLT     R4, R11, R12
    FBRA.NZ R4, ._maxu_b
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._maxu_b:
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_min:
    SSLT    R4, R11, R12
    FBRA.Z  R4, ._min_b
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._min_b:
    LD      R15, R12
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_minu:
    SLT     R4, R11, R12
    FBRA.Z  R4, ._minu_b
    LD      R15, R11
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0
._minu_b:
    LD      R15, R12
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
    AND     R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_rol:
    LOAD16  R5, 0x1F
    AND     R4, R12, R5
    ROTL    R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_ror:
    LOAD16  R5, 0x1F
    AND     R4, R12, R5
    ROTR    R15, R11, R4
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_rev8:
    SHIFTL  R4, R11, 24
    SHIFTR  R5, R11, 24
    OR      R15, R4, R5
    LOAD32  R6, 0x00FF0000
    AND     R4, R11, R6
    SHIFTR  R4, 8
    OR      R15, R4
    LOAD32  R6, 0x0000FF00
    AND     R5, R11, R6
    SHIFTL  R5, 8
    OR      R15, R5
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_do_orc_b:
    LD      R15, 0
    LOAD16  R6, 0xFF
    AND     R4, R11, R6
    FBRA.Z  R4, ._orc_b1
    OR      R15, R6
._orc_b1:
    SHIFTR  R4, R11, 8
    AND     R4, R6
    FBRA.Z  R4, ._orc_b2
    LOAD16  R5, 0xFF00
    OR      R15, R5
._orc_b2:
    SHIFTR  R4, R11, 16
    AND     R4, R6
    FBRA.Z  R4, ._orc_b3
    LOAD24  R5, 0xFF0000
    OR      R15, R5
._orc_b3:
    SHIFTR  R4, R11, 24
    AND     R4, R6
    FBRA.Z  R4, ._orc_done
    LOAD32  R5, 0xFF000000
    OR      R15, R5
._orc_done:
    LOAD16  R14, _forward_to_mem
    JMP     R14, R0

_forward_to_mem:
    FIFO.W  R10, R2
    FIFO.W  R15, R2
    FIFO.W  R14, R2
    FIFO.W  R12, R2
    LOAD16  R14, _ex_main_loop
    JMP     R14, R0