; CONFIG on the ring, receiving: read 5 values on channel 1 (sum 15), then
; wait for the MBOX (vector 2, value 0x77) that core 0 sends to its new
; default target
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

_vector2:
    LDIS    R5, NI_MBOX_VALUE
    LD32    R5, (R5)
    LDI     R6, 0x77
    SEQ     R5, R6
    LD      R14, R5
    FBRA.Z  R14, _bad
    LD      R10, 1
    RETI

_main:
    MBOX.OFF                    ; until the values are read
    LD      R10, 0
    LD      R2, 5
    LD      R1, 0
    LD      R5, 1
._recv:
    FIFO.R  R3, R5
    ADD     R1, R3
    SUB     R2, 1
    BBRA.NZ R2, ._recv
    LD      R4, 15
    SEQ     R4, R1
    FBRA.Z  R4, _bad
    MBOX.ON
._spin:
    FBRA.Z  R10, ._spin
    LD      R1, 0
    TRAP    0
_bad:
    TRAP    15
