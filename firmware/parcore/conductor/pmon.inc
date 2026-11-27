; ==============================================================================
; File: firmware/parcore/conductor/pmon.inc
; pmon, the conductor's console (Road to GHz item 16; Documentation/pmon.md):
; a text monitor and a framed binary protocol on the console UART.
;
; _pmon_poll handles a byte if one has arrived: SOH starts a frame (read and
; answered whole), anything else is a character of the command line. The
; supervisor calls it from its loop with R5 = RST_CTRL (0xF000_0000); it
; keeps R5, R6, R11 and R13 (R13 is the length of the line typed so far).
;
; The leaf routines (those that don't save R14) use only FBRA and BBRA: the
; conductor has no 2-word branches, so a JUMP.cc out of their range becomes
; LDI R14 and JMP, which would lose the return address.
;
; Needs conductor_regs.inc and _reset_vector.
; ==============================================================================

.define PMON_LINE_BUF       0x0E00  ; the line typed, a character a word (128
                                    ; bytes): SECTION_TABLE's, which only boot
                                    ; uses
.define PMON_LINE_MAX       32
.define PMON_SOH            0x01
.define PMON_ACK            0x06
.define PMON_NAK            0x15
.define PMON_ERR_CRC        1
.define PMON_ERR_COMMAND    2
.define PMON_ERR_ALIGN      3       ; address or length not a multiple of 4,
                                    ; or a length over 256
.define PMON_ERR_HELD       4       ; a core's TCM, with the core not held
.ifndef PMON_TIMEOUT_SHIFT
.define PMON_TIMEOUT_SHIFT  21      ; a frame's bytes: 1 << 21 cycles (2.1
.endif                              ; million, 84 ms at 25 MHz); 16 to 30

; ------------------------------------------------------------------------------
; Console I/O
; ------------------------------------------------------------------------------

; Send the byte in R1 (uses R3, R4)
_con_putc:
    LDI     R3, CONSOLE_STATUS_OFFSET
    ADD     R3, R5
._wait:
    LD32    R4, (R3)
    AND     R4, 2                   ; transmitter busy
    BBRA.NZ R4, ._wait
    SUB     R3, 4                   ; CONSOLE_DATA
    ST32    (R3), R1
    RRET

; Send CR LF (uses R1, R3, R4)
_con_crlf:
    ST32    (--SP), R14
    LD      R1, 13
    RCALL   _con_putc
    LD      R1, 10
    RCALL   _con_putc
    LD32    R14, (SP++)
    RRET

; Send the zero-terminated string at R2 (uses R1-R4)
_con_puts:
    ST32    (--SP), R14
._next:
    LD      R1, R2
    SHIFTR  R1, 2
    SHIFTL  R1, 2
    LD32    R1, (R1)                ; its word
    LD      R3, R2
    AND     R3, 3
    SHIFTL  R3, 3
    SHIFTR  R1, R3                  ; its byte
    LDI     R3, 0xFF
    AND     R1, R3
    JUMP.Z  R1, ._end
    RCALL   _con_putc
    ADD     R2, 1
    BBRA    ._next
._end:
    LD32    R14, (SP++)
    RRET

; Send R1 as 8 hex digits (uses R1, R3, R4, R9, R10)
_con_hex8:
    ST32    (--SP), R14
    LD      R9, R1
    LD      R10, 8
._digit:
    LD      R1, R9
    SHIFTR  R1, 15
    SHIFTR  R1, 13                  ; the top nibble
    SHIFTL  R9, 4
    LD      R3, R1
    SLT     R3, 10
    JUMP.NZ R3, ._num
    ADD     R1, 7                   ; 'A' - '0' - 10
._num:
    LD      R14, 0x30               ; '0'
    ADD     R1, R14
    RCALL   _con_putc
    SUB     R10, 1
    JUMP.NZ R10, ._digit
    LD32    R14, (SP++)
    RRET

