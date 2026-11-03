#!/usr/bin/env bash
set -e

echo "==> 1. Correcting FIFO channel register indices in firmware/parcore/riscv/core0_if_uart.asm..."
cat << 'ASM_EOF' > firmware/parcore/riscv/core0_if_uart.asm
; ==============================================================================
; Parcore RV32IM_Zbb: Core 0 (Instruction Fetch & FTDI Console Gateway)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core0_if_uart.asm
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R10, 0x0500         ; Guest RV32 PC (Base at 0x00000500)
    LD      R0, 0               ; R0 = 0 (Channel 0: FTDI Console UART)
    LD      R1, 1               ; R1 = 1 (Channel 1: Core 1 ID Stage Queue)

; ==============================================================================
; Main Fetch Loop
; ==============================================================================
_if_main_loop:
    ; 1. Service UART RX (Non-Blocking Console Pass-Through on Channel 0)
    FIFO.TRYR R3, R0
    FBRA.Z    R3, ._fetch_instruction
    FIFO.W    R3, R0            ; Echo character back to UART TX (Channel 0)

._fetch_instruction:
    ; 2. Fetch 32-bit RV32 Instruction (Dual 16-bit Port A Reads)
    LD16    R4, (R10++)         ; inst[15:0]
    LD16    R5, (R10++)         ; inst[31:16]
    SHIFTL  R5, 16
    OR      R5, R4              ; Full 32-bit instruction word

    ; 3. Push Fetch Packet to ID Core via FIFO Channel 1 [PC, Instruction]
    SUB     R6, R10, 4          ; Base PC of current instruction
    FIFO.W  R6, R1              ; Outbound Word 0: PC (Channel 1)
    FIFO.W  R5, R1              ; Outbound Word 1: Instruction Word (Channel 1)

    LOAD16  R15, _if_main_loop
    JMP     R15, R0

; ==============================================================================
; Trap Vector 1: Branch Redirect / Flush from Core 2 (EX)
; Base: 0x00000100 + (1 << 6) = 0x00000140
; ==============================================================================
.org 0x00000140
_mbox_branch_redirect:
    FAST_ENTER_TRAP

    ; R14 carries resolved branch target PC staged by Core 2
    LD      R10, R14

    ; Inject 2-word flush packet into Core 1 to cancel speculative ops
    LOAD32  R6, 0xFFFFFFFF
    FIFO.W  R6, R1              ; Flush Token Marker: PC = -1 (Channel 1)
    FIFO.W  R6, R1              ; Placeholder Instruction Word (Channel 1)

    FAST_EXIT_TRAP
ASM_EOF

echo "==> 2. Re-assembling firmware..."
touch firmware/parcore/riscv/core0_if_uart.asm
make firmware

echo "==> 3. Running parcore_top_test.dart..."
cd hdl/parcore && dart test test/parcore_top_test.dart

