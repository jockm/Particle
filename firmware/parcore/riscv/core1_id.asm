; ==============================================================================
; Parcore RV32IM_Zbb: Core 1 (Instruction Decode & Register File Scoreboard)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core1_id.asm
; ==============================================================================
;
; Core 1 holds the RISC-V registers, decodes each instruction core 0 sends,
; waits while a source register has a write in flight, and sends core 2 a
; 4-word packet: [control word, operand A, operand B, word 3].
;
; Control word: [31:24] core 2's operation number (parcore_ops.inc), [19:16]
; memory op (OP_MEM), [15:8] Rd, bit 1 the epoch (PC bit 0 as core 0 sent
; it), bit 0 valid.
;
; The hot path is laid out to fall through: one JTBL on opcode[6:2] picks
; the handler, and the common handlers share the tail _send_ctrl.
;
; Registers kept for the whole run:
;   R0   0, and FIFO channel 0 (ifToId: [PC, instruction] from core 0)
;   R1   COUNT_BASE
;   R2   1: FIFO channel 1 (idToEx, to core 2)
;   R3   2: FIFO channel 2 (writebacks from core 3: [Rd, data])
; For each instruction:
;   R10  PC, R11 instruction, R12 flags (valid | epoch << 1),
;   R13  rd field (inst[11:7]), R15 rs1, R7 rs2 (handlers that read it)
; ==============================================================================
.include "lib/vectors.inc"
.include "parcore_ops.inc"

; Zero page
.define REG_BASE          0x0000  ; x0..x31, a word each (0x00..0x7F); x0 stays 0
.define COUNT_BASE        0x0F00  ; 32 bytes (0xF00..0xF1F): writes in flight per register

; dst = inst[pos + len - 1 : pos] (len 1..7). Uses R14.
.macro FIELD dst, pos, len
    LD      %dst, R11
    LD      R14, %pos + %len * 32
    BEXTR   %dst, R14
.endmacro

; A writeback [Rd, data] in R4, R5. Rd + 0x20 is a cancel: nothing is
; committed (its data goes to 0x80 + 4 * Rd, which nothing uses). Either way
; x(Rd) has one write fewer in flight. Writebacks for x0 are ignored (x0 is
; never counted, and a cancel never names it). Uses R6, R8.
.macro RETIRE_WB
    LD      R6, R4
    BCLR    R6, 5               ; R6 = Rd
    FBRA.Z  R6, .%_done
    LD      R8, R4
    SHIFTL  R8, 2
    ST32    (R8), R5            ; commit: REG_BASE + (Rd << 2)
    ADD     R6, R1
    LD8     R8, (R6)
    SUB     R8, 1
    ST8     (R6), R8
.%_done:
.endmacro

; Go to %stall if x(R15) has a write in flight. %chk labels the check, for
; the stall stub to come back to. Uses R8, R14.
.macro WAIT_RS1 chk, stall
%chk:
    LD      R8, R15
    ADD     R8, R1
    LD8     R14, (R8)
    FBRA.NZ R14, %stall
.endmacro

; The same for x(R15) and x(R7). Uses R6, R8, R9, R14.
.macro WAIT_RS1_RS2 chk, stall
%chk:
    LD      R8, R15
    ADD     R8, R1
    LD8     R6, (R8)
    LD      R9, R7
    ADD     R9, R1
    LD8     R14, (R9)
    OR      R14, R6
    FBRA.NZ R14, %stall
.endmacro

; A stall stub, placed after its handler: retire one writeback (waiting for
; it), then check again. Uses R4-R6, R8.
.macro STALL_STUB stall, chk
%stall:
    FIFO.R  R4, R3
    FIFO.R  R5, R3
    RETIRE_WB
    JUMP    %chk
.endmacro

; dst = x(src index register). x0 reads as zero: its word is never written.
.macro READ_REG dst, src
    LD      R14, %src
    SHIFTL  R14, 2
    LD32    %dst, (R14)
