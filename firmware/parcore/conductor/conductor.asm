; ==============================================================================
; File: firmware/parcore/conductor/conductor.asm
; Architecture: Parcore System Lifecycle & Firmware Boot Supervisor
; Target: Particle Conductor Core (Minimal Config: No Mul/Div/FIFO, 2 KB TCM)
; ==============================================================================
; This core is built without the shadow bank (ParcoreConfig)
.define NO_SHADOW_BANK 1
.include "lib/vectors.inc"

; ------------------------------------------------------------------------------
; Hardware MMIO Registers
; ------------------------------------------------------------------------------
; RST_CTRL (0xF000_0000):
;   Bits [5:0] = Per-core active-high reset/hold (1 = Reset/Mux to Conductor)
;   Bit  [31]  = Conductor boot complete status flag
.define RST_CTRL_ADDR       0xF0000000

; SPI Flash Master Controller (0xF000_0010 - 0xF000_0018):
;   +0x00 (0xF000_0010): SPI_CTRL [Bit 0: CS_N, Bit 1: START, Bit 2: BUSY (RO)]
;   +0x04 (0xF000_0014): SPI_DATA [7:0 TX/RX shift register]
;   +0x08 (0xF000_0018): SPI_DIV  [15:0 clock divider]
.define SPI_CTRL_ADDR       0xF0000010
.define SPI_DATA_ADDR       0xF0000014
.define SPI_DIV_ADDR        0xF0000018

