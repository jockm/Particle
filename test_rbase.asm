; ==============================================================================
; Test: test_rbase.asm
; Description: Validates RBASE windowing across pasm.py and psim.py
; ==============================================================================
.include "lib/common.inc"

.org 0x0100
_start:
    ; 1. Load initial value into R1 (physical 1) under RBASE = 0
    LOAD16  R1, 0x1111

    ; 2. Switch RBASE to 16 using immediate format
    RBASE   16

    ; Virtual R1 now maps to physical 17 (starts at 0)
    ; Load distinct value into physical 17
    LOAD16  R1, 0x2222

    ; 3. Verify Virtual R0 remains hardwired 0 even with RBASE=16
    ADD     R2, R0, R1      ; R2 = R1 (0x2222)
    LD      R0, 5           ; 4-bit write to R0 must be discarded
    ADD     R3, R0, R0      ; R3 should remain 0

    ; 4. Switch RBASE back to 0 using register-directed format
    LOAD16  R4, 0
    RBASE   R4

    ; Verify physical 1 still retains 0x1111
    ADD     R5, R1, R0      ; R5 should be 0x1111

    ; Switch to RBASE 16 dynamically using register
    LOAD16  R4, 16
    RBASE   R4
    ADD     R6, R1, R0      ; R6 should be 0x2222

    ; Terminate simulation via Debug Trap 14
    TRAP    14
