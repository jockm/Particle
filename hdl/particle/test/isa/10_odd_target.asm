; A jump to an odd address: the JMP still links, then vector 14 is taken with
; R14 = the odd target
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x480                  ; vector 14
    ADD     R5, 1
    LD      R6, R14
    LDI     R14, _back
    JMP     R14, R0
.org 0x500
_main:
    LDI     R1, _target
    ADD     R1, 1           ; odd
    JMP     R1, R2          ; R2 = link
    LD      R15, 15
_back:
    LD      R7, 7
_halt:
    BBRA    _halt
_target:
    LD      R15, 14
    BBRA    _halt
