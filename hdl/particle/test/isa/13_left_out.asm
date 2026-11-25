; A core without pointer modes, byte and halfword accesses, or the shadow
; bank: those instructions take vector 15 with R14 = the instruction, like any
; undefined opcode, and change nothing; plain word loads and stores still work
; config: no-pointer-modes no-subword no-shadow-bank
; check-memory: 0x8000 96
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
_vec15:                     ; count, log R14 at (R11), skip the instruction
    ADD     R13, 1
    ST32    (R11), R14
    ADD     R11, 4
    ADD     R14, 2
    JMP     R14, R0
.org 0x500
_main:
    LDI     R11, 0x8020     ; the trap log
    LDI     R6, 0x8000
    LDI     R7, 0x8010
    LDI     R5, 0x1234
    ST32    (R6), R5        ; a plain store works
    LD32    R8, (R6)        ; and a plain load
    ; Pointer modes: no access, no pointer change
    LD32    R9, (R6++)
    LD32    R9, (--R6)
    ST32    (R7++), R5
    ST32    (--R7), R5
    ; Byte and halfword accesses
    LD8     R9, (R6)
    LD16    R9, (R6)
    ST8     (R7), R5
    ST16    (R7), R5
    ; The shadow bank
    XCHG    R5
    XCHGALL
    XCHGMOST
    ; R6, R7 and R5 are as they were
    ST32    (R7), R6
_halt:
    BBRA    _halt
