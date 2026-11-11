; ==============================================================================
; Particle Bare-Metal Boundary-Tag Memory Allocator
; ==============================================================================
; Chunks are aligned to 4 bytes and have an 8-byte prefix header:
;   offset -8: [block_size | in_use (bit 0)] (32-bit)
;   offset -4: [prev_phys_size]              (32-bit)
;
; Usable payload returned to caller starts at offset +0.
; Free chunks maintain a singly linked explicit free list:
;   offset +0: [next_free_chunk]             (32-bit)
; ==============================================================================

    .global _rt_alloc
    .global _rt_free
    .global _rt_realloc
    .global __rt_realloc

; ------------------------------------------------------------------------------
; _rt_alloc: Allocate payload of R1 bytes
; Input:   R1 = size in bytes
; Output:  R1 = pointer to usable payload (or 0 on failure)
; ------------------------------------------------------------------------------
_rt_alloc:
    PUSH32  R14
    PUSH32  R2
    PUSH32  R3
    PUSH32  R4
    PUSH32  R5

    ; 1. Align requested payload size up to 4 bytes: (R1 + 3) & ~3
    ADD     R1, 3
    LOAD32  R2, 0xFFFFFFFC
    AND     R1, R2

    ; 2. Chunk size = payload + 8 (header)
    ADD     R1, 8
    ; Enforce minimum chunk size of 12 bytes
    LOAD16  R2, 12
    LD      R3, R1
    SLT     R3, R2              ; R3 = (chunk_size < 12)
    FBRA.Z  R3, ._alloc_init_chk
    LOAD16  R1, 12

._alloc_init_chk:
    ; Initialize heap break if _heap_ptr is 0
    LOAD32  R13, _heap_ptr
    LD32    R2, (R13)
    FBRA.Z  R2, ._alloc_do_init_break
    FBRA    ._alloc_have_break
._alloc_do_init_break:
    LOAD32  R2, _heap_start
    LOAD32  R13, _heap_ptr
    LD32    (R13), R2
    LOAD32  R13, _last_phys_size
    LD32    (R13), R0

._alloc_have_break:
    ; Search explicit free list for first fit: R1 = needed chunk_size
    LOAD32  R2, _free_list_head
    LD32    R3, (R2)            ; R3 = curr_free_chunk
    LD      R4, R0              ; R4 = prev_free_chunk = 0

._alloc_free_search:
    FBRA.NZ R3, ._alloc_check_chunk
    FBRA    ._alloc_expand_break

._alloc_check_chunk:
    LD32    R5, (R3)            ; R5 = curr.block_size
    LOAD32  R13, 0xFFFFFFFC
    AND     R5, R13             ; Clear in_use bit

    ; Check if curr.block_size (R5) >= needed (R1)
    LD      R13, R5
    SLT     R13, R1             ; R13 = (curr < needed)
    FBRA.Z  R13, ._alloc_found_free

    ; Advance in free list
    LD      R4, R3
    ADD     R3, 8               ; Free chunk's payload stores next_free
    LD32    R3, (R3)
    BBRA    ._alloc_free_search

._alloc_found_free:
    ; Unlink R3 from free list
    ADD     R3, 8
    LD32    R2, (R3)            ; R2 = curr.next_free
    SUB     R3, 8
    FBRA.NZ R4, ._alloc_unlink_mid
    LOAD32  R13, _free_list_head
    LD32    (R13), R2
    FBRA    ._alloc_check_split

._alloc_unlink_mid:
    ADD     R4, 8
    LD32    (R4), R2
    SUB     R4, 8

