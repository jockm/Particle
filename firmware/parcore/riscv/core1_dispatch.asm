; ==============================================================================
; Parcore Heterogeneous Emulation: Core 1 (Dispatch & Branch Execution Engine)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core1_dispatch.asm
; ==============================================================================
.include "lib/common.inc"

; ------------------------------------------------------------------------------
; Token Formats (Streamed over FIFO Ch 0 from Core 0)
; Header Packet: [Opcode: 8-bit | Rd: 8-bit | Rs1: 8-bit | Rs2: 8-bit]
; Payload 1:     Immediate / Target Offset (32-bit)
; Payload 2:     Current Guest PC (32-bit)
; ------------------------------------------------------------------------------
.define OP_BEQ          0x01
.define OP_BNE          0x02
.define OP_BLT          0x03
.define OP_BGE          0x04
.define OP_BLTU         0x05
.define OP_BGEU         0x06
.define OP_JAL          0x07
.define OP_JALR         0x08

.org 0x00000100
_reset_vector:
    ; Channel 0: Core 0 -> Core 1 Token Stream
    LD      R1, 0               ; FIFO Channel 0

_dispatch_loop:
    ; Wait for incoming branch/flow micro-op header packet from Core 0
    FIFO.R  R2, 0               ; R2 = [Opcode:31..24, Rd:23..16, Rs1:15..8, Rs2:7..0]

    ; Unpack Opcode (Bits 31..24)
    LD      R3, R2
    SHIFTR  R3, 12
    SHIFTR  R3, 12          ; R3 = Branch Opcode

    ; Unpack Rd (Bits 23..16)
    LD      R4, R2
    SHIFTR  R4, 8
    SHIFTR  R4, 8
    LOAD16  R14, 0xFF
    AND     R4, R14              ; R4 = Rd index

    ; Unpack Rs1 (Bits 15..8)
    LD      R5, R2
    SHIFTR  R5, 8
    LOAD16  R14, 0xFF
    AND     R5, R14              ; R5 = Rs1 index / value

    ; Unpack Rs2 (Bits 7..0)
    LD      R6, R2
    LOAD16  R14, 0xFF
    AND     R6, R14              ; R6 = Rs2 index / value

    ; Pop Payload 1 (Immediate / Offset)
    FIFO.R  R7, 0               ; R7 = Imm32 / Offset

    ; Pop Payload 2 (Current Guest PC)
    FIFO.R  R8, 0               ; R8 = Current Guest PC

    ; Route via Opcode Table Jump
    ; Opcode 1..8 mapped to dispatch table
    LD      R9, R3
    SUB     R9, 1
    LOAD16  R14, _op_table
    JTBL    R9

_op_table:
    FBRA    _exec_beq           ; 1: BEQ
    FBRA    _exec_bne           ; 2: BNE
    FBRA    _exec_blt           ; 3: BLT (Signed)
    FBRA    _exec_bge           ; 4: BGE (Signed)
    FBRA    _exec_bltu          ; 5: BLTU (Unsigned)
    FBRA    _exec_bgeu          ; 6: BGEU (Unsigned)
    FBRA    _exec_jal           ; 7: JAL
    FBRA    _exec_jalr          ; 8: JALR

; ------------------------------------------------------------------------------
; Branch Condition Handlers
; ------------------------------------------------------------------------------
_exec_beq:
    LD      R14, R5
    SUB     R14, R6
    FBRA.Z  R14, _branch_taken
    BBRA    _dispatch_loop

_exec_bne:
    LD      R14, R5
    SUB     R14, R6
    FBRA.NZ R14, _branch_taken
    BBRA    _dispatch_loop

_exec_blt:
    LD      R14, R5
    SSLT    R14, R6         ; R14 = (Rs1 < Rs2) signed
    FBRA.NZ R14, _branch_taken
    BBRA    _dispatch_loop

_exec_bge:
    LD      R14, R5
    SSLT    R14, R6
    FBRA.Z  R14, _branch_taken  ; Taken if !(Rs1 < Rs2)
    BBRA    _dispatch_loop

_exec_bltu:
    LD      R14, R5
    SLT     R14, R6         ; R14 = (Rs1 < Rs2) unsigned
    FBRA.NZ R14, _branch_taken
    BBRA    _dispatch_loop

_exec_bgeu:
    LD      R14, R5
    SLT     R14, R6
    FBRA.Z  R14, _branch_taken  ; Taken if !(Rs1 < Rs2)
    BBRA    _dispatch_loop

; ------------------------------------------------------------------------------
; Branch Taken Handler: Compute Target & Notify Core 0 via MBOX
; ------------------------------------------------------------------------------
_branch_taken:
    LD      R11, R8
    ADD     R11, R7         ; Target PC = Current PC + Imm Offset
    FIFO.W  R11, 1              ; Stream resolved PC back to Core 0
    MBOX    R11, 1              ; Strobe Core 0 with Trap Vector 1 (Branch Redirect)
    BBRA    _dispatch_loop

; ------------------------------------------------------------------------------
; Jump & Link Handlers
; ------------------------------------------------------------------------------
_exec_jal:
    LD      R10, R8
    ADD     R10, 4          ; Link register Rd = PC + 4
    FIFO.W  R10, 1              ; Commit writeback
    LD      R11, R8
    ADD     R11, R7         ; Target PC = Current PC + Imm Offset
    MBOX    R11, 1              ; Redirect Core 0
    BBRA    _dispatch_loop

_exec_jalr:
    LD      R10, R8
    ADD     R10, 4          ; Link register Rd = PC + 4
    FIFO.W  R10, 1
    LD      R11, R5
    ADD     R11, R7
    LOAD32  R14, 0xFFFFFFFE
    AND     R11, R14
    MBOX    R11, 1              ; Redirect Core 0
    BBRA    _dispatch_loop