; R1 = a received byte, or -1 if none comes within the timeout (uses R2-R4)
_con_getc_t:
    LDI     R2, CONSOLE_STATUS_OFFSET
    ADD     R2, R5
    LDI     R3, CYCLES_OFFSET
    ADD     R3, R5
    LD32    R4, (R3)                ; when it started
._poll:
    LD32    R1, (R2)
    AND     R1, 1
    FBRA.NZ R1, ._got
    LD32    R1, (R3)
    SUB     R1, R4                  ; cycles waited
    SHIFTR  R1, 15
    SHIFTR  R1, PMON_TIMEOUT_SHIFT - 15
    BBRA.Z  R1, ._poll
    LD      R1, -1
    RRET
._got:
    SUB     R2, 4                   ; CONSOLE_DATA
    LD32    R1, (R2)
    RRET

; ------------------------------------------------------------------------------
; _pmon_poll: a byte from the console, if one has arrived
; ------------------------------------------------------------------------------
_pmon_poll:
    LDI     R3, CONSOLE_STATUS_OFFSET
    ADD     R3, R5
    LD32    R2, (R3)
    AND     R2, 1
    FBRA.NZ R2, ._byte
    RRET
._byte:
    ST32    (--SP), R14
    SUB     R3, 4                   ; CONSOLE_DATA
    LD32    R1, (R3)
    LD      R2, R1
    SUB     R2, PMON_SOH
    JUMP.NZ R2, ._text
    RCALL   _pmon_frame
    JUMP    ._done
._text:
    LD      R2, R1
    SUB     R2, 13                  ; CR
    JUMP.Z  R2, ._eol
    LD      R2, R1
    SUB     R2, 10                  ; LF
    JUMP.Z  R2, ._eol
    LD      R2, R1
    SUB     R2, 8                   ; backspace
    JUMP.Z  R2, ._bs
    LD      R14, 127                ; DEL
    LD      R2, R1
    SUB     R2, R14
    JUMP.Z  R2, ._bs
    LD      R14, 32
    LD      R2, R1
    SLT     R2, R14
    JUMP.NZ R2, ._done              ; other control characters
    LD      R2, R13
    SUB     R2, R14                 ; PMON_LINE_MAX
    JUMP.Z  R2, ._done              ; the line is full
    LDI     R2, PMON_LINE_BUF
    LD      R3, R13
    SHIFTL  R3, 2
    ADD     R2, R3
    ST32    (R2), R1
    ADD     R13, 1
    RCALL   _con_putc               ; echo
    JUMP    ._done
._bs:
    JUMP.Z  R13, ._done
    SUB     R13, 1
    LD      R1, 8
    RCALL   _con_putc
    LD      R14, 32
    LD      R1, R14
    RCALL   _con_putc
    LD      R1, 8
    RCALL   _con_putc
    JUMP    ._done
._eol:
    RCALL   _con_crlf
    RCALL   _pmon_command
    LD      R13, 0
    RCALL   _pmon_prompt
._done:
    LD32    R14, (SP++)
    RRET

_pmon_prompt:
    ST32    (--SP), R14
    LDI     R2, _str_prompt
    RCALL   _con_puts
    LD32    R14, (SP++)
    RRET

; ------------------------------------------------------------------------------
; The text monitor: one line, R13 characters at PMON_LINE_BUF
;   s               status: core states, cycles, PCs, RST_CTRL
;   h MASK          hold cores (RST_CTRL |= MASK)
;   g MASK          let cores go (RST_CTRL &= ~MASK)
;   r ADDR [N]      read N words (1 by default)
;   w ADDR VALUE    write a word
;   b               boot again from flash
;   ?               help
; Numbers are hex. Uses R1-R4, R7-R10, R12.
; ------------------------------------------------------------------------------
_pmon_command:
    ST32    (--SP), R14
    LD      R8, 0
    RCALL   _pmon_char
    JUMP.Z  R1, ._cmd_done          ; an empty line
    LD      R14, 32
    OR      R1, R14                 ; lower case
    LD      R7, R1
    LD      R14, 0x73               ; 's'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._cmd_s
    LD      R14, 0x68               ; 'h'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._cmd_h
    LD      R14, 0x67               ; 'g'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._cmd_g
    LD      R14, 0x72               ; 'r'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._cmd_r
    LD      R14, 0x77               ; 'w'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._cmd_w
    LD      R14, 0x62               ; 'b'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._cmd_b
    LD      R14, 0x3F               ; '?'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._cmd_help
