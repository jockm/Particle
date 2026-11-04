; ==============================================================================
; Parcore RV32IM_Zbb: Core 1 (Instruction Decode & Register File Scoreboard)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core1_id.asm
; ==============================================================================
.include "lib/common.inc"

.define REG_BASE        0x0600  ; Local TCM base for x0..x31 (32 words = 128 bytes)
.define SCOREBOARD_MASK 0x0680  ; Local TCM address for 32-bit in-flight bitmask

.org 0x00000100
_reset_vector:
    LD      R1, 0               ; FIFO Ch0: Inbound from Core 0 (IF: [PC, Inst])
    LD      R2, 1               ; FIFO Ch1: Outbound to Core 2 (EX: [Ctrl, OpA, OpB, PC])
    LD      R3, 2               ; FIFO Ch2: Inbound Writeback from Core 4/MEM (WB: [Rd, Data])

    ; --------------------------------------------------------------------------
    ; Initialize Architectural Register File (x0..x31 = 0)
    ; --------------------------------------------------------------------------
    LOAD16  R4, REG_BASE
    LD      R5, 0               ; Zero value
    LOAD16  R6, 32              ; 32 registers
_init_rf_loop:
    LD32    (R4++), R5          ; Clear register word
    SUB     R6, 1
    BBRA.NZ R6, _init_rf_loop

    ; Clear Scoreboard mask (no registers in flight)
    LOAD16  R4, SCOREBOARD_MASK
    LD32    (R4), R5

; ==============================================================================
; Main Decode Pipeline Loop
; ==============================================================================
_id_main_loop:
    ; --------------------------------------------------------------------------
    ; 1. Service Retiring Writebacks (Non-blocking check)
    ; --------------------------------------------------------------------------
    FIFO.TRYR R4, R3            ; Try to read Rd index from WB FIFO (Channel 2: memToWb)
    FBRA.NZ   R4, _handle_wb_commit
    LOAD16    R14, _poll_fetch_queue
    JMP       R14, R0

_handle_wb_commit:
    FIFO.R    R5, 2             ; Read committed 32-bit writeback data

    ; Check if Rd == 0 (x0 is hardwired zero; discard commit)
    FBRA.Z    R4, _clear_wb_scoreboard

    ; Commit to local architectural register: REG_BASE + (Rd << 2)
    LOAD16  R6, REG_BASE
    SHIFTL  R7, R4, 2
    ADD     R6, R7
    ST32    (R6), R5            ; Store committed value

_clear_wb_scoreboard:
    ; Clear bit in scoreboard: mask &= ~(1 << Rd)
    LD      R7, 1
    SHIFTL  R7, R4              ; R7 = 1 << Rd
    NOT     R7, R7              ; R7 = ~(1 << Rd)
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R8, (R6)
    AND     R8, R7
    ST32    (R6), R8

_poll_fetch_queue:
    ; --------------------------------------------------------------------------
    ; 2. Pop Next Instruction Packet from Core 0 [PC, Inst]
    ; --------------------------------------------------------------------------
    FIFO.R  R10, R1             ; Pop PC
    LOAD32  R6, 0xFFFFFFFF      ; Check for pipeline flush sentinel (-1)
    SUB     R7, R10, R6
    FBRA.Z  R7, _drain_flush_token

    FIFO.R  R11, R1             ; Pop Instruction Word
    LOAD16  R14, _decode_fields
    JMP     R14, R0

_drain_flush_token:
    FIFO.R  R11, R1             ; Discard instruction word
    ; Pipeline bubble: clear scoreboard mask on flush
    LOAD16  R6, SCOREBOARD_MASK
    LD      R7, 0
    ST32    (R6), R7
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_decode_fields:
    ; --------------------------------------------------------------------------
    ; 3. Bitfield Extractions
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
    ; 4. Data Hazard Interlocking (Scoreboard Resolution)
    ; --------------------------------------------------------------------------
_check_hazard:
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R9, (R6)            ; Load currently pending destination bitmask

    ; Test Rs1 dependency: (scoreboard & (1 << Rs1))
    LD      R6, 0
    FBRA.Z  R15, _test_rs2
    LD      R6, 1
    SHIFTL  R6, R15
    AND     R6, R9

_test_rs2:
    ; Test Rs2 dependency: (scoreboard & (1 << Rs2))
    LD      R5, 0
    FBRA.Z  R7, _evaluate_stall
    LD      R5, 1
    SHIFTL  R5, R7
    AND     R5, R9

