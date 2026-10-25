/* BeeModel - the layout of build/beemodel.exe (ld -m i386pep -T), after
   ld's own PE script: the same ELF objects as the Linux binary, so .rodata
   goes with .rdata, and the operator and .blend tables get the
   __start_ / __stop_ symbols that ELF ld makes by itself. */
SECTIONS
{
  . = SIZEOF_HEADERS;
  . = ALIGN(__section_alignment__);
  .text __image_base__ + (__section_alignment__ < 0x1000 ? . : __section_alignment__) :
  {
    *(.text) *(.text.*)
  }
  .rdata BLOCK(__section_alignment__) :
  {
    *(.rodata) *(.rodata.*) *(.rdata) *(SORT(.rdata$*))
    . = ALIGN(8);
    __start_bee_ops = .;
    KEEP (*(bee_ops))
    __stop_bee_ops = .;
    . = ALIGN(8);
    __start_blend_f = .;
    KEEP (*(blend_f))
    __stop_blend_f = .;
  }
  .data BLOCK(__section_alignment__) :
  {
    *(.data) *(.data.*)
  }
  .bss BLOCK(__section_alignment__) :
  {
    *(.bss) *(.bss.*) *(COMMON)
  }
  .idata BLOCK(__section_alignment__) :
  {
    KEEP (SORT(*)(.idata$2))
    KEEP (SORT(*)(.idata$3))
    LONG (0); LONG (0); LONG (0); LONG (0); LONG (0);
    . = ALIGN(8);
    KEEP (SORT(*)(.idata$4))
    __IAT_start__ = .;
    KEEP (SORT(*)(.idata$5))
    __IAT_end__ = .;
    KEEP (SORT(*)(.idata$6))
    KEEP (SORT(*)(.idata$7))
  }
  /* DWARF (scripts/build.sh debug), kept out of the loaded image as ld's
     own PE script does */
  .debug_aranges BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_aranges) }
  .debug_info BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_info) }
  .debug_abbrev BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_abbrev) }
  .debug_line BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_line) }
  .debug_str BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_str) }
  .debug_line_str BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_line_str) }
  .debug_rnglists BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_rnglists) }
  .debug_frame BLOCK(__section_alignment__) (NOLOAD) : { *(.debug_frame) }
  /DISCARD/ :
  {
    *(.note.*) *(.comment) *(.eh_frame)
  }
}
