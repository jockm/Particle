; WAIT and HALT: sleep in a WAIT until the first MBOX, which is taken (the
; handler adds its value to R10) and returns past the WAIT; then sleep in a
; masked WAIT, which the second MBOX ends without being taken; it is taken
; after EI. Checks R10 at each step, then HALTs (TRAP 15 on a mistake).
.include "lib/vectors.inc"
    RESET_SLOT _main
    TRAP_SLOT_UNEXPECTED 1
    TRAP_SLOT_BRANCH 2, _vector2
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
    TRAP_SLOT_UNEXPECTED 15
    UNEXPECTED_TRAP_ROUTINE

_vector2:                       ; R10 += the value
    LDIS    R5, NI_MBOX_VALUE
    LD32    R5, (R5)
    ADD     R10, R5
    RETI

_main:
    LD      R10, 0
    WAIT                        ; the first MBOX: taken
    LD      R7, R10
    SUB     R7, 1
    BNE     R7, R0, _bad        ; R10 = 1
    DI
    WAIT                        ; the second MBOX ends it, masked
    LD      R12, R10            ; still 1: not taken yet
    EI                          ; taken now
    NOP
    LD      R7, R12
    SUB     R7, 1
    BNE     R7, R0, _bad
    LD      R7, R10
    SUB     R7, 3
    BNE     R7, R0, _bad        ; R10 = 3
    HALT
_bad:
    TRAP    15
