; ==============================================================================
; File: apps/asm/monitor.asm
; Architecture: Particle 32-bit RISC
; Description: Standalone interactive Memory Monitor and Soft Breakpoint Debugger.
;              Updated for Dual-UART hardware architecture (ULX3S 3 Mbps FTDI
;              on FIFO.0, Configurable Aux GPIO UART on FIFO.1, and MMIO Baud Divisor).
; ==============================================================================

.include "lib/common.inc"

; ------------------------------------------------------------------------------
; Hardware MMIO Definitions
; ------------------------------------------------------------------------------
.define MMIO_AUX_UART_DIVISOR   0xF0000010  ; 16-bit Aux GPIO Baud Prescaler Reg
.define DEFAULT_AUX_DIVISOR     217         ; ~115200 baud @ 25 MHz system clock

; ------------------------------------------------------------------------------
; Direct Stride Vector Table Entry Points (0x00000100 - 0x000004FF)
; ------------------------------------------------------------------------------
.org 0x00000100

; --- Trap 0: Hardware Reset ---
_vector_reset:
    LOAD32  R15, 0x00010000     ; Initialize SP to top of 64KB TCM RAM
    LOAD32  R14, _monitor_start
    JMP     R14, R0             ; Jump to monitor cold boot
    .align  64

; --- Trap 1: Soft Breakpoint Handler ---
_vector_breakpoint:
    ; Context save: Hardware latches PC of instruction following trap into R14
    LOAD32  R13, _saved_pc
    LD32    (R13), R14          ; Save breakpoint return PC
    
    ; Snapshot general registers R1-R12
    LOAD32  R13, _saved_regs
    LD32    (R13++), R1
    LD32    (R13++), R2
    LD32    (R13++), R3
    LD32    (R13++), R4
    LD32    (R13++), R5
    LD32    (R13++), R6
    LD32    (R13++), R7
    LD32    (R13++), R8
    LD32    (R13++), R9
    LD32    (R13++), R10
    LD32    (R13++), R11
    LD32    (R13++), R12

    ; Notify console and print hit PC
    LOAD32  R1, _str_bp_hit
    RCALL   _con_putstr

    LOAD32  R13, _saved_pc
    LD32    R1, (R13)
    RCALL   _con_puthex32
    LOAD32  R1, _str_newline
    RCALL   _con_putstr

    RCALL   _cmd_registers

    ; Return back to monitor command prompt
    LOAD32  R14, _cmd_prompt_loop
    JMP     R14, R0
    .align  64

; Pad through default empty traps to user code boundary
_vector_trap2_15:
    .align  0x00000500

; ------------------------------------------------------------------------------
; Monitor Cold Boot & Command Loop
; ------------------------------------------------------------------------------
_monitor_start:
    ; Set default baud rate on Aux GPIO UART (FIFO 1)
    LOAD32  R1, MMIO_AUX_UART_DIVISOR
    LOAD16  R2, DEFAULT_AUX_DIVISOR
    LD16    (R1), R2

    LOAD32  R1, _str_banner
    RCALL   _con_putstr

_cmd_prompt_loop:
    LOAD32  R1, _str_prompt
    RCALL   _con_putstr

    RCALL   _con_read_token     ; Read primary command char -> R1
    
    ; Check 'D' or 'd' (Dump Memory)
    LD      R2, 0x44            ; 'D'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_dump
    BGET    R3, 0
    LD      R2, 0x64            ; 'd'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_dump
    BGET    R3, 0

    ; Check 'W' or 'w' (Write Memory Word)
    LD      R2, 0x57            ; 'W'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_write
    BGET    R3, 0
    LD      R2, 0x77            ; 'w'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_write
    BGET    R3, 0

    ; Check 'G' or 'g' (Go / Run Address)
    LD      R2, 0x47            ; 'G'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_go
    BGET    R3, 0
    LD      R2, 0x67            ; 'g'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_go
    BGET    R3, 0

    ; Check 'R' or 'r' (Display Registers)
    LD      R2, 0x52            ; 'R'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_regs_entry
    BGET    R3, 0
    LD      R2, 0x72            ; 'r'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_regs_entry
    BGET    R3, 0

    ; Check 'B' or 'b' (Configure Aux UART Baud Divisor via MMIO)
    LD      R2, 0x42            ; 'B'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_baud
    BGET    R3, 0
    LD      R2, 0x62            ; 'b'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_baud
    BGET    R3, 0

    ; Check 'T' or 't' (Transmit Test Byte on Aux UART FIFO 1)
    LD      R2, 0x54            ; 'T'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_tx_aux
    BGET    R3, 0
    LD      R2, 0x74            ; 't'
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _cmd_tx_aux
    BGET    R3, 0

    ; Unknown command
    LOAD32  R1, _str_unknown
    RCALL   _con_putstr
    LOAD32  R14, _cmd_prompt_loop
    JMP     R14, R0

