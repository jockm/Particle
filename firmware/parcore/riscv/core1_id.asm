; ==============================================================================
; Parcore RV32IM_Zbb: Core 1 (Instruction Decode & Register File Scoreboard)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core1_id.asm
; ==============================================================================
.include "lib/common.inc"

.define REG_BASE        0x0200  ; Local TCM address for x0..x31 (128 bytes)
.define SCOREBOARD_MASK 0x0280  ; Local TCM address for 32-bit in-flight mask

.org 0x00000100
_reset_vector:
    LD      R1, 0               ; FIFO Ch0: Inbound from Core 0 (IF)
    LD      R2, 1               ; FIFO Ch1: Outbound to Core 2 (EX)
    LD      R3, 2               ; FIFO Ch2: Inbound Writeback from Core 4 (WB)

    ; Clear local architectural register file (x0..x31)
    LOAD16  R4, REG_BASE
    LD      R5, 0               ; Zero value
    LOAD16  R6, 32              ; 32 registers
_init_rf_loop:
    LD32    (R4++), R5          ; Clear register word
    SUB     R6, 1
    BBRA.P  R6, _init_rf_loop

    ; Clear Scoreboard mask
    LOAD16  R4, SCOREBOARD_MASK
    LD32    (R4), R5

_id_main_loop:
    ; --------------------------------------------------------------------------
    ; 1. Service Retiring Writebacks from Core 4 (WB)
    ; --------------------------------------------------------------------------
    FIFO.TRYR R4, R3            ; Non-blocking check for retired Rd index
    FBRA.Z    R4, ._no_wb_drain ; If no packet (R4 == 0), skip writeback commit
    FIFO.R    R5, R3            ; Pop committed 32-bit writeback data

    ; Check if Rd == 0 (x0 is hardwired zero; skip write to TCM)
    FBRA.Z    R4, ._clear_scoreboard_bit

    ; Store into local architectural register table: REG_BASE + (Rd << 2)
    LOAD16  R6, REG_BASE
    SHIFTL  R7, R4, 2
    ADD     R6, R7
    LD32    (R6), R5            ; Commit to architectural register table

._clear_scoreboard_bit:
    ; Clear bit in scoreboard: mask &= ~(1 << Rd)
    LD      R7, 1
    SHIFTL  R7, R4              ; R7 = 1 << Rd
    NOT     R7, R7              ; R7 = ~(1 << Rd)
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R8, (R6)
    AND     R8, R7
    LD32    (R6), R8

._no_wb_drain:
    ; --------------------------------------------------------------------------
    ; 2. Pop Next Instruction Packet from Core 0 [PC, Inst]
    ; --------------------------------------------------------------------------
    FIFO.R  R10, R1             ; Pop PC
    LOAD32  R6, 0xFFFFFFFF      ; Check if Flush Token
    SUB     R7, R10, R6
    FBRA.Z  R7, ._drain_flush_token
    LOAD16  R14, ._not_flush_token
    JMP     R14, R0

._drain_flush_token:
    FIFO.R  R11, R1             ; Pop instruction placeholder
    LOAD16  R6, SCOREBOARD_MASK
    LD      R7, 0
    LD32    (R6), R7            ; Reset scoreboard on flush
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

._not_flush_token:
    FIFO.R  R11, R1             ; Pop Instruction Word

_decode_instruction:
    ; --------------------------------------------------------------------------
    ; 3. Field Extractions
    ; --------------------------------------------------------------------------
    ; Opcode = inst[6:0]
    LOAD16  R14, 0x7F
    AND     R12, R11, R14       ; R12 = Opcode

    ; Rd = inst[11:7]
    SHIFTR  R13, R11, 7
    LOAD16  R14, 0x1F
    AND     R13, R14            ; R13 = Rd

    ; funct3 = inst[14:12]
    SHIFTR  R14, R11, 12
    LD      R15, 0x07
    AND     R14, R15            ; R14 = funct3

    ; Rs1 = inst[19:15]
    SHIFTR  R15, R11, 15
    LOAD16  R7, 0x1F
    AND     R15, R7             ; R15 = Rs1

    ; Rs2 = inst[24:20]
    SHIFTR  R7, R11, 20
    LOAD16  R8, 0x1F
    AND     R7, R8              ; R7 = Rs2

    ; funct7 = inst[31:25]
    SHIFTR  R8, R11, 25         ; R8 = funct7

    ; --------------------------------------------------------------------------
    ; 4. Data Hazard Interlocking (Scoreboard Verification)
    ; --------------------------------------------------------------------------
