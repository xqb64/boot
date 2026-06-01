.set CODE32, 0x08
.set DATA,   0x10
.set CODE64, 0x18

.set KERNEL_LBA,      33
.set KERNEL_SECTORS,  128
.set KERNEL_TMP_SEG,  0x1000
.set KERNEL_TMP_ADDR, 0x10000
.set KERNEL_ADDR,     0x100000
.set KERNEL_BYTES,    KERNEL_SECTORS * 512

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

    # Establish a new stack.
    movw $0x7c00, %sp

    # Stage1 passes the BIOS boot drive in DL.
    movb %dl, boot_drive

    # Read kernel.bin from disk into temporary low memory.
    # BIOS calls are only available before protected/long mode.
    call load_kernel

    # Enable A20 using port 0x92 (System Control Port A ("Fast A20 port")).
    inb $0x92, %al
    orb $0x02, %al
    outb %al, $0x92

    # Load the GDT (Global Descriptor Table).
    #
    # Before entering the protected mode, the CPU must know where the GDT is,
    # because once we enable the protected mode, the segment registers stop
    # behaving like they did in real mode, and start holding selectors instead.
    lgdt gdt_desc

    # Enter protected mode: set CR0.PE (Control Register 0, Protection Enable bit).
    movl %cr0, %eax
    orl $0x1, %eax
    movl %eax, %cr0

    # Far jump reloads CS with a 32-bit protected-mode code selector.
    #
    # NOTE: A normal jump only changes the instruction pointer.
    #       A far jump changes both the code segment register and the ip.
    ljmp $CODE32, $protected_mode_entry

# Prepare to load the kernel:
#  - we need to read KERNEL_SECTORS sectors
#  - put them temporarily at KERNEL_TMP_SEG:0000
#  - start reading from disk LBA KERNEL_LBA
#  - make sure the 64-bit LBA value is clean
# 
# NOTE: DAP = Disk Address Packet
load_kernel:
    movw $KERNEL_SECTORS, sectors_left
    movw $KERNEL_TMP_SEG, dap_segment
    movl $KERNEL_LBA, dap_lba
    movl $0, dap_lba + 4
.read_loop:
    cmpw $0, sectors_left      # are there 0 sectors left to read?
    je .done                   # if yes, kernel loading is finished

    movb $0x42, %ah            # BIOS int 13h function 42h = extended LBA read
    movb boot_drive, %dl       # use the disk we booted from
    movw $dap, %si             # DS:SI points to the Disk Address Packet
    int $0x13                  # ask BIOS to read from disk
    jc disk_error              # if carry flag set, BIOS reported failure

    addw $0x20, dap_segment    # move destination forward by 512 bytes
    addl $1, dap_lba           # next disk sector
    decw sectors_left          # one fewer sector left to read
    jmp .read_loop             # repeat

.done:
    ret

disk_error:
    movw $0xb800, %ax
    movw %ax, %es
    movb $'D', %es:0
    movb $0x4f, %es:1
.hang:
    hlt
    jmp .hang

.code32

