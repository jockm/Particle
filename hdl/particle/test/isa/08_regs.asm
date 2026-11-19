; XCHG, XCHGALL, XCHGMOST and the RBASE window
.include "lib/vectors.inc"
    VECTOR_TABLE _start
_start:
    LD      R1, 1
    LD      R2, 2
    LD      R3, 3
    LD      R14, 14
    LD      R15, 15
    XCHG    R1
    LD      R1, 9
    XCHGALL
    LD      R2, 7
    XCHGMOST
    LD      R3, 6
    RBASE   4               ; R1 is now physical 5
    LD      R1, 11
    LD      R15, 12
    XCHGMOST                ; swaps physical 5..18 (virtual 1..14)
    LD      R2, 13
    LD      R4, 10
    RBASE   R4              ; R4 holds 10: R1 is now physical 11
    LD      R3, 8
    XCHG    R3
    LD      R5, 0
    RBASE   R5              ; window back to 0
_halt:
    BBRA    _halt