._alloc_check_split:
    ; R3 = chunk, R5 = curr_size, R1 = needed_size
    ; Excess = R5 - R1
    LD      R2, R5
    SUB     R2, R1
    LOAD16  R13, 12
    LD      R14, R2
    SLT     R14, R13            ; R14 = (excess < 12)
    FBRA.NZ R14, ._alloc_mark_used_nosplit

    ; Split block: R3 gets size R1 | 1
    LD      R13, R1
    OR      R13, 1
    LD32    (R3), R13

    ; Remainder chunk at R3 + R1
    LD      R4, R3
    ADD     R4, R1              ; R4 = split chunk
    LD32    (R4), R2            ; split.block_size = excess (bit0=0, free)
    ADD     R4, 4
    LD32    (R4), R1            ; split.prev_phys_size = allocated size
    SUB     R4, 4

    ; Update neighbor after split chunk (if within heap)
    LD      R13, R4
    ADD     R13, R2             ; neighbor address
    LOAD32  R14, _heap_ptr
    LD32    R14, (R14)
    LD      R5, R13
    SLT     R5, R14             ; R5 = (neighbor < heap_ptr)
    FBRA.NZ R5, ._alloc_split_upd_neighbor
    LOAD32  R13, _last_phys_size
    LD32    (R13), R2
    FBRA    ._alloc_split_link_free

._alloc_split_upd_neighbor:
    ADD     R13, 4
    LD32    (R13), R2

._alloc_split_link_free:
    ; Link split remainder (R4) into free list
    LOAD32  R13, _free_list_head
    LD32    R14, (R13)
    ADD     R4, 8
    LD32    (R4), R14           ; split.next = old_head
    SUB     R4, 8
    LD32    (R13), R4

    ; Return R3 + 8
    LD      R1, R3
    ADD     R1, 8
    FBRA    ._alloc_exit

._alloc_mark_used_nosplit:
    LD      R13, R5
    OR      R13, 1
    LD32    (R3), R13
    LD      R1, R3
    ADD     R1, 8
    FBRA    ._alloc_exit

._alloc_expand_break:
    ; R1 = needed chunk_size
    LOAD32  R13, _heap_ptr
    LD32    R2, (R13)           ; R2 = current heap break (new chunk address)

    ; Calculate new heap break = R2 + R1
    LD      R3, R2
    ADD     R3, R1
    LD32    (R13), R3           ; Advance heap break

    ; Set new chunk header: [block_size | 1]
    LD      R13, R1
    OR      R13, 1
    LD32    (R2), R13

    ; Set prev_phys_size from _last_phys_size
    LOAD32  R13, _last_phys_size
    LD32    R14, (R13)
    ADD     R2, 4
    LD32    (R2), R14
    SUB     R2, 4

    ; Update _last_phys_size = R1
    LD32    (R13), R1

    ; Return usable payload pointer = R2 + 8
    LD      R1, R2
    ADD     R1, 8

._alloc_exit:
    POP32   R5
    POP32   R4
    POP32   R3
    POP32   R2
    POP32   R14
    RRET

; ------------------------------------------------------------------------------
; _rt_free: Free previously allocated payload
; Input:   R1 = payload pointer (chunk + 8)
; ------------------------------------------------------------------------------
_rt_free:
    PUSH32  R14
    PUSH32  R2
    PUSH32  R3
    PUSH32  R4
    PUSH32  R5
    PUSH32  R6

    FBRA.NZ R1, ._free_start
    FBRA    ._free_exit

._free_start:
    ; R2 = chunk = R1 - 8
    LD      R2, R1
    SUB     R2, 8

    ; Clear in_use bit on current chunk
    LD32    R3, (R2)            ; R3 = block_size | 1
    LOAD32  R13, 0xFFFFFFFC
    AND     R3, R13             ; R3 = size
    LD32    (R2), R3            ; marked free (bit 0 = 0)

    ; --------------------------------------------------------------------------
    ; 1. Try Forward Coalescing
    ; --------------------------------------------------------------------------
    LD      R4, R2
    ADD     R4, R3              ; R4 = next_chunk = chunk + size
    LOAD32  R13, _heap_ptr
    LD32    R13, (R13)
    LD      R5, R4
    SLT     R5, R13             ; R5 = (next_chunk < heap_ptr)
    FBRA.NZ R5, ._free_chk_next_free
    FBRA    ._free_try_bwd

