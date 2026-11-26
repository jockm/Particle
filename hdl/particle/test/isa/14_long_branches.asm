; The 2-word PC-relative instructions: BRA, BRA.Z/NZ/N/P, BEQ, BNE (taken and
; not taken, forward and back over 4 KiB), RJUMP label, Rl and RCALL (links of
; PC + 4), and LEA. Each taken branch skips a poison write (LD R15, 15); each
; not-taken one counts in R4. Operands come from the instruction just before,
; so forwarding into the branch is checked too.
; check-memory: 0x8000 32
.include "lib/vectors.inc"
    VECTOR_TABLE _start
_start:
    LD      R15, 0
    LD      R4, 0
    LD      R1, 0
    LD      R2, -3
    LD      R3, 5
    BRA     _far1           ; over 4 KiB forward
    LD      R15, 15
_back1:
    ; Conditional forms, taken
    BRA.Z   R1, _b1
    LD      R15, 15
_b1:
    BRA.NZ  R3, _b2
    LD      R15, 15
_b2:
    BRA.N   R2, _b3
    LD      R15, 15
_b3:
    BRA.P   R3, _b4
    LD      R15, 15
_b4:
    ; Not taken: execution goes on after the second word
    BRA.Z   R3, _c1
    ADD     R4, 1
_c1:
    BRA.NZ  R1, _c2
    ADD     R4, 1
_c2:
    BRA.N   R3, _c3
    ADD     R4, 1
_c3:
    BRA.P   R2, _c4
    ADD     R4, 1
_c4:
    ; BEQ/BNE, with an operand written just before
    LD      R5, 5
    BEQ     R5, R3, _d1
    LD      R15, 15
_d1:
    LD      R6, 7
    BNE     R6, R3, _d2
    LD      R15, 15
_d2:
    BEQ     R6, R3, _d3     ; not taken
    ADD     R4, 1
_d3:
    BNE     R5, R3, _d4     ; not taken
    ADD     R4, 1
_d4:
    ; A loop: BNE back, 5 times
    LD      R7, 0
_loop:
    ADD     R7, 1
    BNE     R7, R3, _loop
    ; Two 2-word instructions in a row, then an LDI
    BRA     _e1
_e1:
    BRA.Z   R1, _e2
_e2:
    LDI     R8, 0x1234
    ; RJUMP label, Rl and RCALL: the link is PC + 4
    RJUMP   _sub, R9
_ret1:
    RCALL   _sub2
_ret2:
    ; LEA: the addresses of data, before and after
    LEA     R10, _data
    LEA     R11, _start
    LD32    R12, (R10)      ; the word at _data
    ; Results to memory
    LDI     R13, 0x8000
    ST32    (R13++), R4
    ST32    (R13++), R7
    ST32    (R13++), R8
    ST32    (R13++), R9
    ST32    (R13++), R14
    ST32    (R13++), R10
    ST32    (R13++), R11
    ST32    (R13++), R12
    BRA     _halt
    LD      R15, 15
_sub:
    ADD     R4, 1
    LDI     R13, _ret1
    SUB     R13, R9         ; 0 if the link is right
    BRA.NZ  R13, _bad
    JMP     R9, R0
_sub2:
    ADD     R4, 1
    JMP     R14, R0
_bad:
    LD      R15, 14
_halt:
    BBRA    _halt
.align 4
_data:
    .word   0xCAFEF00D

.org 0x1600
_far1:
    ADD     R4, 1
    BRA     _back1          ; over 4 KiB back
