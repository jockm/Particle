; Cluster test: core 1 reads five values from channel 1 and checks that
; they add up to 15 (1 + 2 + 3 + 4 + 5).
.include "lib/common.inc"

.org 0x00000100
_reset:
    JUMP    _main

.org 0x00000200
_main:
    LD      R2, 5               ; values to read
    LD      R1, 0               ; sum
    LD      R5, 1               ; channel
_recv:
    FIFO.R  R3, R5              ; waits until core 0 has sent
    ADD     R1, R3
    SUB     R2, 1
    BBRA.NZ R2, _recv
    LD      R4, 15
    SEQ     R4, R1              ; R4 = (15 == sum)
    FBRA.Z  R4, _bad
    TRAP    0
_bad:
    TRAP    15
