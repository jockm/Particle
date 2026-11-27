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
;   R2   1: FIFO channel 1 (idToEx, to core 2)
;   R3   2: FIFO channel 2 (writebacks from core 3: [Rd * 8, data])
; For each packet: R4 the control word, R15 w1, R13 w2, R9 B, R10 W3 (the
; registers in them already times 8: parcore_ops.inc); R5 operand A, R9
; operand B; R7 a copy of rs2; R11 and R12 a writeback; R6, R8, R14 scratch.
;
; The register file (461): x(r) at 8r, the number of its writes in flight at
; 8r + 4, so one pointer reaches both: LD32 (++Rn) reads the count, LD32
; (--Rn) the value (the pointer modes are built in for this, 464).
; ==============================================================================
; This core is built without the shadow bank (ParcoreConfig)
.define NO_SHADOW_BANK 1
.include "lib/vectors.inc"
.include "parcore_ops.inc"

; Zero page
.define REG_BASE        0x0000  ; x0..x31, 8 bytes each (0x000-0x0FF): the
                                ; value, then its writes in flight; x0 stays 0
.define CANCEL_BASE     0x0800  ; a cancel's value lands at 0x800 + 8 * Rd,
                                ; which nothing reads; the code must end below
                                ; it (make firmware checks)

; A writeback [Rd * 8, data] in R11, R12. Rd * 8 + 0x800 is a cancel: its value
; goes to CANCEL_BASE + 8 * Rd. Either way x(Rd) has one write fewer in flight.
; Writebacks for x0 are ignored (x0 is never counted, and a cancel never names
; it). Uses R6, R8.
.macro RETIRE_WB
    LD      R6, R11
    BCLR    R6, 11              ; R6 = Rd * 8
    FBRA.Z  R6, .%_done
    ST32    (R11), R12          ; commit (a cancel's goes to CANCEL_BASE)
    LD32    R8, (++R6)          ; its writes in flight
    SUB     R8, 1
    ST32    (R6), R8
.%_done:
.endmacro

; A stall: retire one writeback (waiting for it), then check again
.macro STALL_RETIRE
    FIFO.R  R11, R3
    FIFO.R  R12, R3
    RETIRE_WB
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
    LD      R2, 1               ; idToEx
    LD      R3, 2               ; writebacks
    ; x0..x31 = 0, and nothing in flight
    LD      R4, REG_BASE
    LDI     R6, 64
._clear_regs:
    ST32    (R4++), R0
    SUB     R6, 1
    BBRA.NZ R6, ._clear_regs
    JUMP    _id_main_loop

; ==============================================================================
; Main loop: retire a writeback if one is waiting, then take one packet
; ==============================================================================
_id_main_loop:
    FIFO.TRYR R11, R3           ; a writeback?
    FBRA.Z  R14, ._no_wb
    FIFO.R  R12, R3
    RETIRE_WB
._no_wb:
    ; Take a packet only when idToEx has room for what it sends (a FIFO.W to
    ; a full channel is dropped): fewer than 128 words in it (status bit 15)
    FIFO.STAT R14, R2
    SHIFTR  R14, 15
    BBRA.NZ R14, _id_main_loop
    FIFO.TRYR R4, R0            ; a control word?
    BBRA.Z  R14, _id_main_loop
    LD      R14, R4
    BBRA.N  R14, _id_main_loop  ; a marker on its own (operations are < 128)
    FIFO.R  R15, R0             ; w1
    FIFO.R  R13, R0             ; w2
    FIFO.R  R9, R0              ; B
    FIFO.R  R10, R0             ; W3
    ; If W3 is a marker, a flush cut this packet short (core 1 had read its
    ; first words, and the rest are core 0's markers): drop it
    LD      R14, R10
    BBRA.N  R14, _id_main_loop
    BEXTR   R8, R4, 20, 4       ; the class
    JTBL    R8, 16              ; 16-byte entries: the classes inline

    ; CLASS_RS1_IMM: A = x(rs1), B = B
._ri_chk:
    LD32    R14, (++R15)        ; x(rs1)'s writes in flight
    FBRA.NZ R14, ._ri_stall
    LD32    R5, (--R15)         ; A = x(rs1)
    FBRA    _send
    NOP
    NOP
    NOP
    NOP
    ; CLASS_IMM: A = 0, B = B
    LD      R5, 0
    FBRA    _send
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    ; CLASS_ZIMM: A = w1 (the immediate), B = B
    LD      R5, R15
    FBRA    _send
    NOP
    NOP
    NOP
    NOP
    NOP
    NOP
    ; CLASS_STORE: A = x(rs1), B = the offset, word 3 = x(rs2) (the data)
._st_chk:
    LD32    R6, (++R15)
    LD32    R14, (++R13)        ; rs2 is w2
    OR      R14, R6
    FBRA.NZ R14, ._st_stall
    LD32    R5, (--R15)
    LD32    R10, (--R13)
    FBRA    ._push              ; no destination
    NOP
    ; CLASS_BRANCH: A = x(rs1), B = x(rs2), word 3 = W3 (the address if the
    ; prediction is wrong)
._br_chk:
    LD32    R6, (++R15)
    LD32    R14, (++R13)        ; rs2 is w2
    OR      R14, R6
    FBRA.NZ R14, ._br_stall
    LD32    R5, (--R15)
    LD32    R9, (--R13)
    FBRA    ._push              ; no destination
    NOP
    ; CLASS_RS1_RS2: A = x(rs1), B = x(rs2) (rs2 is B); runs on into _send
._rr_chk:
    LD      R7, R9
    LD32    R6, (++R15)
    LD32    R14, (++R7)
    OR      R14, R6
    FBRA.NZ R14, ._rr_stall
    LD32    R5, (--R15)
    LD32    R9, (--R7)
    NOP

; ------------------------------------------------------------------------------
; The shared tail. R4 the control word, R5 and R9 operands A and B, R10 word
; 3; x(rd) (R13 = rd * 8, 0: none) has one more write in flight
; ------------------------------------------------------------------------------
_send:
    FBRA.Z  R13, ._push
    LD32    R6, (++R13)
    ADD     R6, 1
    ST32    (R13), R6
._push:
    FIFO.W  R4, R2              ; control word
    FIFO.W  R5, R2              ; operand A
    FIFO.W  R9, R2              ; operand B
    FIFO.W  R10, R2             ; word 3
    JUMP    _id_main_loop

; Stalls: a source register has a write in flight. Put the pointers back,
; retire one writeback (waiting for it), and check again.
._ri_stall:
    SUB     R15, 4
    STALL_RETIRE
    JUMP    ._ri_chk
._st_stall:
    SUB     R15, 4
    SUB     R13, 4
    STALL_RETIRE
    JUMP    ._st_chk
._br_stall:
    SUB     R15, 4
    SUB     R13, 4
    STALL_RETIRE
    JUMP    ._br_chk
._rr_stall:
    SUB     R15, 4              ; (R7 is copied again from B)
    STALL_RETIRE
    JUMP    ._rr_chk
