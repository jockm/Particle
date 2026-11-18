; ==============================================================================
; Parcore RV32IM_Zbb: Core 4 (Writeback & Architectural Retirement)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core4_wb.asm
; ==============================================================================
.include "lib/common.inc"

.define INSTRET_LO_ADDR 0x0004  ; Zero Page low 32 bits of minstret
.define INSTRET_HI_ADDR 0x0008  ; Zero Page high 32 bits of minstret

.org 0x00000100
_reset_vector:
    LD      R14, INSTRET_LO_ADDR
    LD      R4, 0
    ST32    (R14), R4           ; Clear INSTRET_LO
    LD      R14, INSTRET_HI_ADDR
    ST32    (R14), R4           ; Clear INSTRET_HI

_wb_main_loop:
    FIFO.R  R10, R0              ; Pop from Core 3 (Ch0): Rd
    FIFO.R  R11, R0              ; Pop from Core 3 (Ch0): Data

    ; Check for flush sentinel 0xFFFFFFFF (R10 + 1 == 0)
    LD      R4, R10
    ADD     R4, 1
    FBRA.NZ R4, ._do_count
    LOAD16  R14, _wb_main_loop
    JMP     R14, R0

._do_count:
    ; Increment instruction retirement counter (minstret)
    LD      R14, INSTRET_LO_ADDR
    LD32    R4, (R14)
    ADD     R4, 1
    ST32    (R14), R4
    FBRA.NZ R4, ._commit_retire
    LD      R14, INSTRET_HI_ADDR
    LD32    R6, (R14)
    ADD     R6, 1
    ST32    (R14), R6

._commit_retire:
    FBRA.Z  R10, ._retire_x0

    FIFO.W  R10, R1              ; Channel 1 to Core 1 (Feedback)
    FIFO.W  R11, R1
    LOAD16  R14, _wb_main_loop
    JMP     R14, R0

._retire_x0:
    LD      R12, 0
    FIFO.W  R12, R1
    FIFO.W  R12, R1
    LOAD16  R14, _wb_main_loop
    JMP     R14, R0
