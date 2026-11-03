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
    SHIFTR  R3, R2, 24          ; R3 = Branch Opcode

    ; Unpack Rd (Bits 23..16)
    SHIFTR  R4, R2, 16
    AND     R4, 0xFF            ; R4 = Rd index

    ; Unpack Rs1 (Bits 15..8)
    SHIFTR  R5, R2, 8
    AND     R5, 0xFF            ; R5 = Rs1 index

    ; Unpack Rs2 (Bits 7..0)
    AND     R6, R2, 0xFF        ; R6 = Rs2 index

    ; Pop Payload 1 (Immediate / Offset)
    FIFO.R  R7, 0               ; R7 = Imm32 / Offset

    ; Pop Payload 2 (Current Guest PC)
    FIFO.R  R8, 0               ; R8 = Current Guest PC

    ; Route via Opcode Table Jump
    SUB     R9, R3, 1
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
; Branch Condition Handlers (Evaluate into R14 for wide 8-bit branch reach)
; ------------------------------------------------------------------------------
_exec_beq:
    SUB     R14, R5, R6
    FBRA.Z  R14, _branch_taken
    BBRA    _dispatch_loop

_exec_bne:
    SUB     R14, R5, R6
    FBRA.NZ R14, _branch_taken
    BBRA    _dispatch_loop

_exec_blt:
    SSLT    R14, R5, R6         ; R14 = (Rs1 < Rs2) signed
    FBRA.NZ R14, _branch_taken
    BBRA    _dispatch_loop

_exec_bge:
    SSLT    R14, R5, R6
    FBRA.Z  R14, _branch_taken  ; Taken if !(Rs1 < Rs2)
    BBRA    _dispatch_loop

_exec_bltu:
    SLT     R14, R5, R6         ; R14 = (Rs1 < Rs2) unsigned
    FBRA.NZ R14, _branch_taken
    BBRA    _dispatch_loop

_exec_bgeu:
    SLT     R14, R5, R6
    FBRA.Z  R14, _branch_taken  ; Taken if !(Rs1 < Rs2)
    BBRA    _dispatch_loop

; ------------------------------------------------------------------------------
; Branch Taken Handler: Compute Target & Notify Core 0 via MBOX
; ------------------------------------------------------------------------------
_branch_taken:
    ADD     R11, R8, R7         ; Target PC = Current PC + Imm Offset
    FIFO.W  R11, 1              ; Stream resolved PC back to Core 0
    MBOX    R11, 1              ; Strobe Core 0 with Trap Vector 1 (Branch Redirect)
    BBRA    _dispatch_loop

; ------------------------------------------------------------------------------
; Jump & Link Handlers
; ------------------------------------------------------------------------------
_exec_jal:
    ADD     R10, R8, 4          ; Link register Rd = PC + 4
    FIFO.W  R10, 1              ; Commit writeback
    ADD     R11, R8, R7         ; Target PC = Current PC + Imm Offset
    MBOX    R11, 1              ; Redirect Core 0
    BBRA    _dispatch_loop

_exec_jalr:
    ADD     R10, R8, 4          ; Link register Rd = PC + 4
    FIFO.W  R10, 1
    ADD     R11, R5, R7         ; Target PC = (Rs1 + Imm) & ~1
    AND     R11, 0xFFFFFFFE
    MBOX    R11, 1              ; Redirect Core 0
    BBRA    _dispatch_loop
