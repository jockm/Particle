; ==============================================================================
; Parcore RV32IM_Zbb: Core 3 (Memory Access, Sub-word Formatting & Writeback)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core3_mem.asm
; ==============================================================================
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
    LD      R1, 0               ; FIFO Ch0: Inbound from Core 2 (EX)
    LD      R2, 1               ; FIFO Ch1: Outbound WB to Core 1 (memToWb)
    LD      R7, 2               ; FIFO Ch2: Outbound store mirror to Core 0 (memToIf)

; ==============================================================================
; Main Memory Pipeline Loop
; ==============================================================================
_mem_main_loop:
    FIFO.R  R10, R1             ; Word 0: Control Word [uop:8 | funct:8 | Rd:8 | flags:8]
    FIFO.R  R11, R1             ; Word 1: ALU Result
    FIFO.R  R12, R1             ; Word 2: Effective Memory Address
    FIFO.R  R13, R1             ; Word 3: Store Data (Rs2 Value)

    ; Test valid bit (bit 0)
    LD      R3, R10
    AND     R3, 1
    FBRA.NZ R3, _process_mem_packet
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

_process_mem_packet:
    ; Extract Rd index: Control Word [15:8]
    LD      R4, R10
    SHIFTR  R4, 8
    LOAD16  R5, 0x1F
    AND     R4, R5              ; R4 = Rd index

    ; A cancel from core 2 (flags bit 2): core 1 gets Rd + 0x20, which takes
    ; the register off its in-flight count without writing it
    LD      R14, R10
    AND     R14, 4
    FBRA.Z  R14, ._not_cancel
    LOAD16  R5, 0x20
    OR      R4, R5
    LOAD16  R14, _send_wb_tokens
    JMP     R14, R0
._not_cancel:

    ; Inspect Memory Operation Type: Control Word [19:16]
    LD      R3, R10
    SHIFTR  R3, 12
    SHIFTR  R3, 4
    LD      R5, 0x0F
    AND     R3, R5
    FBRA.Z  R3, _route_alu_wb   ; Non-memory instruction -> direct writeback
    LOAD16  R14, _dispatch_mem_op
    JMP     R14, R0

_route_alu_wb:
    ; Non-memory ALU result -> writeback to Core 1
    LOAD16  R14, _emit_writeback
    JMP     R14, R0

; ==============================================================================
; Memory Operation Dispatch
; 1..5: Loads  (1: LB, 2: LH, 3: LW, 4: LBU, 5: LHU)
; 8..10: Stores (8: SB, 9: SH, 10: SW)
; ==============================================================================
_dispatch_mem_op:
    ; Check Stores (8..10)
    LOAD16  R5, 8
    LD      R6, R3
    SUB     R6, R5
    FBRA.NZ R6, _chk_sh
    LOAD16  R14, _do_sb
    JMP     R14, R0

_chk_sh:
    LOAD16  R5, 9
    LD      R6, R3
    SUB     R6, R5
    FBRA.NZ R6, _chk_sw
    LOAD16  R14, _do_sh
    JMP     R14, R0

_chk_sw:
    LOAD16  R5, 10
    LD      R6, R3
    SUB     R6, R5
    FBRA.NZ R6, _chk_fence_i
    LOAD16  R14, _do_sw
    JMP     R14, R0

_chk_fence_i:
    ; 11: FENCE.I. No writeback (core 1 counts no destination for it).
    LOAD16  R5, 11
    LD      R6, R3
    SUB     R6, R5
    FBRA.NZ R6, _chk_loads
    LOAD16  R9, MIRROR_MARKER
    LOAD16  R14, _mirror_push
    JMP     R14, R0

_chk_loads:
    ; Check Loads (1: LB, 2: LH, 3: LW, 4: LBU, 5: LHU)
    LD      R6, R3
    SUB     R6, 1
    FBRA.NZ R6, _chk_lh
    LOAD16  R14, _do_lb
    JMP     R14, R0

_chk_lh:
    LD      R6, R3
    SUB     R6, 2
    FBRA.NZ R6, _chk_lw
    LOAD16  R14, _do_lh
    JMP     R14, R0

_chk_lw:
    LD      R6, R3
    SUB     R6, 3
    FBRA.NZ R6, _chk_lbu
    LOAD16  R14, _do_lw
    JMP     R14, R0

_chk_lbu:
    LD      R6, R3
    SUB     R6, 4
    FBRA.NZ R6, _chk_lhu
    LOAD16  R14, _do_lbu
    JMP     R14, R0

_chk_lhu:
    LD      R6, R3
    SUB     R6, 5
    FBRA.NZ R6, _mem_drop
    LOAD16  R14, _do_lhu
    JMP     R14, R0

_mem_drop:
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

; ==============================================================================
; Store Operations (SB, SH, SW) - No Writeback Produced
; ==============================================================================
_do_sb:
    ; Byte store: ST8 to effective address
    ST8     (R12), R13
    LOAD16  R8, MIRROR_BYTE
    LOAD16  R14, _mirror_store
    JMP     R14, R0

_do_sh:
    ; Halfword store: ST16 to effective address
    ST16    (R12), R13
    LOAD16  R8, MIRROR_HALF
    LOAD16  R14, _mirror_store
    JMP     R14, R0

_do_sw:
    ; Word store: ST32 to effective address. Mirrored as two halfwords: the
    ; low one here, the high one at address + 2 by _mirror_store.
    ST32    (R12), R13
    LOAD16  R8, MIRROR_HALF
    OR      R8, 1               ; bit 0: a word store
    LOAD16  R14, _mirror_store
    JMP     R14, R0

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
    LOAD16  R14, _mirror_push
    JMP     R14, R0
._outside:
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

; Push the entry in R9 once memToIf has room, then go back to the main loop
_mirror_push:
    LOAD16  R5, _mirror_wait
    JMP     R5, R15
    FIFO.W  R9, R7
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

; Wait while memToIf holds 128 words or more (core 0 drains it); returns to
; the address in R15
_mirror_wait:
    FIFO.STAT R6, R7
    SHIFTR  R6, 15              ; depth[7]
    BBRA.NZ R6, _mirror_wait
    JMP     R15, R0

; ==============================================================================
; Load Operations (LB, LH, LW, LBU, LHU)
; ==============================================================================
_do_lb:
    ; Signed byte load
    LD8     R11, (R12)
    LOAD16  R5, 24
    SHIFTL  R11, R5
    ASHIFTR R11, R5        ; Sign-extend byte to 32 bits
    LOAD16  R14, _emit_writeback
    JMP     R14, R0

_do_lh:
    ; Signed halfword load
    LD16    R11, (R12)
    LOAD16  R5, 16
    SHIFTL  R11, R5
    ASHIFTR R11, R5        ; Sign-extend halfword to 32 bits
    LOAD16  R14, _emit_writeback
    JMP     R14, R0

_do_lw:
    ; Word load
    LD32    R11, (R12)
    LOAD16  R14, _emit_writeback
    JMP     R14, R0

_do_lbu:
    ; Unsigned byte load
    LD8     R11, (R12)
    LOAD16  R5, 0xFF
    AND     R11, R5             ; Zero-extend byte
    LOAD16  R14, _emit_writeback
    JMP     R14, R0

_do_lhu:
    ; Unsigned halfword load
    LD16    R11, (R12)
    LOAD16  R5, 0xFFFF
    AND     R11, R5             ; Zero-extend halfword
    LOAD16  R14, _emit_writeback
    JMP     R14, R0

; ==============================================================================
; Writeback Outbound Section
; ==============================================================================
_emit_writeback:
    ; Only emit writeback packet if Rd != 0 (x0 writes are discarded)
    FBRA.NZ R4, _send_wb_tokens
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

_send_wb_tokens:
    FIFO.W  R4, R2              ; Token 0: Destination Register Rd
    FIFO.W  R11, R2             ; Token 1: 32-bit Committed Data
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0
