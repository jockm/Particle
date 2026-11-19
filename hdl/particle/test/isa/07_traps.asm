; TRAP Imm4 and TRAP Rr enter their vectors with R14 = the next instruction;
; a misaligned store takes vector 14 with R14 = the faulting instruction and
; changes nothing
; check-memory: 0x8000 16
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x1C0                  ; vector 3
    ADD     R1, 1
    LD      R2, R14         ; return address
    JMP     R14, R0
.org 0x200                  ; vector 4
    ADD     R3, 1
    JMP     R14, R0
.org 0x480                  ; vector 14: skip the faulting instruction
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
