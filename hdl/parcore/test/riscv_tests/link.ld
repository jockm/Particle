OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  /* Core 0 (IF) fetches guest instructions starting at 0x00000500 */
  . = 0x00000500;
  .text : AT(0x00000500) {
    *(.text.init)
    *(.text)
    *(.text.*)
    *(.rodata)
    *(.rodata.*)
    . = ALIGN(4);
    LONG(0x00000000);
  }

  /* Core 3 (MEM) accesses guest data in Core 3 TCM starting at VMA 0x00000800.
     Distinct LMA (0x00010000) prevents ELF overlap with .text in Core 0 TCM. */
  .data 0x00000800 : AT(0x00010000) {
    *(.data)
    *(.data.*)
    *(.sdata)
    *(.sdata.*)
    . = ALIGN(4);
  }

  .bss : AT(0x00018000) {
    *(.bss)
    *(.bss.*)
    *(.sbss)
    *(.sbss.*)
    . = ALIGN(4);
  }

  /DISCARD/ : {
    *(.comment)
    *(.riscv.attributes)
  }
}
