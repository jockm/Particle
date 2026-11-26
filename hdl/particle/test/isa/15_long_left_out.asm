; A core without the 2-word branches or the immediate BEXTR: BRA,
; BRA.Z/NZ/N/P, RJUMP disp16, BEQ, BNE, LEA and BEXTR/SBEXTR Rr, Rl, pos, len
; take vector 15 with R14 = the instruction, like any undefined opcode, and
; change nothing. The handler skips the first word; the second is 0 (NOP).
; They are written as halfwords (pasm rejects the branches here).
; config: no-long-branches no-imm-bextr
.include "lib/vectors.inc"
    RESET_SLOT _main
    TRAP_SLOT_UNEXPECTED 1
    TRAP_SLOT_UNEXPECTED 2
    TRAP_SLOT_UNEXPECTED 3
    TRAP_SLOT_UNEXPECTED 4
    TRAP_SLOT_UNEXPECTED 5
    TRAP_SLOT_UNEXPECTED 6
    TRAP_SLOT_UNEXPECTED 7
    TRAP_SLOT_UNEXPECTED 8
    TRAP_SLOT_UNEXPECTED 9
    TRAP_SLOT_UNEXPECTED 10
    TRAP_SLOT_UNEXPECTED 11
    TRAP_SLOT_UNEXPECTED 12
    TRAP_SLOT_UNEXPECTED 13
    TRAP_SLOT_UNEXPECTED 14
    TRAP_SLOT_BRANCH 15, _vec15
    UNEXPECTED_TRAP_ROUTINE
_vec15:                     ; count, record R14, skip the first word
    ADD     R13, 1
    LD      R12, R14
    ADD     R14, 2
    JMP     R14, R0
.org 0x500
_main:
    LD      R1, 0
    LD      R2, 9
    .half   0xCC00, 0x0000  ; BRA
    .half   0xBC10, 0x0000  ; BRA.Z R1
    .half   0xBD20, 0x0000  ; BRA.NZ R2
    .half   0xBE20, 0x0000  ; BRA.N R2
    .half   0xBF20, 0x0000  ; BRA.P R2
    .half   0xCD05, 0x0000  ; RJUMP disp16, R5: R5 unchanged
    .half   0xCE12, 0x0000  ; BEQ R1, R2
    .half   0xCF12, 0x0000  ; BNE R1, R2
    .half   0x0906, 0x0000  ; LEA R6: R6 unchanged
    .half   0x8D72, 0x0000  ; BEXTR R7, R2, 0, 0: R7 unchanged
    RCALL   _sub            ; LDI + JMP with --no-long-branches
    JUMP    _far            ; LDI + JMP: over 255 halfwords
_sub:
    ADD     R3, 1
    JMP     R14, R0
.org 0x900
_far:
    ADD     R3, 1
_halt:
    BBRA    _halt
