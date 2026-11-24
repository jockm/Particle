/* =============================================================================
   File: apps/riscv/link.ld
   Description: Layout of a Parcore guest program (RV32), as the official
                tests use: one guest memory from 0x500, loaded into core 0
                (which fetches from it) and core 3 (which loads and stores).
   ============================================================================= */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x00000500;
  .text : {
    *(.text.init)
    *(.text)
    *(.text.*)
    *(.rodata)
    *(.rodata.*)
    . = ALIGN(4);
    LONG(0x00000000);       /* a zero word: core 0 stops fetching there */
  }

  .data ALIGN(16) : {
    *(.data)
    *(.data.*)
    *(.sdata)
    *(.sdata.*)
    . = ALIGN(4);
  }

  .bss (NOLOAD) : {
    *(.bss)
    *(.bss.*)
    *(.sbss)
    *(.sbss.*)
    . = ALIGN(4);
  }

  /* Core 0 and core 3 have 8 KiB TCMs, and the stack starts at their top */
  ASSERT(. <= 0x1F00, "guest program too big: it must end below 0x1F00, leaving room for the stack")
  _stack_top = 0x2000;

  /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
