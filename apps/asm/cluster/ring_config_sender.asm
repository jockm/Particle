; CONFIG on the ring: channel 1 starts routed to core 1. Send CONFIG
; packets (to the CONFIG register) that route it to core 2's channel 1, make
; core 0 the sender of core 2's channel 1 (for the credits), and make core 2
; this core's default MBOX target. Wait for them to go round the ring, then
; send 1..5 on channel 1 and an MBOX (vector 2, the default target).
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LDIS    R6, NI_CONFIG
    LDI     R7, 0x0001          ; core 0, entry 0 (route), channel 1
    SHIFTL  R7, 15
    SHIFTL  R7, 1               ; R7 = 0x0001_0000
    LDI     R8, 0x0201          ; to core 2, channel 1
    OR      R7, R8
    ST32    (R6), R7
    LDI     R7, 0x0211          ; core 2, entry 1 (sender), channel 1
    SHIFTL  R7, 15
    SHIFTL  R7, 1               ; R7 = 0x0211_0000
    LDI     R8, 0x0001          ; core 0, channel 1
    OR      R7, R8
    ST32    (R6), R7
    LDI     R7, 0x0020          ; core 0, entry 2 (MBOX target)
    SHIFTL  R7, 15
    SHIFTL  R7, 1               ; R7 = 0x0020_0000
    LDI     R8, 0x0200          ; core 2
    OR      R7, R8
    ST32    (R6), R7
    LD      R2, 15              ; let them arrive
._wait:
    SUB     R2, 1
    BBRA.NZ R2, ._wait
    LD      R2, 5
    LD      R3, 1
    LD      R5, 1
._send:
    FIFO.W  R3, R5
    ADD     R3, 1
    SUB     R2, 1
    BBRA.NZ R2, ._send
    LDI     R3, 0x77
    MBOX    R3, 2
    LD      R1, 0
    TRAP    0
