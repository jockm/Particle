; ==============================================================================
; Parcore RV32IM_Zbb: Core 5 (L1 Cache Controller & SDRAM Burster)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core5_cache_mem.asm
; ==============================================================================
.include "lib/common.inc"

.define TAG_ARRAY_BASE   0x0400
.define DATA_ARRAY_BASE  0x1000

.define MMIO_MEM_REQ     0xF0000040
.define MMIO_MEM_RESP    0xF0000044
.define SDRAM_ADDR_REG   0xF0000030
.define SDRAM_CMD_REG    0xF0000034
.define SDRAM_DATA_PORT  0xF0000038

.org 0x00000100
_reset_vector:
    LOAD16  R1, TAG_ARRAY_BASE
    LD      R2, 0
    LOAD16  R3, 256
_init_tag_loop:
    LD32    (R1++), R2          ; Clear tag entry
    SUB     R3, 1
    BBRA.P  R3, _init_tag_loop

    LOAD32  R10, MMIO_MEM_REQ
    LOAD32  R11, MMIO_MEM_RESP

_cache_service_loop:
    LD32    R1, (R10)
    FBRA.NZ R1, ._got_req
    LOAD16  R14, _cache_service_loop
    JMP     R14, R0

._got_req:
    LD      R2, R1
    SHIFTR  R2, 5
    LOAD16  R14, 0xFF
    AND     R2, R14

    LD      R3, R1
    LD      R3, R1
    LOAD16  R14, 8
    SHIFTR  R3, R14
    SHIFTR  R3, R14

    LD      R4, R1
    SHIFTR  R4, 2
    LD      R14, 0x07
    AND     R4, R14

    LOAD16  R5, TAG_ARRAY_BASE
    LD      R6, R2
    SHIFTL  R6, 2
    ADD     R5, R6
    LD32    R6, (R5)

    LD      R7, R6
    AND     R7, 1
    FBRA.Z  R7, ._go_miss

    LD      R7, R6
    LOAD16  R14, 8
    SHIFTR  R7, R14
    SHIFTR  R7, R14
    LD      R8, R7
    SUB     R8, R3
    FBRA.Z  R8, ._go_hit

._go_miss:
    LOAD16  R14, _handle_cache_miss
    JMP     R14, R0

._go_hit:
    LOAD16  R14, _handle_cache_hit
    JMP     R14, R0

_handle_cache_miss:
    LD      R7, R6
    AND     R7, 1
    FBRA.Z  R7, ._trampoline_refill
    LD      R7, R6
    AND     R7, 2
    FBRA.Z  R7, ._trampoline_refill
    LOAD16  R14, ._evict_dirty_line
    JMP     R14, R0

._trampoline_refill:
    LOAD16  R14, ._go_refill
    JMP     R14, R0

._evict_dirty_line:

    LD      R7, R6
    LOAD16  R14, 8
    SHIFTR  R7, R14
    SHIFTR  R7, R14
    SHIFTL  R7, 8
    SHIFTL  R7, 5
    LD      R8, R2
    SHIFTL  R8, 5
    OR      R7, R8

    LOAD32  R8, SDRAM_ADDR_REG
    LD32    (R8), R7

    LOAD32  R8, SDRAM_CMD_REG
    LD      R9, 2
    LD32    (R8), R9

    LOAD16  R8, DATA_ARRAY_BASE
    LD      R9, R2
    SHIFTL  R9, 5
    ADD     R8, R9
    LOAD32  R9, SDRAM_DATA_PORT
    LOAD16  R12, 8
_evict_burst_loop:
    LD32    R13, (R8++)
    LD16    (R9), R13
    LD      R13, R13
    SHIFTR  R13, 8
    SHIFTR  R13, 8
    LD16    (R9), R13
    SUB     R12, 1
    BBRA.P  R12, _evict_burst_loop

._go_refill:
    LOAD16  R7, 0xFFE0
    LD      R14, R1
    AND     R14, R7
    LD      R7, R14
    LOAD32  R8, SDRAM_ADDR_REG
    LD32    (R8), R7

    LOAD32  R8, SDRAM_CMD_REG
    LD      R9, 1
    LD32    (R8), R9

    LOAD16  R8, DATA_ARRAY_BASE
    LD      R9, R2
    SHIFTL  R9, 5
    ADD     R8, R9
    LOAD32  R9, SDRAM_DATA_PORT
    LOAD16  R12, 8
_refill_burst_loop:
    LD16    R13, (R9)
    LD16    R14, (R9)
    LD      R15, R14
    LOAD16  R14, 8
    SHIFTL  R15, R14
    SHIFTL  R15, R14
    OR      R13, R15
    LD32    (R8++), R13
    SUB     R12, 1
    BBRA.P  R12, _refill_burst_loop

    LD      R6, R3
    LOAD16  R14, 8
    SHIFTL  R6, R14
    SHIFTL  R6, R14
    OR      R6, 1
    LD32    (R5), R6

_handle_cache_hit:
    LOAD16  R8, DATA_ARRAY_BASE
    LD      R9, R2
    SHIFTL  R9, 5
    ADD     R8, R9
    LD      R9, R4
    SHIFTL  R9, 2
    ADD     R8, R9

    LD32    R9, (R11)
    FBRA.Z  R9, ._service_read_hit

    LD32    (R8), R9
    LD      R6, R6
    OR      R6, 2
    LD32    (R5), R6
    LD      R12, 1
    LD32    (R11), R12
    LOAD16  R14, ._clear_req_and_loop
    JMP     R14, R0

._service_read_hit:
    LD32    R12, (R8)
    LD32    (R11), R12

._clear_req_and_loop:
    LD      R12, 0
    LD32    (R10), R12
    LOAD16  R14, _cache_service_loop
    JMP     R14, R0
