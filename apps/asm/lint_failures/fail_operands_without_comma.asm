; Operands must be separated by commas: the assembler reads 'R1 R2' as one
; operand, so LD has only one here.
.org 0x00000100
start:
    LD      R1 R2
