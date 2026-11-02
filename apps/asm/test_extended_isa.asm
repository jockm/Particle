; ==============================================================================
; Test Suite: Particle Extended ISA Validation
; Tests: NEG, REV32, SEQ, SNE, SLE, SSLE
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset:
    ; 1. Test NEG (0x48): R1 = -10
    LD      R1, 10
    NEG     R1                  ; R1 = -10 (0xFFFFFFF6)

    ; 2. Test REV32 (0x8C): Endian byte swap
    LOAD32  R2, 0x12345678
    REV32   R2                  ; R2 = 0x78563412

    ; 3. Test SEQ (0x9A): Equality check
    LD      R3, 10
    LD      R4, 10
    SEQ     R3, R4              ; R3 == R4 -> R3 = 1

    LD      R5, 10
    LD      R6, 12
    SEQ     R5, R6              ; R5 != R6 -> R5 = 0

    ; 4. Test SNE (0x9B): Non-equality check
    LD      R7, 10
    LD      R8, 12
    SNE     R7, R8              ; R7 != R8 -> R7 = 1

    ; 5. Test SLE (0x9C): Unsigned less-than-or-equal
    LD      R9, 15
    LD      R10, 15
    SLE     R9, R10             ; 15 <= 15 -> R9 = 1

    ; 6. Test SSLE (0x9D): Signed less-than-or-equal (-5 <= 5)
    LD      R11, 5
    NEG     R11                 ; R11 = -5
    LD      R12, 5
    SSLE    R11, R12            ; -5 <= 5 -> R11 = 1

    ; Sentinel check: If all pass, R10 = 0xCAFE
    LOAD16  R10, 0xCAFE
_halt:
    FBRA    _halt