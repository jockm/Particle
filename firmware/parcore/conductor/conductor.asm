; ==============================================================================
; File: firmware/parcore/conductor/conductor.asm
; Architecture: Parcore System Lifecycle & Firmware Boot Supervisor
; Target: Particle Conductor Core (Minimal Config: No Mul/Div/FIFO, 2 KB TCM)
; ==============================================================================
.include "lib/common.inc"

; ------------------------------------------------------------------------------
; Hardware MMIO Registers
; ------------------------------------------------------------------------------
; RST_CTRL (0xF000_0000):
;   Bits [5:0] = Per-core active-high reset/hold (1 = Reset/Mux to Conductor)
;   Bit  [6]   = Global Pipeline Interconnect FIFO flush strobe
;   Bit  [31]  = Conductor boot complete status flag
.define RST_CTRL_ADDR       0xF0000000

; SPI Flash Master Controller (0xF000_0010 - 0xF000_0018):
;   +0x00 (0xF000_0010): SPI_CTRL [Bit 0: CS_N, Bit 1: START, Bit 2: BUSY (RO)]
;   +0x04 (0xF000_0014): SPI_DATA [7:0 TX/RX shift register]
;   +0x08 (0xF000_0018): SPI_DIV  [15:0 clock divider]
.define SPI_CTRL_ADDR       0xF0000010
.define SPI_DATA_ADDR       0xF0000014
.define SPI_DIV_ADDR        0xF0000018

; Multi-Core Firmware Image Layout (SPI Flash @ 0x0010_0000)
.define IMAGE_MAGIC_HI      0x5041
.define IMAGE_MAGIC_LO      0x5243

; ------------------------------------------------------------------------------
; Register Convention (Supervisor Resident State)
;   R5  = RST_CTRL MMIO base (0xF000_0000)
;   R6  = SPI_CTRL MMIO base (0xF000_0010)
;   R7  = Section Count remaining
;   R8  = Expected Checksum
;   R9  = Running Checksum accumulator
;   R10 = Current Flash Payload Offset
;   R11 = Current Directory Entry Flash Offset
;   R15 = Stack Pointer (0x0000_0800 = top of 2 KB Conductor TCM)
; ------------------------------------------------------------------------------

.org 0x00000100
_reset_vector:
    ; Initialize stack pointer to top of 2 KB Conductor local TCM
    LDI     SP, 0x0800

    ; Load persistent MMIO base pointers into callee-saved registers
    LDI     R5, 0xF000
    SHIFTL  R5, 15
    SHIFTL  R5, 1                   ; R5 = 0xF000_0000 (RST_CTRL)
    LD      R6, R5
    ADD     R6, 15
    ADD     R6, 1                   ; R6 = 0xF000_0010 (SPI_CTRL)

    ; 1. Hold all 6 application cores in reset and assert FIFO flush strobe
    LDI     R1, 0x007F              ; Bits [5:0] = 0x3F (reset), Bit 6 = 1 (flush)
    ST32    (R5), R1
    LDI     R1, 0x003F              ; Deassert flush strobe; keep cores in reset
    ST32    (R5), R1

    ; Configure SPI clock divider = 1 (12.5 MHz SCK @ 25 MHz sysclk)
    LD      R1, 1
    LD      R2, R6
    ADD     R2, 8                   ; R2 = SPI_DIV (0xF000_0018)
    ST32    (R2), R1

    ; 2. Read Multi-Core Image Header from SPI Flash @ 0x0010_0000
    LDI     R1, 0x0010
    SHIFTL  R1, 15
    SHIFTL  R1, 1                   ; R1 = 0x0010_0000
    LDI     R14, _spi_begin_read
    RCALL   R14

    ; Word 0: Magic ("PARC" = 0x50415243)
    LDI     R14, _spi_read_word_le
    RCALL   R14
    LDI     R2, IMAGE_MAGIC_HI
    SHIFTL  R2, 15
    SHIFTL  R2, 1
    LDI     R3, IMAGE_MAGIC_LO
    OR      R2, R3                  ; R2 = 0x50415243
    SEQ     R1, R2
    FBRA.NZ R1, ._magic_ok          ; Skip 1 JUMP (<= 5 halfwords)
    JUMP    _fault_halt
