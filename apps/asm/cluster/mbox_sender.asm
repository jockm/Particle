; Cluster test: core 0 waits a little, so core 1 is stalled on an empty
; FIFO, then raises trap 2 on core 1 with MBOX, sending 0x12345678.
.include "lib/vectors.inc"

    VECTOR_TABLE _main

_main:
    LD      R2, 10
_delay:
    SUB     R2, 1
    BBRA.NZ R2, _delay
    LDI     R3, 0x1234
    SHIFTL  R3, 15
    SHIFTL  R3, 1
    LDI     R4, 0x5678
    OR      R3, R4              ; R3 = 0x12345678
    MBOX    R3, 2
    LD      R1, 0
    TRAP    0
