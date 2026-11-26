; ==============================================================================
; Particle Common Architectural Include File
; ==============================================================================
.ifndef _PARTICLE_COMMON_INC_
.define _PARTICLE_COMMON_INC_ 1

.define TRAP_TABLE_BASE     0x00000100
.define TRAP_STRIDE_BYTES   16

.define TRAP_RESET          0
.define TRAP_MBOX           1
.define TRAP_ALIGN          14
.define TRAP_ILLEGAL        15

; The network interface's registers, at 0xFFFF_FF00 and up. Load an address
; with LDIS, which sign-extends these 16 bits: LDIS R5, NI_MBOX_VALUE
;   NI_FLUSH        store a channel number: send a FLUSH on that channel
;   NI_MBOX_VALUE   load: the value of the last MBOX trap taken
;   NI_MBOX_SOURCE  load: the core that sent it
;   NI_CONFIG       store: send a CONFIG packet (Documentation/mbox_design.md)
.define NI_FLUSH            0xFF00
.define NI_MBOX_VALUE       0xFF04
.define NI_MBOX_SOURCE      0xFF08
.define NI_CONFIG           0xFF0C

.macro LOAD16 reg, value
    LDI     %reg, %value
.endmacro

.macro LOAD16S reg, value
    LDIS    %reg, %value
.endmacro

.macro LOAD24 reg, value
    LDI     R14, ((%value) >> 8) & 0xFFFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

.macro LOAD_R14_32 value
    LDI     R14, ((%value) >> 16) & 0xFFFF
    PUSH8   R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
.endmacro

.macro LOAD32 reg, value
    LDI     R14, ((%value) >> 16) & 0xFFFF
    PUSH8   R14, ((%value) >> 8) & 0xFF
    PUSH8   R14, (%value) & 0xFF
    LD      %reg, R14
.endmacro

.macro LOAD_R14_16 value
    LDI     R14, %value
.endmacro

; --- Zero Page (0x0000..0x00FF) Single-Instruction Pointer Macros ---
; Loads an 8-bit Zero Page address into R14 (or reg) in 1 instruction (2 bytes).
; Note: When reg is R14, prefer `LD R14, zp_addr` directly.
.macro LDZP reg, zp_addr
    LD      R14, (%zp_addr) & 0xFF
    LD      %reg, R14
.endmacro

.macro LDZP32 reg, zp_addr
    LD      R14, (%zp_addr) & 0xFF
    LD32    %reg, (R14)
.endmacro

.macro STZP32 zp_addr, reg
    LD      R14, (%zp_addr) & 0xFF
    ST32    (R14), %reg
.endmacro

.macro START_PROGRAM
    LOAD32  R15, 0x00010000
    LDI     R14, _main
    JMP     R14, R0
.endmacro

.macro LJMP target
    LDI     R14, %target
    JMP     R14, R0
.endmacro

.macro RLCALL target
    LDI     R14, %target
    JMP     R14, R14
.endmacro

.macro RCALL target
    LDI     R14, %target
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
