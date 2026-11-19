; Shifts, rotates, bit operations, BEXTR, CLZ (counts Rl) and REV32
.org 0x100
    LDI     R1, 0x8421
    SHIFTL  R1, 15
    ADD     R1, 0x9         ; R1 = 0x42108009
    LD      R14, 31
    LD      R2, R14
    LD      R3, 0
    LD      R4, R1
    SHIFTL  R4, R2
    LD      R5, R1
    SHIFTR  R5, R2
    LD      R6, R1
    NOT     R6
    ASHIFTR R6, R2
    LD      R7, R1
    ROTL    R7, R2
    LD      R8, R1
    ROTR    R8, R3          ; rotate by 0
    LD      R9, R1
    ROTL    R9, 4
    ROTR    R9, 15
    SHIFTL  R9, 3
    SHIFTR  R9, 1
    ASHIFTR R9, 2
    LD      R10, R1
    BSET    R10, R2
    BCLR    R10, 3
    BINV    R10, 0
    BSET    R10, 1
    LD      R11, R1
    BGET    R11, 3
    LD      R12, R1
    BCLR    R12, R2
    BINV    R12, R2
    LDI     R13, 0x0124     ; BEXTR: pos = 4, len = 9
    LD      R14, R1
    BEXTR   R14, R13
    LD      R2, R14
    LD      R3, R1
    CLZ     R3, R12         ; clz of R12, not R3
    LD      R4, 0
    CLZ     R5, R4          ; clz(0) = 32
    LD      R6, R1
    REV32   R6
    LD      R7, -1
    CLZ     R7, R7
    LD      R8, R1
    BGET    R8, R13
_halt:
    BBRA    _halt