._magic_ok:

    ; Word 1: Section Count (must be 1..6)
    LDI     R14, _spi_read_word_le
    RCALL   R14
    LD      R7, R1                  ; R7 = sectionCount
    FBRA.NZ R7, ._sec_nonzero       ; Skip 1 JUMP
    JUMP    _fault_halt
._sec_nonzero:
    LD      R2, 6
    SLT     R2, R7                  ; R2 = (6 < sectionCount) ? 1 : 0
    FBRA.Z  R2, ._sec_in_range      ; Skip 1 JUMP
    JUMP    _fault_halt
._sec_in_range:

    ; Word 2: Expected Checksum
    LDI     R14, _spi_read_word_le
    RCALL   R14
    LD      R8, R1                  ; R8 = expectedSum

    ; Word 3: Reserved (discard)
    LDI     R14, _spi_read_word_le
    RCALL   R14

    LDI     R14, _spi_end_read
    RCALL   R14

    ; 3. Initialize Section Directory & Payload Flash Pointers
    LD      R9, 0                   ; R9 = runningSum = 0

    ; Directory starts at FLASH_IMAGE_BASE + 16 (0x0010_0010)
    LDI     R11, 0x0010
    SHIFTL  R11, 15
    SHIFTL  R11, 1
    ADD     R11, 15
    ADD     R11, 1                  ; R11 = 0x0010_0010

    ; Payload offset = dirAddr + (sectionCount * 12) = dirAddr + (n << 3) + (n << 2)
    LD      R1, R7
    SHIFTL  R1, 3
    LD      R2, R7
    SHIFTL  R2, 2
    ADD     R1, R2
    LD      R10, R11
    ADD     R10, R1                 ; R10 = payloadFlashOffset

; ------------------------------------------------------------------------------
; Section Staging Loop (iterates R7 times)
; ------------------------------------------------------------------------------
_section_loop:
    FBRA.NZ R7, ._has_sections      ; Skip 1 JUMP
    JUMP    _verify_checksum
._has_sections:

    ; Read 12-byte section entry at R11
    LD      R1, R11
    LDI     R14, _spi_begin_read
    RCALL   R14

    LDI     R14, _spi_read_word_le
    RCALL   R14
    LD      R12, R1                 ; R12 = targetCore (0..5)

    LDI     R14, _spi_read_word_le
    RCALL   R14
    LD      R13, R1                 ; R13 = tcmOffset

    LDI     R14, _spi_read_word_le
    RCALL   R14
    ST32    (--SP), R1              ; Push byteLength onto stack

    LDI     R14, _spi_end_read
    RCALL   R14

    LD32    R3, (SP++)              ; Pop R3 = byteLength

    ; Validate targetCore <= 5 and (byteLength & 3) == 0
    LD      R1, 5
    SLT     R1, R12                 ; R1 = (5 < targetCore)
    FBRA.Z  R1, ._core_id_ok        ; Skip 1 JUMP
    JUMP    _fault_halt
._core_id_ok:
    LD      R1, R3
    AND     R1, 3
    FBRA.Z  R1, ._len_aligned       ; Skip 1 JUMP
    JUMP    _fault_halt
._len_aligned:

    ; Compute destination TCM window address:
    ; dstAddr = 0x1000_0000 + (targetCore << 16) + tcmOffset
    LDI     R1, 0x1000
    SHIFTL  R1, 15
    SHIFTL  R1, 1                   ; 0x1000_0000
    SHIFTL  R12, 15
    SHIFTL  R12, 1                  ; targetCore << 16
    ADD     R12, R1
    ADD     R12, R13                ; R12 = dstAddr (Port B window)

    ; Compute wordCount = byteLength >> 2 and advance payloadFlashOffset
    LD      R13, R3
    SHIFTR  R13, 2                  ; R13 = wordCount

    ; Begin streaming payload words from R10
    LD      R1, R10
    ADD     R10, R3                 ; Advance R10 by byteLength for next section
    ST32    (--SP), R12             ; Save dstAddr across call
    ST32    (--SP), R13             ; Save wordCount across call
    LDI     R14, _spi_begin_read
    RCALL   R14
    LD32    R13, (SP++)             ; Restore wordCount
    LD32    R12, (SP++)             ; Restore dstAddr

