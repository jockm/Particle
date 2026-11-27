; Loads, TAS and MUL followed by instructions that may run while the load's
; data is written (enableLoadOverlap), and by ones that must wait: an
; independent result (W takes port 2), a pointer update (W takes port 1),
; a read or write of the loaded register (R14 written without naming it
; too), TRYR and JMP (both ports)
; check-memory: 0x8000 96
.include "lib/vectors.inc"
    VECTOR_TABLE _start
_start:
    ; a table of words at 0x8000: 0x11, 0x22, ... 0x88
    LDI     R10, 0x8000
    LD      R1, 0
    LD      R2, 8
_fill:
    ADD     R1, 1
    LD      R3, R1
    SHIFTL  R3, 4
    OR      R3, R1
    ST32    (R10++), R3
    SUB     R2, 1
    BBRA.NZ R2, _fill
    LDI     R10, 0x8000
    ; independent result
    LD32    R1, (R10)
    ADD     R2, 3
    LD      R3, R1
    ; pointer loads back to back
    LD32    R4, (R10++)
    LD32    R5, (R10++)
    LD32    R6, (++R10)
    ADD     R4, R5
    ADD     R4, R6
    ; the next instruction reads the loaded register
    LD32    R7, (R10)
    ADD     R7, 1
    ; it writes the loaded register (the later write wins)
    LD32    R8, (R10)
    LD      R8, 5
    ; its pointer is the loaded register
    LDI     R9, 0x8004
    LD32    R9, (R9)
    LD32    R11, (R10--)
    ; a load into R14, then a test of R14
    LD32    R14, (R10)
    FBRA.NZ R14, _nz
    LD      R12, 1
_nz:
    LD      R12, R14
    ; a load, then an LDI (2 words, port 1)
    LD32    R13, (R10)
    LDI     R2, 0x1234
    ADD     R13, R2
    ; a load, then a store with a pointer update
    LDI     R11, 0x8020
    LD32    R1, (R10)
    ST32    (R11++), R2
    ST32    (R11++), R1
    ; a load, then a store of the loaded register
    LD32    R3, (R10)
    ST32    (R11++), R3
    ; a load, then TRYR (writes both ports): an empty channel
    LD      R15, 0
    LD32    R4, (R10)
    FIFO.TRYR R5, R15
    ST32    (R11++), R4
    LD      R6, R14
    ; a load, then JMP and link
    LDI     R7, _after_jmp
    LD32    R1, (R10)
    JMP     R7, R8
_after_jmp:
    ST32    (R11++), R1
    ; a load into R14, then an independent instruction, then ones that
    ; write R14 without naming it
    LD32    R14, (R10)
    ADD     R12, 3
    LD      R13, R14
    LD32    R14, (R10)
    LD      R14, 200
    LD      R1, R14
    LD32    R14, (R10)
    SLT     R14, 100
    LD      R2, R14
    ST32    (R11++), R13
    ST32    (R11++), R1
    ST32    (R11++), R2
    ; TAS, then an independent instruction
    LDI     R9, 0x8050
    LD      R2, 7
    TAS     (R9), R2
    ADD     R3, 2
    ST32    (R11++), R3
    ; MUL, then an independent instruction and a dependent one
    LD      R4, 9
    LD      R5, 7
    MULL    R4, R5
    ADD     R6, 1
    ADD     R4, R6
_halt:
    BBRA    _halt
