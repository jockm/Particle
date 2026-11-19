; FIFO channels loop back to the core: W, R, TRYW, TRYR (status in R14) and
; STAT, including TRYR on an empty channel
.org 0x100
    LD      R1, 1           ; channel 1
    LD      R2, 2           ; channel 2
    LDI     R3, 0x1111
    LDI     R4, 0x2222
    FIFO.W  R3, R1
    FIFO.W  R4, R1
    FIFO.STAT R5, R1        ; two entries
    FIFO.R  R6, R1
    FIFO.TRYR R7, R1        ; data: R7 = 0x2222, R14 = 1
    LD      R8, R14
    LD      R7, 5
    FIFO.TRYR R7, R1        ; empty: R7 unchanged, R14 = 0
    LD      R9, R14
    FIFO.TRYW R3, R2        ; R14 = 1
    LD      R10, R14
    FIFO.STAT R11, R2
    FIFO.TRYR R14, R2       ; data into R14, then the status: R14 = 1
    LD      R12, R14
    FIFO.STAT R13, R2
_halt:
    BBRA    _halt
