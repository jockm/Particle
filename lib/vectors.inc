; ==============================================================================
; File: lib/vectors.inc
; Trap vector table helpers. Every program fills all 16 slots, so no trap can
; land in code that isn't meant for it.
;
; A slot is 16 bytes (8 instructions) at TRAP_TABLE_BASE + n * 16. Each macro
; starts with .org at its slot, so slots must be written in order and a slot
; that overflows is an assembler error.
;
;   VECTOR_TABLE reset        reset jumps to `reset`; vectors 1-15 are
;                             unexpected; the _unexpected_trap routine follows
;                             at 0x200. For programs that handle no traps.
;
; Or write the 16 slots out:
;
;   RESET_SLOT handler        slot 0: jump to `handler`
;   TRAP_SLOT n, handler      XCHGMOST, then jump to `handler`. XCHGMOST moves
;                             R1-R14 to the shadow bank, R14 (the return PC)
;                             included, so the handler may use R1-R14 and
;                             returns with FAST_EXIT_TRAP.
;   TRAP_SLOT_BRANCH n, handler
;                             FBRA to `handler`, changing no register (R14 is
;                             still the return PC). `handler` must start within
;                             510 bytes after the slot (pasm checks).
;   TRAP_SLOT_UNEXPECTED n    XCHGMOST, R1 = n, jump to _unexpected_trap
;   UNEXPECTED_TRAP_ROUTINE   the _unexpected_trap routine, at 0x200: it stores
;                             the return PC at UNEXPECTED_TRAP_PC and the vector
;                             number at UNEXPECTED_TRAP_VECTOR, then spins
; ==============================================================================
.ifndef _VECTORS_INC_
.define _VECTORS_INC_ 1

.include "lib/common.inc"

.define UNEXPECTED_TRAP_PC      0x000000F4
.define UNEXPECTED_TRAP_VECTOR  0x000000F8
.define MBOX_VALUE              0x000000FC

.macro RESET_SLOT handler
.org TRAP_TABLE_BASE
    LOAD_R14_32 %handler
    JMP     R14, R0
.endmacro

.macro TRAP_SLOT n, handler
.org TRAP_TABLE_BASE + (%n) * TRAP_STRIDE_BYTES
    FAST_ENTER_TRAP
    LOAD_R14_32 %handler
    JMP     R14, R0
.endmacro

.macro TRAP_SLOT_BRANCH n, handler
.org TRAP_TABLE_BASE + (%n) * TRAP_STRIDE_BYTES
    FBRA    %handler
.endmacro

.macro TRAP_SLOT_UNEXPECTED n
.org TRAP_TABLE_BASE + (%n) * TRAP_STRIDE_BYTES
    FAST_ENTER_TRAP
    LD      R1, %n
    LOAD_R14_32 _unexpected_trap
    JMP     R14, R0
.endmacro

.macro UNEXPECTED_TRAP_ROUTINE
.org TRAP_TABLE_BASE + 16 * TRAP_STRIDE_BYTES
_unexpected_trap:
    XCHG    R14                 ; R14 = the trap's return PC (from the shadow)
    LDI     R2, UNEXPECTED_TRAP_PC
    ST32    (R2), R14
    ADD     R2, 4               ; UNEXPECTED_TRAP_VECTOR
    ST32    (R2), R1
_unexpected_trap_spin:
    BBRA    _unexpected_trap_spin
.endmacro

.macro VECTOR_TABLE reset
    RESET_SLOT %reset
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
.endmacro

.endif
