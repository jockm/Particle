; The immediate BEXTR and SBEXTR (fields of several positions and lengths,
; signs, a length of 0, a field running past bit 31, the source unchanged,
; the source written just before) and JTBL with entries of 2, 4, 8 and 16
; bytes. Results go to memory.
; check-memory: 0x8000 96
.include "lib/vectors.inc"
    VECTOR_TABLE _start
_start:
    LD      R15, 0
    LDI     R13, 0x8000
    LOAD32  R1, 0xF2345678      ; a RISC-V-like word
    BEXTR   R2, R1, 7, 5        ; rd field: bits 11:7
    ST32    (R13++), R2
    BEXTR   R2, R1, 0, 7        ; opcode
    ST32    (R13++), R2
    SBEXTR  R2, R1, 20, 12      ; I-type immediate: 0xF23 -> negative
    ST32    (R13++), R2
    BEXTR   R2, R1, 20, 12      ; the same, unsigned
    ST32    (R13++), R2
    SBEXTR  R2, R1, 4, 8        ; 0x67: positive, no sign
    ST32    (R13++), R2
    BEXTR   R2, R1, 9, 0        ; length 0: 0
    ST32    (R13++), R2
    SBEXTR  R2, R1, 9, 0        ; length 0, signed: 0
    ST32    (R13++), R2
    BEXTR   R2, R1, 28, 8       ; past bit 31: only bits 31:28
    ST32    (R13++), R2
    SBEXTR  R2, R1, 31, 1       ; one bit, set: -1
    ST32    (R13++), R2
    ST32    (R13++), R1         ; the source is unchanged
    LD      R3, 9
    LD      R3, 12              ; written just before
    BEXTR   R4, R3, 2, 2        ; 3
    ST32    (R13++), R4
    SBEXTR  R3, R3, 2, 2        ; Rr = Rl: -1
    ST32    (R13++), R3

    ; JTBL with each entry size: each table's entry 2 adds its marker to R5
    LD      R5, 0
    LD      R6, 2
    JTBL    R6                  ; 2-byte entries: short branches
    FBRA    _t2_bad
    FBRA    _t2_bad
    FBRA    _t2_ok
    FBRA    _t2_bad
_t2_bad:
    LD      R15, 15
_t2_ok:
    ADD     R5, 1
    JTBL    R6, 4               ; 4-byte entries: 2-word branches
    BRA     _t4_bad
    BRA     _t4_bad
    BRA     _t4_ok
    BRA     _t4_bad
_t4_bad:
    LD      R15, 15
_t4_ok:
    ADD     R5, 2
    JTBL    R6, 8               ; 8-byte entries: 4 instructions inline
    ADD     R5, 15
    FBRA    _t8_end
    NOP
    NOP
    ADD     R5, 15
    FBRA    _t8_end
    NOP
    NOP
    ADD     R5, 4               ; entry 2
    FBRA    _t8_end
    NOP
    NOP
    ADD     R5, 15
    FBRA    _t8_end
    NOP
    NOP
_t8_end:
    JTBL    R6, 16              ; 16-byte entries: 8 instructions inline
    ADD     R5, 15
    FBRA    _t16_end
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    ADD     R5, 15
    FBRA    _t16_end
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    ADD     R5, 8               ; entry 2
    FBRA    _t16_end
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    ADD     R5, 15
    FBRA    _t16_end
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
_t16_end:
    ST32    (R13++), R5         ; 15
_halt:
    BBRA    _halt