_check_hazard:
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R9, (R6)            ; Load in-flight bitmask

    ; Test Rs1: (scoreboard & (1 << Rs1))
    LD      R6, 0
    FBRA.Z  R15, ._test_rs2
    LD      R6, 1
    SHIFTL  R6, R15
    AND     R6, R9
._test_rs2:
    LD      R5, 0
    FBRA.Z  R7, ._eval_stall
    LD      R5, 1
    SHIFTL  R5, R7
    AND     R5, R9
._eval_stall:
    OR      R6, R5
    FBRA.Z  R6, ._hazard_clear  ; Fall through or hop if hazard clear

    ; Stall detected: Wait for retiring writeback to clear reservation
    FIFO.R  R4, R3              ; Blocking wait for Rd from Core 4
    FIFO.R  R5, R3              ; Blocking wait for committed data

    FBRA.Z  R4, ._clear_stall_bit
    LOAD16  R6, REG_BASE
    SHIFTL  R7, R4, 2
    ADD     R6, R7
    LD32    (R6), R5
._clear_stall_bit:
    LD      R7, 1
    SHIFTL  R7, R4
    NOT     R7, R7
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R8, (R6)
    AND     R8, R7
    LD32    (R6), R8
    LOAD16  R14, _check_hazard
    JMP     R14, R0

._hazard_clear:
    ; --------------------------------------------------------------------------
    ; 5. Read Architectural Operands from Local Register File
    ; --------------------------------------------------------------------------
    ; Read OpA (Rs1)
    LD      R5, 0               ; x0 is always 0
    FBRA.Z  R15, ._read_rs2
    LOAD16  R6, REG_BASE
    SHIFTL  R9, R15, 2
    ADD     R6, R9
    LD32    R5, (R6)            ; R5 = Rs1 Value

._read_rs2:
    ; Read OpB (Rs2)
    LD      R6, 0               ; x0 is always 0
    FBRA.Z  R7, ._decode_immed
    LOAD16  R8, REG_BASE
    SHIFTL  R9, R7, 2
    ADD     R8, R9
    LD32    R6, (R8)            ; R6 = Rs2 Value

    ; --------------------------------------------------------------------------
    ; 6. Immediate Field Decoders & Direct Opcode Jumps
    ; --------------------------------------------------------------------------
._decode_immed:
    ASHIFTR R9, R11, 20         ; Default R9 = I-Immediate

    ; Test Opcode: 0x13 (OP-IMM)
    LOAD16  R14, 0x13
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_op_imm

    ; Test Opcode: 0x33 (OP)
    LOAD16  R14, 0x33
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_op_reg

    ; Test Opcode: 0x03 (LOAD)
    LOAD16  R14, 0x03
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_load

    ; Test Opcode: 0x23 (STORE)
    LOAD16  R14, 0x23
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_store

    ; Test Opcode: 0x63 (BRANCH)
    LOAD16  R14, 0x63
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_branch

    ; Test Opcode: 0x37 (LUI)
    LOAD16  R14, 0x37
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_lui

    ; Test Opcode: 0x17 (AUIPC)
    LOAD16  R14, 0x17
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_auipc

    ; Test Opcode: 0x6F (JAL)
    LOAD16  R14, 0x6F
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_jal

    ; Test Opcode: 0x67 (JALR)
    LOAD16  R14, 0x67
    SUB     R4, R12, R14
    FBRA.Z  R4, ._go_jalr

    ; Drop unhandled instructions
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

._go_op_imm:
    LOAD16  R14, _emit_op_imm
    JMP     R14, R0
._go_op_reg:
    LOAD16  R14, _emit_op_reg
    JMP     R14, R0
._go_load:
    LOAD16  R14, _emit_load
    JMP     R14, R0
._go_store:
    LOAD16  R14, _emit_store
    JMP     R14, R0
._go_branch:
    LOAD16  R14, _emit_branch
    JMP     R14, R0
._go_lui:
    LOAD16  R14, _emit_lui
    JMP     R14, R0
._go_auipc:
    LOAD16  R14, _emit_auipc
    JMP     R14, R0
._go_jal:
    LOAD16  R14, _emit_jal
    JMP     R14, R0
._go_jalr:
    LOAD16  R14, _emit_jalr
    JMP     R14, R0

    ; --------------------------------------------------------------------------
    ; 7. Micro-Op Assembly & Dispatch Handlers
    ; --------------------------------------------------------------------------
