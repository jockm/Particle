# =============================================================================
# File: apps/riscv/hello.S
# Description: Parcore demo guest (RV32I): prints a banner on the FTDI UART,
#              echoes what you type, shows the buttons on the LEDs (with a
#              heartbeat on LED 7) and names each button as it's pressed.
# Build: make parcore-guest (a RISC-V GCC toolchain is needed)
# =============================================================================
#
# Guest I/O (core 3):
#   0x1000_0000  store: send a byte; load: the received byte, or -1 if none
#   0x1000_0004  load: status, bit 0 a byte received, bit 1 room to send
#   0x1000_0008  store: the LEDs (bits 7:0)
#   0x1000_000C  load: the buttons, 1 = pressed: bit 0 FIRE1, 1 FIRE2, 2 UP,
#                3 DOWN, 4 LEFT, 5 RIGHT
# FIRE1 also makes the conductor reload the image and restart everything.
#
# The buttons are debounced: a change counts once they have read the same for
# DEBOUNCE passes of the main loop. There's no timer, so this is counted in
# passes: one pass takes about 3,800 cycles at 25 MHz (about 150 us), so 64
# passes are about 10 ms. A faster Parcore will need a larger count.

    .equ IO_BASE,      0x10000000
    .equ IO_DATA,      0
    .equ IO_STATUS,    4
    .equ IO_LEDS,      8
    .equ IO_BUTTONS,   12
    .equ HEARTBEAT,    13           # counter bit shown on LED 7
    .equ DEBOUNCE,     64           # passes the buttons must be steady

# The build stamp: when and from which commit this was built (UTC date and
# time, the git short hash, "-dirty" for uncommitted changes), so the banner
# shows which build is on the board. build_riscv_guest.sh defines it.
#ifndef BUILD_STAMP
#define BUILD_STAMP "unstamped"
#endif

    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top
    li      s0, IO_BASE
    la      a0, banner
    call    puts
    li      s1, 0                   # s1 = loop counter
    li      s2, 0                   # s2 = the buttons, debounced
    li      s7, 0                   # s7 = the buttons as last read
    li      s8, 0                   # s8 = passes they have read the same

main_loop:
    addi    s1, s1, 1

    # A received byte: send it back (and a newline after a return)
    lw      t0, IO_STATUS(s0)
    andi    t0, t0, 1
    beqz    t0, 1f
    lw      a0, IO_DATA(s0)
    call    putc
    li      t1, '\r'
    bne     a0, t1, 1f
    li      a0, '\n'
    call    putc
1:
    # Debounce: s3 = the buttons once they have read the same DEBOUNCE times
    lw      t0, IO_BUTTONS(s0)
    beq     t0, s7, 4f
    mv      s7, t0                  # changed: start counting again
    li      s8, 0
4:
    mv      s3, s2
    li      t1, DEBOUNCE
    bgeu    s8, t1, 5f              # steady for a while already
    addi    s8, s8, 1
    bne     s8, t1, 5f
    mv      s3, s7                  # steady just long enough: accept it
5:
    # The buttons on LEDs 0-5, the heartbeat on LED 7
    srli    t0, s1, HEARTBEAT
    andi    t0, t0, 1
    slli    t0, t0, 7
    or      t0, t0, s3
    sw      t0, IO_LEDS(s0)

    # Name each button that has just been pressed
    not     t0, s2
    and     s4, s3, t0              # s4 = newly pressed
    mv      s2, s3
    beqz    s4, main_loop
    la      s5, button_names        # 8 bytes per name
    li      s6, 0                   # button number
2:
    andi    t0, s4, 1
    beqz    t0, 3f
    slli    t1, s6, 3
    add     a0, s5, t1
    call    puts
3:
    srli    s4, s4, 1
    addi    s6, s6, 1
    bnez    s4, 2b
    j       main_loop

# Send the byte in a0 (core 3 waits while the UART is busy); a0 unchanged
putc:
    sw      a0, IO_DATA(s0)
    ret

# Send the zero-terminated string at a0
puts:
    mv      t2, ra
    mv      t3, a0
1:
    lbu     a0, 0(t3)
    beqz    a0, 2f
    call    putc
    addi    t3, t3, 1
    j       1b
2:
    mv      ra, t2
    ret

    .section .rodata
banner:
    .ascii  "\r\nParcore on the ULX3S: RISC-V on Particles\r\nBuild "
    .ascii  BUILD_STAMP
    .asciz  "\r\nType to echo. Buttons light LEDs 0-5; FIRE1 restarts.\r\n"
    .balign 8
button_names:
    .asciz  "FIRE1\r\n"
    .asciz  "FIRE2\r\n"
    .asciz  "UP\r\n\0\0\0"
    .asciz  "DOWN\r\n\0"
    .asciz  "LEFT\r\n\0"
    .asciz  "RIGHT\r\n"
