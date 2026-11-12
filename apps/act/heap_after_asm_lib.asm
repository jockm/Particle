; ==============================================================================
; heap_after_asm_lib.asm: assembly library for heap_after_asm_main.act
; ==============================================================================
; pbuild assembles this file after the compiled program, so it lies after the
; program's globals and the allocator state. The heap must start after it.

; u32 lib_table_sum(): sum of the 8 words of _lib_table
_lib_table_sum:
    PUSH32  R14
    LOAD32  R2, _lib_table
    LD      R1, 0
    LD      R3, 8
._lib_sum_loop:
    LD32    R4, (R2)
    ADD     R1, R4
    ADD     R2, 4
    SUB     R3, 1
    BBRA.NZ R3, ._lib_sum_loop
    POP32   R14
    RRET

; u32 lib_end_addr(): address just past this library
_lib_end_addr:
    PUSH32  R14
    LOAD32  R1, _lib_end
    POP32   R14
    RRET

    .align  4
_lib_table:
    .word   1, 2, 3, 4, 5, 6, 7, 8
_lib_end:
