/* ===========================================================================
 *  link.ld — linker script for compiling C to this core's split memories
 * ---------------------------------------------------------------------------
 *  The cores are Harvard-style: instructions live in imem and data in dmem,
 *  each a separate memory addressed from 0. So we define two regions and place
 *  code in IMEM (VMA 0) and everything the program reads/writes — rodata,
 *  data, bss, stack — in DMEM (VMA 0). The build converts each region to its
 *  own hex image (see sw/README.md).
 *
 *  Because it's Harvard, a code address and a data address can both be "0x10"
 *  without conflict: the PC only ever indexes imem, and load/store addresses
 *  only ever index dmem. Keep programs within IMEM_SIZE / DMEM_SIZE (the BRAM
 *  the cores instantiate — 256 words each by default).
 * =========================================================================== */

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 1K   /* 256 instruction words */
    DMEM (rw)  : ORIGIN = 0x00000000, LENGTH = 1K   /* 256 data words        */
}

ENTRY(_start)

SECTIONS
{
    /* ---- instructions -> imem ---- */
    .text : {
        *(.text._start)     /* crt0 first, so execution starts at address 0 */
        *(.text*)
    } > IMEM

    /* ---- read-only + read-write data -> dmem ---- */
    .rodata : { *(.rodata*) } > DMEM
    .data   : { *(.data*)   } > DMEM
    .bss    : {
        _bss_start = .;
        *(.bss*) *(COMMON)
        _bss_end = .;
    } > DMEM

    /* stack grows down from the top of dmem */
    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
}
