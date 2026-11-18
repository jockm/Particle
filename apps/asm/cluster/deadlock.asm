; Cluster test, run on both cores: each waits on a channel the other never
; writes, so psim reports a deadlock (exit code 19).
.include "lib/common.inc"

.org 0x00000100
_reset:
    JUMP    _main

.org 0x00000200
_main:
    LD      R2, 3
    FIFO.R  R1, R2
    TRAP    0
