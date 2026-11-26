; Ring flow control: read 1000 values slowly and check their sum (500500)
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LDI     R2, 1000            ; values to read
    LD      R1, 0               ; sum
    LD      R5, 1               ; channel
_recv:
    LD      R6, 12              ; a delay, so the producer runs out of credits
._wait:
    SUB     R6, 1
    BBRA.NZ R6, ._wait
    FIFO.R  R3, R5
    ADD     R1, R3
    SUB     R2, 1
    BBRA.NZ R2, _recv
    LDI     R7, 0x0007          ; R4 = 500500 = 0x0007_A314
    SHIFTL  R7, 15
    SHIFTL  R7, 1
    LDI     R4, 0xA314
    OR      R4, R7
    SEQ     R4, R1
    FBRA.Z  R4, _bad
    LD      R1, 0
    TRAP    0
_bad:
    TRAP    15