; STATUS (0xF000_0020): bits [7:0] the LEDs while the conductor has them;
; bit 8 gives the LEDs to the guest (core 3's I/O, 0x1000_0008).
; BUTTONS (0xF000_0024, read): bit 0 FIRE1, 1 FIRE2, 2 UP, 3 DOWN, 4 LEFT,
; 5 RIGHT (1 = pressed).
.define STATUS_OFFSET       0x20
.define BUTTONS_OFFSET      0x24
.define STATUS_GUEST_LEDS   0x0100

; ------------------------------------------------------------------------------
; Firmware Image (format version 2), in SPI flash at 0x0040_0000
; ------------------------------------------------------------------------------
; Header (16 bytes):
;   +0  Magic 0x50415243 ("PARC")
;   +4  Number of sections, 1..8
;   +8  CRC-32 of the whole image (header, section table and payloads) with
;       these four bytes taken as zero: the standard CRC-32 (zlib's), over
;       the image's bytes in order
;   +12 Format version: 2
; Section n (12 bytes, at 16 + 12*n):
;   +0  Cores: bit i set writes the payload into core i's TCM (bits 0..5)
;   +4  Offset in those TCMs (a multiple of 4)
;   +8  Payload length in bytes (a multiple of 4)
; Then the payloads, in section order.
;
; The conductor reads the image front to back in one pass. On a fault it
; keeps every core held in reset and blinks the fault code on LEDs 0-3, with
; LED 7 flashing:
.define FAULT_MAGIC         1       ; not "PARC"
.define FAULT_VERSION       2       ; not format version 2
.define FAULT_COUNT         3       ; 0 or more than 8 sections
.define FAULT_SECTION       4       ; no cores, cores beyond 5, or an offset
                                    ; or length that isn't a multiple of 4
.define FAULT_CRC           5       ; the CRC-32 doesn't match
; While booting, LED 0 is lit and one more LED lights per section loaded.
; Once the cores are running, the guest has the LEDs, and FIRE1 reloads the
; image and restarts them.

.define IMAGE_BASE_HI       0x0040  ; image at 0x0040_0000
.define IMAGE_MAGIC_HI      0x5041
.define IMAGE_MAGIC_LO      0x5243
.define IMAGE_VERSION       2
.define MAX_SECTIONS        8
.define SECTION_TABLE       0x0600  ; copy of the section table (96 bytes)

; ------------------------------------------------------------------------------
; Register Convention
;   R5  = RST_CTRL MMIO base (0xF000_0000)
;   R6  = SPI_CTRL MMIO base (0xF000_0010)
;   R7  = Sections left
;   R8  = Expected CRC-32
;   R9  = Running CRC-32
;   R10 = LED pattern while booting
;   R11 = Current entry in the section table copy
;   R12 = Offset in the target TCMs of the next payload word
;   R13 = Payload words left in this section
;   R15 = Stack Pointer (0x0000_0800 = top of 2 KB Conductor TCM)
; ------------------------------------------------------------------------------

; CRC-32, four bits at a time: R9 = (R9 >> 4) ^ table[R9 & 15]
; (uses R2, R3)
.macro CRC_NIBBLE
    LD      R2, R9
    AND     R2, 15
    SHIFTL  R2, 2
    LDI     R3, _crc_table
    ADD     R2, R3
    LD32    R2, (R2)
    SHIFTR  R9, 4
    XOR     R9, R2
.endmacro

; CRC-32 of the low byte of R4, then R4 >>= 8 (uses R2, R3)
.macro CRC_BYTE
    LD      R2, R4
    LDI     R3, 0xFF
    AND     R2, R3
    XOR     R9, R2
    CRC_NIBBLE
    CRC_NIBBLE
    SHIFTR  R4, 8
.endmacro

; Show R1 on the LEDs (uses R2)
.macro SET_LEDS
    LD      R2, R5
    ADD     R2, 15
    ADD     R2, 15
    ADD     R2, 2                   ; R2 = STATUS (0xF000_0020)
    ST32    (R2), R1
.endmacro

.macro FAULT code
    LD      R1, %code
    JUMP    _fault_halt
.endmacro

    VECTOR_TABLE _reset_vector
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

    ; Booting: LED 0, and the conductor has the LEDs
    LD      R10, 1
    LD      R1, R10
    SET_LEDS

    ; Configure SPI clock divider = 1 (SCK = clock / 4)
    LD      R1, 1
    LD      R2, R6
    ADD     R2, 8                   ; R2 = SPI_DIV (0xF000_0018)
    ST32    (R2), R1

    ; 2. Read the header
    LD      R9, 0
    SUB     R9, 1                   ; R9 = CRC-32 initial value 0xFFFFFFFF
    LDI     R1, IMAGE_BASE_HI
    SHIFTL  R1, 15
    SHIFTL  R1, 1                   ; R1 = 0x0040_0000
    RCALL   _spi_begin_read

    ; +0: Magic ("PARC" = 0x50415243)
    RCALL   _spi_read_word_le
    LDI     R2, IMAGE_MAGIC_HI
    SHIFTL  R2, 15
    SHIFTL  R2, 1
    LDI     R3, IMAGE_MAGIC_LO
    OR      R2, R3                  ; R2 = 0x50415243
    SEQ     R1, R2
    FBRA.NZ R1, ._magic_ok
    FAULT   FAULT_MAGIC
._magic_ok:

    ; +4: Number of sections (1..8)
    RCALL   _spi_read_word_le
    LD      R7, R1                  ; R7 = sectionCount
    FBRA.NZ R7, ._sec_nonzero
    FAULT   FAULT_COUNT
._sec_nonzero:
    LD      R2, MAX_SECTIONS
    SLT     R2, R7                  ; R2 = (8 < sectionCount) ? 1 : 0
    FBRA.Z  R2, ._sec_in_range
    FAULT   FAULT_COUNT
._sec_in_range:

    ; +8: Expected CRC-32; it counts as four zero bytes in the CRC
    RCALL   _spi_read_word_raw
    LD      R8, R1                  ; R8 = expected CRC-32
    LD      R1, 0
    RCALL   _crc_word

    ; +12: Format version (2)
    RCALL   _spi_read_word_le
    LD      R2, IMAGE_VERSION
    SEQ     R1, R2
    FBRA.NZ R1, ._version_ok
    FAULT   FAULT_VERSION
._version_ok:

    ; 3. Read the section table into SECTION_TABLE, checking each entry
    LDI     R11, SECTION_TABLE
    LD      R12, R7                 ; R12 = entries left to read
_table_loop:
    FBRA.NZ R12, ._table_entry
    JUMP    _table_done
._table_entry:
    ; +0: cores (1..0x3F)
    RCALL   _spi_read_word_le
    ST32    (R11++), R1
    FBRA.NZ R1, ._cores_some
    FAULT   FAULT_SECTION
._cores_some:
    LD      R2, R1
    SHIFTR  R2, 6
    FBRA.Z  R2, ._cores_ok          ; no bits above core 5
    FAULT   FAULT_SECTION
._cores_ok:
    ; +4: TCM offset, +8: length (multiples of 4)
    RCALL   _spi_read_word_le
    ST32    (R11++), R1
    AND     R1, 3
    FBRA.Z  R1, ._offset_ok
    FAULT   FAULT_SECTION
._offset_ok:
    RCALL   _spi_read_word_le
    ST32    (R11++), R1
    AND     R1, 3
    FBRA.Z  R1, ._length_ok
    FAULT   FAULT_SECTION
._length_ok:
    SUB     R12, 1
    JUMP    _table_loop
_table_done:

    ; 4. Payloads, in section order, straight after the table
    LDI     R11, SECTION_TABLE
_section_loop:
    FBRA.NZ R7, ._has_sections
    JUMP    _sections_done
._has_sections:
    LD      R1, R11
    ADD     R1, 4
    LD32    R12, (R1)               ; R12 = TCM offset
    ADD     R1, 4
    LD32    R13, (R1)
    SHIFTR  R13, 2                  ; R13 = payload words

_word_loop:
    FBRA.NZ R13, ._has_words
    JUMP    _section_done
._has_words:
    RCALL   _spi_read_word_le       ; R1 = next payload word
    ; Write it into every core in the section's mask:
    ; 0x1000_0000 + (core << 16) + offset
    LD32    R2, (R11)               ; R2 = cores
    LDI     R3, 0x1000
    SHIFTL  R3, 15
    SHIFTL  R3, 1
    ADD     R3, R12                 ; R3 = core 0's window + offset
._core_loop:
    FBRA.Z  R2, ._cores_done
    LD      R4, R2
    AND     R4, 1
    FBRA.Z  R4, ._next_core
    ST32    (R3), R1
._next_core:
    SHIFTR  R2, 1
    LD      R4, 1
    SHIFTL  R4, 15
    SHIFTL  R4, 1
    ADD     R3, R4                  ; the next core's window
    BBRA    ._core_loop
._cores_done:
    ADD     R12, 4
    SUB     R13, 1
    JUMP    _word_loop

_section_done:
    ; One more LED per section loaded
    SHIFTL  R10, 1
    OR      R10, 1
    LD      R1, R10
    SET_LEDS
    ADD     R11, 12                 ; the next entry in the table copy
    SUB     R7, 1
    JUMP    _section_loop

_sections_done:
    RCALL   _spi_end_read

    ; 5. Check the CRC-32, then release the cores together
    NOT     R9                      ; final XOR with 0xFFFFFFFF
    SEQ     R9, R8
    FBRA.NZ R9, ._crc_ok
    FAULT   FAULT_CRC
._crc_ok:

    ; Release Cores 0..5 simultaneously (bits [5:0] = 0) & set Boot Complete (bit 31)
    LD      R1, 1
    SHIFTL  R1, 15
    SHIFTL  R1, 15
    SHIFTL  R1, 1                   ; R1 = 0x8000_0000
    ST32    (R5), R1                ; Write RST_CTRL

    ; The guest has the LEDs now
    LDI     R1, STATUS_GUEST_LEDS
    SET_LEDS

; ------------------------------------------------------------------------------
; Supervisor: FIRE1 reloads the image and restarts the cores (once released)
; ------------------------------------------------------------------------------
_supervisor_idle:
    LD      R2, R5
    ADD     R2, 15
    ADD     R2, 15
    ADD     R2, 6                   ; R2 = BUTTONS (0xF000_0024)
    LD32    R1, (R2)
    AND     R1, 1                   ; FIRE1
    BBRA.Z  R1, _supervisor_idle
._wait_release:
    LD32    R1, (R2)
    AND     R1, 1
    BBRA.NZ R1, ._wait_release
    JUMP    _reset_vector

; ------------------------------------------------------------------------------
; Fault: R1 = code. Every core stays held in reset; the code is on LEDs 0-3,
; with LED 7 flashing.
; ------------------------------------------------------------------------------
_fault_halt:
    LD      R7, R1                  ; R7 = fault code
    RCALL   _spi_end_read
    LDI     R1, 0x003F              ; Keep all 6 cores held in hardware reset
    ST32    (R5), R1
_fault_blink:
    LD      R1, R7
    LDI     R2, 0x80
    OR      R1, R2                  ; the code, with LED 7 on
    SET_LEDS
    RCALL   _fault_delay
    LD      R1, R7
    SET_LEDS
    RCALL   _fault_delay
    JUMP    _fault_blink

; About 0.2 s at 35 MHz (uses R1)
_fault_delay:
    LDI     R1, 0x0020
    SHIFTL  R1, 15
    SHIFTL  R1, 1                   ; R1 = 0x0020_0000
._delay:
    SUB     R1, 1
    BBRA.NZ R1, ._delay
    RRET

; ==============================================================================
; SPI Flash Low-Level Subroutines (Preserves R5-R13)
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

; _spi_read_word_le: the next 4 bytes as a little-endian word in R1, added
; to the CRC-32 in R9
_spi_read_word_le:
    ST32    (--SP), R14             ; Save return address
    RCALL   _spi_read_word_raw
    RCALL   _crc_word
    LD32    R14, (SP++)
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

; _crc_word: adds the 4 bytes of R1 (low byte first) to the CRC-32 in R9;
; R1 unchanged (uses R2, R3)
_crc_word:
    ST32    (--SP), R4
    LD      R4, R1
    CRC_BYTE
    CRC_BYTE
    CRC_BYTE
    CRC_BYTE
    LD32    R4, (SP++)
    RRET

; CRC-32 (polynomial 0xEDB88320, reflected) for each value of four bits
    .align 4
_crc_table:
    .word 0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC
    .word 0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C
    .word 0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C
    .word 0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C
