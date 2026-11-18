; Cluster test, run on both cores: each adds 1 to a counter in shared
; memory 50 times, holding a TAS lock around each update. Core 1 (R13 = 1,
; from the cluster file) then sets a done flag; core 0 waits for it and
; checks that the counter is 100.
.include "lib/common.inc"

.org 0x00000100
_reset:
    JUMP    _main

.org 0x00000200
_main:
    LOAD32  R5, 0x80000000      ; lock
    LOAD32  R6, 0x80000004      ; counter
    LOAD32  R7, 0x80000008      ; done flag
    LDI     R2, 50
_loop:
_acquire:
    LD      R3, 1
    TAS     (R5), R3            ; R3 = old lock; lock = 1
    BBRA.NZ R3, _acquire        ; held by the other core: try again
    LD32    R4, (R6)
    ADD     R4, 1
    ST32    (R6), R4
    ST32    (R5), R0            ; release
    SUB     R2, 1
    BBRA.NZ R2, _loop
    FBRA.NZ R13, _core1
_wait:
    LD32    R3, (R7)
    BBRA.Z  R3, _wait
    LD32    R1, (R6)
    LDI     R4, 100
    SEQ     R4, R1              ; R4 = (100 == counter)
    FBRA.Z  R4, _bad
    TRAP    0
_core1:
    LD      R3, 1
    ST32    (R7), R3
    LD      R1, 0
    TRAP    0
_bad:
    TRAP    15
