; ==============================================================================
; Parcore RV32IM_Zbb: Core 3 (Memory Access, Sub-word Formatting & Writeback)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core3_mem.asm
; ==============================================================================
; This core is built without the shadow bank (ParcoreConfig)
.define NO_SHADOW_BANK 1
.include "lib/vectors.inc"

; FENCE.I coherence: core 0 fetches guest instructions from its own TCM, so
; every guest store into core 0's guest area (GUEST_AREA_START up to
; GUEST_AREA_END, the end of core 0's TCM) is also sent to core 0 on channel 2
; (memToIf), which writes it into its TCM. An entry is one word, so an MBOX
; can't split it:
;   [31:16] data, [14:13] kind (1 byte, 2 halfword, 3 FENCE.I marker),
;   [12:0] address
; A word store is sent as two halfword entries. After all the stores before
; it, a FENCE.I sends the marker, which core 0's FENCE.I handler waits for.
.define GUEST_AREA_START 0x0500     ; _mirror_store tests address >> 8 >= 5
.define GUEST_AREA_END   0x2000     ; and address >> 13 == 0
.define MIRROR_BYTE      0x2000     ; kind 1 << 13
.define MIRROR_HALF      0x4000     ; kind 2 << 13
.define MIRROR_MARKER    0x6000     ; kind 3 << 13

    VECTOR_TABLE _reset_vector
_reset_vector:
    LDI     R1, 0x000F          ; R1 = 0x000F0004: the memory-op and cancel bits
    SHIFTL  R1, 8
    SHIFTL  R1, 8
    OR      R1, 4
    LD      R2, 1               ; FIFO Ch1: Outbound WB to Core 1 (memToWb)
    LD      R7, 2               ; FIFO Ch2: Outbound store mirror to Core 0 (memToIf)
                                ; FIFO Ch3: the FTDI UART (guest I/O, _io_access)
                                ; FIFO Ch0 (R0): Inbound from Core 2 (EX)

; ==============================================================================
; Main loop. Packets from core 2: [control word, result, address, store data].
; Most are ALU results on their way to core 1: they take the fast path.
; ==============================================================================
_mem_main_loop:
    FIFO.R  R10, R0             ; control word
    FIFO.R  R11, R0             ; result
    FIFO.R  R12, R0             ; address
    FIFO.R  R13, R0             ; store data
    BEXTR   R4, R10, 8, 5
    SHIFTL  R4, 3               ; R4 = Rd * 8, its slot in core 1's register file
    LD      R14, R10
    AND     R14, R1
    FBRA.NZ R14, _not_alu       ; a memory operation or a cancel
_send_wb_tokens:
    ; A writeback for core 1 (one for x0 is ignored there)
    FIFO.W  R4, R2              ; Rd * 8 (+ 0x800: a cancel)
    FIFO.W  R11, R2             ; the value
    BBRA    _mem_main_loop

; ------------------------------------------------------------------------------
; A cancel from core 2 (bit 2): core 1 gets Rd * 8 + 0x800, which takes the
; register off its in-flight count without writing it (the value goes to
; 0x800 + 8 * Rd, which nothing uses). Otherwise dispatch on
; the memory operation (bits 19:16): 1-5 loads LB, LH, LW, LBU, LHU; 8-10
; stores SB, SH, SW; 11 FENCE.I.
; ------------------------------------------------------------------------------
_not_alu:
    LD      R14, R10
    AND     R14, 4
    FBRA.Z  R14, ._not_cancel
    BSET    R4, 11              ; Rd * 8 + 0x800
    JUMP    _send_wb_tokens
