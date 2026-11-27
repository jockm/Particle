; ==============================================================================
; Parcore RV32IM: Core 0 (Instruction Fetch, Decode and Branch Prediction)
; The FTDI console UART is core 3's: guests reach it as memory-mapped I/O.
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core0_if.asm
; ==============================================================================
;
; Core 0 fetches each guest instruction, decodes it, and sends core 1 a
; 5-word packet: [control word, w1, w2, B, W3] (see parcore_ops.inc). It
; predicts as it goes: it follows JAL (and sends nothing for a JAL with no
; link), guesses backward branches taken and forward branches not taken,
; predicts returns with a return-address stack, and fetches down the
; guessed path. Core 2 redirects it when a guess is wrong, on other JALRs,
; MRET and traps, and for FENCE.I.
;
; TCM (16 KiB): the return-address stack in the zero page; the vectors,
; redirect handlers and _apply_mirror below 0x500; the guest image at 0x500-0x1FFF (kept the same as core 3's by its
; store mirror); the fetch and decode loop from 0x2000.
;
; Registers kept for the whole run:
;   R1   1: FIFO channel 1 (ifToId, to core 1)
;   R8   2: FIFO channel 2 (memToIf: stores core 3 mirrors, FENCE.I markers)
;   R9   the flags for the control word: valid | epoch << 1 (1 or 3)
;   R10  the guest PC
;   R11  the mirror entry being applied (0 when none)
;   R12  _apply_mirror's return address
; For each instruction: R5 the instruction, R3 the control word, R4 w1, R6
; w2, R7 B, R13 W3; R15 the next PC when it isn't PC + 4 (_send_*_goto); R2
; and R14 scratch. Registers named in
; w1, w2 and B go as their number times 8 (parcore_ops.inc): R4 is scaled as
; it is extracted, R6 (rd or rs2) at _push, since the control word's Rd is the
; plain number.
; ==============================================================================
; This core is built without the shadow bank (ParcoreConfig)
.define NO_SHADOW_BANK 1
.include "lib/vectors.inc"
.include "parcore_ops.inc"

; The packets core 0 may have queued in ifToId: it sends another only while
; fewer than 16 words are there (four 5-word packets at most)
.define QUEUE_SHIFT     12      ; status >> 12 = words queued / 16

; The return-address stack: 16 words at 0x00-0x3F, used as a ring (a deeper
; call chain overwrites the oldest), and the index of its top at RAS_TOP. A
; call (JAL or JALR with rd x1 or x5) pushes PC + 4; a return (JALR with rd
; x0 and rs1 x1 or x5) pops its guess. A wrong guess costs a redirect.
.define RAS_TOP         0x40

; Push R15 (PC + 4: the caller sets it) on the return-address stack. Uses R2,
; R14.
.macro RAS_PUSH
    LD      R14, RAS_TOP
    LD32    R2, (R14)
    ADD     R2, 1
    AND     R2, 15
    ST32    (R14), R2
    SHIFTL  R2, 2
    ST32    (R2), R15
.endmacro

; dst = src[pos + len - 1 : pos] (len 1..7). Uses R14.
.macro FIELD dst, src, pos, len
    BEXTR   %dst, %src, %pos, %len
.endmacro

; The tails, inline in the commonest handlers so they take no jump to a
; shared one: R2 = op << 8 | class << 4 | mem_op; R6 = rd (SEND_RD) or w2
; (SEND_NORD: the control word gets Rd 0); then the packet, and on to the
; next instruction (PC + 4)
.macro SEND_RD_TAIL
    SHIFTL  R2, 8
    OR      R2, R6
    SHIFTL  R2, 8
    OR      R3, R2
    PUSH_TAIL
.endmacro
.macro SEND_NORD_TAIL
    SHIFTL  R2, 8
    SHIFTL  R2, 8
    OR      R3, R2
    PUSH_TAIL
.endmacro
.macro PUSH_TAIL
    SHIFTL  R6, 3               ; w2: rd or rs2, times 8
    FIFO.W  R3, R1              ; the control word
    FIFO.W  R4, R1              ; w1
    FIFO.W  R6, R1              ; w2
    FIFO.W  R7, R1              ; B
    FIFO.W  R13, R1             ; W3
    ADD     R10, 4
    JUMP    _if_main_loop
.endmacro

    RESET_SLOT _reset_vector
    TRAP_SLOT_BRANCH 1, _branch_redirect_handler
    TRAP_SLOT_BRANCH 2, _fence_i_handler
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
    LDI     R10, 0x0500         ; the guest's first instruction
    LD      R1, 1               ; ifToId
    LD      R8, 2               ; memToIf
    LD      R9, 1               ; valid, epoch 0
    LD      R11, 0              ; no mirror entry
    LD      R14, RAS_TOP
    ST32    (R14), R0           ; the return-address stack: empty (all zero)
    JUMP    _if_main_loop

