; Arithmetic, logic, comparisons and sign extension, register and immediate forms
.org 0x100
    LDI     R1, 0x8000
    SHIFTL  R1, 15
    SHIFTL  R1, 1           ; R1 = 0x80000000
    LD      R2, -1          ; R2 = 0xFFFFFFFF
    LDI     R3, 0x1234
    LD      R4, 7
    LD      R5, R1
    ADD     R5, R2          ; 0x7FFFFFFF
    LD      R6, R3
    SUB     R6, R4
    SADD    R6, R2
    SSUB    R6, R1
    ADD     R6, 15
    SUB     R6, 3
    SADD    R6, -8
    SSUB    R6, 7
    LD      R7, R3
    NEG     R7
    LD      R8, R1
    NEG     R8              ; NEG of 0x80000000 is itself
    LD      R9, R3
    AND     R9, R2
    OR      R9, R1
    XOR     R9, R4
    AND     R9, 12
    OR      R9, 9
    XOR     R9, 15
    LD      R10, R3
    NOT     R10
    LD      R11, R10
    NEZ     R11
    LD      R12, 0
    NEZ     R12
    LDI     R13, 0x00FF
    SEXT8   R13             ; 0xFFFFFFFF
    LDI     R14, 0x7FFF
    SEXT16  R14             ; 0x00007FFF
    XCHG    R14             ; keep R14 in the shadow bank
    LDI     R14, 0x8001
    SEXT16  R14
    XCHG    R13
    ; comparisons (results in R5..R12, R14 forms last)
    LD      R5, R1
    SLT     R5, R4          ; unsigned 0x80000000 < 7 = 0
    LD      R6, R1
    SSLT    R6, R4          ; signed = 1
    LD      R7, R4
    SEQ     R7, R4
    LD      R8, R4
    SNE     R8, R3
    LD      R9, R2
    SLE     R9, R1          ; unsigned 0xFFFFFFFF <= 0x80000000 = 0
    LD      R10, R2
    SSLE    R10, R1         ; signed -1 <= INT_MIN = 0
    LD      R11, R4
    SLT     R11, 8
    LD      R12, R2
    SLT     R12, -3         ; 0xFFFFFFFF < 0xFFFFFFFD = 0
    LD      R13, R1
    SSLT    R13, -3
    LD      R3, R4
    SSLT    R3, 7
    LD      R14, 100
    SLT     R14, 101
    LD      R1, R14
    LD      R14, -50
    SSLT    R14, -49
    LD      R2, R14
    LD      R14, 200
    SLT     R14, -1
    LD      R4, R14
    LD      R14, 5
    SSLT    R14, 100
_halt:
    BBRA    _halt
