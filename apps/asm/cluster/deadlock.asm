; Cluster test, run on both cores: each waits on a channel the other never
; writes, so psim reports a deadlock (exit code 19).
.include "lib/vectors.inc"

    VECTOR_TABLE _main

_main:
    LD      R2, 3
    FIFO.R  R1, R2
    TRAP    0
