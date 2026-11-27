; ==============================================================================
; File: apps/asm/panog2_echo.asm
; Pano Logic G2 board test: prints a banner on the console, then sends every
; byte received back.
;
;   FIFO channel 0: the console UART, on the DVI connector's DDC pins
;                   (1 Mbps; make pano-term)
;
; FIFO.STAT bit 0 = nothing received, bit 1 = transmitter busy. The Pano
; button resets the core, which prints the banner again.
; ==============================================================================

.include "lib/vectors.inc"

    VECTOR_TABLE _start

_start:
    START_PROGRAM

_main:
    LD      R4, 0               ; R4 = channel 0
    LDI     R3, _banner
._banner_next:
    LD8     R5, (R3++)
    FBRA.Z  R5, ._echo
._banner_wait:
    FIFO.STAT R6, R4
    AND     R6, 2               ; transmitter busy?
    BBRA.NZ R6, ._banner_wait
    FIFO.W  R5, R4
    BBRA    ._banner_next

    ; --------------------------------------------------------------------------
    ; Echo
    ; --------------------------------------------------------------------------
._echo:
    FIFO.STAT R6, R4
    AND     R6, 1               ; nothing received?
    BBRA.NZ R6, ._echo
    FIFO.R  R5, R4
._echo_wait:
    FIFO.STAT R6, R4
    AND     R6, 2               ; transmitter busy?
    BBRA.NZ R6, ._echo_wait
    FIFO.W  R5, R4
    BBRA    ._echo

_banner:
    .asciz "Particle Pano G2\r\n"
