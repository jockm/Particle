; ==============================================================================
; Parcore Core 3: Stage 4 - Memory Access & MMIO Router
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R1, 0               ; FIFO Ch0: Inbound from Core 2 (EX)
    LOAD16  R2, 1               ; FIFO Ch1: Outbound to Core 4 (WB)

_mem_loop:
    FIFO.R  R3, R1              ; Pop EX packet from Core 2
    ; If non-memory instruction: bypass directly to WB
    ; If LD8/16/32 or ST8/16/32:
    ;   - Verify 2-byte/4-byte alignment
    ;   - Issue memory request to Core 5 (Cache Controller) via Port B MMIO
    ;   - Await read data or store acknowledgment

    ; Pack WB packet: [RdIndex, FinalResultValue]
    FIFO.W  R4, R2              ; Stream to Core 4 (WB)
    FBRA    _mem_loop