; XCHG, XCHGALL and XCHGMOST
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
    LD      R1, 11
    LD      R15, 12
    XCHGMOST                ; swaps R1..R14, not R15
    LD      R2, 13
    LD      R4, 10
    LD      R3, 8
    XCHG    R3
    LD      R5, 5
    XCHG    R15
    LD      R15, 4
_halt:
    BBRA    _halt
