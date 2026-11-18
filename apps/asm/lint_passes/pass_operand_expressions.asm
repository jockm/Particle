; Operands that are expressions with spaces are one operand each, as the
; assembler reads them (pasm_lint must pass this file).
.org 0x00000100
start:
    LDI     R5, table + 4
    FBRA    skip + 2
    ADD     R1, R2
skip:
    ADD     R1, R2
    ADD     R1, R2
    TRAP    0
table:
    .byte   300 - 100, 0x10 + 1
    .align  4
    .word   table + 4