._not_cancel:
    LD      R3, R10
    SHIFTR  R3, 8
    SHIFTR  R3, 8
    AND     R3, 15              ; the memory operation
    ; Guest I/O (address bits 31:28 = 1), before anything touches the TCM.
    ; (A FENCE.I item carries pc + 4 here, never an I/O address.)
    LD      R14, R12
    SHIFTR  R14, 14
    SHIFTR  R14, 14
    SUB     R14, 1
    FBRA.Z  R14, _t_io
    JTBL    R3
    FBRA    _mem_drop           ; 0 (not reached)
    FBRA    _do_lb              ; 1
    FBRA    _do_lh              ; 2
    FBRA    _do_lw              ; 3
    FBRA    _do_lbu             ; 4
    FBRA    _do_lhu             ; 5
    FBRA    _mem_drop           ; 6
    FBRA    _mem_drop           ; 7
    FBRA    _do_sb              ; 8
    FBRA    _do_sh              ; 9
    FBRA    _do_sw              ; 10
    FBRA    _do_fence_i         ; 11
    FBRA    _mem_drop           ; 12
    FBRA    _mem_drop           ; 13
    FBRA    _mem_drop           ; 14
    FBRA    _mem_drop           ; 15
_t_io:
    JUMP    _io_access
_mem_drop:
    JUMP    _mem_main_loop

; Loads: R11 = the value, then the writeback
_do_lw:
    LD32    R11, (R12)
    JUMP    _send_wb_tokens
_do_lb:
    LD8     R11, (R12)
    SHIFTL  R11, 12
    SHIFTL  R11, 12
    ASHIFTR R11, 12
    ASHIFTR R11, 12             ; sign-extend the byte
    JUMP    _send_wb_tokens
_do_lh:
    LD16    R11, (R12)
    SHIFTL  R11, 8
    SHIFTL  R11, 8
    ASHIFTR R11, 8
    ASHIFTR R11, 8              ; sign-extend the halfword
    JUMP    _send_wb_tokens
_do_lbu:
    LD8     R11, (R12)          ; LD8 and LD16 zero-extend
    JUMP    _send_wb_tokens
_do_lhu:
    LD16    R11, (R12)
    JUMP    _send_wb_tokens

; Stores: no writeback; then the mirror to core 0
_do_sb:
    ST8     (R12), R13
    LDI     R8, MIRROR_BYTE
    JUMP    _mirror_store
_do_sh:
    ST16    (R12), R13
    LDI     R8, MIRROR_HALF
    JUMP    _mirror_store
_do_sw:
    ; Mirrored as two halfwords: the low one here, the high one at address
    ; + 2 by _mirror_store
    ST32    (R12), R13
    LDI     R8, MIRROR_HALF
    OR      R8, 1               ; bit 0: a word store
    JUMP    _mirror_store

; FENCE.I: no writeback (core 1 counts no destination for it); the marker
; for core 0, after every store before it
_do_fence_i:
    LDI     R9, MIRROR_MARKER
    JUMP    _mirror_push

; ==============================================================================
; Store mirror (FENCE.I coherence): R12 address, R13 data, R8 kind (bit 0 set
; for a word store). Stores outside core 0's guest area aren't sent.
; ==============================================================================
_mirror_store:
    ; In range when address >> 13 is 0 (below GUEST_AREA_END) and
    ; address >> 8 is at least 5 (GUEST_AREA_START). The tests use R14, the
    ; register with the longer branch form.
    LD      R14, R12
    SHIFTR  R14, 13
    FBRA.NZ R14, ._outside
    LD      R14, R12
    SHIFTR  R14, 8
    SUB     R14, 5
    FBRA.N  R14, ._outside
    LD      R9, R13
    SHIFTL  R9, 8
    SHIFTL  R9, 8               ; low halfword of the data into [31:16]
    OR      R9, R12             ; address into [12:0]
    LD      R14, R8
    AND     R14, 1
    XOR     R8, R14             ; kind without the word-store bit
    OR      R9, R8
    FBRA.Z  R14, _mirror_push
    ; Word store: the low halfword now, then the high one at address + 2
    LOAD16  R5, _mirror_wait
    JMP     R5, R15
    FIFO.W  R9, R7
    LD      R9, R13
    LOAD32  R5, 0xFFFF0000
    AND     R9, R5              ; high halfword of the data in [31:16]
    OR      R9, R12
    ADD     R9, 2
    OR      R9, R8
    JUMP    _mirror_push
