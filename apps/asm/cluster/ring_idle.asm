; A core that does nothing: on a ring its router still passes packets on
; after the core has stopped
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LD      R1, 0
    TRAP    0