_emit_op_imm:
    SHIFTL  R4, R14, 24
    SHIFTL  R8, R13, 8          ; Insert Rd
    OR      R4, R8
    OR      R4, 1               ; Valid bit

_dispatch_packet:
    FBRA.Z  R13, ._push_to_ex
    LOAD16  R7, SCOREBOARD_MASK
    LD32    R8, (R7)
    LD      R14, 1
    SHIFTL  R14, R13
    OR      R8, R14
    LD32    (R7), R8

._push_to_ex:
    FIFO.W  R4, R2              ; Word 0: Control Word
    FIFO.W  R5, R2              ; Word 1: Operand A
    FIFO.W  R9, R2              ; Word 2: Operand B
    FIFO.W  R10, R2             ; Word 3: PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_op_reg:
    LD      R4, 0
    SUB     R7, R8, 1
    FBRA.Z  R7, ._m_op
    LD      R4, R14
    LOAD16  R14, 0x20
    AND     R7, R8, R14
    FBRA.Z  R7, ._pack_reg_ctrl
    LOAD16  R14, 0x10
    OR      R4, R14
    LOAD16  R14, ._pack_reg_ctrl
    JMP     R14, R0
._m_op:
    LOAD16  R4, 0x20
    OR      R4, R14
._pack_reg_ctrl:
    SHIFTL  R4, 24
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LD      R9, R6              ; OpB = Rs2 Value
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_load:
    ADD     R4, R14, 1
    SHIFTL  R4, 16
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_store:
    ASHIFTR R4, R11, 25
    SHIFTL  R4, 5
    OR      R4, R13             ; S-Immediate
    ADD     R7, R14, 8
    SHIFTL  R7, 16
    OR      R7, 1
    FIFO.W  R7, R2
    FIFO.W  R5, R2              ; Rs1
    FIFO.W  R4, R2              ; Offset
    FIFO.W  R6, R2              ; Store data (Rs2)
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_branch:
    ASHIFTR R4, R11, 31
    SHIFTL  R4, 12
    SHIFTR  R7, R11, 7
    AND     R7, 1
    SHIFTL  R7, 11
    OR      R4, R7
    SHIFTR  R7, R11, 25
    LOAD16  R14, 0x3F
    AND     R7, R14
    SHIFTL  R7, 5
    OR      R4, R7
    SHIFTR  R7, R11, 8
    LD      R14, 0x0F
    AND     R7, R14
    SHIFTL  R7, 1
    OR      R4, R7
    ADD     R7, R14, 1
    SHIFTL  R7, 20
    OR      R7, 1
    FIFO.W  R7, R2
    FIFO.W  R5, R2
    FIFO.W  R6, R2
    FIFO.W  R4, R2
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_lui:
    LOAD32  R7, 0xFFFFF000
    AND     R9, R11, R7
    LOAD16  R4, 0x30
    SHIFTL  R4, 24
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LD      R5, 0
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_auipc:
    LOAD32  R7, 0xFFFFF000
    AND     R9, R11, R7
    LOAD16  R4, 0x31
    SHIFTL  R4, 24
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LD      R5, R10
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_jal:
    ASHIFTR R4, R11, 31
    SHIFTL  R4, 20
    LOAD32  R7, 0x000FF000
    AND     R8, R11, R7
    OR      R4, R8
    SHIFTR  R7, R11, 20
    AND     R7, 1
    SHIFTL  R7, 11
    OR      R4, R7
    SHIFTR  R7, R11, 21
    LOAD16  R14, 0x03FF
    AND     R7, R14
    SHIFTL  R7, 1
    OR      R4, R7
    LOAD16  R7, 0x09
    SHIFTL  R7, 20
    SHIFTL  R8, R13, 8
    OR      R7, R8
    OR      R7, 1
    FIFO.W  R7, R2
    FIFO.W  R10, R2
    FIFO.W  R4, R2
    FIFO.W  R10, R2
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_jalr:
    LOAD16  R7, 0x0A
    SHIFTL  R7, 20
    SHIFTL  R8, R13, 8
    OR      R7, R8
    OR      R7, 1
    FIFO.W  R7, R2
    FIFO.W  R5, R2
    FIFO.W  R9, R2
    FIFO.W  R10, R2
    LOAD16  R14, _id_main_loop
    JMP     R14, R0