.endmacro

    RESET_SLOT _reset_vector
    TRAP_SLOT_UNEXPECTED 1
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
    LDI     R1, COUNT_BASE
    LD      R2, 1               ; idToEx
    LD      R3, 2               ; writebacks

    ; x0..x31 = 0, and nothing in flight
    LD      R4, 0
    LDI     R6, 32
._clear_regs:
    ST32    (R4++), R0
    SUB     R6, 1
    BBRA.NZ R6, ._clear_regs
    LD      R4, R1
    LD      R6, 8
._clear_counts:
    ST32    (R4++), R0
    SUB     R6, 1
    BBRA.NZ R6, ._clear_counts
    JUMP    _id_main_loop

; A writeback the main loop found (its first word in R4)
_retire:
    FIFO.R  R5, R3
    RETIRE_WB
    JUMP    _id_main_loop

; ------------------------------------------------------------------------------
; The shared tail of most handlers; it falls into the main loop
; ------------------------------------------------------------------------------
_send_uop:
    ; R4 = the operation number: to [31:24]
    SHIFTL  R4, 12
    SHIFTL  R4, 12
_send_ctrl:
    ; R4 = the control word without Rd and flags; R5, R9 = words 1 and 2;
    ; word 3 the PC. x(rd) has one more write in flight.
    LD      R6, R13
    SHIFTL  R6, 8
    OR      R4, R6
    OR      R4, R12
    FBRA.Z  R13, ._push
    LD      R8, R13
    ADD     R8, R1
    LD8     R6, (R8)
    ADD     R6, 1
    ST8     (R8), R6
._push:
    FIFO.W  R4, R2              ; control word
    FIFO.W  R5, R2              ; operand A
    FIFO.W  R9, R2              ; operand B
    FIFO.W  R10, R2             ; PC

; ==============================================================================
; Main loop: retire the writebacks waiting, then decode one instruction
; ==============================================================================
_id_main_loop:
    FIFO.TRYR R4, R3            ; a writeback?
    BBRA.NZ R14, _retire
    ; Decode only when idToEx has room for the packet (a FIFO.W to a full
    ; channel is dropped): fewer than 128 words in it (status bit 15 clear)
    FIFO.STAT R14, R2
    SHIFTR  R14, 15
    BBRA.NZ R14, _id_main_loop
    FIFO.TRYR R10, R0           ; a PC?
    BBRA.Z  R14, _id_main_loop

