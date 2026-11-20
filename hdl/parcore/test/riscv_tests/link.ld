OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  /* Core 0 (IF) fetches guest instructions starting at 0x00000500 */
  . = 0x00000500;
  .text : {
    *(.text.init)
    *(.text)
    *(.text.*)
    *(.rodata)
    *(.rodata.*)
    . = ALIGN(4);
    LONG(0x00000000);
  }

  /* One guest memory, as RISC-V expects: .data follows .text, and the whole
     image (.text and .data) is loaded at 0x500 into both core 0 (which
     fetches from it) and core 3 (which loads and stores). Core 3 mirrors
     stores in 0x500-0x1FFF to core 0, for FENCE.I. */
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

  /* Core 0 and core 3 have 8 KiB TCMs */
  ASSERT(. <= 0x2000, "guest image does not fit below 0x2000")

  /DISCARD/ : {
    *(.comment)
    *(.riscv.attributes)
  }
}
