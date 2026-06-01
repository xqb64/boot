# After reset, an AMD64 CPU starts off in real-mode.
#
# In real mode, the processor uses 20-bit physical addresses, which are formed by
# shifting the 16-bit values in the segment registers (%cs, %ds, %ss, %fs, %gs, %es)# left by 4 and adding the 16-bit effective address as an offset, so:
#
#  phys addr = (segment << 4) + offset
#
# For example, if segment is `0xb800`, and offset is `0x0`, then the segment shifted# left by 4 (one hex digit, which appends zero) is:
#
#  0xb8000 + 0x00 = 0xb8000
#
# This means that without an A20 (Address Line 20), the CPU can only address 2^20
# (1MB) worth of space.
#
# We won't spend much time in real mode.
#
# This is the Stage 1 of the three-part boot chain: the BIOS loads the first disk
# sector, `stage1.bin`, into memory at `0x7c00`.  The `stage1` is tiny and its only
# job is to load `stage2.bin` from disk into memory at `0x8000` and jump to it.
# `stage2` is the real loader here.  It loads the separate `kernel.bin` from disk
# into memory at `0x100000`, switched the CPU from real through protected to long
# mode which the kernel expects, and then jumps to the kernel entry point.
# 
# From that moment on, the boot code is finished and the kernel takes over the
# control and owns the machine.

.set STAGE2_ADDR,    0x8000
.set STAGE2_SECTORS, 32

.section .text
.code16
.global _start

_start:
    # Disable interrupts.
    cli

    # Zero out the segment registers.
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    # We have a stack at 0x7c00 growing downward.
    # The reason 0x7c00 is commonly chosen is that the BIOS loads the boot sector at
    # physical address 0x7c00. So if we put the stack pointer at 0x7c00, the stack
    # grows downward, away from our boot code.
    movw $0x7c00, %sp

    # BIOS passes the boot drive number in DL. Preserve it.
    movb %dl, boot_drive

    # BIOS disk read, CHS mode:
    # AH = 0x02 read sectors
    # AL = number of sectors
    # CH = cylinder 0
    # CL = sector 2, because sector 1 is this boot sector
    # DH = head 0
    # DL = boot drive
    # ES:BX = destination 0000:8000
    movw $STAGE2_ADDR, %bx
    movb $0x02, %ah
    movb $STAGE2_SECTORS, %al
    movb $0x00, %ch
    movb $0x02, %cl
    movb $0x00, %dh
    movb boot_drive, %dl

    # Call BIOS disk service.
    # It reports the status of the operation via the carry flag, meaning the carry
    # flag will be clear on success, and set on error.
    int $0x13

    # If carry is set, handle the error.
    jc disk_error

    ljmp $0x0000, $STAGE2_ADDR

disk_error:
    movw $0xb800, %ax
    movw %ax, %es
    movb $'E', %es:0
    movb $0x4f, %es:1
hang:
    hlt
    jmp hang

boot_drive:
    .byte 0

# Pad out the rest of the sector with zeros.
.fill 510 - (. - _start), 1, 0

# Write the boot signature.
.word 0xaa55

