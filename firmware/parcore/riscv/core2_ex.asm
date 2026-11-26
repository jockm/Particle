; ==============================================================================
; Parcore RV32IM_Zbb: Core 2 (Execution, ALU, M-Ext, Zbb & Branch Unit)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core2_ex.asm
; ==============================================================================
;
; Core 2 takes each 4-word packet core 1 sends ([control word, operand A,
; operand B, word 3]), drops it if it carries the old epoch (sending core 3 a
; cancel if it has a destination), and otherwise dispatches on the operation
; number in control-word bits 31:24 (parcore_ops.inc) with one JTBL. ALU
; results, loads, stores and links go on to core 3 as [control word, result,
; address or target, word 3]. Core 0 predicted every branch and followed
; every JAL: core 2 redirects it when a branch went the other way, and for
; JALR, MRET, traps and FENCE.I.
;
; Registers kept for the whole run:
;   R0   0, and FIFO channel 0 (idToEx, from core 1)
;   R1   the epoch, in bit 1 (0 or 2): flips on every redirect
;   R2   1: FIFO channel 1 (exToMem, to core 3)
; For each packet: R10 the control word, R11 operand A, R12 operand B, R13
; word 3 (the PC, or a store's data, or a branch's other address); the result goes
; in R15 and the address or target in R14.
; ==============================================================================
; This core is built without the shadow bank (ParcoreConfig)
.define NO_SHADOW_BANK 1
.include "lib/vectors.inc"
.include "parcore_ops.inc"

    VECTOR_TABLE _reset_vector
.define CSR_BASE         0x0004  ; Zero Page CSR block (0x0004..0x0043)

; Redirect core 0 to the PC in R14 (MBOX vector 1 sends it), and flip the
; epoch: from now on packets of the old epoch are on the path the redirect
; left.
.macro SEND_REDIRECT
    MBOX    R14, 1
    BINV    R1, 1
.endmacro
.define CSR_OFS_CYCLE    0x00    ; 0xC00 (cycle), 0xC01 (time)
.define CSR_OFS_CYCLEH   0x04    ; 0xC80 (cycleh), 0xC81 (timeh)
.define CSR_OFS_INSTRET  0x08    ; 0xC02 (instret)
.define CSR_OFS_STATUS   0x0C    ; 0x300 (mstatus)
.define CSR_OFS_MTVEC    0x10    ; 0x305 (mtvec)
.define CSR_OFS_MSCRATCH 0x14    ; 0x340 (mscratch)
.define CSR_OFS_MEPC     0x18    ; 0x341 (mepc)
.define CSR_OFS_MCAUSE   0x1C    ; 0x342 (mcause)
.define CSR_OFS_MTVAL    0x20    ; 0x343 (mtval)

_reset_vector:
    LD      R1, 0               ; epoch 0
    LD      R2, 1               ; exToMem

    ; Zero the CSR block (16 words from CSR_BASE)
    LD      R4, CSR_BASE
    LD      R5, 15
    ADD     R5, 1               ; 16 words
._zero_csr_loop:
    ST32    (R4), R0          ; no pointer modes in this core
    ADD     R4, 4
    SUB     R5, 1
    BBRA.NZ R5, ._zero_csr_loop

    ; Default trap vector: mtvec = 0x00000480
    LDI     R5, 0x0480
    LD      R14, CSR_BASE+CSR_OFS_MTVEC
    ST32    (R14), R5
    JUMP    _ex_main_loop

