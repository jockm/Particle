; ==============================================================================
; Parcore RV32IM_Zbb: Core 4 (Writeback & Architectural Retirement)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core4_wb.asm
; ==============================================================================
.include "lib/common.inc"

.define INSTRET_LO_ADDR 0x0200
.define INSTRET_HI_ADDR 0x0204

.org 0x00000100
_reset_vector:
    LD      R1, 0
    LD      R2, 1

    LOAD16  R3, INSTRET_LO_ADDR
    LD      R4, 0
    LD32    (R3), R4            ; Clear INSTRET_LO
    LOAD16  R3, INSTRET_HI_ADDR
    LD32    (R3), R4            ; Clear INSTRET_HI

_wb_main_loop:
    FIFO.R  R10, R1
    FIFO.R  R11, R1

    LOAD32  R3, 0xFFFFFFFF
    SUB     R4, R10, R3
    FBRA.NZ R4, ._do_count
    LOAD16  R14, _wb_main_loop
    JMP     R14, R0

._do_count:
    LOAD16  R3, INSTRET_LO_ADDR
    LD32    R4, (R3)
    ADD     R4, 1
    LD32    (R3), R4
    FBRA.NZ R4, ._commit_retire
    LOAD16  R5, INSTRET_HI_ADDR
    LD32    R6, (R5)
    ADD     R6, 1
    LD32    (R5), R6

._commit_retire:
    FBRA.Z  R10, ._retire_x0

    FIFO.W  R10, R2
    FIFO.W  R11, R2
    LOAD16  R14, _wb_main_loop
    JMP     R14, R0

._retire_x0:
    LD      R12, 0
    FIFO.W  R12, R2
    FIFO.W  R12, R2
    LOAD16  R14, _wb_main_loop
    JMP     R14, R0