_evaluate_stall:
    OR      R6, R5              ; Hazard present if either register is reserved
    FBRA.NZ R6, _do_stall_wait
    LOAD16  R14, _hazard_clear
    JMP     R14, R0

_do_stall_wait:
    ; RAW Hazard detected: Wait for retiring writeback to resolve dependency
    FIFO.R  R4, R3              ; Blocking wait for Rd from WB
    FIFO.R  R5, R3              ; Blocking wait for committed data

    FBRA.Z  R4, _clear_stalled_bit
    LOAD16  R6, REG_BASE
    SHIFTL  R7, R4, 2
    ADD     R6, R7
    ST32    (R6), R5            ; Update register table

_clear_stalled_bit:
    LD      R7, 1
    SHIFTL  R7, R4
    NOT     R7, R7
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R8, (R6)
    AND     R8, R7
    ST32    (R6), R8
    LOAD16  R14, _check_hazard  ; Re-evaluate hazard state
    JMP     R14, R0

_hazard_clear:
    ; --------------------------------------------------------------------------
    ; 5. Read Architectural Operands
    ; --------------------------------------------------------------------------
    ; Read OpA (Rs1)
    LD      R5, 0               ; x0 is hardwired to 0
    FBRA.Z  R15, _read_rs2
    LOAD16  R6, REG_BASE
    SHIFTL  R9, R15, 2
    ADD     R6, R9
    LD32    R5, (R6)            ; R5 = Rs1 Value

_read_rs2:
    ; Read OpB (Rs2)
    LD      R6, 0               ; x0 is hardwired to 0
    FBRA.Z  R7, _decode_immediates
    LOAD16  R8, REG_BASE
    SHIFTL  R9, R7, 2
    ADD     R8, R9
    LD32    R6, (R8)            ; R6 = Rs2 Value

    ; --------------------------------------------------------------------------
    ; 6. Immediate Field Decoders & Format Steering
    ; --------------------------------------------------------------------------
_decode_immediates:
    ; Default I-Type sign extension: inst[31:20]
    ASHIFTR R9, R11, 20         ; R9 = Sign-extended I-Immediate

    ; OP-IMM (0x13): ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
    LOAD16  R14, 0x13
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_op_reg
    LOAD16  R14, _emit_op_imm
    JMP     R14, R0

_check_op_reg:
    ; OP (0x33): Register-Register ALU / M-Extension / Zbb
    LOAD16  R14, 0x33
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_load
    LOAD16  R14, _emit_op_reg
    JMP     R14, R0

_check_load:
    ; LOAD (0x03): LB, LH, LW, LBU, LHU
    LOAD16  R14, 0x03
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_store
    LOAD16  R14, _emit_load
    JMP     R14, R0

_check_store:
    ; STORE (0x23): SB, SH, SW
    LOAD16  R14, 0x23
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_branch
    LOAD16  R14, _emit_store
    JMP     R14, R0

_check_branch:
    ; BRANCH (0x63): BEQ, BNE, BLT, BGE, BLTU, BGEU
    LOAD16  R14, 0x63
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_lui
    LOAD16  R14, _emit_branch
    JMP     R14, R0

_check_lui:
    ; LUI (0x37)
    LOAD16  R14, 0x37
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_auipc
    LOAD16  R14, _emit_lui
    JMP     R14, R0

_check_auipc:
    ; AUIPC (0x17)
    LOAD16  R14, 0x17
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_jal
    LOAD16  R14, _emit_auipc
    JMP     R14, R0

_check_jal:
    ; JAL (0x6F)
    LOAD16  R14, 0x6F
    SUB     R4, R12, R14
    FBRA.NZ R4, _check_jalr
    LOAD16  R14, _emit_jal
    JMP     R14, R0

_check_jalr:
    ; JALR (0x67)
    LOAD16  R14, 0x67
    SUB     R4, R12, R14
    FBRA.NZ R4, _drop_unrecognized
    LOAD16  R14, _emit_jalr
    JMP     R14, R0

_drop_unrecognized:
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

    ; --------------------------------------------------------------------------
    ; 7. Micro-Op Assembly & Dispatch Handlers
    ; --------------------------------------------------------------------------
_emit_op_imm:
    SHIFTL  R4, R14, 24         ; Micro-op = funct3
    SHIFTL  R8, R13, 8          ; Pack Rd into bits [15:8]
    OR      R4, R8
    OR      R4, 1               ; Bit 0 = valid
