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

    LOAD16  R14, _id_main_loop
    JMP     R14, R0

; ==============================================================================
; Trap Vector 1: Pipeline Flush on Branch / Jump (Core 2 Strobe)
; Strobe from Core 2 lands at TRAP_TABLE_BASE + (1 * 64) = 0x00000140
; ==============================================================================
.org 0x00000140
_branch_flush_handler:
    ; Reset Scoreboard mask to clear in-flight locks for discarded speculative instructions
    LOAD16  R4, SCOREBOARD_MASK
    LD      R5, 0
    LD32    (R4), R5

    ; Jump back to main decode loop
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

; ==============================================================================
; Main Decode Pipeline Loop
; ==============================================================================
.org 0x00000180
_id_main_loop:
    ; --------------------------------------------------------------------------
    ; 1. Service Retiring Writebacks (Non-blocking check)
    ; --------------------------------------------------------------------------
    FIFO.STAT R4, R3            ; Poll WB channel status (R3 = channel 2)
    AND       R4, 1             ; Bit 0: empty
    FBRA.Z    R4, _do_wb_read   ; If !empty (0), service writeback
    LOAD16    R14, _poll_fetch_queue
    JMP       R14, R0

_do_wb_read:
    FIFO.R    R4, R3            ; Read Rd index
    FIFO.R    R5, R3            ; Read committed 32-bit data

    ; Check if Rd == 0 (x0 is hardwired zero; skip write to register file)
    FBRA.Z    R4, _clear_wb_scoreboard

    ; Commit to local architectural register: REG_BASE + (Rd << 2)
    LOAD16    R6, REG_BASE
    LD        R7, R4
    SHIFTL    R7, 2
    ADD       R6, R7
    ST32      (R6), R5          ; Store committed value

_clear_wb_scoreboard:
    ; Clear bit in scoreboard: mask &= ~(1 << Rd)
    LD      R7, 1
    SHIFTL  R7, R4              ; R7 = 1 << Rd
    NOT     R7              ; R7 = ~(1 << Rd)
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R8, (R6)
    AND     R8, R7
    ST32    (R6), R8

_poll_fetch_queue:
    ; --------------------------------------------------------------------------
    ; 2. Check if Instruction Packet Available from Core 0
    ; --------------------------------------------------------------------------
    FIFO.STAT R4, R1            ; Poll Fetch channel status
    AND       R4, 1             ; Bit 0: empty
    FBRA.NZ   R4, _fetch_empty  ; If empty, loop back to check writebacks
    FIFO.R    R10, R1           ; Pop PC
    LOAD32  R6, 0xFFFFFFFF      ; Check for pipeline flush sentinel (-1)
    LD      R7, R10
    SUB     R7, R6
    FBRA.Z  R7, _drain_flush_token

    FIFO.R  R11, R1             ; Pop Instruction Word
    LOAD16  R14, _decode_fields
    JMP     R14, R0

_fetch_empty:
    LOAD16    R14, _id_main_loop
    JMP       R14, R0

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
    ; Build 5-bit mask (0x1F = 31) into R6 without touching R14 scratch
    LD      R6, 15
    SHIFTL  R6, 1
    OR      R6, 1               ; R6 = 0x1F

    ; Opcode = inst[6:0] (0x7F = 127)
    LD      R12, R11
    LD      R5, 15
    SHIFTL  R5, 3
    OR      R5, 7               ; R5 = 0x7F
    AND     R12, R5             ; R12 = Opcode

    ; Rd = inst[11:7]
    LD      R13, R11
    SHIFTR  R13, 7
    AND     R13, R6             ; R13 = Rd

    ; Rs1 = inst[19:15]
    LD      R15, R11
    SHIFTR  R15, 15
    AND     R15, R6             ; R15 = Rs1

    ; Rs2 = inst[24:20]
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 5
    AND     R7, R6              ; R7 = Rs2

    ; funct7 = inst[31:25]
    LD      R8, R11
    SHIFTR  R8, 15
    SHIFTR  R8, 10              ; R8 = funct7

    ; --------------------------------------------------------------------------
    ; 4. Data Hazard Interlocking (Scoreboard Resolution)
    ; --------------------------------------------------------------------------