protected_mode_entry:
    # Load protected-mode data segments.
    #
    # Since SS contained 0x0, in protected mode, this becomes the null selector,
    # which is invalid to have, so we reload %ss.
    #
    # Likewise for %ds, which is needed for ordinary memory operations.
    #
    # Likewise for %es, which uses ES:EDI for `rep stosl`.
    movw $DATA, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    # Establish a new stack.
    #
    # This location is good because it's below 1MB, and it's far away from boot code
    # and other important data structures residing in memory at this point.
    movl $0x90000, %esp

    # Copy kernel from temporary low memory to 1 MiB.

    # Clear the direction flag.
    cld
    movl $KERNEL_TMP_ADDR, %esi
    movl $KERNEL_ADDR, %edi
    movl $(KERNEL_BYTES >> 2), %ecx
    rep movsl

    # Identity map the first 1GiB using 2MiB huge pages, because this is the
    # simplest useful identity map for entering the long mode.  Later on, the
    # kernel will stop relying on this map.
    #
    # We use:
    #   PML4 at 0x1000
    #   PDPT at 0x2000
    #   PD   at 0x3000

    # Clear 3 pages: 0x1000..0x3fff.
    #
    #  *((uint32_t *)EDI) = EAX
    #
    #  if (direction_flag == 0) {
    #    EDI += 4;
    #  } else {
    #    EDI -= 4;
    #  }
    movl $0x1000, %edi
    xorl %eax, %eax
    # 4096       = page size in bytes
    # 4096*3     = size of 3 pages in bytes
    # (4096*3)/4 = number of 32-bit words in three page
    movl $(4096 * 3 >> 2), %ecx
    
    # Clear the direction flag.
    cld

    # Store String Long (32-bit)
    rep stosl

    # PML4[0] = PDPT | present | writable
    #
    # NOTE: x86 is little-endian, which means that the least-significant
    # byte lives at the lowest memory address.
    #
    # We are first writing the low 32 bits.
    movl $(0x2000 | 0x003), 0x1000
    # ...then the high 32-bits.
    movl $0, 0x1004

    # PDPT[0] = PD | present | writable
    movl $(0x3000 | 0x003), 0x2000
    movl $0, 0x2004

    # Fill PD with 512 huge-page entries.
    # Each maps 2 MiB, so 512 * 2 MiB = 1 GiB.
    #
    # Flags:
    #   bit 0 = present
    #   bit 1 = writable
    #   bit 7 = PS, page size, meaning 2 MiB page
    #
    # 0x83 = present | writable | page-size
    movl $0x3000, %edi
    movl $0x00000083, %eax
    movl $512, %ecx

map_pd:
    # Write the low 32 bits of the current page-directory entry to memory at %edi.
    movl %eax, (%edi)
    # Write the high 32 bits of the 64-bit PD entry.
    movl $0, 4(%edi)
    # Add 2MiB to the physical base address.
    addl $0x200000, %eax
    # Move %edi to the next page directory entry.  Since each entry is 8 bytes,
    # we need to add 8.
    addl $8, %edi
    # %ecx = %ecx - 1
    # if (%ecx != 0) jmp map_pd;
    loop map_pd

    # Enable long mode.
    #
    # Required order:
    #   1. enable PAE in CR4
    #   2. load CR3 with PML4 physical address
    #   3. set EFER.LME
    #   4. enable paging in CR0
    #   5. far jump to a 64-bit code segment

    # CR4.PAE = 1
    movl %cr4, %eax
    orl $(1 << 5), %eax
    movl %eax, %cr4

    # CR3 = physical address of PML4
    movl $0x1000, %eax
    movl %eax, %cr3

    # Set EFER.LME, bit 8.
    # EFER MSR is 0xC0000080.
    movl $0xC0000080, %ecx
    rdmsr
    orl $(1 << 8), %eax
    wrmsr

    # Enable paging: CR0.PG = 1.
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0

    ljmp $CODE64, $long_mode_entry

.code64

long_mode_entry:
    # Reload data segments. Mostly ignored in 64-bit mode,
    # but SS should still contain a valid data selector.
    movw $DATA, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    # Establish a new stack.
    movq $0x90000, %rsp

    # kernel.bin is a flat binary linked to start at 0x100000.
    movabsq $KERNEL_ADDR, %rax
    call *%rax

# .quad emits 8 bytes.  So with .align 8, the gdt label starts at a clean 8-byte
# boundary.
# Strictly speaking, the CPU can load a GDT that is not 8-byte aligned.  But
# alignment is the natural layout, avoids surprises, and makes each descriptor
# sit at an address divisble by 8.
.align 8
gdt:
    .quad 0x0000000000000000
    .quad 0x00cf9a000000ffff
    .quad 0x00cf92000000ffff
    .quad 0x00af9a000000ffff
gdt_end:

gdt_desc:
    .word gdt_end - gdt - 1
    .long gdt

boot_drive:
    .byte 0
sectors_left:
    .word 0

# Disk Address Packet for INT 13h AH=42h.
.align 4
dap:
    .byte 0x10       # packet size
    .byte 0x00       # reserved
    .word 1          # sectors to read per call
    .word 0x0000     # destination offset
dap_segment:
    .word KERNEL_TMP_SEG
dap_lba:
    .quad KERNEL_LBA