._cmd_bad:
    LDI     R2, _str_what
    RCALL   _con_puts
    JUMP    ._cmd_done
._cmd_help:
    LDI     R2, _str_help
    RCALL   _con_puts
    JUMP    ._cmd_done
._cmd_s:
    RCALL   _pmon_status_text
    JUMP    ._cmd_done
._cmd_h:
    RCALL   _pmon_hex
    JUMP.Z  R2, ._cmd_bad
    LD      R14, 0x3F
    AND     R1, R14
    LD32    R2, (R5)
    OR      R2, R1
    ST32    (R5), R2
    JUMP    ._cmd_done
._cmd_g:
    RCALL   _pmon_hex
    JUMP.Z  R2, ._cmd_bad
    LD      R14, 0x3F
    AND     R1, R14
    NOT     R1
    LD32    R2, (R5)
    AND     R2, R1
    ST32    (R5), R2
    JUMP    ._cmd_done
._cmd_r:
    RCALL   _pmon_hex
    JUMP.Z  R2, ._cmd_bad
    LD      R12, R1                 ; the address
    SHIFTR  R12, 2
    SHIFTL  R12, 2
    RCALL   _pmon_hex
    LD      R7, R1                  ; the count
    JUMP.NZ R2, ._r_loop
    LD      R7, 1
._r_loop:
    LD      R1, R12
    RCALL   _con_hex8
    LD      R14, 0x3A               ; ':'
    LD      R1, R14
    RCALL   _con_putc
    LD      R14, 32
    LD      R1, R14
    RCALL   _con_putc
    LD32    R1, (R12)
    RCALL   _con_hex8
    RCALL   _con_crlf
    ADD     R12, 4
    SUB     R7, 1
    JUMP.NZ R7, ._r_loop
    JUMP    ._cmd_done
._cmd_w:
    RCALL   _pmon_hex
    JUMP.Z  R2, ._cmd_bad
    LD      R12, R1
    RCALL   _pmon_hex
    JUMP.Z  R2, ._cmd_bad
    ST32    (R12), R1
    JUMP    ._cmd_done
._cmd_b:
    JUMP    _reset_vector
._cmd_done:
    LD32    R14, (SP++)
    RRET

; R1 = the character at R8 in the line (0 past its end), and R8 += 1
_pmon_char:
    LD      R1, 0
    LD      R2, R8
    SUB     R2, R13
    FBRA.Z  R2, ._past              ; R8 == R13: the end
    LDI     R1, PMON_LINE_BUF
    LD      R2, R8
    SHIFTL  R2, 2
    ADD     R1, R2
    LD32    R1, (R1)
    ADD     R8, 1
._past:
    RRET

; The next hex number in the line, after spaces: R1 = its value, R2 = the
; number of digits (0: none). Uses R3, R4, R8-R10.
_pmon_hex:
    ST32    (--SP), R14
._skip:
    RCALL   _pmon_char
    LD      R14, 32
    LD      R2, R1
    SUB     R2, R14
    JUMP.Z  R2, ._skip
    LD      R9, 0                   ; the value
    LD      R10, 0                  ; digits
._hexdigit:
    LD      R4, R1
    LD      R14, 0x30               ; '0'
    SUB     R4, R14
    LD      R2, R4
    SLT     R2, 10
    JUMP.NZ R2, ._add               ; 0-9
    LD      R14, 32
    OR      R1, R14                 ; lower case
    LD      R4, R1
    LD      R14, 0x61               ; 'a'
    SUB     R4, R14
    LD      R2, R4
    SLT     R2, 6
    JUMP.Z  R2, ._hexend
    ADD     R4, 10