_have_pc:
    ; PC bit 0 is the epoch (core 0 flips it on every redirect): keep it in
    ; the flags for the control word, and decode with the real PC
    LD      R12, R10
    AND     R12, 1
    SHIFTL  R12, 1
    OR      R12, 1              ; R12 = valid | epoch << 1
    BCLR    R10, 0
    FIFO.R  R11, R0             ; the instruction

    FIELD   R13, 7, 5           ; rd
    FIELD   R15, 15, 5          ; rs1
    ; Dispatch on inst[6:0]. Every RV32 instruction has bits [1:0] = 11,
    ; and a PC has bit 1 = 0: a word with bit 1 clear is the next packet's
    ; PC (the flush emptied ifToId after this packet's PC was popped), and
    ; the table starts again with it; bits [1:0] = 10 are illegal.
    FIELD   R9, 0, 7
    JTBL    R9
    FBRA    _t_pc               ; 0x00 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x01 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x02
    FBRA    _h_load             ; 0x03
    FBRA    _t_pc               ; 0x04 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x05 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x06
    FBRA    _h_illegal          ; 0x07
    FBRA    _t_pc               ; 0x08 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x09 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x0A
    FBRA    _h_illegal          ; 0x0B
    FBRA    _t_pc               ; 0x0C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x0D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x0E
    FBRA    _t_misc_mem         ; 0x0F
    FBRA    _t_pc               ; 0x10 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x11 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x12
    FBRA    _h_op_imm           ; 0x13
    FBRA    _t_pc               ; 0x14 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x15 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x16
    FBRA    _h_auipc            ; 0x17
    FBRA    _t_pc               ; 0x18 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x19 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x1A
    FBRA    _h_illegal          ; 0x1B
    FBRA    _t_pc               ; 0x1C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x1D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x1E
    FBRA    _h_illegal          ; 0x1F
    FBRA    _t_pc               ; 0x20 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x21 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x22
    FBRA    _h_store            ; 0x23
    FBRA    _t_pc               ; 0x24 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x25 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x26
    FBRA    _h_illegal          ; 0x27
    FBRA    _t_pc               ; 0x28 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x29 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x2A
    FBRA    _h_illegal          ; 0x2B
    FBRA    _t_pc               ; 0x2C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x2D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x2E
    FBRA    _h_illegal          ; 0x2F
    FBRA    _t_pc               ; 0x30 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x31 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x32
    FBRA    _h_op               ; 0x33
    FBRA    _t_pc               ; 0x34 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x35 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x36
    FBRA    _h_lui              ; 0x37
    FBRA    _t_pc               ; 0x38 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x39 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x3A
    FBRA    _h_illegal          ; 0x3B
    FBRA    _t_pc               ; 0x3C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x3D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x3E
    FBRA    _h_illegal          ; 0x3F
    FBRA    _t_pc               ; 0x40 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x41 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x42
    FBRA    _h_illegal          ; 0x43
    FBRA    _t_pc               ; 0x44 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x45 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x46
    FBRA    _h_illegal          ; 0x47
    FBRA    _t_pc               ; 0x48 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x49 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x4A
    FBRA    _h_illegal          ; 0x4B
    FBRA    _t_pc               ; 0x4C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x4D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x4E
    FBRA    _h_illegal          ; 0x4F
    FBRA    _t_pc               ; 0x50 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x51 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x52
    FBRA    _h_illegal          ; 0x53
    FBRA    _t_pc               ; 0x54 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x55 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x56
    FBRA    _h_illegal          ; 0x57
    FBRA    _t_pc               ; 0x58 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x59 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x5A
    FBRA    _h_illegal          ; 0x5B
    FBRA    _t_pc               ; 0x5C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x5D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x5E
    FBRA    _h_illegal          ; 0x5F
    FBRA    _t_pc               ; 0x60 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x61 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x62
    FBRA    _h_branch           ; 0x63
    FBRA    _t_pc               ; 0x64 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x65 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x66
    FBRA    _t_jalr             ; 0x67
    FBRA    _t_pc               ; 0x68 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x69 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x6A
    FBRA    _h_illegal          ; 0x6B
    FBRA    _t_pc               ; 0x6C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x6D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x6E
    FBRA    _t_jal              ; 0x6F
    FBRA    _t_pc               ; 0x70 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x71 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x72
    FBRA    _t_system           ; 0x73
    FBRA    _t_pc               ; 0x74 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x75 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x76
    FBRA    _h_illegal          ; 0x77
    FBRA    _t_pc               ; 0x78 ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x79 ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x7A
    FBRA    _h_illegal          ; 0x7B
    FBRA    _t_pc               ; 0x7C ; bit 1 clear: a PC
    FBRA    _t_pc               ; 0x7D ; bit 1 clear: a PC
    FBRA    _h_illegal          ; 0x7E
    FBRA    _h_illegal          ; 0x7F

_t_pc:
    LD      R10, R11
    JUMP    _have_pc
_t_jalr:
    JUMP    _h_jalr
_t_jal:
    JUMP    _h_jal
_t_misc_mem:
    JUMP    _h_misc_mem
_t_system:
    JUMP    _h_system

_h_illegal:
    ; An instruction core 1 can't decode (an unknown opcode or encoding):
    ; send core 2 an illegal-instruction item (OP_ILLEGAL), which traps to
    ; mtvec with mcause 2 and mtval = the instruction. No destination
    ; register. (A zero word never gets here: core 0 doesn't send it.)
    LDI     R4, OP_ILLEGAL
    SHIFTL  R4, 12
    SHIFTL  R4, 12
    OR      R4, R12
    FIFO.W  R4, R2              ; control word
    FIFO.W  R0, R2              ; 0
    FIFO.W  R11, R2             ; the instruction (for mtval)
    FIFO.W  R10, R2             ; PC
    JUMP    _id_main_loop

; ------------------------------------------------------------------------------
; LUI: operand A 0; AUIPC: operand A the PC. Operand
; B the U-immediate.
; ------------------------------------------------------------------------------
_h_lui:
    LD      R5, 0
    LDI     R4, OP_LUI
    FBRA    ._u_imm
_h_auipc:
    LD      R5, R10
    LDI     R4, OP_AUIPC
._u_imm:
    LD      R9, R11
    SHIFTR  R9, 12
    SHIFTL  R9, 12              ; inst[31:12] << 12
    JUMP    _send_uop

; ------------------------------------------------------------------------------
; OP-IMM: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI, and the Zbb
; immediate and unary forms. OP_ADD + funct3, SRAI OP_SRA, Zbb their own.
; ------------------------------------------------------------------------------
_h_op_imm:
    WAIT_RS1 ._oi_chk, ._oi_stall
    READ_REG R5, R15            ; operand A = x(rs1)
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 5               ; operand B = the sign-extended I-immediate
    FIELD   R4, 12, 3           ; funct3
    LD      R14, 0x22           ; funct3 1 or 5: shifts and Zbb
    BGET    R14, R4
    FBRA.NZ R14, _t_op_imm_shift
    JUMP    _send_uop
    STALL_STUB ._oi_stall, ._oi_chk

; ------------------------------------------------------------------------------
; LOAD: LB, LH, LW, LBU, LHU. OP_MEM; mem_op 1 LB, 2 LH, 3 LW, 4 LBU, 5 LHU.
; ------------------------------------------------------------------------------
_h_load:
    WAIT_RS1 ._ld_chk, ._ld_stall
    READ_REG R5, R15            ; base
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 5               ; offset
    FIELD   R4, 12, 3           ; funct3
    LD      R14, 0x37           ; valid funct3: bits 0, 1, 2, 4, 5
    BGET    R14, R4
    BBRA.Z  R14, _h_illegal
    LD      R8, R4
    SUB     R8, 3
    SSLT    R8, 0               ; 1 if funct3 < 3
    ADD     R4, R8
    LDI     R8, OP_MEM * 256
    OR      R4, R8
    SHIFTL  R4, 8
    SHIFTL  R4, 8               ; OP_MEM << 24 | mem_op << 16
    JUMP    _send_ctrl
    STALL_STUB ._ld_stall, ._ld_chk

; ------------------------------------------------------------------------------
; OP: register-register ALU, M and Zbb. OP_ADD + funct3, OP_MUL + funct3
; for M, OP_SUB and OP_SRA, Zbb their own.
; ------------------------------------------------------------------------------
_h_op:
    FIELD   R7, 20, 5           ; rs2
    WAIT_RS1_RS2 ._op_chk, ._op_stall
    READ_REG R5, R15            ; operand A
    READ_REG R9, R7             ; operand B
    FIELD   R4, 12, 3           ; funct3
    FIELD   R8, 25, 7           ; funct7
    LD      R14, R8
    FBRA.Z  R14, ._op_f7_0       ; funct7 0: ADD, SLL, SLT, SLTU, XOR, SRL, OR, AND
    SUB     R8, 1
    LD      R14, R8
    FBRA.NZ R14, _t_op_funct7
    ADD     R4, OP_MUL          ; M: MUL ... REMU
._op_f7_0:
    JUMP    _send_uop
    STALL_STUB ._op_stall, ._op_chk

_t_op_imm_shift:
    JUMP    _op_imm_shift
_t_op_funct7:
    JUMP    _op_funct7

; ------------------------------------------------------------------------------
; STORE: SB, SH, SW. OP_MEM; mem_op = funct3 + 8; word 3 the store data.
; ------------------------------------------------------------------------------
_h_store:
    FIELD   R7, 20, 5           ; rs2
    WAIT_RS1_RS2 ._st_chk, ._st_stall
    READ_REG R5, R15            ; base
    READ_REG R6, R7             ; data
    FIELD   R4, 12, 3           ; funct3
    LD      R14, 0x07           ; valid funct3: 0, 1, 2
    BGET    R14, R4
    BBRA.Z  R14, _h_illegal
    ; S-immediate: {inst[31:25], inst[11:7]}, sign-extended
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 10
    SHIFTL  R9, 5
    OR      R9, R13             ; inst[11:7]
    ADD     R4, 8
    LDI     R14, OP_MEM * 256
    OR      R4, R14
    SHIFTL  R4, 8
    SHIFTL  R4, 8               ; OP_MEM << 24 | mem_op << 16
    OR      R4, R12
    FIFO.W  R4, R2              ; control word (Rd 0)
    FIFO.W  R5, R2              ; base
    FIFO.W  R9, R2              ; offset
    FIFO.W  R6, R2              ; store data
    JUMP    _id_main_loop
    STALL_STUB ._st_stall, ._st_chk

; ------------------------------------------------------------------------------
; BRANCH: BEQ, BNE, BLT, BGE, BLTU, BGEU. OP_BEQ + funct3; word 3 the
; target PC.
; ------------------------------------------------------------------------------
_h_branch:
    FIELD   R7, 20, 5           ; rs2
    WAIT_RS1_RS2 ._br_chk, ._br_stall
    READ_REG R5, R15
    READ_REG R6, R7
    FIELD   R8, 12, 3           ; funct3
    LD      R14, 0xF3           ; valid funct3: all but 2 and 3
    BGET    R14, R8
    BBRA.Z  R14, _h_illegal
    ; B-immediate: {inst[31], inst[7], inst[30:25], inst[11:8], 0}
    LD      R4, R11
    ASHIFTR R4, 15
    ASHIFTR R4, 15
    ASHIFTR R4, 1
    SHIFTL  R4, 12              ; inst[31], sign-extended, at bit 12
    LD      R9, R11
    BGET    R9, 7
    SHIFTL  R9, 11
    OR      R4, R9              ; inst[7] at bit 11
    FIELD   R9, 25, 6
    SHIFTL  R9, 5
    OR      R4, R9              ; inst[30:25] at bits 10:5
    FIELD   R9, 8, 4
    SHIFTL  R9, 1
    OR      R4, R9              ; inst[11:8] at bits 4:1
    ADD     R4, R10             ; target
    LDI     R14, OP_BEQ
    ADD     R8, R14
    SHIFTL  R8, 12
    SHIFTL  R8, 12              ; OP_BEQ + funct3, << 24
    OR      R8, R12
    FIFO.W  R8, R2              ; control word
    FIFO.W  R5, R2              ; x(rs1)
    FIFO.W  R6, R2              ; x(rs2)
    FIFO.W  R4, R2              ; target PC
    JUMP    _id_main_loop
    STALL_STUB ._br_stall, ._br_chk

; ------------------------------------------------------------------------------
; JALR: OP_JALR; words: x(rs1), the I-immediate, the PC
; ------------------------------------------------------------------------------
_h_jalr:
    FIELD   R8, 12, 3           ; funct3: 0 only
    LD      R14, R8
    FBRA.NZ R14, _t_illegal
    WAIT_RS1 ._jr_chk, ._jr_stall
    READ_REG R5, R15
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 5
    LDI     R4, OP_JALR
    JUMP    _send_uop
    STALL_STUB ._jr_stall, ._jr_chk

_t_illegal:
    JUMP    _h_illegal

; ------------------------------------------------------------------------------
; JAL: OP_JAL; words: the PC, the offset, the PC
; ------------------------------------------------------------------------------
_h_jal:
    ; J-immediate: {inst[31], inst[19:12], inst[20], inst[30:21], 0}
    LD      R9, R11
    ASHIFTR R9, 15
    ASHIFTR R9, 15
    ASHIFTR R9, 1
    SHIFTL  R9, 15
    SHIFTL  R9, 5               ; inst[31], sign-extended, at bit 20
    LD      R4, R11
    SHIFTL  R4, 12
    SHIFTR  R4, 12
    SHIFTR  R4, 12
    SHIFTL  R4, 12
    OR      R9, R4              ; inst[19:12] at bits 19:12
    LD      R4, R11
    LD      R14, 20
    BGET    R4, R14
    SHIFTL  R4, 11
    OR      R9, R4              ; inst[20] at bit 11
    LD      R4, R11
    SHIFTL  R4, 1
    SHIFTR  R4, 15
    SHIFTR  R4, 7
    SHIFTL  R4, 1
    OR      R9, R4              ; inst[30:21] at bits 10:1
    LD      R5, R10             ; word 1: the PC
    LDI     R4, OP_JAL
    JUMP    _send_uop

; ------------------------------------------------------------------------------
; OP-IMM with funct3 1 or 5: SLLI, SRLI, SRAI, and the Zbb CLZ, CTZ, CPOP,
; SEXT.B, SEXT.H, ORC.B, REV8 and RORI. R4 = funct3, R9 = the I-immediate.
; ------------------------------------------------------------------------------
_op_imm_shift:
    FIELD   R8, 25, 7           ; funct7 (imm[11:5])
    LD      R14, R8
    FBRA.NZ R14, ._imm_f7
    JUMP    _send_uop           ; SLLI / SRLI
._imm_f7:
    LD      R14, R4
    SUB     R14, 5
    FBRA.NZ R14, ._imm_f1
    ; funct3 5
    LDI     R14, 0x20
    SUB     R14, R8
    FBRA.NZ R14, ._imm_f5_zbb
    LDI     R4, OP_SRA          ; SRAI
    JUMP    _send_uop
._imm_f5_zbb:
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 5               ; imm12 = inst[31:20]
    LDI     R14, 0x287
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f5_rev8
    LDI     R4, OP_ORC_B        ; ORC.B
    JUMP    _send_uop
._imm_f5_rev8:
    LDI     R14, 0x698
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f5_rori
    LDI     R4, OP_REV8         ; REV8
    JUMP    _send_uop
._imm_f5_rori:
    LDI     R14, 0x30
    SUB     R14, R8
    FBRA.NZ R14, ._imm_illegal
    LDI     R4, OP_ROR          ; RORI
    JUMP    _send_uop
._imm_f1:
    ; funct3 1, funct7 not 0: Zbb unary, by imm12
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 5               ; imm12
    LDI     R14, 0x600
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_ctz
    LDI     R4, OP_CLZ          ; CLZ
    JUMP    _send_uop
._imm_f1_ctz:
    LDI     R14, 0x601
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_cpop
    LDI     R4, OP_CTZ          ; CTZ
    JUMP    _send_uop
._imm_f1_cpop:
    LDI     R14, 0x602
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_sextb
    LDI     R4, OP_CPOP         ; CPOP
    JUMP    _send_uop
._imm_f1_sextb:
    LDI     R14, 0x604
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_sexth
    LDI     R4, OP_SEXT_B       ; SEXT.B
    JUMP    _send_uop
._imm_f1_sexth:
    LDI     R14, 0x605
    SUB     R14, R7
    FBRA.NZ R14, ._imm_illegal
    LDI     R4, OP_SEXT_H       ; SEXT.H
    JUMP    _send_uop
._imm_illegal:
    JUMP    _h_illegal

; ------------------------------------------------------------------------------
; OP with funct7 not 0 or 1. R4 = funct3, R8 = funct7 - 1.
; ------------------------------------------------------------------------------
_op_funct7:
    ADD     R8, 1               ; funct7
    LDI     R14, 0x20
    SUB     R14, R8
    FBRA.NZ R14, ._reg_chk_30
    ; funct7 0x20: SUB (0), SRA (5), ANDN (7), ORN (6), XNOR (4)
    LD      R14, R4
    SUB     R14, 7
    FBRA.NZ R14, ._reg_20_orn
    LDI     R4, OP_ANDN         ; ANDN
    JUMP    _send_uop
._reg_20_orn:
    LD      R14, R4
    SUB     R14, 6
    FBRA.NZ R14, ._reg_20_xnor
    LDI     R4, OP_ORN          ; ORN
    JUMP    _send_uop
._reg_20_xnor:
    LD      R14, R4
    SUB     R14, 4
    FBRA.NZ R14, ._reg_20_sub_sra
    LDI     R4, OP_XNOR         ; XNOR
    JUMP    _send_uop
._reg_20_sub_sra:
    ; SUB (funct3 0) or SRA (funct3 5); funct3 1-3 are illegal
    LD      R14, R4
    FBRA.NZ R14, ._reg_20_sra
    LD      R4, OP_SUB
    JUMP    _send_uop
._reg_20_sra:
    SUB     R14, 5
    FBRA.NZ R14, ._reg_illegal
    LD      R4, OP_SRA
    JUMP    _send_uop

._reg_chk_30:
    ; funct7 0x30: ROL (funct3 1), ROR (funct3 5)
    LDI     R14, 0x30
    SUB     R14, R8
    FBRA.NZ R14, ._reg_chk_05
    LD      R14, R4
    SUB     R14, 1
    FBRA.NZ R14, ._reg_30_ror
    LDI     R4, OP_ROL          ; ROL
    JUMP    _send_uop
._reg_30_ror:
    LD      R14, R4
    SUB     R14, 5
    FBRA.NZ R14, ._reg_illegal
    LDI     R4, OP_ROR          ; ROR
    JUMP    _send_uop

._reg_chk_05:
    ; funct7 0x05: MIN (4), MINU (5), MAX (6), MAXU (7)
    LD      R14, R8
    SUB     R14, 5
    FBRA.NZ R14, ._reg_chk_04
    LD      R14, R4
    SUB     R14, 4
    FBRA.NZ R14, ._reg_05_minu
    LDI     R4, OP_MIN          ; MIN
    JUMP    _send_uop
._reg_05_minu:
    LD      R14, R4
    SUB     R14, 5
    FBRA.NZ R14, ._reg_05_max
    LDI     R4, OP_MINU         ; MINU
    JUMP    _send_uop
._reg_05_max:
    LD      R14, R4
    SUB     R14, 6
    FBRA.NZ R14, ._reg_05_maxu
    LDI     R4, OP_MAX          ; MAX
    JUMP    _send_uop
._reg_05_maxu:
    LD      R14, R4
    SUB     R14, 7
    FBRA.NZ R14, ._reg_illegal
    LDI     R4, OP_MAXU         ; MAXU
    JUMP    _send_uop

._reg_chk_04:
    ; funct7 0x04: ZEXT.H (funct3 4, rs2 0); anything else is illegal
    LD      R14, R8
    SUB     R14, 4
    FBRA.NZ R14, ._reg_illegal
    LD      R14, R4
    SUB     R14, 4
    FBRA.NZ R14, ._reg_illegal
    LD      R14, R7
    FBRA.NZ R14, ._reg_illegal
    LDI     R4, OP_ZEXT_H       ; ZEXT.H
    JUMP    _send_uop
._reg_illegal:
    JUMP    _h_illegal

; ------------------------------------------------------------------------------
; MISC-MEM: funct3 0 FENCE (nothing to do: one core does every load and
; store, in order), 1 FENCE.I (OP_FENCE_I; words: the PC, 0, the PC); 2-7 are
; reserved (Zicbom/Zicboz cache-block operations use 2) and trap as illegal
; ------------------------------------------------------------------------------
_h_misc_mem:
    FIELD   R4, 12, 3
    LD      R14, R4
    FBRA.NZ R14, ._fence_not_0
    JUMP    _id_main_loop
._fence_not_0:
    SUB     R4, 1
    LD      R14, R4
    FBRA.NZ R14, ._fence_illegal
    LDI     R4, OP_FENCE_I      ; FENCE.I
    SHIFTL  R4, 12
    SHIFTL  R4, 12
    OR      R4, R12
    FIFO.W  R4, R2
    FIFO.W  R10, R2
    FIFO.W  R0, R2
    FIFO.W  R10, R2
    JUMP    _id_main_loop
._fence_illegal:
    JUMP    _h_illegal

; ------------------------------------------------------------------------------
; SYSTEM: funct3 0 ECALL, EBREAK, MRET, WFI (does nothing: there are no
; interrupts to wait for); words: x(rs1), funct12, the PC. funct3 1-3, 5-7:
; CSRRW/S/C (OP_MRET + funct3 & 3) and their immediate forms;
; words: x(rs1) or the 5-bit immediate, the CSR address, the PC. funct3 4 is
; reserved (the hypervisor extension's HLV/HSV use it) and traps.
; ------------------------------------------------------------------------------
_h_system:
    FIELD   R8, 12, 3           ; funct3
    LD      R7, R11
    SHIFTR  R7, 15
    SHIFTR  R7, 5               ; R7 = inst[31:20]: funct12 / CSR address
    LD      R14, R8
    FBRA.NZ R14, ._csr

    WAIT_RS1 ._sy_chk, ._sy_stall
    READ_REG R5, R15
    LD      R14, R7
    FBRA.NZ R14, ._chk_ebreak
    LDI     R4, OP_ECALL        ; ECALL
    FBRA    ._send_system
._chk_ebreak:
    LD      R14, R7
    SUB     R14, 1
    FBRA.NZ R14, ._chk_mret
    LDI     R4, OP_EBREAK       ; EBREAK
    FBRA    ._send_system
._chk_mret:
    LDI     R14, 0x302
    SUB     R14, R7
    FBRA.NZ R14, ._chk_wfi
    LDI     R4, OP_MRET         ; MRET
    FBRA    ._send_system
._chk_wfi:
    LDI     R14, 0x105
    SUB     R14, R7
    FBRA.NZ R14, ._system_illegal
    JUMP    _id_main_loop       ; WFI
._send_system:
    SHIFTL  R4, 12
    SHIFTL  R4, 12
    LD      R6, R13
    SHIFTL  R6, 8
    OR      R4, R6
    OR      R4, R12
    FIFO.W  R4, R2
    FIFO.W  R5, R2
    FIFO.W  R7, R2
    FIFO.W  R10, R2
    JUMP    _id_main_loop
._system_illegal:
    JUMP    _h_illegal

._csr:
    LD      R14, R8
    SUB     R14, 4
    BBRA.Z  R14, ._system_illegal
    LD      R14, R8
    AND     R14, 4
    FBRA.Z  R14, ._csr_reg
    LD      R5, R15             ; the immediate forms: zext(rs1 field)
    FBRA    ._csr_uop
._csr_reg:
    WAIT_RS1 ._cs_chk, ._cs_stall
    READ_REG R5, R15
._csr_uop:
    FIELD   R8, 12, 3           ; funct3 again (the check uses R8)
    AND     R8, 3
    LDI     R4, OP_MRET
    ADD     R4, R8              ; OP_CSRRW, OP_CSRRS, OP_CSRRC
    LD      R9, R7              ; operand B: the CSR address
    JUMP    _send_uop
    STALL_STUB ._sy_stall, ._sy_chk
    STALL_STUB ._cs_stall, ._cs_chk
