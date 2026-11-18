; Cluster test: core 0 waits a little, so core 1 is stalled on an empty
; FIFO, then raises trap 2 on core 1 with MBOX.
.include "lib/common.inc"

.org 0x00000100
_reset:
    JUMP    _main

.org 0x00000200
_main:
    LD      R2, 10
_delay:
    SUB     R2, 1
    BBRA.NZ R2, _delay
    MBOX    R0, 2
    LD      R1, 0
    TRAP    0