; ------------------------------------------------------------------------------
; Command: Dump Memory (D <hex_addr> <count>)
; ------------------------------------------------------------------------------
_cmd_dump:
    RCALL   _con_read_hex       ; Target address -> R1
    LD      R5, R1              ; Base pointer
    RCALL   _con_read_hex       ; Word count -> R1
    LD      R6, R1              ; Counter
    
    ; Enforce 4-byte alignment
    LOAD32  R7, 0xFFFFFFFC
    AND     R5, R7

_dump_line_loop:
    LD      R0, R6
    LOAD32  R14, _cmd_prompt_loop
    BGET    R0, 0               ; Exit if count == 0

    ; Print address prefix
    LD      R1, R5
    RCALL   _con_puthex32
    LOAD32  R1, _str_colon_space
    RCALL   _con_putstr

    ; Print up to 4 words (16 bytes) per row
    LD      R8, 4
_dump_word_loop:
    LD32    R1, (R5++)          ; Read 32-bit word, R5 += 4
    RCALL   _con_puthex32
    LD      R1, 0x20            ; Space
    RCALL   _con_putchar

    SUB     R6, 1
    SUB     R8, 1
    LD      R0, R6
    LOAD32  R14, _dump_row_done
    BGET    R0, 0
    LD      R0, R8
    LOAD32  R14, _dump_word_loop
    BGET    R0, 0

_dump_row_done:
    LOAD32  R1, _str_newline
    RCALL   _con_putstr
    LOAD32  R14, _dump_line_loop
    JMP     R14, R0

; ------------------------------------------------------------------------------
; Command: Write Memory Word (W <hex_addr> <hex_val>)
; ------------------------------------------------------------------------------
_cmd_write:
    RCALL   _con_read_hex       ; Address -> R1
    LD      R5, R1
    RCALL   _con_read_hex       ; Value -> R1
    LD      R6, R1

    LOAD32  R7, 0xFFFFFFFC
    AND     R5, R7              ; Align address

    LD32    (R5), R6            ; Commit 32-bit store

    LOAD32  R1, _str_ok
    RCALL   _con_putstr
    LOAD32  R14, _cmd_prompt_loop
    JMP     R14, R0

; ------------------------------------------------------------------------------
; Command: Go / Run from Address (G <hex_addr>)
; ------------------------------------------------------------------------------
_cmd_go:
    RCALL   _con_read_hex       ; Target PC -> R1
    LD      R5, R1
    
    LOAD32  R7, 0xFFFFFFFE      ; Ensure 2-byte alignment
    AND     R5, R7

    LOAD32  R1, _str_running
    RCALL   _con_putstr

    ; Restore registers from snapshot
    LOAD32  R13, _saved_regs
    LD32    R1, (R13++)
    LD32    R2, (R13++)
    LD32    R3, (R13++)
    LD32    R4, (R13++)
    LD32    R5, (R13++)
    LD32    R6, (R13++)
    LD32    R7, (R13++)
    LD32    R8, (R13++)
    LD32    R9, (R13++)
    LD32    R10, (R13++)
    LD32    R11, (R13++)
    LD32    R12, (R13++)

    JMP     R5, R14             ; Branch to target; link in R14

    ; Clean return back to monitor if target subroutine finishes
    LOAD32  R14, _cmd_prompt_loop
    JMP     R14, R0

; ------------------------------------------------------------------------------
; Command: Dump Registers (R)
; ------------------------------------------------------------------------------
_cmd_regs_entry:
    RCALL   _cmd_registers
    LOAD32  R14, _cmd_prompt_loop
    JMP     R14, R0

