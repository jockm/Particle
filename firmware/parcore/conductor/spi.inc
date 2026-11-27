; ==============================================================================
; File: firmware/parcore/conductor/spi.inc
; The conductor's SPI flash routines, for the boot (conductor.asm) and pmon
; (pmon.inc): R6 = SPI_CTRL (0xF000_0010). They keep R5-R13.
; ==============================================================================

; _spi_begin_read: Asserts CS_N low and shifts out 0x03 READ + 24-bit addr in R1
_spi_begin_read:
    ST32    (--SP), R14             ; Save return address
    ST32    (--SP), R4              ; Save flash address in R4
    LD      R4, R1

    ; Pulse CS_N high then assert CS_N low
    LD      R1, 1
    ST32    (R6), R1                ; SPI_CTRL = 1 (CS_N high)
    ST32    (R6), R0                ; SPI_CTRL = 0 (CS_N low)

    ; Send 0x03 (Standard SPI Read Command)
    LD      R1, 0x03
    RCALL   _spi_xfer_byte

    ; Send Addr[23:16]
    LD      R1, R4
    SHIFTR  R1, 15
    SHIFTR  R1, 1
    LD      R14, 0xFF
    AND     R1, R14
    RCALL   _spi_xfer_byte

    ; Send Addr[15:8]
    LD      R1, R4
    SHIFTR  R1, 8
    LD      R14, 0xFF
    AND     R1, R14
    RCALL   _spi_xfer_byte

    ; Send Addr[7:0]
    LD      R1, R4
    LD      R14, 0xFF
    AND     R1, R14
    RCALL   _spi_xfer_byte

    LD32    R4, (SP++)
    LD32    R14, (SP++)
    RRET

; _spi_end_read: Waits for SPI idle and deasserts CS_N high
_spi_end_read:
._end_wait:
    LD32    R1, (R6)                ; Read SPI_CTRL
    AND     R1, 0x04                ; Bit 2 = BUSY
    BBRA.NZ R1, ._end_wait          ; 2-instruction backward loop (offset = 2)
    LD      R1, 1
    ST32    (R6), R1                ; SPI_CTRL = 1 (CS_N high)
    RRET

; _spi_xfer_byte: Transfers 8-bit TX in R1[7:0], returns 8-bit RX in R1[7:0]
_spi_xfer_byte:
._tx_wait:
    LD32    R2, (R6)                ; Read SPI_CTRL
    AND     R2, 0x04                ; Check BUSY
    BBRA.NZ R2, ._tx_wait           ; 2-instruction backward loop (offset = 2)

    LD      R2, R6
    ADD     R2, 4                   ; R2 = SPI_DATA (0xF000_0014)
    ST32    (R2), R1                ; Write TX byte & auto-start transfer

._rx_wait:
    LD32    R3, (R6)                ; Poll SPI_CTRL
    AND     R3, 0x04                ; Check BUSY
    BBRA.NZ R3, ._rx_wait           ; 2-instruction backward loop (offset = 2)

    LD32    R1, (R2)                ; Read RX byte from SPI_DATA
    LDI     R3, 0xFF                ; (not R14: it holds the return address)
    AND     R1, R3
    RRET

; _spi_read_word_raw: the next 4 bytes as a little-endian word in R1
_spi_read_word_raw:
    ST32    (--SP), R14             ; Save return address
    ST32    (--SP), R4              ; Save R4 accumulator

    ; Byte 0 (LSB)
    LD      R1, 0
    RCALL   _spi_xfer_byte
    LD      R4, R1                  ; R4 = b0

    ; Byte 1
    LD      R1, 0
    RCALL   _spi_xfer_byte
    SHIFTL  R1, 8
    OR      R4, R1                  ; R4 |= (b1 << 8)

    ; Byte 2
    LD      R1, 0
    RCALL   _spi_xfer_byte
    SHIFTL  R1, 15
    SHIFTL  R1, 1
    OR      R4, R1                  ; R4 |= (b2 << 16)

    ; Byte 3 (MSB)
    LD      R1, 0
    RCALL   _spi_xfer_byte
    SHIFTL  R1, 15
    SHIFTL  R1, 9
    OR      R1, R4                  ; R1 = b0 | (b1<<8) | (b2<<16) | (b3<<24)

    LD32    R4, (SP++)
    LD32    R14, (SP++)
    RRET
