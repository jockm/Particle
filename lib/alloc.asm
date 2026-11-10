; ==============================================================================
; Particle RISC Architecture - Boundary-Tag Coalescing Dynamic Allocator
; File: lib/alloc.asm
; ==============================================================================
.include "lib/common.inc"

    .global _rt_alloc
    .global _rt_free
    .global _heap_start
    .global _heap_ptr
    .global _free_list_head
    .global _last_phys_size

; ------------------------------------------------------------------------------
; _rt_alloc: Allocate dynamic memory block
; Input:   R1 = size in bytes
; Output:  R1 = pointer to usable payload (chunk + 8), or 0 if out of memory
; ------------------------------------------------------------------------------
_rt_alloc:
    PUSH32  R14
    PUSH32  R4
    PUSH32  R5
    PUSH32  R6

    ; If R1 == 0, return null
    FBRA.NZ R1, ._alloc_has_size
    FBRA    ._alloc_ret_null
._alloc_has_size:

    ; 4-byte align requested size: aligned = (R1 + 3) & ~3
    ADD     R1, 3
    LOAD32  R2, 0xFFFFFFFC
    AND     R1, R2

    ; Total chunk size = aligned_size + 8 (header)
    ADD     R1, 8

    ; Ensure minimum chunk size of 12 bytes
    LOAD16  R2, 12
    SLT     R3, R1, R2
    FBRA.Z  R3, ._alloc_size_ok
    LD      R1, R2
._alloc_size_ok:

._alloc_init_chk:
    ; Initialize heap break if _heap_ptr is 0
    LOAD32  R13, _heap_ptr
    LD32    R2, (R13)
    FBRA.Z  R2, ._alloc_do_init_break
    FBRA    ._alloc_have_break
._alloc_do_init_break:

    ; First allocation: break = 4-byte aligned _heap_start
    LOAD32  R2, _heap_start
    ADD     R2, 3
    LOAD32  R3, 0xFFFFFFFC
    AND     R2, R3
    LOAD32  R13, _heap_ptr
    LD32    (R13), R2
._alloc_have_break:

._alloc_search_free:
    ; Traverse _free_list_head for first-fit
    ; R4 = curr, R5 = prev
    LOAD32  R13, _free_list_head
    LD32    R4, (R13)
    LD      R5, 0

._alloc_free_loop:
    FBRA.NZ R4, ._alloc_have_free_node
    FBRA    ._alloc_carve_break
._alloc_have_free_node:

    LD32    R2, (R4)            ; R2 = chunk.block_size
    SLT     R3, R2, R1          ; R3 = (chunk_size < needed_size)
    FBRA.Z  R3, ._alloc_match_found

    ; Step to next node
    LD      R5, R4
    LD      R13, R4
    ADD     R13, 8
    LD32    R4, (R13)           ; curr = curr.next_free
    BBRA    ._alloc_free_loop

._alloc_match_found:
    ; Unlink chunk from free list
    LD      R6, R4
    ADD     R6, 8
    LD32    R6, (R6)            ; R6 = chunk.next_free

    FBRA.Z  R5, ._alloc_unlink_head

    ; Unlink from middle/tail: prev.next = chunk.next
    LD      R13, R5
    ADD     R13, 8
    LD32    (R13), R6
    FBRA    ._alloc_chunk_ready

._alloc_unlink_head:
    LOAD32  R13, _free_list_head
    LD32    (R13), R6

._alloc_chunk_ready:
    ; Mark in_use: chunk.block_size |= 1
    LD32    R2, (R4)
    OR      R2, 1
    LD32    (R4), R2

    ; Return payload pointer = R4 + 8
    LD      R1, R4
    ADD     R1, 8
    FBRA    ._alloc_done

._alloc_carve_break:
    ; Carve from current _heap_ptr break
    LOAD32  R13, _heap_ptr
    LD32    R2, (R13)           ; R2 = current break pointer

    ; Candidate break: R3 = R2 + chunk_size
    LD      R3, R2
    ADD     R3, R1

    ; Headroom limit = R15 - 256
    LD      R13, R15
    LOAD16  R4, 0x0100
    SUB     R13, R4
    SLT     R4, R3, R13         ; R4 = (candidate < limit)
    FBRA.NZ R4, ._alloc_commit_break
    FBRA    ._alloc_ret_null