; ==============================================================================
; Trap 1: core 2 redirects (a wrong guess, JALR, MRET, a trap). ifToId was
; flushed as the MBOX arrived; core 1 may have read part of a packet, so a
; marker packet goes first (see parcore_ops.inc).
; ==============================================================================
_branch_redirect_handler:
    LDI     R14, _apply_mirror  ; finish an entry the MBOX interrupted
    JMP     R14, R12
    LDIS    R14, NI_MBOX_VALUE  ; the MBOX's value (Documentation/mbox_design.md)
    LD32    R10, (R14)          ; the new PC
    BINV    R9, 1               ; new epoch: core 2 drops what was sent before
_send_markers:
    ; Flush ifToId first: the network interface sends a FLUSH behind what was
    ; sent on the wrong path, and core 1's buffer is emptied when it arrives
    LDIS    R14, NI_FLUSH       ; 0xFFFF_FF00, the FLUSH register
    ST32    (R14), R1           ; R1 = 1, the channel to core 1
    LD      R14, -1
    FIFO.W  R14, R1
    FIFO.W  R14, R1
    FIFO.W  R14, R1
    FIFO.W  R14, R1
    FIFO.W  R14, R1
    ; Taking the MBOX masked further ones, and these handlers don't return
    ; with RETI (they restart the main loop): unmask here
    EI
    JUMP    _if_main_loop

; FENCE.I (MBOX vector 2 from core 2): redirect to the instruction after the
; FENCE.I, but first write into the TCM every store core 3 mirrored before it,
; up to its marker. Nothing new reaches core 2 meanwhile, since nothing is
; fetched, so no other MBOX arrives.
_fence_i_handler:
    LDI     R14, _apply_mirror  ; finish an entry the MBOX interrupted
    JMP     R14, R12
    LDIS    R14, NI_MBOX_VALUE  ; the MBOX's value (Documentation/mbox_design.md)
    LD32    R10, (R14)          ; the new PC
    BINV    R9, 1               ; new epoch
._fence_drain:
    FIFO.R  R11, R8             ; waits for core 3
    BEXTR   R4, R11, 13, 2
    SUB     R4, 3               ; kind 3: the marker
    FBRA.Z  R4, ._fence_done
    RJUMP   _apply_mirror, R12
    BBRA    ._fence_drain
._fence_done:
    LD      R11, 0
    BBRA    _send_markers

; Write the mirror entry in R11 into the TCM and set R11 to 0; returns to R12.
; Entry: [31:16] data, [14:13] kind (1 byte, 2 halfword, 3 marker),
; [12:0] address. Does nothing when R11 is 0 or a marker. Writing an entry
; twice is harmless, so a handler can apply one the MBOX interrupted.
_apply_mirror:
    LD      R14, R11
    FBRA.Z  R14, ._apply_done
    LD      R3, R11
    LDI     R4, 0x1FFF
    AND     R3, R4              ; R3 = address
    BEXTR   R5, R11, 16, 16     ; R5 = data
    BEXTR   R4, R11, 13, 2      ; R4 = kind
    SUB     R4, 1
    FBRA.NZ R4, ._apply_half
    ST8     (R3), R5
    FBRA    ._apply_done
._apply_half:
    SUB     R4, 1
    FBRA.NZ R4, ._apply_done    ; the marker: nothing to write
    ST16    (R3), R5
._apply_done:
    LD      R11, 0
    JMP     R12, R0

