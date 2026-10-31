; ==============================================================================
; Parcore Core 1: Stage 2 - Instruction Decode & Register Scoreboard
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R1, 0               ; FIFO Ch0: Inbound from Core 0 (IF)
    LOAD16  R2, 1               ; FIFO Ch1: Outbound to Core 2 (EX)
    LOAD16  R3, 2               ; FIFO Ch2: Inbound Writeback from Core 4 (WB)

_id_loop:
    ; Drain writeback stream from Core 4 (WB) to update architectural registers
    FIFO.TRYR R4, R3
    BBRA.Z    R4, _read_if_stream
    ; Unpack (Rd, Value) from R4, update local R0-R15, and clear scoreboard lock

_read_if_stream:
    FIFO.R  R5, R1              ; Pop instruction word from IF
    LOAD32  R6, 0xFFFFFFFF      ; Check flush token
    SUB     R7, R5, R6
    BBRA.Z  R7, _id_loop        ; Flush pipeline bubble on branch misprediction

    ; Check data hazard scoreboard for source registers (Rr, Rl)
    ; If dependency is outstanding: wait until Core 4 (WB) clears lock
    
    ; Assemble decoded micro-op packet: [Opcode, RrVal, RlVal, RdIndex]
    FIFO.W  R8, R2              ; Dispatch to Core 2 (EX)
    FBRA    _id_loop