._alloc_commit_break:
    ; Commit new break pointer
    LOAD32  R13, _heap_ptr
    LD32    (R13), R3

    ; Chunk header:
    ; Offset 0: block_size | 1 (in_use)
    LD      R4, R1
    OR      R4, 1
    LD32    (R2), R4

    ; Offset 4: prev_phys_size from _last_phys_size
    LOAD32  R13, _last_phys_size
    LD32    R4, (R13)
    LD      R13, R2
    ADD     R13, 4
    LD32    (R13), R4

    ; Update _last_phys_size = R1
    LOAD32  R13, _last_phys_size
    LD32    (R13), R1

    ; Return payload pointer = R2 + 8
    LD      R1, R2
    ADD     R1, 8
    FBRA    ._alloc_done

._alloc_ret_null:
    LD      R1, 0

._alloc_done:
    POP32   R6
    POP32   R5
    POP32   R4
    POP32   R14
    RRET

; ------------------------------------------------------------------------------
; Helper: _unlink_free_chunk
; Unlink chunk at R10 from _free_list_head
; Clobbers: R11, R12, R13
; ------------------------------------------------------------------------------
_unlink_free_chunk:
    LOAD32  R13, _free_list_head
    LD32    R11, (R13)          ; R11 = curr
    LD      R12, 0              ; R12 = prev

._unlink_loop:
    FBRA.NZ R11, ._unlink_check_node
    FBRA    ._unlink_done       ; End of list (not found)
._unlink_check_node:
    SEQ     R13, R11, R10
    FBRA.Z  R13, ._unlink_step
    FBRA    ._unlink_found
._unlink_step:
    LD      R12, R11            ; prev = curr
    LD      R13, R11
    ADD     R13, 8
    LD32    R11, (R13)          ; curr = curr.next
    BBRA    ._unlink_loop

._unlink_found:
    LD      R13, R11
    ADD     R13, 8
    LD32    R13, (R13)          ; R13 = curr.next

    FBRA.Z  R12, ._unlink_head_node
    ; Mid/tail node: prev.next = curr.next
    LD      R11, R12
    ADD     R11, 8
    LD32    (R11), R13
    FBRA    ._unlink_done

._unlink_head_node:
    LOAD32  R11, _free_list_head
    LD32    (R11), R13

._unlink_done:
    RRET

; ------------------------------------------------------------------------------
; _rt_free: Deallocate dynamic memory block and coalesce adjacent free chunks
; Input:   R1 = pointer to usable payload (chunk + 8)
; ------------------------------------------------------------------------------
_rt_free:
    PUSH32  R14
    PUSH32  R4
    PUSH32  R5
    PUSH32  R6
    PUSH32  R7
    PUSH32  R8

    ; Null check
    FBRA.NZ R1, ._free_do_work
    FBRA    ._free_exit

._free_do_work:
    ; R4 = curr_chunk = R1 - 8
    LD      R4, R1
    SUB     R4, 8

    ; Clear in_use bit: R5 = curr_size = block_size & ~3
    LD32    R5, (R4)
    LOAD32  R13, 0xFFFFFFFC
    AND     R5, R13
    LD32    (R4), R5            ; Store cleared in_use bit

    ; ==========================================================================
    ; 1. Forward Coalesce: check physical next chunk at (R4 + R5)
    ; ==========================================================================
    LD      R6, R4
    ADD     R6, R5              ; R6 = next_chunk

    ; Check if next_chunk < *_heap_ptr
    LOAD32  R13, _heap_ptr
    LD32    R7, (R13)           ; R7 = heap_break
    SLT     R8, R6, R7          ; R8 = (next_chunk < heap_break)
    FBRA.NZ R8, ._fwd_within_break
    FBRA    ._free_backward_coalesce
._fwd_within_break:

    ; Inspect next_chunk.block_size
    LD32    R8, (R6)
    AND     R8, 1               ; R8 = next.in_use
    FBRA.Z  R8, ._fwd_next_is_free
    FBRA    ._free_backward_coalesce
._fwd_next_is_free:

    ; Next is FREE! Unlink next (R6) from free list
    LD      R10, R6
    RCALL   _unlink_free_chunk

    ; Merge sizes: curr_size += next.raw_size
    LD32    R8, (R6)
    LOAD32  R13, 0xFFFFFFFC
    AND     R8, R13             ; R8 = next_size
    ADD     R5, R8              ; R5 = merged curr_size
    LD32    (R4), R5            ; Update curr.block_size

    ; Update neighbor after next (if within break): prev_phys_size = merged_size
    LD      R7, R6
    ADD     R7, R8              ; R7 = neighbor after next
    LOAD32  R13, _heap_ptr
    LD32    R8, (R13)
    SLT     R8, R7, R8
    FBRA.NZ R8, ._fwd_update_neighbor
    ; If next reached break, update _last_phys_size = R5
    LOAD32  R13, _last_phys_size
    LD32    (R13), R5
    FBRA    ._free_backward_coalesce

._fwd_update_neighbor:
    LD      R13, R7
    ADD     R13, 4
    LD32    (R13), R5           ; neighbor.prev_phys_size = R5

    ; ==========================================================================
    ; 2. Backward Coalesce: check physical prev chunk using curr.prev_phys_size
    ; ==========================================================================
._free_backward_coalesce:
    LD      R13, R4
    ADD     R13, 4
    LD32    R6, (R13)           ; R6 = curr.prev_phys_size
    FBRA.NZ R6, ._bwd_has_prev
    FBRA    ._free_link_curr
._bwd_has_prev:

    ; R7 = prev_chunk = curr_chunk - prev_phys_size
    LD      R7, R4
    SUB     R7, R6

    ; Inspect prev_chunk.block_size
    LD32    R8, (R7)
    AND     R8, 1               ; R8 = prev.in_use
    FBRA.Z  R8, ._bwd_prev_is_free
    FBRA    ._free_link_curr
._bwd_prev_is_free:

    ; Prev is FREE! Unlink prev (R7) from free list
    LD      R10, R7
    RCALL   _unlink_free_chunk

    ; Merge: prev_size += curr_size
    LD32    R8, (R7)
    LOAD32  R13, 0xFFFFFFFC
    AND     R8, R13
    ADD     R8, R5              ; R8 = merged total size
    LD32    (R7), R8            ; prev.block_size = merged total

    ; Update neighbor after curr (if within break): prev_phys_size = merged size
    LD      R6, R4
    ADD     R6, R5              ; R6 = neighbor after curr
    LOAD32  R13, _heap_ptr
    LD32    R5, (R13)
    SLT     R5, R6, R5
    FBRA.NZ R5, ._bwd_update_neighbor
    LOAD32  R13, _last_phys_size
    LD32    (R13), R8
    FBRA    ._bwd_finish_merge

._bwd_update_neighbor:
    LD      R13, R6
    ADD     R13, 4
    LD32    (R13), R8           ; neighbor.prev_phys_size = R8

._bwd_finish_merge:
    ; R4 now points to prev_chunk, R5 = merged size
    LD      R4, R7
    LD      R5, R8

._free_link_curr:
    ; Insert R4 into _free_list_head
    LOAD32  R13, _free_list_head
    LD32    R6, (R13)           ; R6 = old_head
    LD      R13, R4
    ADD     R13, 8
    LD32    (R13), R6           ; R4.next_free = old_head

    LOAD32  R13, _free_list_head
    LD32    (R13), R4           ; *_free_list_head = R4

._free_exit:
    POP32   R8
    POP32   R7
    POP32   R6
    POP32   R5
    POP32   R4
    POP32   R14
    RRET

; ------------------------------------------------------------------------------
; Allocator State Variables
; ------------------------------------------------------------------------------
    .data
    .align 4
_heap_ptr:
    .word 0
_free_list_head:
    .word 0
_last_phys_size:
    .word 0

    .align 4
_heap_start:
