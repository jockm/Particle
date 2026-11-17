; ==============================================================================
; Particle Runtime & Vector Table
; ==============================================================================
.ifndef _PARTICLE_RUNTIME_ASM_
.define _PARTICLE_RUNTIME_ASM_ 1

.include "lib/common.inc"

.org 0x00000100

; Every vector fits in 8 halfwords. The reset vector jumps to the startup
; code; a trap vector jumps to its handler, which returns from the trap
; itself with FAST_EXIT_TRAP.
_vector_reset:
    LOAD_R14_32 _start
    JMP     R14, R0
    .align  TRAP_STRIDE_BYTES

_vector_mbox:
    FAST_ENTER_TRAP
    LOAD_R14_32 _on_mbox_trap
    JMP     R14, R0
    .align  TRAP_STRIDE_BYTES

_start:
    LOAD32  R15, 0x00010000
    LOAD32  R14, _main
    JMP     R14, R0

_on_mbox_trap:
    FAST_EXIT_TRAP

_on_alignment_error:
_panic_align_loop:
    FBRA    _panic_align_loop

_on_illegal_instruction:
_panic_illegal_loop:
    FBRA    _panic_illegal_loop

.endif
