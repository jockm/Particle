# =============================================================================
# File: apps/riscv/bench.S
# Description: Parcore benchmark guest (RV32IM): a fixed mix of RISC-V work,
#              in five phases, for `make parcore-profile`. It does no I/O
#              until the end, so its run time depends only on Parcore.
# Build: make parcore-guest PARCORE_GUEST=apps/riscv/bench.S
# =============================================================================
#
# Phases (the LEDs, 0x1000_0008, show the phase number as it starts):
#   1 ALU:      a xorshift generator mixed with adds, shifts and compares
#   2 Memory:   fill a 256-byte buffer, copy it word by word and byte by byte,
#               and sum the copy
#   3 Branches: insertion sort of 24 words
#   4 Calls:    recursive Fibonacci of 12 (calls, returns, the stack)
#   5 Mul/Div:  multiplies, divides and remainders, and Euclid's GCD
# At the end it stores 0xA5 to the LEDs (the profiler stops there), leaves a
# checksum of every phase in a0 and its parts in s1..s5, and runs into a
# zero word, where core 0 stops fetching.

    .equ IO_BASE,  0x10000000
    .equ IO_LEDS,  8
    .equ DONE,     0xA5

    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top
    li      s0, IO_BASE

    # ---- Phase 1: ALU -------------------------------------------------------
    li      t0, 1
    sw      t0, IO_LEDS(s0)
    li      t1, 0x12345678          # xorshift state
    li      t2, 300                 # iterations
    li      s1, 0
1:
    slli    t3, t1, 13
    xor     t1, t1, t3
    srli    t3, t1, 17
    xor     t1, t1, t3
    slli    t3, t1, 5
    xor     t1, t1, t3
    add     s1, s1, t1
    sltu    t4, s1, t1              # carry out of the add
    add     s1, s1, t4
    andi    t3, t1, 0xFF
    srai    t5, t1, 3
    or      t3, t3, t5
    sub     s1, s1, t3
    addi    t2, t2, -1
    bnez    t2, 1b

    # ---- Phase 2: Memory ----------------------------------------------------
    li      t0, 2
    sw      t0, IO_LEDS(s0)
    la      a1, buf_a
    la      a2, buf_b
    li      t2, 64                  # 64 words
    li      t1, 0x01020304
    mv      t3, a1
1:
    sw      t1, 0(t3)
    addi    t1, t1, 0x111
    addi    t3, t3, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    # word copy a -> b
    li      t2, 64
    mv      t3, a1
    mv      t4, a2
1:
    lw      t5, 0(t3)
    sw      t5, 0(t4)
    addi    t3, t3, 4
    addi    t4, t4, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    # byte copy b -> a, reversed
    li      t2, 256
    mv      t3, a2
    addi    t4, a1, 255
1:
    lbu     t5, 0(t3)
    sb      t5, 0(t4)
    addi    t3, t3, 1
    addi    t4, t4, -1
    addi    t2, t2, -1
    bnez    t2, 1b
    # sum a as halfwords
    li      t2, 128
    mv      t3, a1
    li      s2, 0
1:
    lhu     t5, 0(t3)
    add     s2, s2, t5
    addi    t3, t3, 2
    addi    t2, t2, -1
    bnez    t2, 1b

    # ---- Phase 3: Branches (insertion sort) ---------------------------------
    li      t0, 3
    sw      t0, IO_LEDS(s0)
    la      a1, sort_data
    li      a2, 24                  # elements
    li      t0, 1                   # i
2:
    slli    t1, t0, 2
    add     t1, a1, t1
    lw      t2, 0(t1)               # key
    addi    t3, t0, -1              # j
3:
    bltz    t3, 4f
    slli    t4, t3, 2
    add     t4, a1, t4
    lw      t5, 0(t4)
    ble     t5, t2, 4f
    sw      t5, 4(t4)
    addi    t3, t3, -1
    j       3b
4:
    addi    t4, t3, 1
    slli    t4, t4, 2
    add     t4, a1, t4
    sw      t2, 0(t4)
    addi    t0, t0, 1
    blt     t0, a2, 2b
    # checksum: sum of element * index
    li      s3, 0
    li      t0, 0
    mv      t1, a1
5:
    lw      t2, 0(t1)
    mul     t2, t2, t0
    add     s3, s3, t2
    addi    t1, t1, 4
    addi    t0, t0, 1
    blt     t0, a2, 5b

    # ---- Phase 4: Calls -----------------------------------------------------
    li      t0, 4
    sw      t0, IO_LEDS(s0)
    li      a0, 12
    call    fib
    mv      s4, a0

    # ---- Phase 5: Mul/Div ---------------------------------------------------
    li      t0, 5
    sw      t0, IO_LEDS(s0)
    li      s5, 0
    li      t1, 1000003             # a
    li      t2, 40                  # iterations
1:
    li      t3, 7919
    mul     t4, t1, t3
    mulhu   t5, t1, t3
    add     s5, s5, t4
    xor     s5, s5, t5
    divu    t4, t4, t2
    remu    t5, t1, t2
    add     s5, s5, t4
    add     s5, s5, t5
    li      t6, -12345
    div     t4, t6, t2
    rem     t5, t6, t2
    sub     s5, s5, t4
    add     s5, s5, t5
    addi    t1, t1, 977
    addi    t2, t2, -1
    bnez    t2, 1b
    # GCD of pairs (Euclid, with remu)
    la      a1, gcd_pairs
    li      a2, 8
2:
    lw      t1, 0(a1)
    lw      t2, 4(a1)
3:
    beqz    t2, 4f
    remu    t3, t1, t2
    mv      t1, t2
    mv      t2, t3
    j       3b
4:
    add     s5, s5, t1
    addi    a1, a1, 8
    addi    a2, a2, -1
    bnez    a2, 2b

    # ---- Done ---------------------------------------------------------------
    add     a0, s1, s2
    add     a0, a0, s3
    add     a0, a0, s4
    add     a0, a0, s5
    li      t0, DONE
    sw      t0, IO_LEDS(s0)
    .word   0                       # core 0 stops fetching here

# Recursive Fibonacci: a0 = fib(a0)
fib:
    li      t0, 2
    blt     a0, t0, 1f
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s6, 8(sp)
    mv      s6, a0
    addi    a0, a0, -1
    call    fib
    mv      t1, a0
    addi    a0, s6, -2
    sw      t1, 4(sp)
    call    fib
    lw      t1, 4(sp)
    add     a0, a0, t1
    lw      s6, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
1:
    ret

    .section .data
    .balign 4
sort_data:
    .word   57, -3, 912, 14, 0, 77, -400, 23, 5, 5, 1000, -1
    .word   333, 2, 61, -88, 19, 740, 12, -7, 450, 3, 99, 28
gcd_pairs:
    .word   1071, 462,  270, 192,  1000000, 2048,  17, 5
    .word   123456, 7890,  99991, 1,  360, 84,  0x7FFFFFFF, 0x3FFF
    .section .bss
    .balign 4
buf_a:
    .space  256
buf_b:
    .space  256
