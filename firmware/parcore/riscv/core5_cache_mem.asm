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
    SHIFTR  R2, R1, 5
    LOAD16  R14, 0xFF
    AND     R2, R14

    SHIFTR  R3, R1, 13

    SHIFTR  R4, R1, 2
    LD      R14, 0x07
    AND     R4, R14

    LOAD16  R5, TAG_ARRAY_BASE
    SHIFTL  R6, R2, 2
    ADD     R5, R6
    LD32    R6, (R5)

    AND     R7, R6, 1
    FBRA.Z  R7, ._go_miss

    SHIFTR  R7, R6, 13
    SUB     R8, R7, R3
    FBRA.Z  R8, ._go_hit

._go_miss:
    LOAD16  R14, _handle_cache_miss
    JMP     R14, R0

._go_hit:
    LOAD16  R14, _handle_cache_hit
    JMP     R14, R0

_handle_cache_miss:
    AND     R7, R6, 1
    FBRA.Z  R7, ._go_refill
    AND     R7, R6, 2
    FBRA.Z  R7, ._go_refill

    SHIFTR  R7, R6, 13
    SHIFTL  R7, 13
    SHIFTL  R8, R2, 5
    OR      R7, R8

    LOAD32  R8, SDRAM_ADDR_REG
    LD32    (R8), R7

    LOAD32  R8, SDRAM_CMD_REG
    LD      R9, 2
    LD32    (R8), R9

    LOAD16  R8, DATA_ARRAY_BASE
    SHIFTL  R9, R2, 5
    ADD     R8, R9
    LOAD32  R9, SDRAM_DATA_PORT
    LOAD16  R12, 8
_evict_burst_loop:
    LD32    R13, (R8++)
    LD16    (R9), R13           ; Lower 16 bits
    SHIFTR  R13, 16
    LD16    (R9), R13           ; Upper 16 bits
    SUB     R12, 1
    BBRA.P  R12, _evict_burst_loop

._go_refill:
    LOAD16  R7, 0xFFE0
    AND     R7, R1, R7
    LOAD32  R8, SDRAM_ADDR_REG
    LD32    (R8), R7

    LOAD32  R8, SDRAM_CMD_REG
    LD      R9, 1
    LD32    (R8), R9

    LOAD16  R8, DATA_ARRAY_BASE
    SHIFTL  R9, R2, 5
    ADD     R8, R9
    LOAD32  R9, SDRAM_DATA_PORT
    LOAD16  R12, 8
_refill_burst_loop:
    LD16    R13, (R9)
    LD16    R14, (R9)
    SHIFTL  R14, 16
    OR      R13, R14
    LD32    (R8++), R13
    SUB     R12, 1
    BBRA.P  R12, _refill_burst_loop

    SHIFTL  R6, R3, 13
    OR      R6, 1
    LD32    (R5), R6

_handle_cache_hit:
    LOAD16  R8, DATA_ARRAY_BASE
    SHIFTL  R9, R2, 5
    ADD     R8, R9
    SHIFTL  R9, R4, 2
    ADD     R8, R9

    LD32    R9, (R11)
    FBRA.Z  R9, ._service_read_hit

    LD32    (R8), R9            ; Store payload into cache
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