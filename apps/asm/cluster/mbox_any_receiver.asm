; MBOX to any core, receiving: vector 3 must bring 0x11 times this core's
; number (R12, from its initial registers) from core 0; vector 4 must be the
; broadcast 0x99. Both must arrive before the run ends.
.include "lib/vectors.inc"
    RESET_SLOT _main
    TRAP_SLOT_UNEXPECTED 1
    TRAP_SLOT_UNEXPECTED 2
    TRAP_SLOT_BRANCH 3, _vector3
    TRAP_SLOT_BRANCH 4, _vector4
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
    TRAP_SLOT_UNEXPECTED 15
    UNEXPECTED_TRAP_ROUTINE

_vector3:
    LDIS    R5, NI_MBOX_SOURCE
    LD32    R5, (R5)
    LD      R14, R5
    FBRA.NZ R14, _bad           ; from core 0
    LDIS    R5, NI_MBOX_VALUE
    LD32    R5, (R5)
    LD      R6, R12
    SHIFTL  R6, 4
    OR      R6, R12             ; R6 = 0x11 * R12
    SEQ     R5, R6
    LD      R14, R5
    FBRA.Z  R14, _bad
    BSET    R10, 0
    RETI
_vector4:
    LDIS    R5, NI_MBOX_VALUE
    LD32    R5, (R5)
    LDI     R6, 0x99
    SEQ     R5, R6
    LD      R14, R5
    FBRA.Z  R14, _bad
    BSET    R10, 1
    RETI

_main:
    LD      R10, 0
._spin:
    LD      R7, R10
    SUB     R7, 3
    BBRA.NZ R7, ._spin
    LD      R1, 0
    TRAP    0
_bad:
    TRAP    15
