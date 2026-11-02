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
    BBRA.NZ R3, _init_tag_loop

    LOAD32  R10, MMIO_MEM_REQ
    LOAD32  R11, MMIO_MEM_RESP

_cache_service_loop:
    LD32    R1, (R10)           ; Poll MMIO_MEM_REQ
    LD      R14, R1
    FBRA.NZ R14, ._got_req      ; R14 Imm8 branch (up to 510 bytes)
    LOAD16  R14, _cache_service_loop
    JMP     R14, R0

._got_req:
    ; Extract index: R2 = (R1 >> 5) & 0xFF
    SHIFTR  R2, R1, 5
    LOAD16  R14, 0xFF
    AND     R2, R14

    ; Extract tag: R3 = R1 >> 13
    SHIFTR  R3, R1, 13

    ; Extract block offset: R4 = (R1 >> 2) & 0x07
    SHIFTR  R4, R1, 2
    LD      R14, 0x07
    AND     R4, R14

    ; Read tag entry: TAG_ARRAY_BASE + (R2 << 2)
    LOAD16  R5, TAG_ARRAY_BASE
    SHIFTL  R6, R2, 2
    ADD     R5, R6
    LD32    R6, (R5)            ; R6 = Tag Word [31:13 Tag, 1 Dirty, 0 Valid]

    ; Check Valid bit
    AND     R7, R6, 1
    LD      R14, R7
    FBRA.Z  R14, ._tag_miss     ; R14 Imm8 branch to miss handler

    ; Compare stored tag against request tag
    SHIFTR  R7, R6, 13
    SUB     R8, R7, R3
    LD      R14, R8
    FBRA.Z  R14, ._tag_hit      ; R14 Imm8 branch to hit handler

._tag_miss:
    LOAD16  R14, _handle_cache_miss
    JMP     R14, R0

._tag_hit:
    LOAD16  R14, _handle_cache_hit
    JMP     R14, R0

; ------------------------------------------------------------------------------
; Cache Miss: Writeback if Dirty, then Refill Block from SDRAM
; ------------------------------------------------------------------------------
_handle_cache_miss:
    AND     R7, R6, 1           ; Check valid
    LD      R14, R7
    FBRA.Z  R14, ._do_refill
    AND     R7, R6, 2           ; Check dirty
    LD      R14, R7
    FBRA.Z  R14, ._do_refill

    ; Evict dirty line: Compute old address = (Tag << 13) | (Index << 5)
    SHIFTR  R7, R6, 13
    SHIFTL  R7, 13
    SHIFTL  R8, R2, 5
    OR      R7, R8

    LOAD32  R8, SDRAM_ADDR_REG
    LD32    (R8), R7

    LOAD32  R8, SDRAM_CMD_REG
    LD      R9, 2               ; Command 2: SDRAM Write Burst
    LD32    (R8), R9

    ; Write 32 bytes (8 words / 16 halfwords) to SDRAM data port
    LOAD16  R8, DATA_ARRAY_BASE
    SHIFTL  R9, R2, 5
    ADD     R8, R9
    LOAD32  R9, SDRAM_DATA_PORT
    LOAD16  R12, 8
_evict_burst_loop:
    LD32    R13, (R8++)
    LD16    (R9), R13           ; Write low halfword
    SHIFTR  R13, 16
    LD16    (R9), R13           ; Write high halfword
    SUB     R12, 1
    BBRA.NZ R12, _evict_burst_loop

._do_refill:
    ; Program SDRAM read burst at aligned address: R1 & 0xFFFFFFE0
    LOAD16  R7, 0xFFE0
    AND     R7, R1, R7
    LOAD32  R8, SDRAM_ADDR_REG
    LD32    (R8), R7

    LOAD32  R8, SDRAM_CMD_REG
    LD      R9, 1               ; Command 1: SDRAM Read Burst
    LD32    (R8), R9

    ; Fill 32 bytes from SDRAM data port into data array
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
    BBRA.NZ R12, _refill_burst_loop

    ; Update tag array entry: (Tag << 13) | Valid (1)
    SHIFTL  R6, R3, 13
    OR      R6, 1
    LD32    (R5), R6

; ------------------------------------------------------------------------------
; Cache Hit Service
; ------------------------------------------------------------------------------
_handle_cache_hit:
    ; Calculate word address in cache data array:
    ; DATA_ARRAY_BASE + (Index << 5) + (BlockOffset << 2)
    LOAD16  R8, DATA_ARRAY_BASE
    SHIFTL  R9, R2, 5
    ADD     R8, R9
    SHIFTL  R9, R4, 2
    ADD     R8, R9

    ; Check if request is Write (MMIO_MEM_RESP has non-zero store data):
    LD32    R9, (R11)
    LD      R14, R9
    FBRA.Z  R14, ._service_read_hit

    ; Service write hit:
    LD32    (R8), R9            ; Write new data into cache line
    OR      R6, 2               ; Set dirty bit
    LD32    (R5), R6            ; Update tag entry
    LD      R12, 1
    LD32    (R11), R12          ; Acknowledge write completion
    FBRA    ._clear_req_and_loop

._service_read_hit:
    LD32    R12, (R8)           ; Read word from cache
    LD32    (R11), R12          ; Return data via MMIO_MEM_RESP

._clear_req_and_loop:
    LD      R12, 0
    LD32    (R10), R12          ; Clear MMIO_MEM_REQ to acknowledge completion
    LOAD16  R14, _cache_service_loop
    JMP     R14, R0