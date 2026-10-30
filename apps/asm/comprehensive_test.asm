; ==============================================================================
; File: apps/asm/comprehensive_test.asm
; Target: Particle 32-bit RISC Core
; Description: End-to-end hardware validation suite with explicit reset vector
;              and register pre-seeding.
; ==============================================================================

.include "lib/common.inc"

.org 0x00000100

; --- Reset Vector (0x0100) ---
_reset_handler:
    ; Explicit initialization (expanded from START_PROGRAM macro)
    LOAD32  R15, 0x00010000     ; Stack Pointer to top of 64KB RAM
    LOAD32  R14, _main          ; Load address of main
    JMP     R14, R0             ; Jump to _main without linking
    .align  64

; --- Trap 1: MBOX Vector (0x0140) ---
_mbox_handler:
    FAST_ENTER_TRAP
    FAST_EXIT_TRAP
    .align  64

; --- Application Main Entry Point ---
_main:
    ; --------------------------------------------------------------------------
    ; Step 1: Pre-seed registers R1-R10 with unique patterns
    ; --------------------------------------------------------------------------
    LOAD32  R1, 0x11111111
    LOAD32  R2, 0x22222222
    LOAD32  R3, 0x33333333
    LOAD32  R4, 0x44444444
    LOAD32  R5, 0x55555555
    LOAD32  R6, 0x66666666
    LOAD32  R7, 0x77777777
    LOAD32  R8, 0x88888888
    LOAD32  R9, 0x99999999
    LOAD32  R10, 0xAAAAAAAA

    ; --------------------------------------------------------------------------
    ; Step 2: Test Tiered Immediate Loading
    ; --------------------------------------------------------------------------
    LOAD16  R1, 0x1234          ; Overwrite R1: 0x00001234
    LOAD24  R2, 0x123456        ; Overwrite R2: 0x00123456
    LOAD32  R3, 0xAABBCCDD      ; Overwrite R3: 0xAABBCCDD

    ; --------------------------------------------------------------------------
    ; Step 3: Test Memory Post-Increment Store & Load
    ; --------------------------------------------------------------------------
    LOAD32  R4, _scratchpad     ; R4 points to scratchpad
    LD32    (R4++), R3          ; Store 0xAABBCCDD, R4 post-increments by 4
    LOAD32  R4, _scratchpad     ; Reset pointer
    LD32    R5, (R4++)          ; Overwrite R5: should read back 0xAABBCCDD

    ; --------------------------------------------------------------------------
    ; Step 4: Test Atomic Test-and-Set / Swap (TAS)
    ; --------------------------------------------------------------------------
    LOAD32  R6, _mutex          ; Address of mutex
    LD      R7, 1               ; Set R7 to 1
    TAS     (R6), R7            ; Overwrite R7 with previous mutex value (0x00000000)

    ; --------------------------------------------------------------------------
    ; Step 5: Test Subroutine Call & Return Linkage
    ; --------------------------------------------------------------------------
    RCALL   _test_subroutine    ; Doubles R1 (0x1234 * 2 = 0x2468)

    ; --------------------------------------------------------------------------
    ; Step 6: Test Completion Flag (R10 set to 0xCAFE)
    ; --------------------------------------------------------------------------
    LOAD16  R10, 0xCAFE

_success_loop:
    FBRA    _success_loop

; --- Test Subroutine ---
_test_subroutine:
    ADD     R1, R1              ; Double R1
    RRET                        ; Return through R14

; --- Scratchpad Memory Area ---
.align 4
_mutex:
    .word 0x00000000
_scratchpad:
    .word 0x00000000