; Ring FLUSH: wait until the flush has happened, then read 300 values and
; check their sum (45150); nothing else may be left
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LDI     R6, 400             ; a delay: the wrong words and the FLUSH arrive
._wait:
    SUB     R6, 1
    BBRA.NZ R6, ._wait
    LDI     R2, 300
    LD      R1, 0
    LD      R5, 1
_recv:
    FIFO.R  R3, R5
    ADD     R1, R3
    SUB     R2, 1
    BBRA.NZ R2, _recv
    LDI     R4, 45150
    SEQ     R4, R1
    FBRA.Z  R4, _bad
    FIFO.TRYR R3, R5            ; nothing more
    FBRA.NZ R14, _bad
    LD      R1, 0
    TRAP    0
_bad:
    TRAP    15
