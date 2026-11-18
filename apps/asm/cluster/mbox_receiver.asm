; Cluster test: core 1 stalls reading a channel nothing writes. Core 0's
; MBOX interrupts the stall with trap 2, whose handler ends the run.
.include "lib/common.inc"

.org 0x00000100
_reset:
    JUMP    _main

.org 0x00000180                 ; vector 2
_vector2:
    LD      R1, 0
    TRAP    0

.org 0x00000200
_main:
    LD      R4, 2
    FIFO.R  R3, R4              ; stalls: channel 2 is never written
    TRAP    15                  ; not reached