_check_hazard:
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R9, (R6)

    ; --- Test Rs1 dependency ---
    LD      R6, 0
    FBRA.NZ R15, ._check_rs1_ops
    LOAD16  R14, ._check_rs2
    JMP     R14, R0

._check_rs1_ops:
    ; Test JAL (0x6F): bits [3:2] == 3
    LD      R4, R12
    SHIFTR  R4, 2
    AND     R4, 3
    LD      R5, 3
    SUB     R4, R5
    FBRA.Z  R4, ._skip_rs1_eval

    ; Test LUI/AUIPC: bits [4:2] == 5
    LD      R4, R12
    SHIFTR  R4, 2
    AND     R4, 7
    LD      R5, 5
    SUB     R4, R5
    FBRA.NZ R4, ._do_test_rs1

._skip_rs1_eval:
    LOAD16  R14, ._check_rs2
    JMP     R14, R0

._do_test_rs1:
    ; Rs1 is valid: test (scoreboard & (1 << Rs1))
    LD      R6, 1
    SHIFTL  R6, R15
    AND     R6, R9

._check_rs2:
    ; --- Test Rs2 dependency ---
    LD      R5, 0
    FBRA.Z  R7, ._skip_rs2_test

    ; Only OP (0x33), STORE (0x23), BRANCH (0x63) use Rs2 (bit 5 must be 1, bit 2 must be 0)
    LD      R4, R12
    LOAD16  R14, 0x20
    AND     R4, R14
    FBRA.Z  R4, ._skip_rs2_test

    LD      R4, R12
    AND     R4, 4
    FBRA.NZ R4, ._skip_rs2_test

    ; Rs2 valid: test (scoreboard & (1 << Rs2))
    LD      R5, 1
    SHIFTL  R5, R7
    AND     R5, R9

._skip_rs2_test:
_evaluate_stall:
    OR      R6, R5
    FBRA.NZ R6, ._stall_jump
    LOAD16  R14, _hazard_clear
    JMP     R14, R0
._stall_jump:
    LOAD16  R14, _do_stall_wait
    JMP     R14, R0

_do_stall_wait:
    ; RAW Hazard detected: Wait for retiring writeback to resolve dependency
    FIFO.R  R4, R3              ; Blocking wait for Rd from WB
    FIFO.R  R5, R3              ; Blocking wait for committed data

    FBRA.Z  R4, _clear_stalled_bit
    LOAD16  R6, REG_BASE
    LD      R8, R4
    SHIFTL  R8, 2
    ADD     R6, R8
    ST32    (R6), R5            ; Update register table

_clear_stalled_bit:
    LD      R8, 1
    SHIFTL  R8, R4
    NOT     R8
    LOAD16  R6, SCOREBOARD_MASK
    LD32    R9, (R6)
    AND     R9, R8
    ST32    (R6), R9
    LOAD16  R14, _check_hazard  ; Re-evaluate hazard state (R7/Rs2 preserved)
    JMP     R14, R0

_hazard_clear:
    ; --------------------------------------------------------------------------
    ; 5. Read Architectural Operands
    ; --------------------------------------------------------------------------
    ; Read OpA (Rs1)
    LD      R5, 0               ; x0 is hardwired to 0
    FBRA.Z  R15, _read_rs2
    LOAD16  R6, REG_BASE
    LD      R9, R15
    SHIFTL  R9, 2
    ADD     R6, R9
    LD32    R5, (R6)            ; R5 = Rs1 Value

_read_rs2:
    ; Read OpB (Rs2)
    LD      R6, 0               ; x0 is hardwired to 0
    FBRA.Z  R7, ._skip_rs2_read
    LOAD16  R14, REG_BASE
    LD      R9, R7
    SHIFTL  R9, 2
    ADD     R14, R9
    LD32    R6, (R14)           ; R6 = Rs2 Value
._skip_rs2_read:

    ; --------------------------------------------------------------------------
    ; 6. Immediate Field Decoders & Format Steering
    ; --------------------------------------------------------------------------
    ; Extract funct3 = inst[14:12] unconditionally
    LD      R14, R11
    SHIFTR  R14, 12
    AND     R14, 7              ; R14 = funct3

