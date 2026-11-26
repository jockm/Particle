; WAIT and HALT: wake the receiver from its first WAIT with an MBOX (value
; 1), wait long enough for it to reach its second WAIT, masked, then end that
; one with a second MBOX (value 2). Then HALT: the run ends when both cores
; have stopped.
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LDI     R2, 100
._d1:
    SUB     R2, 1
    BBRA.NZ R2, ._d1
    LD      R3, 1
    MBOX    R3, 2
    LDI     R2, 400
._d2:
    SUB     R2, 1
    BBRA.NZ R2, ._d2
    LD      R3, 2
    MBOX    R3, 2
    HALT
