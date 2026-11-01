; ==============================================================================
; Parcore RV32IM_Zbb: Core 3 (Memory Access, Alignment Engine & Cache Interface)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core3_mem.asm
; ==============================================================================
.include "lib/common.inc"

.define MMIO_MEM_REQ    0xF0000040
.define MMIO_MEM_RESP   0xF0000044

.org 0x00000100
_reset_vector:
    LD      R1, 0
    LD      R2, 1

_mem_main_loop:
    FIFO.R  R10, R1             ; Control Word
    FIFO.R  R11, R1             ; Computed Result
    FIFO.R  R12, R1             ; Memory Target Address
    FIFO.R  R13, R1             ; Store Data

    SHIFTR  R9, R10, 8
    LOAD16  R14, 0x1F
    AND     R9, R14

    SHIFTR  R14, R10, 16
    LD      R15, 0x0F
    AND     R14, R15
    FBRA.NZ R14, ._mem_op
    LOAD16  R14, _forward_wb
    JMP     R14, R0

._mem_op:
    SUB     R3, R14, 3
    FBRA.NZ R3, ._chk_lb
    LOAD16  R14, _do_lw
    JMP     R14, R0

._chk_lb:
    SUB     R3, R14, 1
    FBRA.NZ R3, ._chk_lh
    LOAD16  R14, _do_lb
    JMP     R14, R0

._chk_lh:
    SUB     R3, R14, 2
    FBRA.NZ R3, ._chk_lbu
    LOAD16  R14, _do_lh
    JMP     R14, R0

._chk_lbu:
    SUB     R3, R14, 4
    FBRA.NZ R3, ._chk_lhu
    LOAD16  R14, _do_lbu
    JMP     R14, R0

._chk_lhu:
    SUB     R3, R14, 5
    FBRA.NZ R3, ._chk_sw
    LOAD16  R14, _do_lhu
    JMP     R14, R0

._chk_sw:
    LOAD16  R5, 10
    SUB     R3, R14, R5
    FBRA.NZ R3, ._chk_sb
    LOAD16  R14, _do_sw
    JMP     R14, R0

._chk_sb:
    LOAD16  R5, 8
    SUB     R3, R14, R5
    FBRA.NZ R3, ._chk_sh
    LOAD16  R14, _do_sb
    JMP     R14, R0

._chk_sh:
    LOAD16  R5, 9
    SUB     R3, R14, R5
    FBRA.NZ R3, ._chk_pass
    LOAD16  R14, _do_sh
    JMP     R14, R0

._chk_pass:
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_lw:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    R11, (R4)
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_lb:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    R5, (R4)
    AND     R6, R12, 0x03
    SHIFTL  R6, 3
    SHIFTR  R5, R6
    SEXT8   R11, R5
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_lbu:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    R5, (R4)
    AND     R6, R12, 0x03
    SHIFTL  R6, 3
    SHIFTR  R5, R6
    LOAD16  R14, 0xFF
    AND     R11, R5, R14
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_lh:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    R5, (R4)
    AND     R6, R12, 0x02
    SHIFTL  R6, 3
    SHIFTR  R5, R6
    SEXT16  R11, R5
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_lhu:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    R5, (R4)
    AND     R6, R12, 0x02
    SHIFTL  R6, 3
    SHIFTR  R5, R6
    LOAD16  R7, 0xFFFF
    AND     R11, R5, R7
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_sw:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    (R4), R13
    LD      R9, 0
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_sb:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    R5, (R4)
    AND     R6, R12, 0x03
    SHIFTL  R6, 3
    LOAD16  R7, 0xFF
    SHIFTL  R7, R6
    NOT     R7, R7
    AND     R5, R7
    LOAD16  R8, 0xFF
    AND     R8, R13, R8
    SHIFTL  R8, R6
    OR      R5, R8
    LD32    (R4), R5
    LD      R9, 0
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_do_sh:
    LOAD32  R4, MMIO_MEM_REQ
    LD32    (R4), R12
    LOAD32  R4, MMIO_MEM_RESP
    LD32    R5, (R4)
    AND     R6, R12, 0x02
    SHIFTL  R6, 3
    LOAD16  R7, 0xFFFF
    SHIFTL  R7, R6
    NOT     R7, R7
    AND     R5, R7
    LOAD16  R8, 0xFFFF
    AND     R8, R13, R8
    SHIFTL  R8, R6
    OR      R5, R8
    LD32    (R4), R5
    LD      R9, 0
    LOAD16  R14, _forward_wb
    JMP     R14, R0

_forward_wb:
    FIFO.W  R9, R2
    FIFO.W  R11, R2
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0