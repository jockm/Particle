; A misaligned load, store or TAS takes vector 14 with R14 = the faulting
; instruction and changes nothing: no pointer update, no register written,
; no memory written. Every pointer mode, and the pointer as data register.
; check-memory: 0x8000 16
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
    TRAP_SLOT_BRANCH 14, _vec14
    TRAP_SLOT_UNEXPECTED 15
    UNEXPECTED_TRAP_ROUTINE
_vec14:                     ; count, record R14, skip the instruction
    ADD     R13, 1
    LD      R12, R14
    ADD     R14, 2
    JMP     R14, R0
.org 0x500
_main:
    LDI     R1, 0x8001      ; odd: misaligned for 16- and 32-bit accesses
    LDI     R5, 0x8002      ; 2-aligned only: misaligned for 32-bit accesses
    LD      R2, 7
    LD32    R2, (R1)
    LD32    R2, (R1++)
    LD32    R2, (++R1)
    LD32    R2, (R1--)
    LD32    R2, (--R1)
    LD32    R1, (R1++)      ; pointer as destination
    LD16    R2, (R1)
    LD16    R2, (R1++)
    LD16    R2, (--R1)
    LD32    R2, (R5++)
    ST32    (R1), R2
    ST32    (R1++), R2
    ST32    (--R1), R1      ; pointer as data
    ST16    (R1++), R2
    ST16    (--R1), R2
    ST32    (R5++), R2
    TAS     (R1), R2
    TAS     (R5), R2
    LD16    R6, (R5)        ; aligned: loads
    LD16    R7, (R5++)      ; aligned: loads, R5 += 2
_halt:
    BBRA    _halt