._outside:
    JUMP    _mem_main_loop

; Push the entry in R9 once memToIf has room, then go back to the main loop
_mirror_push:
    LOAD16  R5, _mirror_wait
    JMP     R5, R15
    FIFO.W  R9, R7
    JUMP    _mem_main_loop

; Wait while memToIf holds 128 words or more (core 0 drains it); returns to
; the address in R15
_mirror_wait:
    FIFO.STAT R6, R7
    SHIFTR  R6, 15              ; depth[7]
    BBRA.NZ R6, _mirror_wait
    JMP     R15, R0

; ==============================================================================
; Guest I/O: the FTDI UART, on FIFO channel 3
;   0x1000_0000  store: send the low byte (waits while the transmitter is busy)
;                load:  the received byte, or 0xFFFFFFFF if none has arrived
;   0x1000_0004  load:  status: bit 0 a byte has been received, bit 1 room to
;                send
;   0x1000_0008  store: the board LEDs (bits 7:0), once the conductor has
;                handed them over; load: the value last stored
;   0x1000_000C  load:  the buttons, 1 = pressed: bit 0 FIRE1, 1 FIRE2, 2 UP,
;                3 DOWN, 4 LEFT, 5 RIGHT
; Other addresses from 0x1000_0000 to 0x1FFF_FFFF: stores are ignored, loads
; return 0. The LEDs and buttons are core 3's own I/O at 0xF000_0000 and
; 0xF000_0004. Loads aren't sign-extended. R12 address, R13 store data, R3 the
; memory operation, R4 Rd * 8 (kept for the writeback).
; ==============================================================================
_io_access:
    LD      R6, 3               ; FIFO channel 3: the UART
    LOAD32  R5, 0x0FFFFFFF
    AND     R5, R12             ; R5 = offset from 0x1000_0000
    LD      R14, R3
    SUB     R14, 8
    FBRA.N  R14, ._io_load      ; operations 1-5 are loads, 8-10 stores
    FBRA.Z  R5, ._io_send
    LD      R14, R5
    SUB     R14, 8
    FBRA.NZ R14, ._io_done      ; a store elsewhere is ignored
    LOAD32  R14, 0xF0000000     ; the LEDs
    ST32    (R14), R13
    FBRA    ._io_done
._io_send:
    FIFO.TRYW R13, R6           ; R14 = 1 when the byte was sent
    BBRA.Z  R14, ._io_send
._io_done:
    JUMP    _mem_main_loop
._io_load:
    LD      R11, 0
    LD      R14, R5
    FBRA.Z  R14, ._io_receive   ; 0x1000_0000: a received byte
    SUB     R14, 8
    FBRA.Z  R14, ._io_board     ; 0x1000_0008: the LEDs
    SUB     R14, 4
    FBRA.Z  R14, ._io_board     ; 0x1000_000C: the buttons
    LD      R14, R5
    SUB     R14, 4
    FBRA.NZ R14, ._io_result    ; another address: 0
    FIFO.STAT R11, R6           ; bit 0 nothing received, bit 1 busy
    NOT     R11
    AND     R11, 3
    FBRA    ._io_result
._io_receive:
    FIFO.TRYR R11, R6           ; R14 = 1 when a byte was received
    FBRA.NZ R14, ._io_result
    LD      R11, 0
    SUB     R11, 1              ; none: 0xFFFFFFFF
._io_board:
    ; 0xF000_0000 the LEDs, 0xF000_0004 the buttons: bit 2 of the address
    ; picks between them, as bit 2 of the offset (8 or 0xC) does
    LOAD32  R14, 0xF0000000
    AND     R5, 4
    OR      R14, R5
    LD32    R11, (R14)
._io_result:
    JUMP    _send_wb_tokens