._free_chk_next_free:
    LD32    R5, (R4)            ; R5 = next.block_size
    AND     R5, 1               ; R5 = next.in_use
    FBRA.Z  R5, ._free_do_fwd_merge
    FBRA    ._free_try_bwd

._free_do_fwd_merge:
    ; Next is free: unlink next_chunk (R4)
    LD      R10, R4
    RCALL   _unlink_free_chunk

    ; Combined size = R3 + (next.size & ~3)
    LD32    R5, (R4)
    LOAD32  R13, 0xFFFFFFFC
    AND     R5, R13
    ADD     R3, R5              ; R3 = merged size
    LD32    (R2), R3            ; chunk.block_size = merged size

    ; Update neighbor after next (if within break)
    LD      R13, R2
    ADD     R13, R3
    LOAD32  R14, _heap_ptr
    LD32    R14, (R14)
    LD      R5, R13
    SLT     R5, R14
    FBRA.NZ R5, ._free_fwd_upd_neighbor
    LOAD32  R13, _last_phys_size
    LD32    (R13), R3
    FBRA    ._free_try_bwd

._free_fwd_upd_neighbor:
    ADD     R13, 4
    LD32    (R13), R3

    ; --------------------------------------------------------------------------
    ; 2. Try Backward Coalescing
    ; --------------------------------------------------------------------------
._free_try_bwd:
    ; Read current chunk's prev_phys_size at offset +4
    ADD     R2, 4
    LD32    R4, (R2)            ; R4 = prev_phys_size
    SUB     R2, 4
    FBRA.NZ R4, ._free_chk_prev_free
    FBRA    ._free_link_curr

._free_chk_prev_free:
    ; prev_chunk = R2 - R4
    LD      R5, R2
    SUB     R5, R4              ; R5 = prev_chunk
    LD32    R6, (R5)            ; R6 = prev.block_size
    AND     R6, 1               ; in_use
    FBRA.Z  R6, ._free_do_bwd_merge
    FBRA    ._free_link_curr

._free_do_bwd_merge:
    ; prev_chunk is free: unlink prev_chunk (R5)
    LD      R10, R5
    RCALL   _unlink_free_chunk

    ; Combined size = prev.size + current size
    LD32    R6, (R5)
    LOAD32  R13, 0xFFFFFFFC
    AND     R6, R13
    ADD     R6, R3              ; R6 = new combined size
    LD32    (R5), R6            ; prev.block_size = new size

    ; Update neighbor after current (if within break)
    LD      R13, R5
    ADD     R13, R6
    LOAD32  R14, _heap_ptr
    LD32    R14, (R14)
    LD      R3, R13
    SLT     R3, R14
    FBRA.NZ R3, ._free_bwd_upd_neighbor
    LOAD32  R13, _last_phys_size
    LD32    (R13), R6
    FBRA    ._free_bwd_set_curr

._free_bwd_upd_neighbor:
    ADD     R13, 4
    LD32    (R13), R6

._free_bwd_set_curr:
    LD      R2, R5              ; Merged block starts at prev_chunk

._free_link_curr:
    ; Link chunk R2 into _free_list_head
    LOAD32  R13, _free_list_head
    LD32    R14, (R13)
    ADD     R2, 8
    LD32    (R2), R14           ; chunk.next = old_head
    SUB     R2, 8
    LD32    (R13), R2

._free_exit:
    POP32   R6
    POP32   R5
    POP32   R4
    POP32   R3
    POP32   R2
    POP32   R14
    RRET

; ------------------------------------------------------------------------------
; _unlink_free_chunk: Remove chunk in R10 from singly linked free list
; ------------------------------------------------------------------------------
_unlink_free_chunk:
    PUSH32  R14
    PUSH32  R1
    PUSH32  R2
    PUSH32  R3

    LOAD32  R1, _free_list_head
    LD32    R2, (R1)            ; R2 = curr
    LD      R3, R0              ; R3 = prev = 0