_dispatch_packet:
    ; If Rd != 0, set destination reservation in scoreboard
    FBRA.Z  R13, _push_to_ex
    LOAD16  R7, SCOREBOARD_MASK
    LD32    R8, (R7)
    LD      R14, 1
    SHIFTL  R14, R13
    OR      R8, R14
    ST32    (R7), R8

_push_to_ex:
    FIFO.W  R4, R2              ; Word 0: Control Word [uop:8 | funct:8 | Rd:8 | flags:8]
    FIFO.W  R5, R2              ; Word 1: Operand A
    FIFO.W  R9, R2              ; Word 2: Operand B (Imm or Rs2)
    FIFO.W  R10, R2             ; Word 3: PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_op_reg:
    LD      R4, 0
    SUB     R7, R8, 1           ; Check if M-extension (funct7 == 1)
    FBRA.NZ R7, _std_op
    LOAD16  R4, 0x20            ; Mark M-extension prefix
    OR      R4, R14
    FBRA    _pack_reg_ctrl
_std_op:
    LD      R4, R14             ; Base ALU uop from funct3
    LOAD16  R14, 0x20
    AND     R7, R8, R14         ; Check funct7 bit 5 (SUB / SRA / Zbb bit ops)
    FBRA.Z  R7, _pack_reg_ctrl
    LOAD16  R14, 0x10           ; Alternate operation flag
    OR      R4, R14
_pack_reg_ctrl:
    SHIFTL  R4, 24
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LD      R9, R6              ; OpB = Rs2 value
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_load:
    ADD     R4, R14, 1          ; uop ID for load
    SHIFTL  R4, 16
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_store:
    ; S-Type immediate: {inst[31:25], inst[11:7]}
    ASHIFTR R4, R11, 25
    SHIFTL  R4, 5
    OR      R4, R13             ; R4 = S-Immediate offset
    ADD     R7, R14, 8          ; Store uop ID
    SHIFTL  R7, 16
    OR      R7, 1
    FIFO.W  R7, R2              ; Control Word
    FIFO.W  R5, R2              ; Base Address (Rs1)
    FIFO.W  R4, R2              ; Offset Immediate
    FIFO.W  R6, R2              ; Store Data (Rs2)
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_branch:
    ; B-Type immediate: {inst[31], inst[7], inst[30:25], inst[11:8], 0}
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
    OR      R4, R7              ; R4 = Sign-extended branch offset
    ADD     R7, R14, 1          ; Branch uop
    SHIFTL  R7, 20
    OR      R7, 1
    FIFO.W  R7, R2              ; Control Word
    FIFO.W  R5, R2              ; Rs1 Value
    FIFO.W  R6, R2              ; Rs2 Value
    FIFO.W  R4, R2              ; Target Offset
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_lui:
    ; U-Type immediate: inst[31:12] << 12
    LOAD32  R7, 0xFFFFF000
    AND     R9, R11, R7
    LOAD16  R4, 0x30            ; LUI uop
    SHIFTL  R4, 24
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LD      R5, 0               ; OpA = 0
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_auipc:
    ; U-Type immediate: inst[31:12] << 12
    LOAD32  R7, 0xFFFFF000
    AND     R9, R11, R7
    LOAD16  R4, 0x31            ; AUIPC uop
    SHIFTL  R4, 24
    SHIFTL  R7, R13, 8
    OR      R4, R7
    OR      R4, 1
    LD      R5, R10             ; OpA = Current PC
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_jal:
    ; J-Type immediate: {inst[31], inst[19:12], inst[20], inst[30:21], 0}
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
    OR      R4, R7              ; R4 = J-Immediate jump offset
    LOAD16  R7, 0x09            ; JAL uop
    SHIFTL  R7, 20
    SHIFTL  R8, R13, 8
    OR      R7, R8
    OR      R7, 1
    FIFO.W  R7, R2              ; Control Word
    FIFO.W  R10, R2             ; Link PC
    FIFO.W  R4, R2              ; Jump Offset
    FIFO.W  R10, R2             ; Base PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_jalr:
    LOAD16  R7, 0x0A            ; JALR uop
    SHIFTL  R7, 20
    SHIFTL  R8, R13, 8
    OR      R7, R8
    OR      R7, 1
    FIFO.W  R7, R2              ; Control Word
    FIFO.W  R5, R2              ; Base Register (Rs1)
    FIFO.W  R9, R2              ; I-Immediate Offset
    FIFO.W  R10, R2             ; Link PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0
