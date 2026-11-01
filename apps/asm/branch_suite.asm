; ==============================================================================
; File: apps/asm/branch_suite.asm
; Target: Particle 32-bit RISC Core
; Description: Exhaustive regression test for FBRA.NZ, BBRA.NZ, and BRANCH Rr.
; ==============================================================================

.org 0x00000100

_reset_handler:
    FBRA    _main               ; Branch directly to _main
    .align  64

_main:
    ; --------------------------------------------------------------------------
    ; Test 1: FBRA.NZ Fallthrough when register is Zero
    ; --------------------------------------------------------------------------
    LD      R1, 0
    FBRA.NZ R1, _test1_fail
    LD      R2, 1               ; Marker 1 passed (R1 == 0, branch not taken)
    FBRA    _test2_start

_test1_fail:
    LD      R10, 1
    FBRA    _fail_halt

    ; --------------------------------------------------------------------------
    ; Test 2: FBRA.NZ Branch Taken when register is Non-Zero
    ; --------------------------------------------------------------------------
_test2_start:
    LD      R1, 10
    FBRA.NZ R1, _test2_pass
    LD      R10, 2
    FBRA    _fail_halt

_test2_pass:
    LD      R3, 2               ; Marker 2 passed (R1 != 0, branch taken)

    ; --------------------------------------------------------------------------
    ; Test 3: BBRA.NZ Loop Countdown
    ; --------------------------------------------------------------------------
    LD      R4, 5
_loop_bbra:
    SUB     R4, 1
    BBRA.NZ R4, _loop_bbra
    LD      R5, 3               ; Marker 3 passed (Loop exited with R4 == 0)

    ; --------------------------------------------------------------------------
    ; Test 4: BRANCH Rr Forward
    ; --------------------------------------------------------------------------
    LD      R6, (_branch_fwd_dest - _trigger_fwd_branch) / 2
_trigger_fwd_branch:
    BRANCH  R6
    LD      R10, 4
    FBRA    _fail_halt
_branch_fwd_dest:
    LD      R7, 4               ; Marker 4 passed

    ; --------------------------------------------------------------------------
    ; Test 5: BRANCH Rr Backward
    ; --------------------------------------------------------------------------
    LD      R8, (_branch_bwd_dest - _trigger_bwd_branch) / 2
    FBRA    _trigger_bwd_branch
_branch_bwd_dest:
    LD      R9, 5               ; Marker 5 passed
    FBRA    _all_passed

_trigger_bwd_branch:
    BRANCH  R8
    LD      R10, 5
    FBRA    _fail_halt

_all_passed:
    LD      R14, 0xCA           ; Imm8 load to R14
    PUSH8   R14, 0xFE           ; Shift left 8 and OR 0xFE -> R14 = 0xCAFE
    LD      R10, R14            ; Sentinel for overall suite success
_spin_done:
    FBRA    _spin_done          ; Terminal halt loop

_fail_halt:
    FBRA    _fail_halt