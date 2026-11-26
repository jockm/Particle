; Ring FLUSH: send ten wrong words, flush the channel (a store of the channel
; number to the network interface's FLUSH register, 0xFFFF_FF00), then send
; 1..300. The consumer must see only the 300. At the end every credit must be
; back (FIFO.STAT reports the channel empty), the discarded ten included.
.include "lib/vectors.inc"
    VECTOR_TABLE _main
_main:
    LD      R5, 1               ; channel
    LDI     R3, 1000            ; the wrong words
    LD      R2, 10
._junk:
    FIFO.W  R3, R5
    SUB     R2, 1
    BBRA.NZ R2, ._junk
    LDIS    R6, 0xFF00          ; R6 = 0xFFFF_FF00, the FLUSH register
    ST32    (R6), R5            ; flush channel 1
    LDI     R2, 300
    LD      R3, 1
_send:
    FIFO.TRYW R3, R5
    BBRA.Z  R14, _send
    ADD     R3, 1
    SUB     R2, 1
    BBRA.NZ R2, _send
_drain:                         ; wait for every credit to come back
    FIFO.STAT R7, R5
    BGET    R7, 0               ; bit 0: empty
    BBRA.Z  R7, _drain
    LD      R1, 0
    TRAP    0
