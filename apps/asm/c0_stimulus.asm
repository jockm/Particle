
.include "lib/common.inc"

.org 0x00000100

_c0_entry:
    ; --- BEQ Taken Stimulus ---
    ; Token 1: Opcode 1 (BEQ), R5 = 0x55, R6 = 0x55 -> 0x01005555
    LOAD32  R2, 0x01005555
    FIFO.W  R2, 0

    ; Token 2: Target Offset = 0x00000080
    LOAD32  R2, 0x00000080
    FIFO.W  R2, 0

    ; Token 3: Current PC = 0x00002000
    LOAD32  R2, 0x00002000
    FIFO.W  R2, 0

_c0_done:
    FBRA    _c0_done
