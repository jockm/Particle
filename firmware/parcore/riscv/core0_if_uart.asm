; ==============================================================================
; Parcore RV32IM_Zbb: Core 0 (Instruction Fetch & FTDI Console Gateway)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core0_if_uart.asm
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R10, 0x0500         ; Guest RV32 PC (Base at 0x00000500)
    LD      R1, 0               ; FIFO Ch0: FTDI Console UART
    LD      R2, 1               ; FIFO Ch1: Core 1 (ID Stage Queue)

; ==============================================================================
; Main Fetch Loop
; ==============================================================================
_if_main_loop:
    ; 1. Service UART RX (Non-Blocking Console Pass-Through on Channel 0)
    FIFO.TRYR R3, R1
    FBRA.Z    R3, _fetch_instruction
    FIFO.W    R3, R1            ; Echo character back to UART TX

_fetch_instruction:
    ; 2. Fetch 32-bit RV32 Instruction (Dual 16-bit Port A Reads)
    LD16    R4, (R10++)         ; inst[15:0]
    LD16    R5, (R10++)         ; inst[31:16]
    SHIFTL  R5, 16
    OR      R5, R4              ; Full 32-bit instruction word

    ; 3. Push Fetch Packet to ID Core via FIFO Channel 1 [PC, Instruction]
    SUB     R6, R10, 4          ; Base PC of current instruction
    FIFO.W  R6, R2              ; Outbound Word 0: PC
    FIFO.W  R5, R2              ; Outbound Word 1: Instruction Word

    LOAD16  R14, _if_main_loop
    JMP     R14, R0

; ==============================================================================
; Trap Vector 1: Branch Redirect / Flush from Core 2 (EX)
; ==============================================================================
.org 0x00000140
_mbox_branch_redirect:
    FAST_ENTER_TRAP

    ; R14 carries the branch target PC from Core 2 (or read from shared register)
    ; Update guest PC to target branch address
    LD      R10, R14

    ; Inject 2-word flush packet into Core 1 to cancel speculative ops
    LOAD32  R6, 0xFFFFFFFF
    FIFO.W  R6, R2              ; Flush Token Marker: PC = -1
    FIFO.W  R6, R2              ; Placeholder Instruction Word

    FAST_EXIT_TRAP
