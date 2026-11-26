; Ring flow control: send 1..1000 on channel 1 to a slow consumer. Only 256
; words fit in its buffer, so FIFO.TRYW fails (R14 = 0) until it has read
; some and their credits have come back round the ring; then try again.
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LDI     R2, 1000            ; values to send
    LD      R3, 1               ; next value
    LD      R5, 1               ; channel
_send:
    FIFO.TRYW R3, R5
    BBRA.Z  R14, _send          ; no credit yet: try again
    ADD     R3, 1
    SUB     R2, 1
    BBRA.NZ R2, _send
    LD      R1, 0
    TRAP    0
