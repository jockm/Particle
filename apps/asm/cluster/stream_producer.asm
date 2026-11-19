; Cluster test: core 0 sends 1..5 on channel 1, which the cluster file
; routes to core 1's channel 1.
.include "lib/vectors.inc"

    VECTOR_TABLE _main

_main:
    LD      R2, 5               ; values to send
    LD      R3, 1               ; first value
    LD      R5, 1               ; channel
_send:
    FIFO.W  R3, R5
    ADD     R3, 1
    SUB     R2, 1
    BBRA.NZ R2, _send
    LD      R1, 0
    TRAP    0
