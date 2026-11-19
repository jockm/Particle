; Immediate loads: LD forms, PUSH4, PUSH8, LDI and LDIS (back to back)
.include "lib/vectors.inc"
    VECTOR_TABLE _start
_start:
    LD      R1, 15
    LD      R2, -15
    LD      R3, 0
    LD      R14, 255
    LD      R4, R14
    LD      R14, -255
    LD      R5, R14
    LD      R6, 0xA
    PUSH4   R6, 0xB
    PUSH4   R6, 0xC
    LD      R14, 0x12
    PUSH8   R14, 0x34
    PUSH8   R14, 0x56
    PUSH8   R14, 0x78
    LD      R7, R14
    LDI     R8, 0xFFFF
    LDIS    R9, 0xFFFF
    LDIS    R10, 0x7FFF
    LDI     R11, 0x8000
    LDIS    R12, 0x8000
    LDI     R13, 1
    LDI     R13, 2
    ADD     R13, R12
_halt:
    BBRA    _halt