._unlink_loop:
    FBRA.NZ R2, ._unlink_check
    FBRA    ._unlink_done

._unlink_check:
    LD      R13, R2
    SEQ     R13, R10            ; R13 = (curr == target)
    FBRA.NZ R13, ._unlink_match

    ; Advance
    LD      R3, R2
    ADD     R2, 8
    LD32    R2, (R2)
    BBRA    ._unlink_loop

._unlink_match:
    ADD     R2, 8
    LD32    R2, (R2)            ; R2 = curr.next
    FBRA.NZ R3, ._unlink_mid
    LOAD32  R13, _free_list_head
    LD32    (R13), R2
    FBRA    ._unlink_done

._unlink_mid:
    ADD     R3, 8
    LD32    (R3), R2

._unlink_done:
    POP32   R3
    POP32   R2
    POP32   R1
    POP32   R14
    RRET

; ------------------------------------------------------------------------------
; _rt_realloc / __rt_realloc: Resize an allocated memory block
; Input:   R1 = existing payload pointer (or 0 to allocate new)
;          R2 = new requested payload size in bytes (or 0 to free)
; Output:  R1 = pointer to resized/new usable payload, or 0 on failure
; ------------------------------------------------------------------------------
_rt_realloc:
__rt_realloc:
    PUSH32  R14
    PUSH32  R4
    PUSH32  R5
    PUSH32  R6
    PUSH32  R7
    PUSH32  R8

    ; Check if old_ptr == 0 -> call alloc(new_size)
    FBRA.NZ R1, ._realloc_chk_size_zero
    LD      R1, R2
    RCALL   _rt_alloc
    LOAD32  R13, ._realloc_exit
    JMP     R13, R0

._realloc_chk_size_zero:
    ; Check if new_size == 0 -> call free(old_ptr) and return 0
    FBRA.NZ R2, ._realloc_calc_size
    RCALL   _rt_free
    LD      R1, 0
    LOAD32  R13, ._realloc_exit
    JMP     R13, R0

._realloc_calc_size:
    ; Preserve old_ptr in R4
    LD      R4, R1
    ; Align new size to 4 bytes: (R2 + 3) & ~3
    ADD     R2, 3
    LOAD32  R13, 0xFFFFFFFC
    AND     R2, R13
    ; Needed chunk size = aligned_payload + 8
    LD      R5, R2
    ADD     R5, 8
    ; Enforce minimum chunk size of 12 bytes
    LOAD16  R13, 12
    LD      R14, R5
    SLT     R14, R13
    FBRA.Z  R14, ._realloc_get_curr_size
    LOAD16  R5, 12

._realloc_get_curr_size:
    ; R6 = curr_chunk = R4 - 8
    LD      R6, R4
    SUB     R6, 8
    ; R7 = curr_chunk_size = curr_chunk.block_size & ~3
    LD32    R7, (R6)
    LOAD32  R13, 0xFFFFFFFC
    AND     R7, R13

    ; Compare curr_chunk_size (R7) vs needed_chunk_size (R5)
    LD      R13, R7
    SLT     R13, R5             ; R13 = (curr < needed)
    FBRA.Z  R13, ._realloc_case_shrink
    LOAD32  R13, ._realloc_try_fwd_grow
    JMP     R13, R0

    ; --------------------------------------------------------------------------
    ; Case A: In-place shrink (needed <= curr)
    ; --------------------------------------------------------------------------
._realloc_case_shrink:
    ; Remainder = curr_chunk_size - needed_chunk_size
    LD      R8, R7
    SUB     R8, R5
    LOAD16  R13, 12
    LD      R14, R8
    SLT     R14, R13            ; R14 = (rem < 12)
    FBRA.Z  R14, ._realloc_do_shrink_split
    ; If rem < 12, cannot split: return original pointer
    LD      R1, R4
    LOAD32  R13, ._realloc_exit
    JMP     R13, R0

