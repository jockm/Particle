; apps/asm/test_new_ops.asm
.include "lib/common.inc"

.org 0x00000100

_reset:
    ; 1. Test Immediate Multiplier: MULL R1, 6
    LD      R1, 7
    MULL    R1, 6               ; R1 = 7 * 6 = 42 (0x2A)

    ; 2. Test Immediate Bit Manipulation: BSET R2, 5
    LD      R2, 0
    BSET    R2, 5               ; R2 = 1 << 5 = 32 (0x20)

    ; 3. Test Immediate Comparison: SLT R3, 10
    LD      R3, 4
    SLT     R3, 10              ; R3 = 4 < 10 -> 1

    ; 4. Test Table Jump (JTBL)
    LD      R4, 2               ; Table index 2 -> jump target is slot 2
    JTBL    R4
    FBRA    _fail               ; Slot 0
    FBRA    _fail               ; Slot 1
    FBRA    _pass               ; Slot 2 (Target)

_fail:
    LOAD16  R10, 0xDEAD
_spin_fail:
    BBRA    _spin_fail

_pass:
    LOAD16  R10, 0xCAFE         ; Sentinel flag: Success!
_spin_pass:
    BBRA    _spin_pass