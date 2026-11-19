; ==============================================================================
; File: apps/asm/ulx3s_echo.asm
; ULX3S board test: prints a banner on both UARTs, then sends every byte
; received on a UART back on the same UART.
;
;   FIFO channel 0: FTDI USB UART (1 Mbps)
;   FIFO channel 1: GPIO UART on gp[0] (transmit) / gp[1] (receive), 115200
;
; FIFO.STAT bit 0 = nothing received, bit 1 = transmitter busy. It uses only
; instructions the current hardware decodes (see hdl_architecture.md). In
; psim, channels 0 and 1 of a single core loop back to the core itself, so
; there it echoes its own banner over and over.
; ==============================================================================

.include "lib/vectors.inc"

    VECTOR_TABLE _start

_start:
    START_PROGRAM

_main:
    ; --------------------------------------------------------------------------
    ; Banner on channel 0, then on channel 1
    ; --------------------------------------------------------------------------
    LD      R4, 0               ; R4 = channel
._banner_chan:
    LDI     R3, _banner
._banner_next:
    LD8     R5, (R3)        ; (R3++) would do, but the hardware doesn't
    ADD     R3, 1           ; update the pointer for post-increment yet
    FBRA.Z  R5, ._banner_done
._banner_wait:
    FIFO.STAT R6, R4
    AND     R6, 2               ; transmitter busy?
    BBRA.NZ R6, ._banner_wait
    FIFO.W  R5, R4
    BBRA    ._banner_next
._banner_done:
    ADD     R4, 1
    LD      R6, R4
    SUB     R6, 2
    BBRA.NZ R6, ._banner_chan

    ; --------------------------------------------------------------------------
    ; Echo: poll channels 0 and 1 in turn
    ; --------------------------------------------------------------------------
    LD      R4, 0
._poll:
    FIFO.STAT R6, R4
    AND     R6, 1               ; nothing received?
    FBRA.NZ R6, ._next_chan
    FIFO.R  R5, R4
._echo_wait:
    FIFO.STAT R6, R4
    AND     R6, 2               ; transmitter busy?
    BBRA.NZ R6, ._echo_wait
    FIFO.W  R5, R4
._next_chan:
    XOR     R4, 1
    BBRA    ._poll

_banner:
    .asciz "Particle ULX3S\r\n"
