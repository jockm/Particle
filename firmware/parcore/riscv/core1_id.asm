; ==============================================================================
; Parcore RV32IM_Zbb: Core 1 (Register File & Scoreboard)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core1_id.asm
; ==============================================================================
;
; Core 0 has already decoded each instruction: core 1 takes its 5-word packet
; [control word, w1, w2, B, W3], dispatches on the class in control-word
; bits 23:20 (parcore_ops.inc), waits while a source register it reads has a
; write in flight, reads the registers, counts the destination's write, and
; sends core 2 [control word, operand A, operand B, word 3]. It also retires
; the writebacks core 3 sends back.
;
; Registers kept for the whole run:
;   R0   0, and FIFO channel 0 (ifToId, from core 0)
;   R1   COUNT_BASE
;   R2   1: FIFO channel 1 (idToEx, to core 2)
;   R3   2: FIFO channel 2 (writebacks from core 3: [Rd, data])
; For each packet: R4 the control word, R15 rs1, R7 rs2, R13 rd (0: none),
; R5 operand A, R9 operand B, R10 word 3; R11 and R12 a writeback.
; ==============================================================================
; This core is built without the shadow bank (ParcoreConfig)
.define NO_SHADOW_BANK 1
.include "lib/vectors.inc"
.include "parcore_ops.inc"

; Zero page
.define REG_BASE          0x0000  ; x0..x31, a word each (0x00..0x7F); x0 stays 0
.define COUNT_BASE        0x0F00  ; 32 bytes (0xF00..0xF1F): writes in flight per register

; A writeback [Rd, data] in R11, R12. Rd + 0x20 is a cancel: nothing is
; committed (its data goes to 0x80 + 4 * Rd, which nothing uses). Either way
; x(Rd) has one write fewer in flight. Writebacks for x0 are ignored (x0 is
; never counted, and a cancel never names it). Uses R6, R8.
.macro RETIRE_WB
    LD      R6, R11
    BCLR    R6, 5               ; R6 = Rd
    FBRA.Z  R6, .%_done
    LD      R8, R11
    SHIFTL  R8, 2
    ST32    (R8), R12           ; commit: REG_BASE + (Rd << 2)
    ADD     R6, R1
    LD8     R8, (R6)
    SUB     R8, 1
    ST8     (R6), R8
.%_done:
.endmacro

; Go to %stall if x(R15) has a write in flight. Uses R8, R14.
.macro WAIT_RS1 chk, stall
%chk:
    LD      R8, R15
    ADD     R8, R1
    LD8     R14, (R8)
    FBRA.NZ R14, %stall
.endmacro

; The same for x(R15) and x(R7). Uses R6, R8, R14.
.macro WAIT_RS1_RS2 chk, stall
%chk:
    LD      R8, R15
    ADD     R8, R1
    LD8     R6, (R8)
    LD      R8, R7
    ADD     R8, R1
    LD8     R14, (R8)
    OR      R14, R6
    FBRA.NZ R14, %stall
.endmacro

; A stall stub, placed after its handler: retire one writeback (waiting for
; it), then check again. Uses R6, R8, R11, R12.
.macro STALL_STUB stall, chk
%stall:
    FIFO.R  R11, R3
    FIFO.R  R12, R3
    RETIRE_WB
    JUMP    %chk
.endmacro

; dst = x(src index register). x0 reads as zero: its word is never written.
.macro READ_REG dst, src
    LD      R14, %src
    SHIFTL  R14, 2
    LD32    %dst, (R14)
.endmacro

