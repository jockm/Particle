; ==============================================================================
; Particle Common Architectural Include File
; ==============================================================================
.ifndef _PARTICLE_COMMON_INC_
.define _PARTICLE_COMMON_INC_ 1

.define R0          0
.define R1          1
.define R2          2
.define R3          3
.define R4          4
.define R5          5
.define R6          6
.define R7          7
.define R8          8
.define R9          9
.define R10         10
.define R11         11
.define R12         12
.define R13         13
.define R14         14
.define R15         15

.define TRAP_TABLE_BASE     0x00000100
.define TRAP_STRIDE_BYTES   64

.define TRAP_RESET          0
.define TRAP_MBOX           1
.define TRAP_ALIGN          14
.define TRAP_ILLEGAL        15

.macro LOAD16 reg, value
    LD      R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

.macro LOAD24 reg, value
    LD      R14, ((%value) >> 16) & 0xFF
    PUSH8   R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

.macro LOAD32 reg, value
    LD      R14, ((%value) >> 24) & 0xFF
    PUSH8   R14, ((%value) >> 16) & 0xFF
    PUSH8   R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

.macro START_PROGRAM
    LOAD32  R15, 0x00010000
    LOAD32  R14, _main
    JMP     R14, R0
.endmacro

.macro RCALL target
    LOAD32  R14, %target
    JMP     R14, R14
.endmacro

.macro RRET
    JMP     R14, R0
.endmacro

.macro PUSH32 reg
    LD32    (--R15), %reg
.endmacro

.macro POP32 reg
    LD32    %reg, (R15++)
.endmacro

.macro FAST_ENTER_TRAP
    XCHGMOST
.endmacro

.macro FAST_EXIT_TRAP
    XCHGMOST
    JMP     R14, R0
.endmacro

; ------------------------------------------------------------------------------
; Extended Native ISA Opcodes (NEG, REV32, SEQ, SNE, SLE, SSLE)
; ------------------------------------------------------------------------------
; Note: NEG is now a native 1-cycle instruction (0x48).
; Legacy macro wrapper removed to ensure native instruction execution.

.endif