_cmd_registers:
    PUSH32  R14
    LOAD32  R5, _saved_regs
    LOAD16  R6, 1

_reg_dump_loop:
    LOAD32  R1, _str_r_prefix
    RCALL   _con_putstr
    LD      R1, R6
    RCALL   _con_puthex8
    LOAD32  R1, _str_colon_space
    RCALL   _con_putstr

    LD32    R1, (R5++)
    RCALL   _con_puthex32
    LOAD32  R1, _str_newline
    RCALL   _con_putstr

    ADD     R6, 1
    LOAD16  R7, 13
    SUB     R7, R6
    LOAD32  R14, _reg_dump_loop
    BGET    R7, 0

    POP32   R14
    RRET

; ------------------------------------------------------------------------------
; Command: Configure Aux UART Baud Divisor (B <hex_divisor>)
; ------------------------------------------------------------------------------
_cmd_baud:
    RCALL   _con_read_hex       ; Read new divisor -> R1
    LD      R5, R1

    ; Write to MMIO Register 0xF0000010
    LOAD32  R6, MMIO_AUX_UART_DIVISOR
    LD16    (R6), R5

    LOAD32  R1, _str_baud_set
    RCALL   _con_putstr
    LD      R1, R5
    RCALL   _con_puthex16
    LOAD32  R1, _str_newline
    RCALL   _con_putstr

    LOAD32  R14, _cmd_prompt_loop
    JMP     R14, R0

; ------------------------------------------------------------------------------
; Command: Transmit Test Byte on Aux UART (T <hex_byte>)
; ------------------------------------------------------------------------------
_cmd_tx_aux:
    RCALL   _con_read_hex       ; Byte value -> R1
    RCALL   _aux_putchar        ; Send out FIFO Channel 1
    LOAD32  R1, _str_ok
    RCALL   _con_putstr
    LOAD32  R14, _cmd_prompt_loop
    JMP     R14, R0

; ==============================================================================
; Generic FIFO Channel Serial I/O
; R1 = Character / Data byte
; R2 = Target FIFO Channel (0 = FTDI 3Mbps Console, 1 = Aux GPIO UART)
; ==============================================================================

; Blocking character transmit on FIFO channel in R2
_chan_putchar:
    FIFO.W  R1, (R2)            ; Transmit byte to channel in R2
    RRET

; Blocking character receive from FIFO channel in R2 into R1
_chan_getchar:
_chan_getchar_poll:
    FIFO.STAT R14, (R2)         ; Read status of channel in R2
    BGET    R14, FIFO_STAT_EMPTY_BIT
    LOAD32  R14, _chan_getchar_poll
    FBRA    _chan_getchar_poll  ; Spin while empty
    FIFO.R  R1, (R2)            ; Fetch byte
    RRET

; ------------------------------------------------------------------------------
; Console Wrappers (Hardware FTDI UART - Channel 0)
; ------------------------------------------------------------------------------
_con_putchar:
    PUSH32  R2
    LD      R2, 0
    RCALL   _chan_putchar
    POP32   R2
    RRET

_con_getchar:
    PUSH32  R2
    LD      R2, 0
    RCALL   _chan_getchar
    POP32   R2
    RRET

; ------------------------------------------------------------------------------
; Auxiliary GPIO UART Wrappers (Channel 1)
; ------------------------------------------------------------------------------
_aux_putchar:
    PUSH32  R2
    LD      R2, 1
    RCALL   _chan_putchar
    POP32   R2
    RRET

_aux_getchar:
    PUSH32  R2
    LD      R2, 1
    RCALL   _chan_getchar
    POP32   R2
    RRET

; ------------------------------------------------------------------------------
; Console Formatting Helpers
; ------------------------------------------------------------------------------

; Print string pointed to by R1 to console
_con_putstr:
    PUSH32  R14
    LD      R3, R1
_putstr_loop:
    LD8     R1, (R3++)
    LD      R0, R1
    LOAD32  R14, _putstr_done
    BGET    R0, 0
    PUSH32  R3
    RCALL   _con_putchar
    POP32   R3
    LOAD32  R14, _putstr_loop
    JMP     R14, R0
_putstr_done:
    POP32   R14
    RRET

; Print 32-bit hex in R1
_con_puthex32:
    PUSH32  R14
    PUSH32  R1
    LD      R4, 28
