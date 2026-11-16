// =============================================================================
// Parcore RV32IM_Zbb Bare-Metal Environment Header for official riscv-tests
// =============================================================================
#ifndef _PARCORE_RISCV_TEST_H
#define _PARCORE_RISCV_TEST_H

#define TESTNUM gp

#define RVTEST_RV32U                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_RV32M                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_CODE_BEGIN                                               \
  .section .text.init;                                                  \
  .align  2;                                                            \
  .globl _start;                                                        \
_start:                                                                 \
  init;

#define RVTEST_CODE_END                                                 \
  .word 0x00000000

#define RVTEST_PASS                                                     \
  nop;                                                                  \
  nop;                                                                  \
  li TESTNUM, 1;                                                        \
  li a0, 0;                                                             \
  li x31, 0xCAFE0001;                                                   \
  .word 0x00000000;

#define RVTEST_FAIL                                                     \
  nop;                                                                  \
  nop;                                                                  \
  slli a0, TESTNUM, 1;                                                  \
  ori  a0, a0, 1;                                                       \
  li   x31, 0xDEAD0000;                                                 \
  or   x31, x31, TESTNUM;                                               \
  .word 0x00000000;

#define RVTEST_DATA_BEGIN                                               \
  .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END                                                 \
  .align 4; .global end_signature; end_signature:

#endif
