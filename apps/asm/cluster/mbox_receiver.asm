; Cluster test: core 1 stalls reading a channel nothing writes. Core 0's
; MBOX interrupts the stall with trap 2, whose handler checks the value and
; the sender (the MBOX registers) and ends the run.
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

_vector2:                       ; ends the run
    LDIS    R5, NI_MBOX_SOURCE
    LD32    R5, (R5)
    FBRA.NZ R5, _bad_value      ; it came from core 0
    LDIS    R5, NI_MBOX_VALUE
    LD32    R5, (R5)
    LDI     R6, 0x1234
    SHIFTL  R6, 15
    SHIFTL  R6, 1
    LDI     R7, 0x5678
    OR      R6, R7              ; R6 = 0x12345678
    SEQ     R5, R6
    FBRA.Z  R5, _bad_value
    LD      R1, 0
    TRAP    0
_bad_value:
    LD      R1, R5
    TRAP    15

_main:
    LD      R4, 2
    FIFO.R  R3, R4              ; stalls: channel 2 is never written
    TRAP    15                  ; not reached