._add:
    SHIFTL  R9, 4
    OR      R9, R4
    ADD     R10, 1
    RCALL   _pmon_char
    JUMP    ._hexdigit
._hexend:
    LD      R1, R9
    LD      R2, R10
    LD32    R14, (SP++)
    RRET

; The status as text: core states and cycles, then the cores' PCs
; (uses R1-R4, R7-R10)
_pmon_status_text:
    ST32    (--SP), R14
    LDI     R2, _str_state
    RCALL   _con_puts
    LD      R14, CORE_STATE_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    RCALL   _con_hex8
    LDI     R2, _str_cycles
    RCALL   _con_puts
    LD      R14, CYCLES_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    RCALL   _con_hex8
    LDI     R2, _str_rst
    RCALL   _con_puts
    LD32    R1, (R5)
    RCALL   _con_hex8
    LDI     R2, _str_pc
    RCALL   _con_puts
    LD      R7, 0
._pc:
    LD      R14, 32
    LD      R1, R14
    RCALL   _con_putc
    LD      R14, CORE_PC_OFFSET
    ADD     R14, R5
    LD      R1, R7
    SHIFTL  R1, 2
    ADD     R14, R1
    LD32    R1, (R14)
    RCALL   _con_hex8
    ADD     R7, 1
    LD      R1, R7
    SUB     R1, 4
    JUMP.NZ R1, ._pc
    RCALL   _con_crlf
    LD32    R14, (SP++)
    RRET

; ------------------------------------------------------------------------------
; Frames: SOH (already read), command, address (4 bytes), length (2), data,
; CRC-16 (2, high byte first). Little-endian. The CRC (CRC-16/CCITT-FALSE:
; polynomial 0x1021, start 0xFFFF) covers the command to the data; run on
; through the CRC bytes it ends at 0. Answers: ACK; NAK and an error code;
; for R and S, ACK, the data and its CRC-16.
;   H MASK  hold cores          G MASK  let cores go
;   W       write the data      R       read LENGTH bytes
;   S       status: CORE_STATE, CYCLES, the PCs of cores 0-3, RST_CTRL
;   B       boot again from flash (after the ACK)
; For W and R, the address and length are multiples of 4 and the length at
; most 256 (else NAK PMON_ERR_ALIGN); only W carries data. A frame whose
; bytes stop for 1 << PMON_TIMEOUT_SHIFT cycles is dropped unanswered.
; ------------------------------------------------------------------------------
_pmon_frame:
    ST32    (--SP), R14
    ST32    (--SP), R6
    ST32    (--SP), R11
    ST32    (--SP), R13
    LD      R12, SP                 ; for a timeout: back to here
    LDI     R10, 0xFFFF             ; the CRC
    RCALL   _pf_byte
    LD      R7, R1                  ; the command
    RCALL   _pf_word
    LD      R8, R1                  ; the address (H, G: the mask)
    RCALL   _pf_byte
    LD      R9, R1
    RCALL   _pf_byte
    SHIFTL  R1, 8
    OR      R9, R1                  ; the length
    ; R11 = the error for W and R (0: none): the address and length
    ; multiples of 4, the length at most 256
    LD      R11, PMON_ERR_ALIGN
    LD      R1, R8
    OR      R1, R9
    AND     R1, 3
    JUMP.NZ R1, ._checked
    LD      R1, R9
    LDI     R2, 257
    SLT     R1, R2
    JUMP.Z  R1, ._checked
    LD      R11, 0
._checked:
    ; Only W carries data: it is written as it arrives (the cores it goes to
    ; are held), so a W with a bad CRC has written its data anyway; the host
    ; sends it again
    LD      R14, 0x57               ; 'W'
    LD      R2, R7
    SUB     R2, R14
    JUMP.NZ R2, ._crc
    JUMP.NZ R11, ._skip_data
    RCALL   _pf_check_held
    JUMP.NZ R11, ._skip_data
    LD      R13, R9
    SHIFTR  R13, 2
