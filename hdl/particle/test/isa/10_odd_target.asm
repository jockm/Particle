; A jump to an odd address: the JMP still links, then vector 14 is taken with
; R14 = the odd target
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
    TRAP_SLOT_BRANCH 14, _vec14
    TRAP_SLOT_UNEXPECTED 15
    UNEXPECTED_TRAP_ROUTINE
_vec14:
    ADD     R5, 1
    LD      R6, R14
    LDI     R14, _back
    JMP     R14, R0
.org 0x500
_main:
    LDI     R1, _target
    ADD     R1, 1           ; odd
    JMP     R1, R2          ; R2 = link
    LD      R15, 15
_back:
    LD      R7, 7
_halt:
    BBRA    _halt
_target:
    LD      R15, 14
    BBRA    _halt
