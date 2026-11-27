; ==============================================================================
; File: firmware/parcore/conductor/conductor_regs.inc
; The conductor's registers (Documentation/parcore_architecture.md, Conductor),
; and SET_LEDS. Included by conductor.asm, and by tests of its parts.
; ==============================================================================

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
; bit 8 gives the LEDs to the guest (core 3's I/O, 0x1000_0008); bit 9 (read
; only) the SPI lines go to a flash that can be written (PARCORE_REAL_FLASH).
; BUTTONS (0xF000_0024, read): bit 0 FIRE1, 1 FIRE2, 2 UP, 3 DOWN, 4 LEFT,
; 5 RIGHT (1 = pressed).
.define STATUS_OFFSET       0x20
.define BUTTONS_OFFSET      0x24
.define CORE_STATE_OFFSET   0x28    ; CORE_STATE (read): 2 bits per core, 0 running,
                                    ; 1 in a WAIT, 2 halted, 3 held in reset
.define CYCLES_OFFSET       0x2C    ; CYCLES (read): cycles since reset
.define CORE_PC_OFFSET      0x30    ; CORE_PC (read): core n's PC at 0x30 + 4n
.define ACTIVITY_OFFSET     0x40    ; ACTIVITY (read; clears): bit n core n ran,
                                    ; bit 8 the ring moved, since the last read
.define CONSOLE_DATA_OFFSET 0x50    ; CONSOLE_DATA: write sends a byte, read
                                    ; takes the byte received
.define CONSOLE_STATUS_OFFSET 0x54  ; CONSOLE_STATUS (read): bit 0 a byte
                                    ; received, bit 1 the transmitter busy

; Show R1 on the LEDs (uses R2; R5 = RST_CTRL)
.macro SET_LEDS
    LD      R2, R5
    ADD     R2, 15
    ADD     R2, 15
    ADD     R2, 2                   ; R2 = STATUS (0xF000_0020)
    ST32    (R2), R1
.endmacro
