; MBOX queueing: start masked, unmask after a while, take six MBOXes (the
; handler adds each value to R10 and returns with RETI), and check the sum
; (21) and that the interrupted code's R14 survived every trap.
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

_vector2:                       ; R10 += the value, R11 += 1 (R5 is free)
    LDIS    R5, NI_MBOX_VALUE
    LD32    R5, (R5)
    ADD     R10, R5
    ADD     R11, 1
    RETI

_main:
    MBOX.OFF
    LD      R10, 0              ; sum
    LD      R11, 0              ; MBOXes taken
    LDI     R6, 200             ; a delay, while the sender fills the queue
._wait:
    SUB     R6, 1
    BBRA.NZ R6, ._wait
    LDI     R14, 0x55           ; must survive the traps
    MBOX.ON
._spin:
    LD      R7, R11
    SUB     R7, 6
    BBRA.NZ R7, ._spin
    LD      R7, 15
    ADD     R7, 6               ; 21
    SEQ     R7, R10
    FBRA.Z  R7, _bad
    LDI     R7, 0x55
    SEQ     R7, R14
    FBRA.Z  R7, _bad
    LD      R1, 0
    TRAP    0
_bad:
    TRAP    15
