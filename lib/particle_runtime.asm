; ==============================================================================
; Particle Runtime & Vector Table
; ==============================================================================
.ifndef _PARTICLE_RUNTIME_ASM_
.define _PARTICLE_RUNTIME_ASM_ 1

.include "lib/vectors.inc"

; Reset jumps to the startup code; an MBOX (vector 1) returns at once with
; RETI (vector 1 is for MBOX traps: RETI returns to EPC); every
; other vector is unexpected (lib/vectors.inc).
    RESET_SLOT _start
    TRAP_SLOT_BRANCH 1, _on_mbox_trap
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

_start:
    LOAD32  R15, 0x00010000
    LOAD32  R14, _main
    JMP     R14, R0

_on_mbox_trap:                  ; nothing to do: back to EPC, unmasked
    RETI

.endif