_hex_loop:
    POP32   R1
    PUSH32  R1
    SHIFTR  R1, R4
    AND     R1, 0x0F
    LOAD16  R2, 9
    SLT     R2, R1
    LOAD32  R14, _hex_alpha
    BGET    R2, 0
    ADD     R1, 0x30            ; '0'-'9'
    LOAD32  R14, _hex_emit
    JMP     R14, R0
_hex_alpha:
    ADD     R1, 0x37            ; 'A'-'F'
_hex_emit:
    RCALL   _con_putchar
    SUB     R4, 4
    LD      R0, R4
    LOAD32  R14, _hex_loop
    BGET    R0, 0
    POP32   R1
    POP32   R14
    RRET

; Print 16-bit hex in R1
_con_puthex16:
    PUSH32  R14
    PUSH32  R1
    SHIFTR  R1, 8
    RCALL   _con_puthex8
    POP32   R1
    RCALL   _con_puthex8
    POP32   R14
    RRET

; Print 8-bit hex in R1
_con_puthex8:
    PUSH32  R14
    PUSH32  R1
    SHIFTR  R1, 4
    AND     R1, 0x0F
    ADD     R1, 0x30
    RCALL   _con_putchar
    POP32   R1
    AND     R1, 0x0F
    ADD     R1, 0x30
    RCALL   _con_putchar
    POP32   R14
    RRET

; Read command character token (skipping whitespace)
_con_read_token:
    PUSH32  R14
_read_tok_poll:
    RCALL   _con_getchar
    LD      R2, 0x20
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _read_tok_poll
    BGET    R3, 0               ; Discard spaces
    POP32   R14
    RRET

; Parse hexadecimal number from console into R1
_con_read_hex:
    PUSH32  R14
    LD      R5, 0               ; Accumulator
_read_hex_loop:
    RCALL   _con_getchar
    ; Check delimiter (space, CR, LF)
    LD      R2, 0x20
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _read_hex_done
    BGET    R3, 0
    LD      R2, 0x0A
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _read_hex_done
    BGET    R3, 0
    LD      R2, 0x0D
    SUB     R3, R1
    ADD     R3, R2
    LOAD32  R14, _read_hex_done
    BGET    R3, 0

    ; Parse hex nibble
    LOAD16  R2, 0x39            ; '9'
    SLT     R2, R1
    LOAD32  R14, _nibble_letter
    BGET    R2, 0
    SUB     R1, 0x30            ; '0'-'9'
    LOAD32  R14, _nibble_accum
    JMP     R14, R0
_nibble_letter:
    AND     R1, 0xDF            ; Uppercase
    SUB     R1, 0x37            ; 'A'-'F'
_nibble_accum:
    SHIFTL  R5, 4
    OR      R5, R1
    LOAD32  R14, _read_hex_loop
    JMP     R14, R0

_read_hex_done:
    LD      R1, R5
    POP32   R14
    RRET

; ------------------------------------------------------------------------------
; Static Data & State Snapshots
; ------------------------------------------------------------------------------
.align 4
_saved_pc:
    .word 0x00000000

_saved_regs:
    .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0   ; R1..R12

_str_banner:
    .asciz "\r\n=== Particle Dual-UART Memory Monitor ===\r\nCommands:\r\n  D <addr> <words>  : Dump memory\r\n  W <addr> <val>    : Write word\r\n  G <addr>          : Run from address\r\n  R                 : Show registers\r\n  B <hex_div>       : Set Aux UART baud prescaler (MMIO 0xF0000010)\r\n  T <hex_byte>      : Transmit test byte on Aux UART (FIFO 1)\r\n"
_str_prompt:
    .asciz "MON> "
_str_bp_hit:
    .asciz "\r\n*** BREAKPOINT (TRAP 1) HIT AT PC = 0x"
_str_ok:
    .asciz "OK\r\n"
_str_unknown:
    .asciz "? SYNTAX ERROR\r\n"
_str_running:
    .asciz "Running...\r\n"
_str_baud_set:
    .asciz "Aux UART Baud Divisor set to 0x"
_str_r_prefix:
    .asciz "R"
_str_colon_space:
    .asciz ": "
_str_newline:
    .asciz "\r\n"