; ==============================================================================
; Parcore RV32IM_Zbb: Core 3 (Memory Access, Sub-word Formatting & Writeback)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core3_mem.asm
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LD      R1, 0               ; FIFO Ch0: Inbound from Core 2 (EX)
    LD      R2, 1               ; FIFO Ch1: Outbound Writeback to Core 1 (ID: [Rd, Data])

; ==============================================================================
; Main Memory Pipeline Loop
; ==============================================================================
_mem_main_loop:
    FIFO.R  R10, R1             ; Word 0: Control Word [uop:8 | funct:8 | Rd:8 | flags:8]
    FIFO.R  R11, R1             ; Word 1: ALU Result
    FIFO.R  R12, R1             ; Word 2: Effective Memory Address
    FIFO.R  R13, R1             ; Word 3: Store Data (Rs2 Value)

    ; Test valid bit (bit 0)
    AND     R3, R10, 1
    FBRA.NZ R3, _process_mem_packet
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

_process_mem_packet:
    ; Extract Rd index: Control Word [15:8]
    SHIFTR  R4, R10, 8
    LOAD16  R5, 0x1F
    AND     R4, R5              ; R4 = Rd index

    ; Inspect Memory Operation Type: Control Word [19:16]
    SHIFTR  R3, R10, 16
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
    SUB     R6, R3, R5
    FBRA.NZ R6, _chk_sh
    LOAD16  R14, _do_sb
    JMP     R14, R0

_chk_sh:
    LOAD16  R5, 9
    SUB     R6, R3, R5
    FBRA.NZ R6, _chk_sw
    LOAD16  R14, _do_sh
    JMP     R14, R0

_chk_sw:
    LOAD16  R5, 10
    SUB     R6, R3, R5
    FBRA.NZ R6, _chk_loads
    LOAD16  R14, _do_sw
    JMP     R14, R0

_chk_loads:
    ; Check Loads (1: LB, 2: LH, 3: LW, 4: LBU, 5: LHU)
    SUB     R6, R3, 1
    FBRA.NZ R6, _chk_lh
    LOAD16  R14, _do_lb
    JMP     R14, R0

_chk_lh:
    SUB     R6, R3, 2
    FBRA.NZ R6, _chk_lw
    LOAD16  R14, _do_lh
    JMP     R14, R0

_chk_lw:
    SUB     R6, R3, 3
    FBRA.NZ R6, _chk_lbu
    LOAD16  R14, _do_lw
    JMP     R14, R0

_chk_lbu:
    SUB     R6, R3, 4
    FBRA.NZ R6, _chk_lhu
    LOAD16  R14, _do_lbu
    JMP     R14, R0

_chk_lhu:
    SUB     R6, R3, 5
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
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

_do_sh:
    ; Halfword store: ST16 to effective address
    ST16    (R12), R13
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

_do_sw:
    ; Word store: ST32 to effective address
    ST32    (R12), R13
    LOAD16  R14, _mem_main_loop
    JMP     R14, R0

; ==============================================================================
; Load Operations (LB, LH, LW, LBU, LHU)
; ==============================================================================
_do_lb:
    ; Signed byte load
    LD8     R11, (R12)
    SEXT8   R11, R11            ; Sign-extend byte to 32 bits
    LOAD16  R14, _emit_writeback
    JMP     R14, R0

_do_lh:
    ; Signed halfword load
    LD16    R11, (R12)
    SEXT16  R11, R11            ; Sign-extend halfword to 32 bits
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
