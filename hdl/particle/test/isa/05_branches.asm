; Every branch and jump form, taken and not taken, and the links of JMP and
; RJUMP. Each taken branch skips a poison write (LD R15, 15).
.org 0x100
    LD      R15, 0
    LD      R1, 0
    LD      R2, -3
    LD      R3, 5
    ; Imm4 forms
    FBRA.Z  R1, _a1
    LD      R15, 15
_a1:
    FBRA.N  R2, _a2
    LD      R15, 15
_a2:
    FBRA.P  R3, _a3
    LD      R15, 15
_a3:
    FBRA.NZ R3, _a4
    LD      R15, 15
_a4:
    FBRA.Z  R3, _a5         ; not taken
    ADD     R4, 1
_a5:
    FBRA.N  R1, _a6         ; not taken
    ADD     R4, 1
_a6:
    FBRA.P  R2, _a7         ; not taken
    ADD     R4, 1
_a7:
    FBRA.NZ R1, _a8         ; not taken
    ADD     R4, 1
_a8:
    FBRA    _a9
    LD      R15, 15
_a9:
    ; backward branches: a loop counting R5 up to 3 with BBRA.NZ
    LD      R6, 3
_loop:
    ADD     R5, 1
    SUB     R6, 1
    BBRA.NZ R6, _loop
    LD      R6, -2
_loop2:
    ADD     R7, 1
    ADD     R6, 1
    BBRA.N  R6, _loop2
    LD      R6, 2
_loop3:
    ADD     R8, 1
    SUB     R6, 1
    BBRA.P  R6, _loop3
    LD      R6, 0
    LD      R9, 0
_loop4:
    ADD     R9, 1
    FBRA.NZ R6, _done4
    LD      R6, 1
    BBRA.Z  R1, _loop4      ; R1 = 0: taken once
_done4:
    ; R14 / Imm8 forms (written as .half: for targets this close pasm picks
    ; the Imm4 forms)
    LD      R14, 0
    .half   0xB702          ; FBRA.Z R14, +2 halfwords
    LD      R15, 15
    LD      R14, -1
    .half   0xB802          ; FBRA.N R14, +2
    LD      R15, 15
    LD      R14, 1
    .half   0xB902          ; FBRA.P R14, +2
    LD      R15, 15
    .half   0xBB02          ; FBRA.NZ R14, +2
    LD      R15, 15
    LD      R14, 0
    .half   0xB802          ; FBRA.N R14, +2: not taken
    ADD     R4, 1
    ; register-displacement forms: FBRA.Z Rr, Rl jumps Rl halfwords
    LD      R10, 2
    FBRA.Z  R10, R1         ; not taken: R10 is not zero
    ADD     R4, 1
    FBRA.Z  R1, R10         ; taken (+2)
    LD      R15, 15
    FBRA.N  R2, R10         ; taken
    LD      R15, 15
    FBRA.P  R3, R10         ; taken
    LD      R15, 15
    ; JTBL, BRANCH, JMP and RJUMP with links
    LD      R11, 1
    JTBL    R11             ; PC + 2 + 2
    LD      R15, 15
    LD      R12, 2
    BRANCH  R12             ; PC + 4
    LD      R15, 15
    LDI     R13, _sub
    JMP     R13, R14        ; call: R14 = return address
    ADD     R4, 1
    LD      R12, 3
    RJUMP   R12, R11        ; PC + 6, R11 = link
    LD      R15, 15
    LD      R15, 15
    LDI     R13, _sub2
    JMP     R13, R13        ; target read before the link is written
    FBRA    _halt
_sub:
    ADD     R4, 1
    JMP     R14, R0         ; return
_sub2:
    ADD     R4, 1
_halt:
    BBRA    _halt
