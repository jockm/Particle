; Every load and store addressing mode at 8, 16 and 32 bits, the cases where
; the pointer is also the data register, and TAS
; check-memory: 0x8000 128
.org 0x100
    LDI     R1, 0xA1B2
    SHIFTL  R1, 15
    SHIFTL  R1, 1
    LDI     R14, 0xC3D4
    OR      R1, R14         ; R1 = 0xA1B2C3D4
    LDI     R10, 0x8010
    ; stores: plain, ++, pre-inc, --, pre-dec
    ST32    (R10), R1
    ST32    (R10++), R1
    ST32    (++R10), R1
    ST16    (R10++), R1
    ST16    (++R10), R1
    ST8     (R10++), R1
    ST8     (++R10), R1
    ST8     (R10--), R1
    ST8     (--R10), R1
    LDI     R10, 0x8040
    ST16    (R10--), R1
    ST16    (--R10), R1
    ST32    (R10--), R1
    ST32    (--R10), R1
    LD      R11, R10        ; pointer after the stores
    ; loads from the stored pattern
    LDI     R10, 0x8010
    LD32    R2, (R10)
    LD16    R3, (R10++)
    LD16    R4, (++R10)
    LD8     R5, (R10++)
    LD8     R6, (++R10)
    LD8     R7, (R10--)
    LD8     R8, (--R10)
    LDI     R10, 0x8020
    LD32    R9, (R10++)
    LD32    R12, (++R10)
    LD32    R13, (R10--)
    XCHG    R9
    XCHG    R12
    XCHG    R13
    LD32    R9, (--R10)
    LD16    R12, (R10--)
    LD16    R13, (--R10)
    XCHG    R11
    LD      R11, R10
    ; pointer is also the data register
    LDI     R10, 0x8050
    ST32    (R10++), R10    ; stores the updated pointer
    LDI     R10, 0x8060
    ST32    (--R10), R10
    LDI     R10, 0x8070
    ST16    (R10), R10
    LDI     R10, 0x8050
    LD32    R10, (R10++)    ; the loaded value wins
    LD      R2, R10
    LDI     R10, 0x8060
    LD32    R10, (--R10)
    LD      R3, R10
    ; TAS: swap R4 with memory
    LDI     R10, 0x8078
    LD      R4, 9
    TAS     (R10), R4       ; memory was 0
    LD      R5, 6
    TAS     (R10), R5       ; R5 = 9, memory = 6
_halt:
    BBRA    _halt
