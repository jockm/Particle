; ==============================================================================
; File: apps/asm/test_ldi_ldis.asm
; Target: Particle 32-bit RISC Core
; Description: Verification suite for LDI (0x07) and LDIS (0x08) instructions:
;              1. Unsigned 16-bit zero-extension (0, 0x1234, 0xFFFF)
;              2. Signed 16-bit sign-extension (0x7FFF, -1, -4096, -32768, 0x8001)
;              3. R14 preservation across LDI / LDIS
;              4. Symbol/label resolution & 4-byte PC tracking across branches
; ==============================================================================

.include "lib/common.inc"

.org 0x00000100

_reset:
    ; Pre-load R14 with sentinel 0xABCD to verify LDI/LDIS never clobber R14
    LD      R14, 0xAB
    PUSH8   R14, 0xCD           ; R14 = 0x0000ABCD

    ; 1. LDI unsigned boundary tests (must zero-extend bits [31:16])
    LDI     R1, 0x0000          ; R1 = 0x00000000
    FBRA.Z  R1, ._ok_1
    FBRA    _fail
._ok_1:

    LDI     R2, 0x1234          ; R2 = 0x00001234
    LD      R8, 1
    SHIFTL  R8, 4
    OR      R8, 2
    SHIFTL  R8, 4
    OR      R8, 3
    SHIFTL  R8, 4
    OR      R8, 4               ; R8 = 0x00001234 built via 4-bit ops
    SNE     R2, R8
    FBRA.Z  R2, ._ok_2
    FBRA    _fail
._ok_2:

    LDI     R3, 0xFFFF          ; R3 = 0x0000FFFF (must NOT sign-extend)
    LD      R8, 1
    SHIFTL  R8, 15
    SHIFTL  R8, 1
    SUB     R8, 1               ; R8 = 0x0000FFFF independently
    SNE     R3, R8
    FBRA.Z  R3, ._ok_3
    FBRA    _fail
._ok_3:

    ; 2. LDIS signed positive & negative boundary tests
    LDIS    R4, 0x7FFF          ; Max positive 16-bit signed -> 0x00007FFF
    LD      R8, 1
    SHIFTL  R8, 15
    SUB     R8, 1               ; R8 = 0x00007FFF
    SNE     R4, R8
    FBRA.Z  R4, ._ok_4
    FBRA    _fail
._ok_4:

    LDIS    R5, -1              ; -1 -> 0xFFFFFFFF
    LD      R8, -1              ; R8 = 0xFFFFFFFF
    SNE     R5, R8
    FBRA.Z  R5, ._ok_5
    FBRA    _fail
._ok_5:

    LDIS    R6, -4096           ; -4096 (0xF000) -> 0xFFFFF000
    LD      R8, -1
    SHIFTL  R8, 12              ; R8 = 0xFFFFF000
    SNE     R6, R8
    FBRA.Z  R6, ._ok_6
    FBRA    _fail
._ok_6:

    LDIS    R7, -32768          ; Min negative 16-bit signed -> 0xFFFF8000
    LD      R8, -1
    SHIFTL  R8, 15              ; R8 = 0xFFFF8000
    SNE     R7, R8
    FBRA.Z  R7, ._ok_7
    FBRA    _fail
._ok_7:

    LDIS    R9, 0x8001          ; Raw 16-bit negative pattern -> 0xFFFF8001
    LD      R8, -1
    SHIFTL  R8, 15
    OR      R8, 1               ; R8 = 0xFFFF8001
    SNE     R9, R8
    FBRA.Z  R9, ._ok_8
    FBRA    _fail
._ok_8:

    ; 3. Verify R14 was completely preserved across all LDI/LDIS instructions
    LDI     R8, 0xABCD
    SNE     R14, R8
    FBRA.Z  R14, ._ok_9
    FBRA    _fail
._ok_9:

    ; 4. Verify label resolution and PC+4 tracking across forward/backward branches
    FBRA    _after_table
    LDI     R1, 0xDEAD          ; 4-byte skipped instruction
    LDIS    R2, -1234           ; 4-byte skipped instruction
_after_table:
    LDI     R11, _data_word     ; Load 16-bit symbol address of _data_word
    LD32    R12, (R11)          ; Read 0xCAFEBABE from _data_word
    LDI     R8, 0xCAFE
    SHIFTL  R8, 15
    SHIFTL  R8, 1
    LDI     R13, 0xBABE
    OR      R8, R13             ; R8 = 0xCAFEBABE
    SNE     R12, R8
    FBRA.Z  R12, ._ok_10
    FBRA    _fail
._ok_10:

    ; All checks passed
    LDI     R1, 0xCAFE
    LDI     R10, 0xCAFE
    TRAP    0

_fail:
    LDI     R1, 0xDEAD
    LDI     R10, 0xDEAD
    TRAP    15

.align 4
_data_word:
    .word   0xCAFEBABE