_decode_immediates:
    ; Default I-Type sign extension: inst[31:20]
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 5               ; R9 = Sign-extended I-Immediate

    ; OP-IMM (0x13): ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
    LOAD16  R14, 0x13
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_op_reg
    LOAD16  R14, _emit_op_imm
    JMP     R14, R0

_check_op_reg:
    ; OP (0x33): Register-Register ALU / M-Extension / Zbb
    LOAD16  R14, 0x33
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_load
    LOAD16  R14, _emit_op_reg
    JMP     R14, R0

_check_load:
    ; LOAD (0x03): LB, LH, LW, LBU, LHU
    LOAD16  R14, 0x03
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_store
    LOAD16  R14, _emit_load
    JMP     R14, R0

_check_store:
    ; STORE (0x23): SB, SH, SW
    LOAD16  R14, 0x23
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_branch
    LOAD16  R14, _emit_store
    JMP     R14, R0

_check_branch:
    ; BRANCH (0x63): BEQ, BNE, BLT, BGE, BLTU, BGEU
    LOAD16  R14, 0x63
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_lui
    LOAD16  R14, _emit_branch
    JMP     R14, R0

_check_lui:
    ; LUI (0x37)
    LOAD16  R14, 0x37
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_auipc
    LOAD16  R14, _emit_lui
    JMP     R14, R0

_check_auipc:
    ; AUIPC (0x17)
    LOAD16  R14, 0x17
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_jal
    LOAD16  R14, _emit_auipc
    JMP     R14, R0

_check_jal:
    ; JAL (0x6F)
    LOAD16  R14, 0x6F
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_jalr
    LOAD16  R14, _emit_jal
    JMP     R14, R0

_check_jalr:
    ; JALR (0x67)
    LOAD16  R14, 0x67
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_fence
    LOAD16  R14, _emit_jalr
    JMP     R14, R0

_check_fence:
    ; FENCE (0x0F): in-order memory drain
    LOAD16  R14, 0x0F
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _check_system
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_check_system:
    ; SYSTEM (0x73): ECALL, EBREAK, MRET, CSRRW, CSRRS, CSRRC
    LOAD16  R14, 0x73
    LD      R4, R12
    SUB     R4, R14
    FBRA.NZ R4, _drop_unrecognized
    LOAD16  R14, _emit_system
    JMP     R14, R0

_drop_unrecognized:
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

    ; --------------------------------------------------------------------------
    ; 7. Micro-Op Assembly & Dispatch Handlers
    ; --------------------------------------------------------------------------
_emit_op_imm:
    ; Extract funct3 from R11[14:12]
    LD      R4, R11
    SHIFTR  R4, 12
    AND     R4, 7
    ; Check if SRAI (funct3 == 5 and inst[30] == 1)
    LD      R8, R4
    SUB     R8, 5
    FBRA.NZ R8, _pack_imm_ctrl
    LD      R8, R11
    SHIFTR  R8, 15
    SHIFTR  R8, 15              ; R8 = inst[31:30]
    AND     R8, 1               ; bit 30
    FBRA.Z  R8, _pack_imm_ctrl
    LOAD16  R8, 0x10            ; SRAI: uop = 0x15
    OR      R4, R8

_pack_imm_ctrl:
    ; Shift funct3 into bits [31:24]
    LD      R8, 12
    SHIFTL  R8, 1               ; R8 = 24
    SHIFTL  R4, R8              ; R4 = funct3 << 24
    ; Pack Rd into bits [15:8]
    LD      R8, R13             ; R8 = Rd
    SHIFTL  R8, 8               ; R8 = Rd << 8
    OR      R4, R8              ; Pack Rd
    OR      R4, 1               ; Valid bit
_dispatch_packet:
    ; If Rd != 0, set destination reservation in scoreboard
    FBRA.Z  R13, _push_to_ex
    LOAD16  R14, SCOREBOARD_MASK
    LD32    R8, (R14)
    LD      R6, 1
    SHIFTL  R6, R13
    OR      R8, R6
    ST32    (R14), R8

_push_to_ex:
    FIFO.W  R4, R2              ; Word 0: Control Word [uop:8 | funct:8 | Rd:8 | flags:8]
    FIFO.W  R5, R2              ; Word 1: Operand A
    FIFO.W  R9, R2              ; Word 2: Operand B (Imm or Rs2)
    FIFO.W  R10, R2             ; Word 3: PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_op_reg:
    ; Extract funct3 directly from R11[14:12] into R4
    LD      R4, R11
    SHIFTR  R4, 12
    AND     R4, 7               ; R4 = funct3

    ; Extract funct7 directly from R11[31:25] into R8
    LD      R8, R11
    SHIFTR  R8, 15
    SHIFTR  R8, 10              ; R8 = funct7

    LD      R9, R8              ; R9 = funct7
    SUB     R9, 1               ; Check if M-extension (funct7 == 1)
    FBRA.NZ R9, _std_op
    LOAD16  R9, 0x20            ; Mark M-extension prefix
    OR      R4, R9
    LOAD16  R9, _pack_reg_ctrl
    JMP     R9, R0
_std_op:
    LOAD16  R9, 0x20
    AND     R9, R8              ; Check funct7 bit 5 (SUB / SRA / Zbb bit ops)
    FBRA.Z  R9, _pack_reg_ctrl
    LOAD16  R9, 0x10            ; Alternate operation flag (e.g. SUB / SRA)
    OR      R4, R9
_pack_reg_ctrl:
    SHIFTL  R4, 12
    SHIFTL  R4, 12              ; R4 = uop << 24
    LD      R8, R13             ; R8 = Rd
    SHIFTL  R8, 8               ; R8 = Rd << 8
    OR      R4, R8              ; Pack Rd into bits [15:8]
    OR      R4, 1               ; Valid bit
    LD      R9, R6              ; OpB = Rs2 value
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_load:
    ; Re-extract I-Type signed immediate offset: inst[31:20] into R9
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 5               ; R9 = Sign-extended 12-bit load offset

    ; Extract funct3 from R11[14:12]
    LD      R4, R11
    SHIFTR  R4, 12
    AND     R4, 7               ; R4 = funct3 (0: LB, 1: LH, 2: LW, 4: LBU, 5: LHU)
    LD      R8, R4
    SUB     R8, 3
    SSLT    R8, 0               ; R8 = (funct3 < 3) ? 1 : 0
    ADD     R4, R8              ; mem_op: 1=LB, 2=LH, 3=LW, 4=LBU, 5=LHU
    SHIFTL  R4, 8
    SHIFTL  R4, 8               ; R4 = mem_op << 16
    LD      R8, R13             ; R8 = Rd
    SHIFTL  R8, 8               ; R8 = Rd << 8
    OR      R4, R8              ; Pack Rd into bits [15:8]
    OR      R4, 1               ; Valid bit
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_store:
    ; S-Type immediate: {inst[31:25], inst[11:7]}
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 10              ; Sign-extended inst[31:25]
    SHIFTL  R9, 5
    LD      R8, R11
    SHIFTR  R8, 7
    LOAD16  R14, 0x1F
    AND     R8, R14
    OR      R9, R8              ; R9 = Sign-extended S-Immediate offset

    ; Extract funct3 from R11[14:12] for store mem_op (8: SB, 9: SH, 10: SW)
    LD      R4, R11
    SHIFTR  R4, 12
    AND     R4, 7               ; R4 = funct3 (0: SB, 1: SH, 2: SW)
    ADD     R4, 8               ; mem_op = funct3 + 8
    SHIFTL  R4, 8
    SHIFTL  R4, 8               ; R4 = mem_op << 16
    OR      R4, 1               ; Valid bit (Rd = 0)

    ; Send 4-word token packet to Core 2 (idToEx)
    FIFO.W  R4, R2              ; Word 0: Control Word (mem_op in [19:16], Rd=0)
    FIFO.W  R5, R2              ; Word 1: Base Address (Rs1)
    FIFO.W  R9, R2              ; Word 2: Offset Immediate
    FIFO.W  R6, R2              ; Word 3: Store Data (Rs2)
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_branch:
    ; 1. B-Type immediate: {inst[31], inst[7], inst[30:25], inst[11:8], 0}
    ; Sign-extend inst[31] shifted to bit 12
    LD      R4, R11
    ASHIFTR R4, 15
    ASHIFTR R4, 15
    ASHIFTR R4, 1
    SHIFTL  R4, 12

    ; inst[7] to bit 11
    LD      R7, R11
    SHIFTR  R7, 7
    AND     R7, 1
    SHIFTL  R7, 11
    OR      R4, R7

    ; inst[30:25] to bits [10:5]
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 10
    LOAD16  R14, 0x3F
    AND     R7, R14
    SHIFTL  R7, 5
    OR      R4, R7

    ; inst[11:8] to bits [4:1]
    LD      R7, R11
    SHIFTR  R7, 8
    LD      R14, 0x0F
    AND     R7, R14
    SHIFTL  R7, 1
    OR      R4, R7              ; R4 = Sign-extended branch offset

    ; 2. Target PC = Base PC (R10) + Offset (R4)
    ADD     R4, R10

    ; 3. Control Word: uop in [23:20], valid bit in [0]
    ; uop = funct3 + 1 (1: BEQ, 2: BNE, 4: BLT, 5: BGE, 6: BLTU, 7: BGEU)
    LD      R7, R11
    SHIFTR  R7, 12
    AND     R7, 7
    ADD     R7, 1
    LD      R8, 10
    SHIFTL  R8, 1               ; R8 = 20
    SHIFTL  R7, R8              ; R7 = uop << 20
    OR      R7, 1               ; Valid bit

    ; 4. Push 4-word token packet to Core 2 via Channel 1 (R2)
    FIFO.W  R7, R2              ; Word 0: Control Word
    FIFO.W  R5, R2              ; Word 1: Rs1 Value
    FIFO.W  R6, R2              ; Word 2: Rs2 Value
    FIFO.W  R4, R2              ; Word 3: Target PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_lui:
    ; U-Type immediate: inst[31:12] << 12
    LD      R9, R11
    LOAD32  R7, 0xFFFFF000
    AND     R9, R7              ; R9 = inst & 0xFFFFF000
    LOAD16  R4, 0x30            ; LUI uop
    LD      R8, 12
    SHIFTL  R8, 1               ; R8 = 24
    SHIFTL  R4, R8              ; R4 = uop << 24
    LD      R7, R13
    SHIFTL  R7, 8               ; R7 = Rd << 8
    OR      R4, R7
    OR      R4, 1               ; Valid bit
    LD      R5, 0               ; OpA = 0
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_auipc:
    ; U-Type immediate: inst[31:12] << 12
    LD      R9, R11
    LOAD32  R7, 0xFFFFF000
    AND     R9, R7              ; R9 = inst & 0xFFFFF000
    LOAD16  R4, 0x31            ; AUIPC uop
    LD      R8, 12
    SHIFTL  R8, 1               ; R8 = 24
    SHIFTL  R4, R8              ; R4 = uop << 24
    LD      R7, R13
    SHIFTL  R7, 8               ; R7 = Rd << 8
    OR      R4, R7
    OR      R4, 1               ; Valid bit
    LD      R5, R10             ; OpA = Current PC
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

; ==============================================================================
; SYSTEM Instruction Decoder (Opcode 0x73: ECALL, EBREAK, MRET, CSR)
; ==============================================================================
_emit_system:
    ; Extract funct3 from R11[14:12]
    LD      R14, R11
    SHIFTR  R14, 12
    AND     R14, 7
    FBRA.NZ R14, _emit_csr_rw

    ; funct3 == 0: ECALL, EBREAK, or MRET based on inst[31:20]
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 5               ; R7 = inst[31:20]

    ; Check 0x000: ECALL
    FBRA.NZ R7, ._chk_ebreak
    LOAD16  R4, 0x40            ; uop = 0x40 (ECALL)
    FBRA    ._pack_system_ctrl

._chk_ebreak:
    ; Check 0x001: EBREAK
    LD      R8, R7
    SUB     R8, 1
    FBRA.NZ R8, ._chk_mret
    LOAD16  R4, 0x41            ; uop = 0x41 (EBREAK)
    FBRA    ._pack_system_ctrl

._chk_mret:
    ; Check 0x302: MRET
    LOAD16  R8, 0x302
    SUB     R8, R7
    FBRA.Z  R8, ._do_mret
    LOAD16  R14, _drop_unrecognized
    JMP     R14, R0
