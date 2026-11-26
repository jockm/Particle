; MBOX queueing: send 1..6 with MBOX vector 2 to a receiver that is masked.
; Its queue holds 4, so the fifth MBOX waits (or, on a ring, is NACKed and
; sent again) until the receiver unmasks and takes some: none is lost.
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LD      R2, 6               ; MBOXes to send
    LD      R3, 1               ; first value
_send:
    MBOX    R3, 2
    ADD     R3, 1
    SUB     R2, 1
    BBRA.NZ R2, _send
    LD      R1, 0
    TRAP    0