; ==============================================================================
; Main loop, past the guest area
; ==============================================================================
.org 0x2000
; A zero word: the end of the program, or past it after a branch guessed not
; taken. Sleep (CORE_STATE shows it, so the conductor's watchdog knows the
; guest is done) until a redirect's MBOX wakes the core; its handler goes back
; to the main loop. Not HALT: a halted core takes no MBOX, and the redirect
; may be on its way. (Here, not in the loop: the loop's test falls through.)
_if_program_end:
    WAIT
_if_main_loop:
    ; Fewer than 16 words queued in ifToId (bits 16:8 of its status)?
    FIFO.STAT R14, R1
    SHIFTR  R14, QUEUE_SHIFT
    FBRA.NZ R14, _if_queue_full
    LD32    R5, (R10)           ; the instruction (a zero word: entry 0)
    LD      R13, R10            ; W3: the PC
    LD      R3, R9              ; the control word: the flags so far
    FIELD   R6, R5, 7, 5        ; w2: rd (scaled at _push)
    FIELD   R4, R5, 15, 5
    SHIFTL  R4, 3               ; w1: rs1 * 8 (core 1's register slot)
    FIELD   R2, R5, 0, 7
    JTBL    R2
    FBRA    _h_zero             ; 0x00: a zero word ends the program
    FBRA    _h_illegal          ; 0x01
    FBRA    _h_illegal          ; 0x02
    FBRA    _h_load             ; 0x03
    FBRA    _h_illegal          ; 0x04
    FBRA    _h_illegal          ; 0x05
    FBRA    _h_illegal          ; 0x06
    FBRA    _h_illegal          ; 0x07
    FBRA    _h_illegal          ; 0x08
    FBRA    _h_illegal          ; 0x09
    FBRA    _h_illegal          ; 0x0A
    FBRA    _h_illegal          ; 0x0B
    FBRA    _h_illegal          ; 0x0C
    FBRA    _h_illegal          ; 0x0D
    FBRA    _h_illegal          ; 0x0E
    FBRA    _t_misc_mem         ; 0x0F
    FBRA    _h_illegal          ; 0x10
    FBRA    _h_illegal          ; 0x11
    FBRA    _h_illegal          ; 0x12
    FBRA    _h_op_imm           ; 0x13
    FBRA    _h_illegal          ; 0x14
    FBRA    _h_illegal          ; 0x15
    FBRA    _h_illegal          ; 0x16
    FBRA    _t_auipc            ; 0x17
    FBRA    _h_illegal          ; 0x18
    FBRA    _h_illegal          ; 0x19
    FBRA    _h_illegal          ; 0x1A
    FBRA    _h_illegal          ; 0x1B
    FBRA    _h_illegal          ; 0x1C
    FBRA    _h_illegal          ; 0x1D
    FBRA    _h_illegal          ; 0x1E
    FBRA    _h_illegal          ; 0x1F
    FBRA    _h_illegal          ; 0x20
    FBRA    _h_illegal          ; 0x21
    FBRA    _h_illegal          ; 0x22
    FBRA    _h_store            ; 0x23
    FBRA    _h_illegal          ; 0x24
    FBRA    _h_illegal          ; 0x25
    FBRA    _h_illegal          ; 0x26
    FBRA    _h_illegal          ; 0x27
    FBRA    _h_illegal          ; 0x28
    FBRA    _h_illegal          ; 0x29
    FBRA    _h_illegal          ; 0x2A
    FBRA    _h_illegal          ; 0x2B
    FBRA    _h_illegal          ; 0x2C
    FBRA    _h_illegal          ; 0x2D
    FBRA    _h_illegal          ; 0x2E
    FBRA    _h_illegal          ; 0x2F
    FBRA    _h_illegal          ; 0x30
    FBRA    _h_illegal          ; 0x31
    FBRA    _h_illegal          ; 0x32
    FBRA    _t_op               ; 0x33
    FBRA    _h_illegal          ; 0x34
    FBRA    _h_illegal          ; 0x35
    FBRA    _h_illegal          ; 0x36
    FBRA    _t_lui              ; 0x37
    FBRA    _h_illegal          ; 0x38
    FBRA    _h_illegal          ; 0x39
    FBRA    _h_illegal          ; 0x3A
    FBRA    _h_illegal          ; 0x3B
    FBRA    _h_illegal          ; 0x3C
    FBRA    _h_illegal          ; 0x3D
    FBRA    _h_illegal          ; 0x3E
    FBRA    _h_illegal          ; 0x3F
    FBRA    _h_illegal          ; 0x40
    FBRA    _h_illegal          ; 0x41
    FBRA    _h_illegal          ; 0x42
    FBRA    _h_illegal          ; 0x43
    FBRA    _h_illegal          ; 0x44
    FBRA    _h_illegal          ; 0x45
    FBRA    _h_illegal          ; 0x46
    FBRA    _h_illegal          ; 0x47
    FBRA    _h_illegal          ; 0x48
    FBRA    _h_illegal          ; 0x49
    FBRA    _h_illegal          ; 0x4A
    FBRA    _h_illegal          ; 0x4B
    FBRA    _h_illegal          ; 0x4C
    FBRA    _h_illegal          ; 0x4D
    FBRA    _h_illegal          ; 0x4E
    FBRA    _h_illegal          ; 0x4F
    FBRA    _h_illegal          ; 0x50
    FBRA    _h_illegal          ; 0x51
    FBRA    _h_illegal          ; 0x52
    FBRA    _h_illegal          ; 0x53
    FBRA    _h_illegal          ; 0x54
    FBRA    _h_illegal          ; 0x55
    FBRA    _h_illegal          ; 0x56
    FBRA    _h_illegal          ; 0x57
    FBRA    _h_illegal          ; 0x58
    FBRA    _h_illegal          ; 0x59
    FBRA    _h_illegal          ; 0x5A
    FBRA    _h_illegal          ; 0x5B
    FBRA    _h_illegal          ; 0x5C
    FBRA    _h_illegal          ; 0x5D
    FBRA    _h_illegal          ; 0x5E
    FBRA    _h_illegal          ; 0x5F
    FBRA    _h_illegal          ; 0x60
    FBRA    _h_illegal          ; 0x61
    FBRA    _h_illegal          ; 0x62
    FBRA    _h_branch           ; 0x63
    FBRA    _h_illegal          ; 0x64
    FBRA    _h_illegal          ; 0x65
    FBRA    _h_illegal          ; 0x66
    FBRA    _t_jalr             ; 0x67
    FBRA    _h_illegal          ; 0x68
    FBRA    _h_illegal          ; 0x69
    FBRA    _h_illegal          ; 0x6A
    FBRA    _h_illegal          ; 0x6B
    FBRA    _h_illegal          ; 0x6C
    FBRA    _h_illegal          ; 0x6D
    FBRA    _h_illegal          ; 0x6E
    FBRA    _t_jal              ; 0x6F
    FBRA    _h_illegal          ; 0x70
    FBRA    _h_illegal          ; 0x71
    FBRA    _h_illegal          ; 0x72
    FBRA    _t_system           ; 0x73
    FBRA    _h_illegal          ; 0x74
    FBRA    _h_illegal          ; 0x75
    FBRA    _h_illegal          ; 0x76
    FBRA    _h_illegal          ; 0x77
    FBRA    _h_illegal          ; 0x78
    FBRA    _h_illegal          ; 0x79
    FBRA    _h_illegal          ; 0x7A
    FBRA    _h_illegal          ; 0x7B
    FBRA    _h_illegal          ; 0x7C
    FBRA    _h_illegal          ; 0x7D
    FBRA    _h_illegal          ; 0x7E
    FBRA    _h_illegal          ; 0x7F

; ifToId is full: meanwhile apply one store core 3 mirrored (FENCE.I
; coherence), if it sent any. Only here (462; the FENCE.I handler takes them
; all): core 2 waits while its channel to core 3 is half full, so a core 3
; waiting on a full memToIf holds the pipeline up until core 0's queue fills
; and core 0 comes here.
_if_queue_full:
    FIFO.STAT R14, R8
    AND     R14, 1              ; bit 0: empty
    BBRA.NZ R14, _if_main_loop
    FIFO.R  R11, R8
    RJUMP   _apply_mirror, R12
    BBRA    _if_main_loop

; Opcode 0: a zero word is the end of the program (or past it, after a branch
; guessed not taken); anything else is illegal
_h_zero:
    LD      R14, R5
    BBRA.Z  R14, _if_program_end
    JUMP    _h_illegal

_t_jal:
    JUMP    _h_jal
_t_jalr:
    JUMP    _h_jalr
_t_system:
    JUMP    _h_system
_t_misc_mem:
    JUMP    _h_misc_mem
_t_op:
    JUMP    _h_op
_t_lui:
    JUMP    _h_lui
_t_auipc:
    JUMP    _h_auipc

; ------------------------------------------------------------------------------
; An instruction that can't be decoded: OP_ILLEGAL, which traps in core 2
; with mcause 2 and mtval = the instruction (B). No destination.
; ------------------------------------------------------------------------------
_h_illegal:
    LDI     R2, OP_ILLEGAL * 256 + CLASS_IMM * 16
    LD      R6, 0
    LD      R7, R5
    JUMP    _send_rd

; ------------------------------------------------------------------------------
; LOAD: OP_MEM, CLASS_RS1_IMM; mem_op 1 LB, 2 LH, 3 LW, 4 LBU, 5 LHU
; ------------------------------------------------------------------------------
_h_load:
    FIELD   R2, R5, 12, 3       ; funct3
    LD      R14, 0x37           ; valid funct3: bits 0, 1, 2, 4, 5
    BGET    R14, R2
    BBRA.Z  R14, _h_illegal
    LD      R14, R2
    SUB     R14, 3
    SSLT    R14, 0              ; 1 if funct3 < 3
    ADD     R2, R14             ; mem_op
    LDI     R14, OP_MEM * 256 + CLASS_RS1_IMM * 16
    OR      R2, R14
    SBEXTR  R7, R5, 20, 12      ; B: the offset
    SEND_RD_TAIL

; ------------------------------------------------------------------------------
; OP-IMM: OP_ADD + funct3, SRAI OP_SRA, the Zbb forms their own;
; CLASS_RS1_IMM, B the I-immediate
; ------------------------------------------------------------------------------
_h_op_imm:
    FIELD   R2, R5, 12, 3       ; funct3
    LD      R14, 0x22           ; funct3 1 or 5: shifts and Zbb
    BGET    R14, R2
    FBRA.NZ R14, _t_op_imm_shift
_op_imm_send:
    SBEXTR  R7, R5, 20, 12      ; B: the I-immediate
    SHIFTL  R2, 8               ; op << 8, CLASS_RS1_IMM, mem_op 0
    SEND_RD_TAIL

; ------------------------------------------------------------------------------
; STORE: OP_MEM, CLASS_STORE; mem_op = funct3 + 8; w2 rs2, B the offset
; ------------------------------------------------------------------------------
_h_store:
    FIELD   R2, R5, 12, 3       ; funct3
    LD      R14, 0x07           ; valid funct3: 0, 1, 2
    BGET    R14, R2
    BBRA.Z  R14, _h_illegal
    ADD     R2, 8
    LDI     R14, OP_MEM * 256 + CLASS_STORE * 16
    OR      R2, R14
    ; S-immediate: {inst[31:25], inst[11:7]} (R6 holds inst[11:7])
    SBEXTR  R7, R5, 25, 7
    SHIFTL  R7, 5
    OR      R7, R6
    FIELD   R6, R5, 20, 5       ; w2: rs2
    SEND_NORD_TAIL

; ------------------------------------------------------------------------------
; BRANCH: OP_BEQ + funct3, CLASS_BRANCH; w2 rs2. Backward: guess taken
; (fetch the target; W3 = PC + 4). Forward: guess not taken (W3 = the target).
; ------------------------------------------------------------------------------
_h_branch:
    FIELD   R2, R5, 12, 3       ; funct3
    LD      R14, 0xF3           ; valid funct3: all but 2 and 3
    BGET    R14, R2
    BBRA.Z  R14, _h_illegal
    LDI     R14, OP_BEQ
    ADD     R2, R14
    SHIFTL  R2, 8
    LD      R14, CLASS_BRANCH * 16
    OR      R2, R14
    ; B-immediate: {inst[31], inst[7], inst[30:25], inst[11:8], 0}
    SBEXTR  R7, R5, 31, 1
    SHIFTL  R7, 12              ; inst[31], sign-extended, at bit 12
    LD      R14, R6
    AND     R14, 1
    SHIFTL  R14, 11
    OR      R7, R14             ; inst[7] (rd bit 0) at bit 11
    LD      R14, R6
    BCLR    R14, 0
    OR      R7, R14             ; inst[11:8] (rd bits 4:1) at bits 4:1
    BEXTR   R14, R5, 25, 6
    SHIFTL  R14, 5
    OR      R7, R14             ; inst[30:25] at bits 10:5
    ADD     R7, R10             ; the target
    FIELD   R6, R5, 20, 5       ; w2: rs2
    FBRA.N  R5, ._b_backward    ; inst[31]: the offset's sign
    LD      R13, R7             ; forward: not taken; if wrong, the target
    SEND_NORD_TAIL
._b_backward:
    OR      R3, 8               ; predicted taken
    LD      R13, R10
    ADD     R13, 4              ; if wrong, PC + 4
    LD      R15, R7             ; fetch the target next
    JUMP    _send_nord_goto

; ------------------------------------------------------------------------------
; The shared tails (the commonest handlers have their own copies:
; SEND_RD_TAIL, SEND_NORD_TAIL): R2 = op << 8 | class << 4 | mem_op; R6 = rd
; (_send_rd) or w2 (_send_nord, the control word gets Rd 0); then the packet,
; and the PC moves on to PC + 4, or with _send_*_goto to R15
; ------------------------------------------------------------------------------
_send_rd:
    SEND_RD_TAIL
_send_nord_goto:
    SHIFTL  R2, 8
    SHIFTL  R2, 8
    OR      R3, R2
    FBRA    _push_goto
_send_rd_goto:
    SHIFTL  R2, 8
    OR      R2, R6
    SHIFTL  R2, 8
    OR      R3, R2
_push_goto:
    SHIFTL  R6, 3               ; w2: rd or rs2, times 8
    FIFO.W  R3, R1              ; the control word
    FIFO.W  R4, R1              ; w1
    FIFO.W  R6, R1              ; w2
    FIFO.W  R7, R1              ; B
    FIFO.W  R13, R1             ; W3
_goto:
    LD      R10, R15
    JUMP    _if_main_loop
; Nothing to send: on to PC + 4
_advance:
    ADD     R10, 4
    JUMP    _if_main_loop

_t_op_imm_shift:
    JUMP    _op_imm_shift

; ------------------------------------------------------------------------------
; OP: OP_ADD + funct3, OP_MUL + funct3 for M, OP_SUB and OP_SRA, the Zbb
; operations their own; CLASS_RS1_RS2, B rs2
; ------------------------------------------------------------------------------
_h_op:
    FIELD   R2, R5, 12, 3       ; funct3
    BEXTR   R14, R5, 25, 7      ; funct7
    FBRA.Z  R14, _op_send       ; ADD, SLL, SLT, SLTU, XOR, SRL, OR, AND
    SUB     R14, 1
    FBRA.NZ R14, _t_op_funct7
    ADD     R2, OP_MUL          ; M: MUL ... REMU
_op_send:
    FIELD   R7, R5, 20, 5
    SHIFTL  R7, 3               ; B: rs2 * 8
    SHIFTL  R2, 8
    LD      R14, CLASS_RS1_RS2 * 16
    OR      R2, R14
    SEND_RD_TAIL
_t_op_funct7:
    JUMP    _op_funct7

; ------------------------------------------------------------------------------
; JALR: OP_JALR, CLASS_RS1_IMM, B the I-immediate. A call (rd x1 or x5)
; pushes PC + 4 and isn't predicted: core 2 redirects, and until then core 0
; fetches on from PC + 4. A return (rd x0, rs1 x1 or x5) is predicted from
; the return-address stack: core 0 fetches the guess, sets bit 3 and sends
; the guess as W3; core 2 redirects only if the target differs.
; ------------------------------------------------------------------------------
_h_jalr:
    FIELD   R2, R5, 12, 3       ; funct3: 0 only
    LD      R14, R2
    FBRA.NZ R14, _t_illegal
    SBEXTR  R7, R5, 20, 12
    LD      R14, R6
    FBRA.Z  R14, ._jalr_rd0
    OR      R14, 4
    SUB     R14, 5
    FBRA.NZ R14, ._jalr_send    ; rd not x1 or x5: not a call
    LD      R15, R10
    ADD     R15, 4
    RAS_PUSH                    ; PC + 4
    FBRA    ._jalr_send
._jalr_rd0:
    LD      R14, R4
    SHIFTR  R14, 3              ; rs1 (R4 is rs1 * 8)
    OR      R14, 4
    SUB     R14, 5
    FBRA.NZ R14, ._jalr_send    ; rs1 not x1 or x5: not a return
    ; A return: pop the guess
    LD      R14, RAS_TOP
    LD32    R2, (R14)
    LD      R13, R2
    SHIFTL  R13, 2
    LD32    R13, (R13)          ; W3: the guess
    SUB     R2, 1
    AND     R2, 15
    ST32    (R14), R2
    OR      R3, 8               ; predicted
    LD      R15, R13            ; fetch the guess next
    LDI     R2, OP_JALR * 256 + CLASS_RS1_IMM * 16
    JUMP    _send_rd_goto
._jalr_send:
    LDI     R2, OP_JALR * 256 + CLASS_RS1_IMM * 16
    JUMP    _send_rd
_t_illegal:
    JUMP    _h_illegal

; ------------------------------------------------------------------------------
; JAL: followed. With a link: OP_JAL, CLASS_IMM (core 2 sends PC + 4 to rd).
; Without one (j): nothing to send.
; ------------------------------------------------------------------------------
_h_jal:
    ; J-immediate: {inst[31], inst[19:12], inst[20], inst[30:21], 0}
    SBEXTR  R7, R5, 31, 1
    SHIFTL  R7, 15
    SHIFTL  R7, 5               ; inst[31], sign-extended, at bit 20
    BEXTR   R14, R5, 12, 8
    SHIFTL  R14, 12
    OR      R7, R14             ; inst[19:12] at bits 19:12
    BEXTR   R14, R5, 20, 1
    SHIFTL  R14, 11
    OR      R7, R14             ; inst[20] at bit 11
    BEXTR   R14, R5, 21, 10
    SHIFTL  R14, 1
    OR      R7, R14             ; inst[30:21] at bits 10:1
    LD      R14, R6
    FBRA.Z  R14, ._jal_go       ; no link
    OR      R14, 4
    SUB     R14, 5
    FBRA.NZ R14, ._jal_go       ; rd not x1 or x5: not a call
    LD      R15, R10
    ADD     R15, 4
    RAS_PUSH                    ; PC + 4
._jal_go:
    LD      R15, R10
    ADD     R15, R7             ; fetch the target next
    LD      R14, R6
    BBRA.Z  R14, _goto          ; no link: nothing to send
    LDI     R2, OP_JAL * 256 + CLASS_IMM * 16
    JUMP    _send_rd_goto

; ------------------------------------------------------------------------------
; LUI (OP_LUI) and AUIPC (OP_AUIPC): CLASS_IMM, B the U-immediate
; ------------------------------------------------------------------------------
_h_lui:
    LDI     R2, OP_LUI * 256 + CLASS_IMM * 16
    FBRA    ._u_imm
_h_auipc:
    LDI     R2, OP_AUIPC * 256 + CLASS_IMM * 16
._u_imm:
    LD      R7, R5
    SHIFTR  R7, 12
    SHIFTL  R7, 12              ; inst[31:12] << 12
    SEND_RD_TAIL

; ------------------------------------------------------------------------------
; MISC-MEM: funct3 0 FENCE (nothing to do: one core does every load and
; store, in order), 1 FENCE.I (OP_FENCE_I, CLASS_IMM, no Rd); 2-7 are
; reserved (Zicbom/Zicboz cache-block operations use 2) and trap as illegal
; ------------------------------------------------------------------------------
_h_misc_mem:
    FIELD   R2, R5, 12, 3
    LD      R14, R2
    BBRA.Z  R14, _advance       ; FENCE
    SUB     R14, 1
    FBRA.NZ R14, ._misc_illegal
    LDI     R2, OP_FENCE_I * 256 + CLASS_IMM * 16
    LD      R6, 0
    LD      R7, 0
    JUMP    _send_rd
._misc_illegal:
    JUMP    _h_illegal

; ------------------------------------------------------------------------------
; SYSTEM. funct3 0: ECALL, EBREAK, MRET (CLASS_RS1_IMM with Rd 0, B funct12);
; WFI does nothing (there are no interrupts to wait for). funct3 1-3: CSRRW,
; CSRRS, CSRRC (OP_MRET + funct3 & 3, CLASS_RS1_IMM, B the CSR); 5-7 their
; immediate forms (CLASS_ZIMM, w1 the immediate); 4 is reserved (the
; hypervisor extension's HLV/HSV use it) and traps.
; ------------------------------------------------------------------------------
_h_system:
    FIELD   R2, R5, 12, 3       ; funct3
    BEXTR   R7, R5, 20, 12    ; B: inst[31:20], funct12 or the CSR
    LD      R14, R2
    FBRA.NZ R14, ._csr
    LD      R6, 0               ; no Rd
    LD      R14, R7
    FBRA.NZ R14, ._chk_ebreak
    LDI     R2, OP_ECALL * 256
    JUMP    _send_rd
._chk_ebreak:
    SUB     R14, 1
    FBRA.NZ R14, ._chk_mret
    LDI     R2, OP_EBREAK * 256
    JUMP    _send_rd
._chk_mret:
    LDI     R14, 0x302
    SUB     R14, R7
    FBRA.NZ R14, ._chk_wfi
    LDI     R2, OP_MRET * 256
    JUMP    _send_rd
._chk_wfi:
    LDI     R14, 0x105
    SUB     R14, R7
    FBRA.NZ R14, ._system_illegal
    JUMP    _advance            ; WFI
._system_illegal:
    JUMP    _h_illegal
._csr:
    SUB     R14, 4
    BBRA.Z  R14, ._system_illegal
    LD      R14, R2
    AND     R2, 3
    LDI     R13, OP_MRET
    ADD     R2, R13             ; OP_CSRRW, OP_CSRRS, OP_CSRRC
    LD      R13, R10            ; W3: the PC again
    SHIFTL  R2, 8               ; CLASS_RS1_IMM
    AND     R14, 4
    FBRA.Z  R14, ._csr_send
    LD      R14, CLASS_ZIMM * 16 ; the immediate forms: w1 = zext(rs1 field)
    OR      R2, R14
    SHIFTR  R4, 3               ; (not scaled: it is a value)
._csr_send:
    JUMP    _send_rd

; ------------------------------------------------------------------------------
; OP-IMM with funct3 (R2) 1 or 5: SLLI, SRLI, SRAI, and the Zbb CLZ, CTZ,
; CPOP, SEXT.B, SEXT.H, ORC.B, REV8 and RORI. Uses R7 and R14; B (R7) is set
; again at _op_imm_send.
; ------------------------------------------------------------------------------
_op_imm_shift:
    BEXTR   R7, R5, 25, 7     ; funct7 (imm[11:5])
    LD      R14, R7
    FBRA.NZ R14, ._imm_f7
    JUMP    _op_imm_send        ; SLLI / SRLI
._imm_f7:
    LD      R14, R2
    SUB     R14, 5
    FBRA.NZ R14, ._imm_f1
    ; funct3 5
    LDI     R14, 0x20
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f5_zbb
    LD      R2, OP_SRA          ; SRAI
    JUMP    _op_imm_send
._imm_f5_zbb:
    LDI     R14, 0x30
    SUB     R14, R7
    BEXTR   R7, R5, 20, 12    ; imm12
    FBRA.NZ R14, ._imm_f5_orcb
    LDI     R2, OP_ROR          ; RORI
    JUMP    _op_imm_send
._imm_f5_orcb:
    LDI     R14, 0x287
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f5_rev8
    LDI     R2, OP_ORC_B        ; ORC.B
    JUMP    _op_imm_send
._imm_f5_rev8:
    LDI     R14, 0x698
    SUB     R14, R7
    FBRA.NZ R14, ._imm_illegal
    LDI     R2, OP_REV8         ; REV8
    JUMP    _op_imm_send
._imm_f1:
    ; funct3 1, funct7 not 0: Zbb unary, by imm12
    BEXTR   R7, R5, 20, 12    ; imm12
    LDI     R14, 0x600
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_ctz
    LDI     R2, OP_CLZ
    JUMP    _op_imm_send
._imm_f1_ctz:
    LDI     R14, 0x601
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_cpop
    LDI     R2, OP_CTZ
    JUMP    _op_imm_send
._imm_f1_cpop:
    LDI     R14, 0x602
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_sextb
    LDI     R2, OP_CPOP
    JUMP    _op_imm_send
._imm_f1_sextb:
    LDI     R14, 0x604
    SUB     R14, R7
    FBRA.NZ R14, ._imm_f1_sexth
    LDI     R2, OP_SEXT_B
    JUMP    _op_imm_send
._imm_f1_sexth:
    LDI     R14, 0x605
    SUB     R14, R7
    FBRA.NZ R14, ._imm_illegal
    LDI     R2, OP_SEXT_H
    JUMP    _op_imm_send
._imm_illegal:
    JUMP    _h_illegal

; ------------------------------------------------------------------------------
; OP with funct7 not 0 or 1. R2 = funct3; uses R7 and R14 (B is set again at
; _op_send).
; ------------------------------------------------------------------------------
_op_funct7:
    BEXTR   R7, R5, 25, 7     ; funct7
    LDI     R14, 0x20
    SUB     R14, R7
    FBRA.NZ R14, ._reg_chk_30
    ; funct7 0x20: SUB (0), SRA (5), ANDN (7), ORN (6), XNOR (4)
    LD      R14, R2
    SUB     R14, 7
    FBRA.NZ R14, ._reg_20_orn
    LDI     R2, OP_ANDN
    JUMP    _op_send
._reg_20_orn:
    LD      R14, R2
    SUB     R14, 6
    FBRA.NZ R14, ._reg_20_xnor
    LDI     R2, OP_ORN
    JUMP    _op_send
._reg_20_xnor:
    LD      R14, R2
    SUB     R14, 4
    FBRA.NZ R14, ._reg_20_sub
    LDI     R2, OP_XNOR
    JUMP    _op_send
._reg_20_sub:
    LD      R14, R2
    FBRA.NZ R14, ._reg_20_sra
    LD      R2, OP_SUB
    JUMP    _op_send
._reg_20_sra:
    SUB     R14, 5
    FBRA.NZ R14, ._reg_illegal
    LD      R2, OP_SRA
    JUMP    _op_send
._reg_chk_30:
    ; funct7 0x30: ROL (funct3 1), ROR (funct3 5)
    LDI     R14, 0x30
    SUB     R14, R7
    FBRA.NZ R14, ._reg_chk_05
    LD      R14, R2
    SUB     R14, 1
    FBRA.NZ R14, ._reg_30_ror
    LDI     R2, OP_ROL
    JUMP    _op_send
._reg_30_ror:
    LD      R14, R2
    SUB     R14, 5
    FBRA.NZ R14, ._reg_illegal
    LDI     R2, OP_ROR
    JUMP    _op_send
._reg_chk_05:
    ; funct7 0x05: MIN (4), MINU (5), MAX (6), MAXU (7)
    LD      R14, R7
    SUB     R14, 5
    FBRA.NZ R14, ._reg_chk_04
    LD      R14, R2
    SUB     R14, 4
    FBRA.NZ R14, ._reg_05_minu
    LDI     R2, OP_MIN
    JUMP    _op_send
._reg_05_minu:
    LD      R14, R2
    SUB     R14, 5
    FBRA.NZ R14, ._reg_05_max
    LDI     R2, OP_MINU
    JUMP    _op_send
._reg_05_max:
    LD      R14, R2
    SUB     R14, 6
    FBRA.NZ R14, ._reg_05_maxu
    LDI     R2, OP_MAX
    JUMP    _op_send
._reg_05_maxu:
    LD      R14, R2
    SUB     R14, 7
    FBRA.NZ R14, ._reg_illegal
    LDI     R2, OP_MAXU
    JUMP    _op_send
._reg_chk_04:
    ; funct7 0x04: ZEXT.H (funct3 4, rs2 0); anything else is illegal
    LD      R14, R7
    SUB     R14, 4
    FBRA.NZ R14, ._reg_illegal
    LD      R14, R2
    SUB     R14, 4
    FBRA.NZ R14, ._reg_illegal
    FIELD   R7, R5, 20, 5       ; rs2
    LD      R14, R7
    FBRA.NZ R14, ._reg_illegal
    LDI     R2, OP_ZEXT_H
    JUMP    _op_send
._reg_illegal:
    JUMP    _h_illegal
