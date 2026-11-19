; A macro whose operands are its parameters: the linter leaves its body to
; the assembler, which checks each expansion
.include "lib/vectors.inc"
.macro SET_FLAG reg
    LD      R14, 0x84
    LD32    R14, (R14)
    OR      %reg, R14
.endmacro

    VECTOR_TABLE _main
_main:
    LD      R4, 0
    SET_FLAG R4
    TRAP    0
