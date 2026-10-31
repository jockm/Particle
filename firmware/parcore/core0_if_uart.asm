; ==============================================================================
; Parcore Core 0: Stage 1 - Instruction Fetch & UART Gateway
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD32  R10, 0x00000500     ; R10 = Application Program Counter (PC)
    LOAD16  R1, 0               ; FIFO Ch0: FTDI Console UART
    LOAD16  R2, 1               ; FIFO Ch1: Core 1 (ID Stage)

_if_loop:
    ; Non-blocking polling of UART console
    FIFO.TRYR R3, R1
    BBRA.Z    R3, _fetch_inst
    ; Pass incoming host character/debug command into monitor queue...

_fetch_inst:
    LD16    R4, (R10++)         ; Fetch next 16-bit instruction word from Port A
    FIFO.W  R4, R2              ; Stream raw instruction packet to Core 1 (ID)
    FBRA    _if_loop

.org 0x00000140
_mbox_branch_redirect:          ; Vector 1: Triggered by Core 2 (EX)
    FAST_ENTER_TRAP
    ; Load resolved PC staged by Core 2
    LD      R10, R1             ; Update PC to branch target
    LOAD32  R5, 0xFFFFFFFF      ; Flush token
    FIFO.W  R5, R2              ; Notify Core 1 to drop speculatively queued ops
    FAST_EXIT_TRAP