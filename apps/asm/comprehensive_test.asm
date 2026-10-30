; Comprehensive Test
.include "lib/common.inc"
.org 0x00000100
_reset_handler:
    START_PROGRAM
_main:
    LOAD16 R1, 0x1234
    LOAD32 R10, 0xCAFE
_loop:
    FBRA _loop
