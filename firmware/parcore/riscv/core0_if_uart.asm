; ==============================================================================
; Parcore RV32IM: Core 0 (Instruction Fetch & FTDI Console Gateway)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core0_if_uart.asm
; ==============================================================================
.include "lib/vectors.inc"

    RESET_SLOT _reset_vector
    TRAP_SLOT_BRANCH 1, _branch_redirect_handler
    TRAP_SLOT_UNEXPECTED 2
    TRAP_SLOT_UNEXPECTED 3
    TRAP_SLOT_UNEXPECTED 4
    TRAP_SLOT_UNEXPECTED 5
    TRAP_SLOT_UNEXPECTED 6
    TRAP_SLOT_UNEXPECTED 7
    TRAP_SLOT_UNEXPECTED 8
    TRAP_SLOT_UNEXPECTED 9
    TRAP_SLOT_UNEXPECTED 10
    TRAP_SLOT_UNEXPECTED 11
    TRAP_SLOT_UNEXPECTED 12
    TRAP_SLOT_UNEXPECTED 13
    TRAP_SLOT_UNEXPECTED 14
    TRAP_SLOT_UNEXPECTED 15
    UNEXPECTED_TRAP_ROUTINE

_reset_vector:
    LOAD16  R10, 0x0500         ; Guest RV32 PC (Base at 0x00000500)
    ; LD      R0, 0               ; R0 = 0 (Channel 0: FTDI Console UART)
    LD      R1, 1               ; R1 = 1 (Channel 1: Core 1 ID Stage Queue)
    LD      R9, 0               ; R9 = epoch, sent in PC bit 0; flips on every redirect

; ==============================================================================
; Main Fetch & Console Loop
; ==============================================================================
_if_main_loop:
    ; 1. Service UART RX (Non-Blocking Console Pass-Through on Channel 0)
    FIFO.TRYR R3, R0            ; R14 = 1 if a byte was read into R3
    FBRA.Z    R14, ._check_fifo_space

    ; Character received: Echo character back to UART TX (Channel 0)
    FIFO.W    R3, R0
    BBRA      _if_main_loop     ; Immediately loop back to keep console responsive

._check_fifo_space:
    ; Ensure ifToId FIFO (Channel 1) is not full/near-full before pushing 2 words
    FIFO.STAT R4, R1
    LD        R7, R4
    AND       R7, 2             ; Bit 1: full flag
    BBRA.NZ   R7, _if_main_loop
    SHIFTR    R4, 15            ; Check if depth[7] (depth >= 128 words) is set
    BBRA.NZ   R4, _if_main_loop

._fetch_instruction:
    ; 2. Fetch 32-bit RV32 Instruction via Port B Word Read
    LD32    R5, (R10)           ; Load full 32-bit instruction into R5

    ; If instruction word is 0 (end of guest code / uninitialized), skip pushing
    FBRA.Z  R5, ._loop_back

    ; 3. Push Fetch Packet to ID Core via FIFO Channel 1 [PC, Instruction]
    LD      R6, R10             ; Original instruction PC
    OR      R6, R9              ; with the epoch in bit 0
    ADD     R10, 4              ; Advance PC pointer
    FIFO.W  R6, R1              ; Word 0: PC
    FIFO.W  R5, R1              ; Word 1: Instruction Word

._loop_back:
    BBRA    _if_main_loop

; ==============================================================================
; Trap 1: Core 2 (EX) Branch Redirection & Pipeline Flush Handler
; Core 2's MBOX lands at vector 1; its slot branches here
; ==============================================================================
_branch_redirect_handler:
    LOAD16  R14, MBOX_VALUE
    LD32    R10, (R14)          ; Set primary PC pointer to redirect target
    LD      R7, 1
    XOR     R9, R7              ; New epoch: core 2 drops what was sent before
    BBRA    _if_main_loop
