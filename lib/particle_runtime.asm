; ==============================================================================
; Particle Runtime & Vector Table
; ==============================================================================
.ifndef _PARTICLE_RUNTIME_ASM_
.define _PARTICLE_RUNTIME_ASM_ 1

.include "lib/common.inc"

.org 0x00000100

_vector_reset:
    LOAD32  R15, 0x00010000
    LOAD32  R14, _main
    JMP      R14, R0
    .align  64

_vector_mbox:
    FAST_ENTER_TRAP
    LOAD32  R14, _on_mbox_trap
    JMP     R14, R14
    FAST_EXIT_TRAP
    .align  64

_on_mbox_trap:
    RRET

_on_alignment_error:
_panic_align_loop:
    FBRA    _panic_align_loop

_on_illegal_instruction:
_panic_illegal_loop:
    FBRA    _panic_illegal_loop

.endif