; ==============================================================================
; Send [R10, R15, R14, R13] to core 3, then the main loop
; ==============================================================================
_forward_to_mem:
    FIFO.W  R10, R2             ; control word
    FIFO.W  R15, R2             ; result
    FIFO.W  R14, R2             ; address / target
    FIFO.W  R13, R2             ; word 3 (a store's data)

_ex_main_loop:
    FIFO.R  R10, R0             ; control word
    FIFO.R  R11, R0             ; operand A
    FIFO.R  R12, R0             ; operand B
    FIFO.R  R13, R0             ; word 3
    LD      R14, R10
    AND     R14, 2
    SUB     R14, R1
    FBRA.NZ R14, _stale         ; the old epoch
    LD      R9, R10
    SHIFTR  R9, 12
    SHIFTR  R9, 12              ; the operation number
    JTBL    R9
    FBRA    _op_add             ; OP_ADD
    FBRA    _op_sll             ; OP_SLL
    FBRA    _op_slt             ; OP_SLT
    FBRA    _op_sltu            ; OP_SLTU
    FBRA    _op_xor             ; OP_XOR
    FBRA    _op_srl             ; OP_SRL
    FBRA    _op_or              ; OP_OR
    FBRA    _op_and             ; OP_AND
    FBRA    _op_sub             ; OP_SUB
    FBRA    _op_sra             ; OP_SRA
    FBRA    _op_mul             ; OP_MUL
    FBRA    _op_mulh            ; OP_MULH
    FBRA    _op_mulhsu          ; OP_MULHSU
    FBRA    _op_mulhu           ; OP_MULHU
    FBRA    _op_div             ; OP_DIV
    FBRA    _op_divu            ; OP_DIVU
    FBRA    _op_rem             ; OP_REM
    FBRA    _op_remu            ; OP_REMU
    FBRA    _op_andn            ; OP_ANDN
    FBRA    _op_orn             ; OP_ORN
    FBRA    _op_xnor            ; OP_XNOR
    FBRA    _op_clz             ; OP_CLZ
    FBRA    _t_ctz              ; OP_CTZ
    FBRA    _t_cpop             ; OP_CPOP
    FBRA    _op_max             ; OP_MAX
    FBRA    _op_maxu            ; OP_MAXU
    FBRA    _op_min             ; OP_MIN
    FBRA    _op_minu            ; OP_MINU
    FBRA    _op_sext_b          ; OP_SEXT_B
    FBRA    _op_sext_h          ; OP_SEXT_H
    FBRA    _op_zext_h          ; OP_ZEXT_H
    FBRA    _op_rol             ; OP_ROL
    FBRA    _op_ror             ; OP_ROR
    FBRA    _t_orc_b            ; OP_ORC_B
    FBRA    _t_rev8             ; OP_REV8
    FBRA    _op_lui             ; OP_LUI
    FBRA    _op_auipc           ; OP_AUIPC
    FBRA    _t_fence_i          ; OP_FENCE_I
    FBRA    _op_mem             ; OP_MEM
    FBRA    _op_beq             ; OP_BEQ
    FBRA    _op_bne             ; OP_BNE
    FBRA    _op_none            ; (BEQ + 2: never sent)
    FBRA    _op_none            ; (BEQ + 3: never sent)
    FBRA    _op_blt             ; OP_BLT
    FBRA    _op_bge             ; OP_BGE
    FBRA    _op_bltu            ; OP_BLTU
    FBRA    _op_bgeu            ; OP_BGEU
    FBRA    _op_jal             ; OP_JAL
    FBRA    _op_jalr            ; OP_JALR
    FBRA    _op_ecall           ; OP_ECALL
    FBRA    _op_ebreak          ; OP_EBREAK
    FBRA    _op_mret            ; OP_MRET
    FBRA    _op_csrrw           ; OP_CSRRW
    FBRA    _op_csrrs           ; OP_CSRRS
    FBRA    _op_csrrc           ; OP_CSRRC
    FBRA    _op_illegal         ; OP_ILLEGAL

; ------------------------------------------------------------------------------
; A packet of the old epoch was decoded on the path a taken branch left: it
; doesn't run, and if it has a destination its cancel goes to core 1
; (through core 3), which takes the register off its in-flight count
; ------------------------------------------------------------------------------
_stale:
    LD      R4, R10
    SHIFTR  R4, 8
    SHIFTL  R4, 15
    SHIFTL  R4, 12              ; Rd, in bits 31:27
    FBRA.Z  R4, _op_none
    SHIFTR  R4, 15
    SHIFTR  R4, 12
    SHIFTL  R4, 8
    OR      R4, 5               ; valid (bit 0) + cancel (bit 2), Rd in [15:8]
    LD      R10, R4
    LD      R15, 0
    LD      R14, 0
    LD      R13, 0
    JUMP    _forward_to_mem
_op_none:
    JUMP    _ex_main_loop

; Out-of-line operations
_t_ctz:
    JUMP    _do_ctz
_t_cpop:
    JUMP    _do_cpop
_t_orc_b:
    JUMP    _do_orc_b
_t_rev8:
    JUMP    _do_rev8
_t_fence_i:
    JUMP    _do_fence_i

; The SYSTEM operations go to _dispatch_system with their old uop in R3
_op_ecall:
    LDI     R3, 0x40
    JUMP    _dispatch_system
_op_ebreak:
    LDI     R3, 0x41
    JUMP    _dispatch_system
_op_mret:
    LDI     R3, 0x42
    JUMP    _dispatch_system
_op_csrrw:
    LDI     R3, 0x43
    JUMP    _dispatch_system
_op_csrrs:
    LDI     R3, 0x44
    JUMP    _dispatch_system
_op_csrrc:
    LDI     R3, 0x45
    JUMP    _dispatch_system
_op_illegal:
    LDI     R3, 0x46
    JUMP    _dispatch_system

; ------------------------------------------------------------------------------
; ALU, M and Zbb: R15 = the result
; ------------------------------------------------------------------------------
_op_add:
    LD      R15, R11
    ADD     R15, R12
    BBRA    _forward_to_mem
_op_sub:
    LD      R15, R11
    SUB     R15, R12
    BBRA    _forward_to_mem
_op_sll:
    LD      R15, R11
    SHIFTL  R15, R12            ; by R12 & 31
    BBRA    _forward_to_mem
_op_srl:
    LD      R15, R11
    SHIFTR  R15, R12
    BBRA    _forward_to_mem
_op_sra:
    LD      R15, R11
    ASHIFTR R15, R12
    BBRA    _forward_to_mem
_op_slt:
    LD      R15, R11
    SSLT    R15, R12
    BBRA    _forward_to_mem
_op_sltu:
    LD      R15, R11
    SLT     R15, R12
    BBRA    _forward_to_mem
_op_xor:
    LD      R15, R11
    XOR     R15, R12
    BBRA    _forward_to_mem
_op_or:
    LD      R15, R11
    OR      R15, R12
    BBRA    _forward_to_mem
_op_and:
    LD      R15, R11
    AND     R15, R12
    BBRA    _forward_to_mem
_op_lui:
    LD      R15, R12
    BBRA    _forward_to_mem
_op_auipc:
    LD      R15, R13
    ADD     R15, R12
    BBRA    _forward_to_mem
_op_mem:
    ; Loads and stores: the address; core 3 does the access
    LD      R14, R11
    ADD     R14, R12
    BBRA    _forward_to_mem

_op_mul:
    LD      R15, R11
    MULL    R15, R12
    BBRA    _forward_to_mem
_op_mulh:
    LD      R15, R11
    SMULH   R15, R12
    BBRA    _forward_to_mem
_op_mulhsu:
    LD      R15, R11
    MULHSU  R15, R12
    BBRA    _forward_to_mem
_op_mulhu:
    LD      R15, R11
    MULH    R15, R12            ; unsigned high word
    BBRA    _forward_to_mem
; Particle's divides give RISC-V's results: / 0 is all ones, % 0 the
; dividend, INT_MIN / -1 is INT_MIN and INT_MIN % -1 is 0
_op_div:
    LD      R15, R11
    SDIV    R15, R12
    BBRA    _forward_to_mem
_op_divu:
    LD      R15, R11
    DIV     R15, R12
    BBRA    _forward_to_mem
_op_rem:
    LD      R15, R11
    SMOD    R15, R12
    BBRA    _forward_to_mem
_op_remu:
    LD      R15, R11
    MOD     R15, R12
    BBRA    _forward_to_mem

_op_andn:
    LD      R15, R12
    NOT     R15
    AND     R15, R11
    BBRA    _forward_to_mem
_op_orn:
    LD      R15, R12
    NOT     R15
    OR      R15, R11
    BBRA    _forward_to_mem
_op_xnor:
    LD      R15, R11
    XOR     R15, R12
    NOT     R15
    BBRA    _forward_to_mem
_op_clz:
    CLZ     R15, R11
    BBRA    _forward_to_mem
_op_max:
    LD      R15, R11
    LD      R14, R11
    SSLT    R14, R12
    BBRA.Z  R14, _forward_to_mem    ; A >= B: A
    LD      R15, R12
    BBRA    _forward_to_mem
_op_maxu:
    LD      R15, R11
    LD      R14, R11
    SLT     R14, R12
    BBRA.Z  R14, _forward_to_mem
    LD      R15, R12
    BBRA    _forward_to_mem
_op_min:
    LD      R15, R11
    LD      R14, R11
    SSLT    R14, R12
    BBRA.NZ R14, _forward_to_mem    ; A < B: A
    LD      R15, R12
    BBRA    _forward_to_mem
_op_minu:
    LD      R15, R11
    LD      R14, R11
    SLT     R14, R12
    BBRA.NZ R14, _forward_to_mem
    LD      R15, R12
    BBRA    _forward_to_mem
_op_sext_b:
    LD      R15, R11
    SHIFTL  R15, 12
    SHIFTL  R15, 12
    ASHIFTR R15, 12
    ASHIFTR R15, 12
    BBRA    _forward_to_mem
_op_sext_h:
    LD      R15, R11
    SHIFTL  R15, 8
    SHIFTL  R15, 8
    ASHIFTR R15, 8
    ASHIFTR R15, 8
    BBRA    _forward_to_mem
_op_zext_h:
    LD      R15, R11
    SHIFTL  R15, 8
    SHIFTL  R15, 8
    SHIFTR  R15, 8
    SHIFTR  R15, 8
    BBRA    _forward_to_mem
_op_rol:
    LD      R15, R11
    ROTL    R15, R12
    JUMP    _forward_to_mem
_op_ror:
    LD      R15, R11
    ROTR    R15, R12
    JUMP    _forward_to_mem

; ------------------------------------------------------------------------------
; Branches. Core 0 guessed the direction (control-word bit 3: guessed taken)
; and fetched down that path; R13 is the address to go to if the guess is
; wrong. R14 = 1 if the branch is not taken (BEQ, BGE, BGEU) or taken (BNE,
; BLT, BLTU); XOR with the guess tells whether to redirect.
; ------------------------------------------------------------------------------
_op_beq:
    LD      R14, R11
    SUB     R14, R12
    NEZ     R14                 ; 1: not taken
    FBRA    ._b_not_taken_in_r14
_op_bge:
    LD      R14, R11
    SSLT    R14, R12            ; 1: not taken
    FBRA    ._b_not_taken_in_r14
_op_bgeu:
    LD      R14, R11
    SLT     R14, R12            ; 1: not taken
._b_not_taken_in_r14:
    ; wrong if not taken == guessed taken
    LD      R4, R10
    BGET    R4, 3
    XOR     R14, R4
    FBRA.Z  R14, _b_wrong
    JUMP    _ex_main_loop
_op_bne:
    LD      R14, R11
    SUB     R14, R12
    NEZ     R14                 ; 1: taken
    FBRA    ._b_taken_in_r14
_op_blt:
    LD      R14, R11
    SSLT    R14, R12            ; 1: taken
    FBRA    ._b_taken_in_r14
_op_bltu:
    LD      R14, R11
    SLT     R14, R12            ; 1: taken
._b_taken_in_r14:
    ; wrong if taken != guessed taken
    LD      R4, R10
    BGET    R4, 3
    XOR     R14, R4
    FBRA.NZ R14, _b_wrong
    JUMP    _ex_main_loop
_b_wrong:
    LD      R14, R13
    SEND_REDIRECT
    JUMP    _ex_main_loop

; ------------------------------------------------------------------------------
; JAL: core 0 followed it, and sends it only with a link: R15 = PC + 4 to rd.
; JALR (R11 + R12): a return core 0 predicted (bit 3) redirects only if its
; guess (R13) was wrong; any other: R15 = the link, redirect to the target,
; and the link goes to core 3 for a destination register.
; ------------------------------------------------------------------------------
_op_jal:
    LD      R15, R13
    ADD     R15, 4
    JUMP    _forward_to_mem
_op_jalr:
    LD      R14, R11
    ADD     R14, R12
    BCLR    R14, 0
    LD      R4, R10
    BGET    R4, 3
    FBRA.Z  R4, ._jalr_unpredicted
    ; A return core 0 predicted (Rd 0): R13 is its guess
    LD      R4, R14
    SUB     R4, R13
    FBRA.NZ R4, ._jalr_wrong
    JUMP    _ex_main_loop
._jalr_wrong:
    SEND_REDIRECT
    JUMP    _ex_main_loop
._jalr_unpredicted:
    LD      R15, R13
    ADD     R15, 4              ; the link: PC + 4
    SEND_REDIRECT
    LD      R4, R10
    SHIFTR  R4, 8
    SHIFTL  R4, 15
    SHIFTL  R4, 12              ; Rd, in bits 31:27
    FBRA.Z  R4, ._no_link
    JUMP    _forward_to_mem
._no_link:
    JUMP    _ex_main_loop

; ------------------------------------------------------------------------------
; Out-of-line Zbb operations
; ------------------------------------------------------------------------------
_do_ctz:
    LD      R4, R11
    SUB     R4, 1
    LD      R5, R11
    NOT     R5
    AND     R4, R5
    CLZ     R4, R4
    LOAD16  R15, 32
    SUB     R15, R4
    JUMP    _forward_to_mem

_do_cpop:
    LD      R4, R11
    SHIFTR  R4, 1
    LOAD32  R5, 0x55555555
    AND     R4, R5
    LD      R6, R11
    SUB     R6, R4
    LOAD32  R5, 0x33333333
    LD      R4, R6
    AND     R4, R5
    SHIFTR  R6, 2
    AND     R6, R5
    ADD     R6, R4
    LD      R4, R6
    SHIFTR  R4, 4
    ADD     R6, R4
    LOAD32  R5, 0x0F0F0F0F
    AND     R6, R5
    LOAD32  R5, 0x01010101
    MULL    R6, R5
    LD      R15, R6
    SHIFTR  R15, 12
    SHIFTR  R15, 12
    JUMP    _forward_to_mem

_do_orc_b:
    LD      R15, 0
    LOAD16  R6, 0xFF
    LD      R4, R11
    AND     R4, R6
    FBRA.Z  R4, ._orcb_b1
    OR      R15, R6
._orcb_b1:
    LD      R4, R11
    SHIFTR  R4, 8
    AND     R4, R6
    FBRA.Z  R4, ._orcb_b2
    LOAD16  R5, 0xFF00
    OR      R15, R5
._orcb_b2:
    LD      R4, R11
    SHIFTR  R4, 15
    SHIFTR  R4, 1
    AND     R4, R6
    FBRA.Z  R4, ._orcb_b3
    LOAD32  R5, 0x00FF0000
    OR      R15, R5
._orcb_b3:
    LD      R4, R11
    SHIFTR  R4, 15
    SHIFTR  R4, 9
    AND     R4, R6
    FBRA.Z  R4, ._orcb_done
    LOAD32  R5, 0xFF000000
    OR      R15, R5
._orcb_done:
    JUMP    _forward_to_mem

_do_rev8:
    LOAD16  R6, 0xFF
    ; b0 (inst[7:0]) -> byte3 (res[31:24]) (<< 24)
    LD      R15, R11
    AND     R15, R6
    SHIFTL  R15, 15
    SHIFTL  R15, 9

    ; b1 (inst[15:8]) -> byte2 (res[23:16]) (>> 8, & 0xFF, << 16)
    LD      R4, R11
    SHIFTR  R4, 8
    AND     R4, R6
    SHIFTL  R4, 15
    SHIFTL  R4, 1
    OR      R15, R4

    ; b2 (inst[23:16]) -> byte1 (res[15:8]) (>> 16, & 0xFF, << 8)
    LD      R4, R11
    SHIFTR  R4, 15
    SHIFTR  R4, 1
    AND     R4, R6
    SHIFTL  R4, 8
    OR      R15, R4

    ; b3 (inst[31:24]) -> byte0 (res[7:0]) (>> 24, & 0xFF)
    LD      R4, R11
    SHIFTR  R4, 15
    SHIFTR  R4, 9
    AND     R4, R6
    OR      R15, R4

    JUMP    _forward_to_mem


_do_fence_i:
    ; Like a taken branch to pc + 4, but with MBOX vector 2: core 0's FENCE.I
    ; handler then waits for core 3's marker, which follows every earlier
    ; store, so the next instruction is fetched after they are in its TCM.
    LD      R14, R13
    ADD     R14, 4
    MBOX    R14, 2
    BINV    R1, 1
    ; Send core 3 the FENCE.I item (valid, memory operation 11, no Rd)
    LOAD32  R10, 0x000B0001
    LD      R15, 0
    LD      R14, 0
    JUMP    _forward_to_mem

; ------------------------------------------------------------------------------
; SYSTEM and CSRs. R3 = 0x40 ECALL, 0x41 EBREAK, 0x42 MRET, 0x43 CSRRW,
; 0x44 CSRRS, 0x45 CSRRC, 0x46 an illegal instruction.
; ------------------------------------------------------------------------------
_dispatch_system:
    ; uop in R3: 0x40=ECALL, 0x41=EBREAK, 0x42=MRET, 0x43=CSRRW, 0x44=CSRRS, 0x45=CSRRC,
    ; 0x46=illegal instruction
    ; R10 = Control Word, R11 = OpA, R12 = OpB (12-bit CSR; the instruction for
    ; 0x46), R13 = Base PC

    ; 0x46: an instruction core 1 couldn't decode: mcause 2, mtval = it
    LOAD16  R4, 0x46
    LD      R5, R3
    SUB     R5, R4
    FBRA.NZ R5, ._not_illegal
    LD      R14, CSR_BASE+CSR_OFS_MEPC
    ST32    (R14), R13
    LD      R14, CSR_BASE+CSR_OFS_MTVAL
    ST32    (R14), R12
    LOAD16  R7, 2
    LD      R14, CSR_BASE+CSR_OFS_MCAUSE
    ST32    (R14), R7
    JUMP    ._system_trap_redirect
._not_illegal:

    ; 0x40: ECALL
    LOAD16  R4, 0x40
    BNE     R3, R4, ._chk_ebreak

._do_ecall:
    LD      R14, CSR_BASE+CSR_OFS_MEPC
    ST32    (R14), R13
    LOAD16  R7, 11
    LD      R14, CSR_BASE+CSR_OFS_MCAUSE
    ST32    (R14), R7
    JUMP    ._system_trap_redirect

._chk_ebreak:
    ; 0x41: EBREAK
    LOAD16  R4, 0x41
    BNE     R3, R4, ._chk_mret

._do_ebreak:
    LD      R14, CSR_BASE+CSR_OFS_MEPC
    ST32    (R14), R13
    LOAD16  R7, 3
    LD      R14, CSR_BASE+CSR_OFS_MCAUSE
    ST32    (R14), R7
    JUMP    ._system_trap_redirect

._chk_mret:
    ; 0x42: MRET
    LOAD16  R4, 0x42
    BNE     R3, R4, ._chk_csr_ops

._do_mret:
    LD      R14, CSR_BASE+CSR_OFS_MEPC
    LD32    R14, (R14)
    SEND_REDIRECT
    JUMP    _ex_main_loop

._system_trap_redirect:
    LD      R14, CSR_BASE+CSR_OFS_MTVEC
    LD32    R14, (R14)
    FBRA.Z  R14, ._use_default_mtvec
    JUMP    ._do_trap_strobe      ; R14 (the target) is kept

._use_default_mtvec:
    LOAD32  R14, 0x00000480

._do_trap_strobe:
    SEND_REDIRECT
    JUMP    _ex_main_loop

._chk_csr_ops:
    ; R6 holds the CSR's address
    ; 0xC00: cycle
    LOAD16  R6, CSR_BASE+CSR_OFS_CYCLE
    LOAD16  R7, 0xC00
    BEQ     R12, R7, ._read_csr_val

._c1:
    ; 0xC01: time
    LOAD16  R7, 0xC01
    BEQ     R12, R7, ._read_csr_val

._c2:
    ; 0xC80: cycleh
    LOAD16  R6, CSR_BASE+CSR_OFS_CYCLEH
    LOAD16  R7, 0xC80
    BEQ     R12, R7, ._read_csr_val

._c3:
    ; 0xC81: timeh
    LOAD16  R7, 0xC81
    BEQ     R12, R7, ._read_csr_val

._c4:
    ; 0xC02: instret
    LOAD16  R6, CSR_BASE+CSR_OFS_INSTRET
    LOAD16  R7, 0xC02
    BEQ     R12, R7, ._read_csr_val

._c5:
    ; 0x300: mstatus
    LOAD16  R6, CSR_BASE+CSR_OFS_STATUS
    LOAD16  R7, 0x300
    BEQ     R12, R7, ._read_csr_val

._c6:
    ; 0x305: mtvec
    LOAD16  R6, CSR_BASE+CSR_OFS_MTVEC
    LOAD16  R7, 0x305
    BEQ     R12, R7, ._read_csr_val

._c7:
    ; 0x340: mscratch
    LOAD16  R6, CSR_BASE+CSR_OFS_MSCRATCH
    LOAD16  R7, 0x340
    BEQ     R12, R7, ._read_csr_val

._c8:
    ; 0x341: mepc
    LOAD16  R6, CSR_BASE+CSR_OFS_MEPC
    LOAD16  R7, 0x341
    BEQ     R12, R7, ._read_csr_val

._c9:
    ; 0x342: mcause
    LOAD16  R6, CSR_BASE+CSR_OFS_MCAUSE
    LOAD16  R7, 0x342
    BEQ     R12, R7, ._read_csr_val

._c10:
    ; 0x343: mtval
    LOAD16  R6, CSR_BASE+CSR_OFS_MTVAL
    LOAD16  R7, 0x343
    BEQ     R12, R7, ._read_csr_val

._csr_unmapped:
    LD      R15, 0
    JUMP    _forward_to_mem

._read_csr_val:
    LD32    R15, (R6)           ; R15 = Old CSR Value (R6 = CSR address)

    ; Compute New CSR Value in R4 based on uop in R3
    LOAD16  R7, 0x43            ; CSRRW
    BNE     R3, R7, ._try_csrrs

._is_csrrw:
    LD      R4, R11
    JUMP    ._do_st_csr    ; CSRRW always writes, even a value of 0

._try_csrrs:
    LOAD16  R7, 0x44            ; CSRRS
    BNE     R3, R7, ._try_csrrc

._is_csrrs:
    LD      R4, R15
    OR      R4, R11
    JUMP    ._writeback_csr

._try_csrrc:
    LD      R8, R11             ; CSRRC
    NOT     R8
    LD      R4, R15
    AND     R4, R8

._writeback_csr:
    ; CSRRS / CSRRC with nothing to set or clear don't write
    FBRA.NZ R11, ._do_st_csr
    JUMP    ._finish_csr

._do_st_csr:
    ST32    (R6), R4

._finish_csr:
    JUMP    _forward_to_mem
; ------------------------------------------------------------------------------