._realloc_do_shrink_split:
    ; Split chunk:
    ; 1. Set curr_chunk.block_size = needed | 1
    LD      R13, R5
    OR      R13, 1
    LD32    (R6), R13

    ; 2. Remainder chunk at R6 + R5
    LD      R7, R6
    ADD     R7, R5              ; R7 = rem_chunk
    LD32    (R7), R8            ; rem.block_size = rem_size (free, bit0=0)
    ADD     R7, 4
    LD32    (R7), R5            ; rem.prev_phys_size = needed_size
    SUB     R7, 4

    ; 3. Update neighbor after rem (if within break): prev_phys_size = rem_size
    LD      R13, R7
    ADD     R13, R8             ; R13 = neighbor after rem
    LOAD32  R14, _heap_ptr
    LD32    R14, (R14)
    LD      R3, R13
    SLT     R3, R14             ; R3 = (neighbor < heap_ptr)
    FBRA.NZ R3, ._realloc_shrink_upd_neighbor
    ; Rem reached break: update _last_phys_size
    LOAD32  R13, _last_phys_size
    LD32    (R13), R8
    FBRA    ._realloc_shrink_free_rem

._realloc_shrink_upd_neighbor:
    ADD     R13, 4
    LD32    (R13), R8

._realloc_shrink_free_rem:
    ; Free the remainder chunk to link/coalesce it
    LD      R1, R7
    ADD     R1, 8
    RCALL   _rt_free

    ; Return original payload in R4
    LD      R1, R4
    LOAD32  R13, ._realloc_exit
    JMP     R13, R0

    ; --------------------------------------------------------------------------
    ; Case B: In-place grow via forward free neighbor
    ; --------------------------------------------------------------------------
._realloc_try_fwd_grow:
    LD      R8, R6
    ADD     R8, R7              ; R8 = next_chunk = curr_chunk + curr_size
    LOAD32  R13, _heap_ptr
    LD32    R13, (R13)
    LD      R14, R8
    SLT     R14, R13            ; R14 = (next_chunk < heap_ptr)
    FBRA.NZ R14, ._realloc_fwd_check_free
    LOAD32  R13, ._realloc_fallback_copy
    JMP     R13, R0

._realloc_fwd_check_free:
    LD32    R13, (R8)           ; R13 = next.block_size
    AND     R13, 1              ; R13 = next.in_use
    FBRA.Z  R13, ._realloc_fwd_is_free
    LOAD32  R13, ._realloc_fallback_copy
    JMP     R13, R0

._realloc_fwd_is_free:
    ; Next is free: check total available size = curr_size + next_size
    LD32    R13, (R8)
    LOAD32  R7, 0xFFFFFFFC
    AND     R13, R7             ; R13 = next_size
    LD32    R7, (R6)            ; reload curr_chunk.block_size
    LOAD32  R10, 0xFFFFFFFC
    AND     R7, R10
    ADD     R7, R13             ; R7 = combined_size
    LD      R10, R7
    SLT     R10, R5             ; R10 = (combined < needed)
    FBRA.Z  R10, ._realloc_do_fwd_merge
    LOAD32  R13, ._realloc_fallback_copy
    JMP     R13, R0

._realloc_do_fwd_merge:
    ; Unlink next_chunk (R8) from free list
    LD      R10, R8
    RCALL   _unlink_free_chunk

    ; Update curr_chunk.block_size = combined_size | 1
    LD      R13, R7
    OR      R13, 1
    LD32    (R6), R13

    ; Update neighbor after next (if within break): prev_phys_size = combined_size
    LD      R13, R6
    ADD     R13, R7             ; R13 = neighbor
    LOAD32  R14, _heap_ptr
    LD32    R14, (R14)
    LD      R8, R13
    SLT     R8, R14
    FBRA.NZ R8, ._realloc_merge_upd_neighbor
    LOAD32  R8, _last_phys_size
    LD32    (R8), R7
    FBRA    ._realloc_merge_done

._realloc_merge_upd_neighbor:
    ADD     R13, 4
    LD32    (R13), R7

._realloc_merge_done:
    ; Check if excess can be split: excess = combined - needed
    LD      R8, R7
    SUB     R8, R5
    LOAD16  R13, 12
    LD      R14, R8
    SLT     R14, R13
    FBRA.Z  R14, ._realloc_do_excess_split
    ; Cannot split excess: return original payload
    LD      R1, R4
    LOAD32  R13, ._realloc_exit
    JMP     R13, R0

._realloc_do_excess_split:
    ; Split excess
    LD      R13, R5
    OR      R13, 1
    LD32    (R6), R13           ; set curr_size = needed | 1

    LD      R7, R6
    ADD     R7, R5              ; R7 = split chunk
    LD32    (R7), R8            ; split.block_size = excess
    ADD     R7, 4
    LD32    (R7), R5            ; split.prev_phys_size = needed
    SUB     R7, 4

    ; Update neighbor after split
    LD      R13, R7
    ADD     R13, R8
    LOAD32  R14, _heap_ptr
    LD32    R14, (R14)
    LD      R3, R13
    SLT     R3, R14             ; R3 = (neighbor < heap_ptr)
    FBRA.NZ R3, ._realloc_split_upd_neighbor
    LOAD32  R13, _last_phys_size
    LD32    (R13), R8
    FBRA    ._realloc_split_free

._realloc_split_upd_neighbor:
    ADD     R13, 4
    LD32    (R13), R8

._realloc_split_free:
    LD      R1, R7
    ADD     R1, 8
    RCALL   _rt_free
    LD      R1, R4
    LOAD32  R13, ._realloc_exit
    JMP     R13, R0

    ; --------------------------------------------------------------------------
    ; Case C: Allocate, copy, and free old block
    ; --------------------------------------------------------------------------
._realloc_fallback_copy:
    ; Allocate new block of size (needed_chunk_size - 8)
    LD      R1, R5
    SUB     R1, 8
    RCALL   _rt_alloc
    FBRA.NZ R1, ._realloc_do_copy
    LOAD32  R13, ._realloc_exit
    JMP     R13, R0

._realloc_do_copy:
    LD      R8, R1              ; R8 = new_payload

    ; Reload old chunk size cleanly from (R4 - 8)
    LD      R6, R4
    SUB     R6, 8
    LD32    R7, (R6)            ; R7 = curr_chunk.block_size
    LOAD32  R13, 0xFFFFFFFC
    AND     R7, R13             ; R7 = curr_chunk_size

    ; Determine copy word count: min(old_payload_words, new_payload_words)
    LD      R2, R7
    SUB     R2, 8               ; old payload bytes
    LD      R3, R5
    SUB     R3, 8               ; new payload bytes
    LD      R13, R2
    SLT     R13, R3
    FBRA.NZ R13, ._realloc_copy_len_set
    LD      R2, R3
._realloc_copy_len_set:
    SHIFTR  R2, 2               ; R2 = copy words

    ; Copy loop: R4 = old_ptr, R8 = new_ptr, R2 = words remaining
    LD      R6, R0              ; R6 = byte offset
._realloc_copy_loop:
    FBRA.NZ R2, ._realloc_copy_step
    FBRA    ._realloc_copy_finished
._realloc_copy_step:
    LD      R13, R4
    ADD     R13, R6
    LD32    R7, (R13)           ; R7 = old_ptr[i]
    LD      R13, R8
    ADD     R13, R6
    LD32    (R13), R7           ; new_ptr[i] = R7
    ADD     R6, 4
    SUB     R2, 1
    LOAD32  R13, ._realloc_copy_loop
    JMP     R13, R0

._realloc_copy_finished:
    ; Free old payload in R4
    LD      R1, R4
    RCALL   _rt_free

    ; Return new payload in R8
    LD      R1, R8

._realloc_exit:
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
_free_list_head:
    .word 0
_heap_ptr:
    .word 0
_last_phys_size:
    .word 0
_heap_start:
    .word 0x00010000
