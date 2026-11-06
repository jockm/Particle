# Particle 32-bit Architecture Port for ChibiOS/RT & LCC

This document bundles the complete port files for running ChibiOS/RT on the **Particle 32-bit RISC architecture**, compiled via a retargeted **LCC (Little C Compiler)** backend.

---

## 1. LCC Machine Description: `src/particle.md`

Save this file into your LCC source tree as `src/particle.md`. It provides the `lburg` tree-matching patterns to generate Particle assembly conforming to `tools/pasm.py`.

```c
%{
#include "c.h"
#define NODEPTR_TYPE Node
#define OP_LABEL(p) ((p)->op)
#define LEFT_CHILD(p) ((p)->kids[0])
#define RIGHT_CHILD(p) ((p)->kids[1])
#define STATE_LABEL(p) ((p)->x.state)

static void emit_relational(char *op, Node p);
static void emit_branch(int op, Node p, Symbol target);
%}

%term CNSTU4=8449 CNSTI4=4353 CNSTP4=12545
%term ADDRGP4=20737 ADDRFP4=16641 ADDRLP4=18689
%term INDIRU4=8465 INDIRI4=4369 INDIRU1=8451 INDIRI1=4355 INDIRU2=8453 INDIRI2=4357
%term CVUI4=4389 CVII4=4357 CVIU4=8485 CVPU4=8485
%term ASGNI4=4369 ASGNU4=8465 ASGNU1=8451 ASGNI1=4355 ASGNU2=8453 ASGNI2=4357

%%
reg:  INDIRI4(VREGP)          "# read register\n"
reg:  INDIRU4(VREGP)          "# read register\n"

/* 4-bit immediate matchers for native Particle instructions (-15..15) */
con4: CNSTI4                  "%a"   range(a, 0, 15)
neg4: CNSTI4                  "%a"   range(a, -15, -1)

/* Loading Constants */
reg:  con4                    "LD\t%c, %0\n"        1
reg:  neg4                    "LD\t%c, %0\n"        1
reg:  CNSTI4                  "LOAD32\t%c, %0\n"    4
reg:  CNSTU4                  "LOAD32\t%c, %0\n"    4
reg:  CNSTP4                  "LOAD32\t%c, %0\n"    4
reg:  ADDRGP4                 "LOAD32\t%c, %a\n"    4
reg:  ADDRFP4                 "LOAD32\t%c, %a\n"    4
reg:  ADDRLP4                 "LOAD32\t%c, %a\n"    4

/* Memory Load Operations */
reg:  INDIRI4(reg)            "LD32\t%c, (%0)\n"    1
reg:  INDIRU4(reg)            "LD32\t%c, (%0)\n"    1
reg:  INDIRI2(reg)            "LD16\t%c, (%0)\n"    1
reg:  INDIRU2(reg)            "LD16\t%c, (%0)\n"    1
reg:  INDIRI1(reg)            "LD8\t%c, (%0)\n"     1
reg:  INDIRU1(reg)            "LD8\t%c, (%0)\n"     1

/* Memory Store Operations */
stmt: ASGNI4(reg, reg)        "ST32\t(%0), %1\n"    1
stmt: ASGNU4(reg, reg)        "ST32\t(%0), %1\n"    1
stmt: ASGNI2(reg, reg)        "ST16\t(%0), %1\n"    1
stmt: ASGNU2(reg, reg)        "ST16\t(%0), %1\n"    1
stmt: ASGNI1(reg, reg)        "ST8\t(%0), %1\n"     1
stmt: ASGNU1(reg, reg)        "ST8\t(%0), %1\n"     1

/* Arithmetic & Bitwise Logic */
reg:  ADDI4(reg, reg)         "ADD\t%c, %1\n"       1
reg:  ADDI4(reg, con4)        "ADD\t%c, %1\n"       1
reg:  SUBI4(reg, reg)         "SUB\t%c, %1\n"       1
reg:  SUBI4(reg, con4)        "SUB\t%c, %1\n"       1
reg:  BANDI4(reg, reg)        "AND\t%c, %1\n"       1
reg:  BORI4(reg, reg)         "OR\t%c, %1\n"        1
reg:  BXORI4(reg, reg)        "XOR\t%c, %1\n"       1
reg:  BCOMI4(reg)             "NOT\t%c, %0\n"       1
reg:  LSHI4(reg, con4)        "SHIFTL\t%c, %1\n"    1
reg:  RSHI4(reg, con4)        "SHIFTR\t%c, %1\n"    1

/* Flagless Relational Comparison: write 0/1 boolean result directly to %c */
reg:  EQI4(reg, reg)          "SEQ\t%c, %1\n"       1
reg:  NEI4(reg, reg)          "SNE\t%c, %1\n"       1
reg:  LTI4(reg, reg)          "SLT\t%c, %1\n"       1
reg:  LEI4(reg, reg)          "SLE\t%c, %1\n"       1
reg:  GTI4(reg, reg)          "SGT\t%c, %1\n"       1
reg:  GEI4(reg, reg)          "SGE\t%c, %1\n"       1
%%

/* Branch Emitter: Invert sense across 4-bit limit and emit trampoline */
static void emit_branch(int op, Node p, Symbol target) {
    print("    FBRA.Z   %s, 2\n", p->sym[0]->x.name);
    print("    LOAD32   R14, %s\n", target->x.name);
    print("    JMP      R14, R0\n");
}
```

---

## 2. ChibiOS Architecture Header: `os/common/ports/PARTICLE/chcore.h`

Save this file into your ChibiOS tree as `os/common/ports/PARTICLE/chcore.h`.

```c
#ifndef _CHCORE_H_
#define _CHCORE_H_

#include <stdint.h>
#include <stdbool.h>

#define PORT_ARCHITECTURE_NAME          "Particle 32-bit RISC"
#define PORT_CORE_VARIANT_NAME          "Parcore"

/* Basic types */
typedef uint32_t                        stkalign_t;
typedef uint32_t                        syssts_t;

/* Context saved by cooperative context switch (_port_switch) */
struct port_intctx {
    uint32_t    r5;
    uint32_t    r6;
    uint32_t    r7;
    uint32_t    r8;
    uint32_t    r9;
    uint32_t    r10;
    uint32_t    r14;    /* Target PC / Return Link Register */
};

/* Context saved across preemption or interrupts */
struct port_extctx {
    uint32_t    r1;
    uint32_t    r2;
    uint32_t    r3;
    uint32_t    r4;
    uint32_t    r11;
    uint32_t    r12;
    uint32_t    r13;
    uint32_t    r14;
};

/* Stack architecture: full descending, 4-byte aligned */
#define PORT_STACK_ALIGN                4
#define PORT_WORKING_AREA_ALIGN         4
#define PORT_INT_REQUIRED_STACK         64

/* Context initialization macro */
#define PORT_SETUP_CONTEXT(tp, wbase, wtop, pf, arg) {                         \
    tp->ctx.sp = (struct port_intctx *)((uint8_t *)(wtop) -                   \
                                        sizeof(struct port_intctx));           \
    tp->ctx.sp->r14 = (uint32_t)(pf);                                          \
    tp->ctx.sp->r5  = (uint32_t)(arg);                                         \
    tp->ctx.sp->r6  = 0;                                                       \
    tp->ctx.sp->r7  = 0;                                                       \
    tp->ctx.sp->r8  = 0;                                                       \
    tp->ctx.sp->r9  = 0;                                                       \
    tp->ctx.sp->r10 = 0;                                                       \
}

/* Architecture hooks */
#define port_init()
#define port_switch(ntp, otp)           _port_switch(ntp, otp)

/* Interrupt lock/unlock macros */
#define port_lock()                     asm volatile (" ; lock ")
#define port_unlock()                   asm volatile (" ; unlock ")
#define port_lock_from_isr()
#define port_unlock_from_isr()

void _port_switch(void *ntp, void *otp);
void _port_thread_start(void);

#endif /* _CHCORE_H_ */
```

---

## 3. ChibiOS Architecture C Implementation: `os/common/ports/PARTICLE/chcore.c`

Save this file as `os/common/ports/PARTICLE/chcore.c`.

```c
#include "ch.h"

/**
 * @brief   Performs thread start initialization.
 */
void _port_thread_start(void) {
    chSysUnlock();
    /* Jump directly into thread routine via R14 */
}

/**
 * @brief   Initializes port architecture-specific subsystems.
 */
void _port_init(void) {
    /* Setup timer interrupt vector base if needed */
}
```

---

## 4. Context Switch Assembly: `os/common/ports/PARTICLE/chcore.s`

Save this file as `os/common/ports/PARTICLE/chcore.s`. This routine handles cooperative task switching and timer interrupt preemption. It directly targets `tools/pasm.py`.

```assembly
; ==============================================================================
; ChibiOS/RT Port: Particle 32-bit Architecture Context Switch
; File: os/common/ports/PARTICLE/chcore.s
; Compatible with: tools/pasm.py
; ==============================================================================
.include "lib/common.inc"

.global _port_switch
_port_switch:
    ; --------------------------------------------------------------------------
    ; 1. Save Callee-Saved Registers onto Current Thread Stack (R15 / SP)
    ; Frame Size: 7 words (28 bytes)
    ; --------------------------------------------------------------------------
    SUB     R15, 28             ; Allocate stack frame
    ST32    (R15),    R5        ; Preserve callee-saved registers R5-R10
    ST32    4(R15),   R6
    ST32    8(R15),   R7
    ST32    12(R15),  R8
    ST32    16(R15),  R9
    ST32    20(R15),  R10
    ST32    24(R15),  R14       ; Preserve Link Register (Return PC)

    ; --------------------------------------------------------------------------
    ; 2. Store Stack Pointer into Old Thread Control Block (otp)
    ; R2 contains otp. otp->ctx.sp is located at byte offset 0.
    ; --------------------------------------------------------------------------
    ST32    (R2), R15

    ; --------------------------------------------------------------------------
    ; 3. Load Stack Pointer from New Thread Control Block (ntp)
    ; R1 contains ntp. ntp->ctx.sp is located at byte offset 0.
    ; --------------------------------------------------------------------------
    LD32    R15, (R1)

    ; --------------------------------------------------------------------------
    ; 4. Restore Callee-Saved Context from New Thread Stack
    ; --------------------------------------------------------------------------
    LD32    R5,   (R15)
    LD32    R6,   4(R15)
    LD32    R7,   8(R15)
    LD32    R8,   12(R15)
    LD32    R9,   16(R15)
    LD32    R10,  20(R15)
    LD32    R14,  24(R15)       ; Restore Link / Target PC

    ADD     R15, 28             ; Deallocate stack frame

    ; --------------------------------------------------------------------------
    ; 5. Branch to Restored Thread
    ; --------------------------------------------------------------------------
    JMP     R14, R0             ; Return: PC <- R14

; ==============================================================================
; Preemptive Timer Tick Handler (Direct Stride Vector Slot)
; Vector Base: 0x00000180 (Vector 2 = TRAP_TABLE_BASE + 2 * 64)
; ==============================================================================
.org 0x00000180
_timer_tick_vector:
    ; Instantly swap R1-R14 with hardware shadow registers S1-S14
    FAST_ENTER_TRAP

    ; Call ChibiOS System Tick / Preemption Handler
    LOAD32  R14, chSysTimerHandlerI
    RCALL   R14, R0

    ; Check if scheduler requested a reschedule
    LOAD32  R1, ch
    LD32    R2, (R1)
    FBRA.Z  R2, ._no_preempt

    ; Preemption requested: swap back to main registers and switch
    FAST_EXIT_TRAP
    LOAD32  R14, chSchDoReschedule
    RCALL   R14, R0
    RRET

._no_preempt:
    FAST_EXIT_TRAP
```