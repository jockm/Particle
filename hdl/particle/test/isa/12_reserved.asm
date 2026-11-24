; The reserved opcodes 0xD3 and 0xD4 (formerly RBASE) take vector 15 with
; R14 = the instruction, like any undefined opcode, and change nothing
.include "lib/vectors.inc"
    RESET_SLOT _main
    TRAP_SLOT_UNEXPECTED 1
    TRAP_SLOT_UNEXPECTED 2
    TRAP_SLOT_UNEXPECTED 3
    TRAP_SLOT_UNEXPECTED 4
    TRAP_SLOT_UNEXPECTED 5
    TRAP_SLOT_UNEXPECTED 6
    TRAP_SLOT_UNEXPECTED 7
    TRAP_SLOT_UNEXPECTED 8
    TRAP_SLOT_UNEXPECTED 9
    TRAP_SLOT_UNEXPECTED 10
    TRAP_SLOT_UNEXPECTED 11
    TRAP_SLOT_UNEXPECTED 12
    TRAP_SLOT_UNEXPECTED 13
    TRAP_SLOT_UNEXPECTED 14
    TRAP_SLOT_BRANCH 15, _vec15
    UNEXPECTED_TRAP_ROUTINE
_vec15:                     ; count, record R14, skip the instruction
    ADD     R13, 1
    LD      R12, R14
    ADD     R14, 2
    JMP     R14, R0
.org 0x500
_main:
    LD      R1, 1
    LD      R2, 2
    .half   0xD304          ; was RBASE 4
    LD      R1, 5           ; still R1
    .half   0xD420          ; was RBASE R2
    LD      R3, 6           ; still R3
    .half   0xD300          ; was RBASE 0
    LD      R4, 7
_halt:
    BBRA    _halt
