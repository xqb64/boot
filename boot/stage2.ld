OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

SECTIONS {
    . = 0x8000;

    .text : {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note*)
        *(.comment*)
    }
}
