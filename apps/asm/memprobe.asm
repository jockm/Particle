; ==============================================================================
; File: apps/asm/memprobe.asm
; Board bring-up: checks the core's data reads and writes, and prints what it
; finds on the console (FIFO channel 0), one value a line in hex, then echoes.
; It prints only from immediates and registers, and calls its routines
; through link registers (no stack), so its output doesn't depend on the
; memory accesses it is checking.
;
;   A=  the address LDI loaded (_probe_data)
;   W=  LD32 of _probe_data                   expect 44332211
;   H=  LD16 of _probe_data + 2               expect 00004433
;   B=  LD8 of _probe_data + 1                expect 00000022
;   C=  LD32 of the reset vector (0x100)      expect the program's first word
;   S=  ST32 0x12345678 to 0x8000, LD32 back  expect 12345678
;   T=  ST8 0xAB to 0x8001, LD32 0x8000 back  expect 1234AB78
;
; make particle-pano PANO_PROGRAM=apps/asm/memprobe.asm
; ==============================================================================

.include "lib/vectors.inc"

; Send character CH (an immediate) through _putc
.macro PUTCH ch
    LD      R14, %ch
    LD      R5, R14
    RJUMP   _putc, R13
.endmacro

; Print "L=" for letter L, then R1 in hex and a new line
.macro SHOW letter
    PUTCH   %letter
    PUTCH   0x3D
    RJUMP   _puthex, R12
    PUTCH   0x0D
    PUTCH   0x0A
.endmacro

    VECTOR_TABLE _start

_start:
    START_PROGRAM

_main:
    LD      R4, 0               ; R4 = channel 0
    PUTCH   0x0D
    PUTCH   0x0A
    PUTCH   0x70                ; "probe"
    PUTCH   0x72
    PUTCH   0x6F
    PUTCH   0x62
    PUTCH   0x65
    PUTCH   0x0D
    PUTCH   0x0A

    LDI     R8, _probe_data
    LD      R1, R8
    SHOW    0x41                ; A
    LD32    R1, (R8)
    SHOW    0x57                ; W
    LD      R9, R8
    ADD     R9, 2
    LD16    R1, (R9)
    SHOW    0x48                ; H
    LD      R9, R8
    ADD     R9, 1
    LD8     R1, (R9)
    SHOW    0x42                ; B
    LDI     R9, 0x100
    LD32    R1, (R9)
    SHOW    0x43                ; C

    LOAD32  R10, 0x12345678
    LDI     R9, 0x8000
    ST32    (R9), R10
    LD32    R1, (R9)
    SHOW    0x53                ; S
    LD      R14, 0xAB
    LD      R10, R14
    LD      R11, R9
    ADD     R11, 1
    ST8     (R11), R10
    LD32    R1, (R9)
    SHOW    0x54                ; T

    ; Echo
._echo:
    FIFO.STAT R6, R4
    AND     R6, 1               ; nothing received?
    BBRA.NZ R6, ._echo
    FIFO.R  R5, R4
    RJUMP   _putc, R13
    BBRA    ._echo

; ------------------------------------------------------------------------------
; _putc: send R5 on channel R4 (uses R6); returns through R13
; ------------------------------------------------------------------------------
_putc:
    FIFO.STAT R6, R4
    AND     R6, 2               ; transmitter busy?
    BBRA.NZ R6, _putc
    FIFO.W  R5, R4
    JMP     R13, R0

; ------------------------------------------------------------------------------
; _puthex: R1 as 8 hex digits (uses R2, R3, R5, R6, R7, R14); returns
; through R12
; ------------------------------------------------------------------------------
_puthex:
    LD      R3, R1
    LD      R2, 8
._ph_loop:
    ROTL    R3, 4
    LD      R5, R3
    AND     R5, 0x0F
    LDI     R7, 9
    SLT     R7, R5              ; 9 < digit: a letter
    FBRA.NZ R7, ._ph_alpha
    LD      R14, 0x30
    ADD     R5, R14             ; '0'-'9'
    FBRA    ._ph_emit
._ph_alpha:
    LD      R14, 0x37
    ADD     R5, R14             ; 'A'-'F'
._ph_emit:
    RJUMP   _putc, R13
    SUB     R2, 1
    LD      R14, R2
    BBRA.NZ R14, ._ph_loop
    JMP     R12, R0

    .align 4
_probe_data:
    .byte 0x11, 0x22, 0x33, 0x44
