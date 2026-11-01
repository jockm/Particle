; ==============================================================================
; Parcore RV32IM_Zbb: Core 0 (Instruction Fetch & FTDI Console Gateway)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core0_if_uart.asm
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R10, 0x0500         ; R10 = Guest RV32 Program Counter
    LD      R1, 0               ; FIFO Ch0: Console UART
    LD      R2, 1               ; FIFO Ch1: Core 1 (ID Stage Queue)

_if_main_loop:
    ; 1. Service UART RX (Non-Blocking Console Pass-Through)
    FIFO.TRYR R3, R1
    FBRA.Z    R3, _fetch_inst   ; Jump forward if no serial byte available
    FIFO.W    R3, R1            ; Echo character back to UART TX

_fetch_inst:
    ; 2. Fetch 32-bit Instruction (Dual 16-bit Port A BRAM Reads)
    LD16    R4, (R10++)         ; inst[15:0]
    LD16    R5, (R10++)         ; inst[31:16]
    SHIFTL  R5, 16
    OR      R5, R4              ; Full 32-bit RV32 instruction

    ; 3. Push Fetch Packet to ID Core [PC, Instruction]
    SUB     R6, R10, 4
    FIFO.W  R6, R2              ; Outbound Word 0: PC
    FIFO.W  R5, R2              ; Outbound Word 1: Instruction Word
    BBRA    _if_main_loop       ; Loop backward to _if_main_loop

; ==============================================================================
; Trap Vector 1: Branch Redirect / Flush from Core 2 (EX)
; ==============================================================================
.org 0x00000140
_mbox_branch_redirect:
    FAST_ENTER_TRAP
    LD      R10, R1             ; Update PC to target address

    ; Flush Token to Core 1
    LOAD32  R6, 0xFFFFFFFF
    FIFO.W  R6, R2
    FIFO.W  R6, R2
    FAST_EXIT_TRAP