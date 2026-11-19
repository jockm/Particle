; Bring-up: immediates, ALU, LDI, a load and a store, a taken branch
; check-memory: 0x8000 16
.org 0x100
    LD      R1, 5
    LD      R2, 7
    ADD     R1, R2          ; R1 = 12
    LDI     R3, 0x8000
    ST32    (R3), R1
    LD32    R4, (R3)        ; R4 = 12
    ADD     R4, 1           ; R4 = 13
    ST16    (R3), R4
    LD8     R5, (R3)
    FBRA.NZ R5, _skip
    LD      R6, 9           ; skipped
_skip:
    LD      R7, 3
_halt:
    BBRA    _halt