_word_stream_loop:
    FBRA.NZ R13, ._has_words        ; Skip 1 JUMP
    JUMP    _section_done
._has_words:
    ST32    (--SP), R12             ; Save dstAddr
    ST32    (--SP), R13             ; Save wordCount
    LDI     R14, _spi_read_word_le
    RCALL   R14                     ; R1 = next 32-bit little-endian word
    LD32    R13, (SP++)             ; Restore wordCount
    LD32    R12, (SP++)             ; Restore dstAddr

    ST32    (R12++), R1             ; Write word to target Core TCM & advance +4
    ADD     R9, R1                  ; runningSum += word
    SUB     R13, 1                  ; wordCount--
    JUMP    _word_stream_loop

_section_done:
    LDI     R14, _spi_end_read
    RCALL   R14

    ADD     R11, 12                 ; Advance directory pointer by 12 bytes
    SUB     R7, 1                   ; sectionCount--
    JUMP    _section_loop

; ------------------------------------------------------------------------------
; Checksum Validation & Synchronized Core Release
; ------------------------------------------------------------------------------
_verify_checksum:
    SEQ     R9, R8                  ; R9 = (runningSum == expectedSum) ? 1 : 0
    FBRA.NZ R9, ._checksum_ok       ; Skip 1 JUMP
    JUMP    _fault_halt
._checksum_ok:

    ; Release Cores 0..5 simultaneously (bits [5:0] = 0) & set Boot Complete (bit 31)
    LD      R1, 1
    SHIFTL  R1, 15
    SHIFTL  R1, 15
    SHIFTL  R1, 1                   ; R1 = 0x8000_0000
    ST32    (R5), R1                ; Write RST_CTRL

_supervisor_idle:
    NOP
    BBRA    _supervisor_idle        ; 1-instruction backward loop (offset = 1)

_fault_halt:
    LDI     R1, 0x003F              ; Keep all 6 cores held in hardware reset
    ST32    (R5), R1
_fault_spin:
    NOP
    BBRA    _fault_spin             ; 1-instruction backward loop (offset = 1)

; ==============================================================================
; SPI Flash Low-Level Subroutines (Preserves R5-R11)
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
    LDI     R14, _spi_xfer_byte
    RCALL   R14

    ; Send Addr[23:16]
    LD      R1, R4
    SHIFTR  R1, 15
    SHIFTR  R1, 1
    LD      R14, 0xFF
    AND     R1, R14
    LDI     R14, _spi_xfer_byte
    RCALL   R14

    ; Send Addr[15:8]
    LD      R1, R4
    SHIFTR  R1, 8
    LD      R14, 0xFF
    AND     R1, R14
    LDI     R14, _spi_xfer_byte
    RCALL   R14

    ; Send Addr[7:0]
    LD      R1, R4
    LD      R14, 0xFF
    AND     R1, R14
    LDI     R14, _spi_xfer_byte
    RCALL   R14

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
    LD      R14, 0xFF
    AND     R1, R14
    RRET

; _spi_read_word_le: Reads 4 bytes from SPI and packs into 32-bit little-endian R1
_spi_read_word_le:
    ST32    (--SP), R14             ; Save return address
    ST32    (--SP), R4              ; Save R4 accumulator

    ; Byte 0 (LSB)
    LD      R1, 0
    LDI     R14, _spi_xfer_byte
    RCALL   R14
    LD      R4, R1                  ; R4 = b0

    ; Byte 1
    LD      R1, 0
    LDI     R14, _spi_xfer_byte
    RCALL   R14
    SHIFTL  R1, 8
    OR      R4, R1                  ; R4 |= (b1 << 8)

    ; Byte 2
    LD      R1, 0
    LDI     R14, _spi_xfer_byte
    RCALL   R14
    SHIFTL  R1, 15
    SHIFTL  R1, 1
    OR      R4, R1                  ; R4 |= (b2 << 16)

    ; Byte 3 (MSB)
    LD      R1, 0
    LDI     R14, _spi_xfer_byte
    RCALL   R14
    SHIFTL  R1, 15
    SHIFTL  R1, 9
    OR      R1, R4                  ; R1 = b0 | (b1<<8) | (b2<<16) | (b3<<24)

    LD32    R4, (SP++)
    LD32    R14, (SP++)
    RRET
