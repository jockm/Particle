; ==============================================================================
; Parcore Core 2: Stage 3 - Execution, ALU, DSP Math & Branch Resolution
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R1, 0               ; FIFO Ch0: Inbound from Core 1 (ID)
    LOAD16  R2, 1               ; FIFO Ch1: Outbound to Core 3 (MEM)

_ex_loop:
    FIFO.R  R3, R1              ; Pop decoded micro-op from Core 1
    ; Execute operation:
    ; - ALU / Bitwise / Shift (ADD, SUB, NOT, NEZ, SHIFTL)
    ; - Single-cycle DSP Multiplier (MULL, MULH, SMULH)
    ; - Multi-cycle Divider (DIV, MOD)

    ; If branch/jump instruction, evaluate condition:
    ; On taken branch:
    ;   MBOX R14, 0             ; Strobe Core 0 (IF) with branch target PC

    ; Pack EX result packet: [MemOpcode, TargetAddr, StoreData, RdIndex, AluResult]
    FIFO.W  R4, R2              ; Stream to Core 3 (MEM)
    FBRA    _ex_loop