._data:
    JUMP.Z  R13, ._crc
    RCALL   _pf_word
    ST32    (R8++), R1
    SUB     R13, 1
    JUMP    ._data
._skip_data:
    LD      R13, R9                 ; a W in error: read its data, unwritten
._skip_byte:
    JUMP.Z  R13, ._crc
    RCALL   _pf_byte
    SUB     R13, 1
    JUMP    ._skip_byte
._crc:
    RCALL   _pf_byte
    RCALL   _pf_byte
    LD      R1, PMON_ERR_CRC
    JUMP.NZ R10, _pf_nak
    ; The command
    LD      R14, 0x48               ; 'H'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._f_h
    LD      R14, 0x47               ; 'G'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._f_g
    LD      R14, 0x57               ; 'W'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._f_w
    LD      R14, 0x52               ; 'R'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._f_r
    LD      R14, 0x53               ; 'S'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._f_s
    LD      R14, 0x42               ; 'B'
    LD      R2, R7
    SUB     R2, R14
    JUMP.Z  R2, ._f_b
    LD      R1, PMON_ERR_COMMAND
    JUMP    _pf_nak
._f_h:
    LD      R14, 0x3F
    AND     R8, R14
    LD32    R1, (R5)
    OR      R1, R8
    ST32    (R5), R1
    JUMP    _pf_ack
._f_g:
    LD      R14, 0x3F
    AND     R8, R14
    NOT     R8
    LD32    R1, (R5)
    AND     R1, R8
    ST32    (R5), R1
    JUMP    _pf_ack
._f_w:
    LD      R1, R11
    JUMP.NZ R1, _pf_nak
    JUMP    _pf_ack
._f_r:
    LD      R1, R11
    JUMP.NZ R1, _pf_nak
    RCALL   _pf_send_ack
    LDI     R10, 0xFFFF
    LD      R13, R9
    SHIFTR  R13, 2
._r_word:
    JUMP.Z  R13, _pf_send_crc
    LD32    R1, (R8++)
    RCALL   _pf_send_word
    SUB     R13, 1
    JUMP    ._r_word
._f_s:
    RCALL   _pf_send_ack
    LDI     R10, 0xFFFF
    LD      R14, CORE_STATE_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    RCALL   _pf_send_word
    LD      R14, CYCLES_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    RCALL   _pf_send_word
    LDI     R8, CORE_PC_OFFSET
    ADD     R8, R5
    LD      R13, 4
._s_pc:
    LD32    R1, (R8++)
    RCALL   _pf_send_word
    SUB     R13, 1
    JUMP.NZ R13, ._s_pc
    LD32    R1, (R5)                ; RST_CTRL
    RCALL   _pf_send_word
    JUMP    _pf_send_crc
._f_b:
    RCALL   _pf_send_ack
    JUMP    _reset_vector

; A W into a core's TCM (0x1000_0000 + (n << 16)) needs core n held: R11 =
; PMON_ERR_HELD if it isn't (uses R1-R3)
_pf_check_held:
    LD      R2, R8
    SHIFTR  R2, 15
    SHIFTR  R2, 13                  ; bits 31:28
    SUB     R2, 1
    FBRA.NZ R2, ._ok                ; not a core's window
    LD      R2, R8
    SHIFTR  R2, 15
    SHIFTR  R2, 1
    AND     R2, 7                   ; the core (bits 18:16)
    LD32    R3, (R5)
    SHIFTR  R3, R2
    AND     R3, 1
    FBRA.NZ R3, ._ok
    LD      R11, PMON_ERR_HELD
._ok:
    RRET

; The next byte of the frame into R1, added to the CRC in R10; on a timeout
; the frame is dropped (uses R2-R4)
_pf_byte:
    ST32    (--SP), R14
    RCALL   _con_getc_t
    JUMP.N  R1, _pf_drop
    RCALL   _pf_crc
    LD32    R14, (SP++)
    RRET

