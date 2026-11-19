; Multiplies and divides, including division by zero and INT_MIN / -1
; max-cycles: 40000
.org 0x100
    LDI     R1, 0x8000
    SHIFTL  R1, 15
    SHIFTL  R1, 1           ; INT_MIN
    LD      R2, -1
    LDI     R3, 12345
    LD      R4, -7
    LD      R5, 0
    LD      R6, R3
    MULL    R6, R4
    LD      R7, R3
    MULH    R7, R4
    LD      R8, R3
    SMULH   R8, R4
    LD      R9, R4
    MULHSU  R9, R3
    LD      R10, R2
    MULL    R10, 15
    LD      R11, R2
    MULH    R11, 15
    LD      R12, R4
    SMULH   R12, -8
    LD      R13, R4
    MULHSU  R13, 9
    XCHG    R6
    XCHG    R7
    XCHG    R8
    XCHG    R9
    ; divides
    LD      R6, R3
    DIV     R6, R4          ; unsigned
    LD      R7, R3
    MOD     R7, R4
    LD      R8, R3
    SDIV    R8, R4
    LD      R9, R3
    SMOD    R9, R4
    LD      R10, R1
    SDIV    R10, R2         ; INT_MIN / -1 = INT_MIN
    LD      R11, R1
    SMOD    R11, R2         ; = 0
    LD      R12, R3
    DIV     R12, R5         ; / 0 = 0xFFFFFFFF
    LD      R13, R3
    MOD     R13, R5         ; % 0 = dividend
    XCHG    R10
    XCHG    R11
    XCHG    R12
    XCHG    R13
    LD      R10, R4
    SDIV    R10, R5         ; / 0 = -1
    LD      R11, R4
    SMOD    R11, R5         ; % 0 = dividend
    LD      R12, R3
    DIV     R12, 7
    LD      R13, R3
    MOD     R13, 7
    LD      R14, R4
    SDIV    R14, -3
    LD      R6, R4
    SMOD    R6, -3
    LD      R7, R3
    DIV     R7, 0
    LD      R8, R3
    SMOD    R8, 0
_halt:
    BBRA    _halt
