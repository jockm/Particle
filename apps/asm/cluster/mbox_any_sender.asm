; MBOX to any core: MBOX Rr, Rl with the target in Rl bits 7:0 and the vector
; in 11:8. Send 0x11 to core 1 and 0x22 to core 2 (vector 3), then a
; broadcast (core 0xFF, vector 4) to both.
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LDI     R3, 0x11
    LDI     R4, 0x0301          ; vector 3, core 1
    MBOX    R3, R4
    LDI     R3, 0x22
    LDI     R4, 0x0302          ; vector 3, core 2
    MBOX    R3, R4
    LDI     R3, 0x99
    LDI     R4, 0x04FF          ; vector 4, every core
    MBOX    R3, R4
    LD      R1, 0
    TRAP    0