._do_mret:
    LOAD16  R4, 0x42            ; uop = 0x42 (MRET)

._pack_system_ctrl:
    LD      R8, 12
    SHIFTL  R8, 1               ; R8 = 24
    SHIFTL  R4, R8              ; uop << 24
    LD      R8, R13             ; Rd
    SHIFTL  R8, 8               ; Rd << 8
    OR      R4, R8
    OR      R4, 1               ; Valid bit

    FIFO.W  R4, R2              ; Word 0: Control Word
    FIFO.W  R5, R2              ; Word 1: Rs1 Value
    FIFO.W  R7, R2              ; Word 2: funct12 / CSR Addr
    FIFO.W  R10, R2             ; Word 3: Guest PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_csr_rw:
    ; R14 = funct3 (1: CSRRW, 2: CSRRS, 3: CSRRC, 5: CSRRWI, 6: CSRRSI, 7: CSRRCI)
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 5               ; R7 = CSR Address (inst[31:20])

    ; Check if immediate form (funct3 bit 2 is set)
    LD      R8, R14
    AND     R8, 4
    FBRA.Z  R8, ._csr_reg_op
    LD      R5, R15             ; Immediate operand = 5-bit zext(rs1)

._csr_reg_op:
    ; Base uop: 0x43 (CSRRW), 0x44 (CSRRS), 0x45 (CSRRC)
    LD      R8, R14
    AND     R8, 3
    LOAD16  R4, 0x42
    ADD     R4, R8              ; R4 = uop (0x43, 0x44, or 0x45)

    LD      R8, 12
    SHIFTL  R8, 1               ; R8 = 24
    SHIFTL  R4, R8              ; uop << 24

    ; DO NOT pack funct3 into bits [19:16] - that is reserved for mem_op!
    LD      R8, R13             ; Rd
    SHIFTL  R8, 8               ; Rd << 8
    OR      R4, R8
    OR      R4, 1               ; Valid bit

    LD      R9, R7              ; OpB = CSR Address
    LOAD16  R14, _dispatch_packet
    JMP     R14, R0

_emit_jal:
    ; J-Type immediate: {inst[31], inst[19:12], inst[20], inst[30:21], 0}
    LD      R4, R11
    ASHIFTR R4, 15
    ASHIFTR R4, 15
    ASHIFTR R4, 1               ; Sign extend bit 31 (31-bit shift)
    SHIFTL  R4, 12
    SHIFTL  R4, 8               ; R4 = bit 31 << 20
    LOAD16  R7, 0x00FF
    SHIFTL  R7, 12              ; R7 = 0x000FF000
    LD      R9, R11
    AND     R9, R7
    OR      R4, R9
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 5               ; >> 20
    AND     R7, 1
    SHIFTL  R7, 11
    OR      R4, R7
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 6               ; >> 21
    LOAD16  R14, 0x03FF
    AND     R7, R14
    SHIFTL  R7, 1
    OR      R4, R7              ; R4 = J-Immediate jump offset

    LOAD16  R7, 0x09            ; JAL uop
    SHIFTL  R7, 12
    SHIFTL  R7, 8               ; uop << 20
    LD      R8, R13             ; Rd
    SHIFTL  R8, 8               ; Rd << 8
    OR      R7, R8
    OR      R7, 1               ; Valid bit
    FIFO.W  R7, R2              ; Control Word
    FIFO.W  R10, R2             ; Link PC
    FIFO.W  R4, R2              ; Jump Offset
    FIFO.W  R10, R2             ; Base PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0

_emit_jalr:
    LOAD16  R7, 0x0A            ; JALR uop
    SHIFTL  R7, 12
    SHIFTL  R7, 8               ; uop << 20
    LD      R8, R13             ; Rd
    SHIFTL  R8, 8               ; Rd << 8
    OR      R7, R8
    OR      R7, 1
    FIFO.W  R7, R2              ; Control Word
    FIFO.W  R5, R2              ; Base Register (Rs1)
    FIFO.W  R9, R2              ; I-Immediate Offset
    FIFO.W  R10, R2             ; Link PC
    LOAD16  R14, _id_main_loop
    JMP     R14, R0