; The next 4 bytes as a little-endian word in R1 (uses R2-R4, R6)
_pf_word:
    ST32    (--SP), R14
    RCALL   _pf_byte
    LD      R6, R1
    RCALL   _pf_byte
    SHIFTL  R1, 8
    OR      R6, R1
    RCALL   _pf_byte
    SHIFTL  R1, 15
    SHIFTL  R1, 1
    OR      R6, R1
    RCALL   _pf_byte
    SHIFTL  R1, 15
    SHIFTL  R1, 9
    OR      R1, R6
    LD32    R14, (SP++)
    RRET

; R10 = the CRC-16 of R10 and the byte in R1 (keeps R1; uses R2, R3)
_pf_crc:
    LD      R2, R1
    SHIFTL  R2, 8
    XOR     R10, R2
    LD      R3, 8
._bit:
    LD      R2, R10
    BGET    R2, 15
    SHIFTL  R10, 1
    FBRA.Z  R2, ._no_xor
    LDI     R2, 0x1021
    XOR     R10, R2
._no_xor:
    SUB     R3, 1
    BBRA.NZ R3, ._bit
    LDI     R2, 0xFFFF
    AND     R10, R2
    RRET

; Send the byte in R1, adding it to the CRC in R10 (uses R2-R4)
_pf_send:
    ST32    (--SP), R14
    RCALL   _pf_crc
    RCALL   _con_putc
    LD32    R14, (SP++)
    RRET

; Send the word in R1, little-endian, adding it to the CRC (uses R1-R4, R6)
_pf_send_word:
    ST32    (--SP), R14
    LD      R6, R1
    LD      R14, 4
    ST32    (--SP), R14
._byte4:
    LD      R1, R6
    LDI     R2, 0xFF
    AND     R1, R2
    RCALL   _pf_send
    SHIFTR  R6, 8
    LD32    R1, (SP)
    SUB     R1, 1
    ST32    (SP), R1
    JUMP.NZ R1, ._byte4
    LD32    R1, (SP++)
    LD32    R14, (SP++)
    RRET

_pf_send_ack:
    ST32    (--SP), R14
    LD      R1, PMON_ACK
    RCALL   _con_putc
    LD32    R14, (SP++)
    RRET

; The ends of a frame: each goes back to _pmon_frame's caller
_pf_ack:
    LD      R1, PMON_ACK
    RCALL   _con_putc
    JUMP    _pf_end
; NAK and the error code in R1
_pf_nak:
    LD      R7, R1
    LD      R14, PMON_NAK
    LD      R1, R14
    RCALL   _con_putc
    LD      R1, R7
    RCALL   _con_putc
    JUMP    _pf_end
; The CRC of the data sent, high byte first
_pf_send_crc:
    LD      R7, R10
    LD      R1, R7
    SHIFTR  R1, 8
    RCALL   _con_putc
    LD      R1, R7
    LDI     R2, 0xFF
    AND     R1, R2
    RCALL   _con_putc
    JUMP    _pf_end
; Dropped: no answer
_pf_drop:
_pf_end:
    LD      SP, R12
    LD32    R13, (SP++)
    LD32    R11, (SP++)
    LD32    R6, (SP++)
    LD32    R14, (SP++)
    RRET

_str_prompt:
    .asciz  "pmon> "
_str_what:
    .asciz  "?\r\n"
_str_help:
    .asciz  "s status | h MASK hold | g MASK go | r ADDR [N] read | w ADDR VALUE write | b boot\r\n"
_str_state:
    .asciz  "state "
_str_cycles:
    .asciz  " cycles "
_str_rst:
    .asciz  " rst "
_str_pc:
    .asciz  "\r\npc"
_str_hang:
    .asciz  "\r\nHANG: cores 1-3 have stopped\r\n"
_str_hello:
    .asciz  "\r\npmon: Parcore conductor console (? for help)\r\n"
.align 2
