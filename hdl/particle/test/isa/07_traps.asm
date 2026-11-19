; TRAP Imm4 and TRAP Rr enter their vectors with R14 = the next instruction;
; a misaligned store takes vector 14 with R14 = the faulting instruction and
; changes nothing
; check-memory: 0x8000 16
.include "lib/vectors.inc"
    RESET_SLOT _main
    TRAP_SLOT_UNEXPECTED 1
    TRAP_SLOT_UNEXPECTED 2
    TRAP_SLOT_BRANCH 3, _vec3
    TRAP_SLOT_BRANCH 4, _vec4
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
_vec3:
    ADD     R1, 1
    LD      R2, R14         ; return address
    JMP     R14, R0
_vec4:
    ADD     R3, 1
    JMP     R14, R0
_vec14:                     ; skip the faulting instruction
    ADD     R5, 1
    LD      R6, R14
    ADD     R14, 2
    JMP     R14, R0
.org 0x500
_main:
    TRAP    3
    LD      R7, 4
    TRAP    R7
    LDI     R8, 0x8001
    LD      R9, -1
    ST32    (R8), R9        ; misaligned: faults, nothing stored
    ADD     R10, 1
    ST16    (R8), R9        ; misaligned: faults
    ADD     R10, 1
    ST8     (R8), R9        ; bytes are never misaligned
_halt:
    BBRA    _halt
