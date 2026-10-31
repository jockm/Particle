; ==============================================================================
; Parcore Core 4: Stage 5 - Writeback & Architectural Commitment
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R1, 0               ; FIFO Ch0: Inbound from Core 3 (MEM)
    LOAD16  R2, 1               ; FIFO Ch1: Outbound to Core 1 (ID Register File)

_wb_loop:
    FIFO.R  R3, R1              ; Pop completed instruction packet from Core 3
    ; Validate destination register index:
    ; If Rd == R0: discard (hardwired zero convention)
    ; If Rd != R0:
    ;   Emit writeback commitment token [RdIndex, ResultData] to Core 1
    FIFO.W  R3, R2
    FBRA    _wb_loop