OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

SECTIONS
{
    . = 0x7c00;
    __boot_start = .;

    .text : {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    /*
     * BIOS requires the boot signature at byte offsets 510..511
     * relative to the start of the boot sector.
     *
     * Since the boot sector is loaded at 0x7c00:
     *   0x7c00 + 510 = 0x7dfe
     */
    . = 0x7dfe;

    .boot_signature : {
        SHORT(0xaa55)
    }

    __boot_end = .;

    ASSERT(__boot_end <= 0x7e00, "boot image exceeds 512 bytes")

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note*)
        *(.comment*)
    }
}