; The rest of a packet: w1, w2, B, W3 into the registers given. If W3 is a
; marker, a flush cut this packet short (core 1 had read its first words,
; and the rest are core 0's markers): drop it.
.macro REST w1, w2, b
    FIFO.R  %w1, R0
    FIFO.R  %w2, R0
    FIFO.R  %b, R0
    FIFO.R  R10, R0
    LD      R14, R10
    BBRA.N  R14, _id_main_loop
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
    ST32    (R4), R0          ; no pointer modes in this core
    ADD     R4, 4
    SUB     R6, 1
    BBRA.NZ R6, ._clear_regs
    LD      R4, R1
    LD      R6, 8
._clear_counts:
    ST32    (R4), R0          ; no pointer modes in this core
    ADD     R4, 4
    SUB     R6, 1
    BBRA.NZ R6, ._clear_counts
    JUMP    _id_main_loop

; A writeback the main loop found (its first word in R11)
_retire:
    FIFO.R  R12, R3
    RETIRE_WB
    JUMP    _id_main_loop

; ------------------------------------------------------------------------------
; The shared tail; it falls into the main loop. R4 the control word, R5 and
; R9 operands A and B, R10 word 3; x(R13) has one more write in flight
; (R13 = 0: no destination).
; ------------------------------------------------------------------------------
_send:
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
    FIFO.W  R10, R2             ; word 3

; ==============================================================================
; Main loop: retire the writebacks waiting, then take one packet
; ==============================================================================
_id_main_loop:
    FIFO.TRYR R11, R3           ; a writeback?
    BBRA.NZ R14, _retire
    ; Take a packet only when idToEx has room for what it sends (a FIFO.W to
    ; a full channel is dropped): fewer than 128 words in it (status bit 15)
    FIFO.STAT R14, R2
    SHIFTR  R14, 15
    BBRA.NZ R14, _id_main_loop
    FIFO.TRYR R4, R0            ; a control word?
    BBRA.Z  R14, _id_main_loop
    LD      R9, R4
    LD      R14, 20 + 4 * 32
    BEXTR   R9, R14             ; the class
    JTBL    R9
    FBRA    _c_rs1_imm          ; CLASS_RS1_IMM
    FBRA    _c_rs1_rs2          ; CLASS_RS1_RS2
    FBRA    _c_store            ; CLASS_STORE
    FBRA    _c_branch           ; CLASS_BRANCH
    FBRA    _c_imm              ; CLASS_IMM
    FBRA    _c_zimm             ; CLASS_ZIMM
    FBRA    _skip               ; 6-14: not used
    FBRA    _skip
    FBRA    _skip
    FBRA    _skip
    FBRA    _skip
    FBRA    _skip
    FBRA    _skip
    FBRA    _skip
    FBRA    _skip
    FBRA    _skip               ; CLASS_MARKER: a marker word on its own

_skip:
    JUMP    _id_main_loop

; ------------------------------------------------------------------------------
; CLASS_RS1_IMM: A = x(rs1), B = B
; ------------------------------------------------------------------------------
_c_rs1_imm:
    REST    R15, R13, R9
    WAIT_RS1 ._ri_chk, ._ri_stall
    READ_REG R5, R15
    JUMP    _send
    STALL_STUB ._ri_stall, ._ri_chk

; ------------------------------------------------------------------------------
; CLASS_RS1_RS2: A = x(rs1), B = x(rs2) (rs2 in the B word)
; ------------------------------------------------------------------------------
_c_rs1_rs2:
    REST    R15, R13, R7
    WAIT_RS1_RS2 ._rr_chk, ._rr_stall
    READ_REG R5, R15
    READ_REG R9, R7
    JUMP    _send
    STALL_STUB ._rr_stall, ._rr_chk

; ------------------------------------------------------------------------------
; CLASS_STORE: A = x(rs1), B = the offset, word 3 = x(rs2) (the data)
; ------------------------------------------------------------------------------
_c_store:
    REST    R15, R7, R9
    WAIT_RS1_RS2 ._st_chk, ._st_stall
    READ_REG R5, R15
    READ_REG R10, R7
    LD      R13, 0
    JUMP    _send
    STALL_STUB ._st_stall, ._st_chk

; ------------------------------------------------------------------------------
; CLASS_BRANCH: A = x(rs1), B = x(rs2), word 3 = W3 (the address if the
; prediction is wrong)
; ------------------------------------------------------------------------------
_c_branch:
    REST    R15, R7, R9
    WAIT_RS1_RS2 ._br_chk, ._br_stall
    READ_REG R5, R15
    READ_REG R9, R7
    LD      R13, 0
    JUMP    _send
    STALL_STUB ._br_stall, ._br_chk

; ------------------------------------------------------------------------------
; CLASS_IMM: A = 0, B = B; CLASS_ZIMM: A = w1
; ------------------------------------------------------------------------------
_c_imm:
    REST    R5, R13, R9
    LD      R5, 0
    JUMP    _send
_c_zimm:
    REST    R5, R13, R9
    JUMP    _send
