# After reset, an AMD64 CPU starts off in real-mode.
# 
# In real mode, the processor uses 20-bit physical addresses, which are formed by
# shifting the 16-bit values in the segment registers (%cs, %ds, %ss, %fs, %gs, %es)# left by 4 and adding the 16-bit effective address as an offset, so:
#
#  phys addr = (segment << 4) + offset
# 
# For exmaple, if segment is `0xb800`, and offset is `0x0`, then the segment shifted# left by 4 (one hex digit, which appends zero) is:
# 
#  0xb8000 + 0x00 = 0xb8000
#
# This means that without an A20 (Address Line 20), the CPU can only address 2^20 
# (1MB) worth of space.
#
# We won't spend much time in real mode.
#
# We will zero out the segment registers, establish a stack which grows away from
# our boot code, enable A20, load the GDT (Global Descriptor Table), set CR0.PE,
# and then long-jump to protected_mode_entry.
#
# Once in protected mode, we will once again load the data segments, establish a new
# stack, and set up paging through a quick identity-mapping for the first 1GiB,
# and then finally proceed to long mode.

.extern kernel_main

.set CODE32, 0x08
.set DATA,   0x10
.set CODE64, 0x18

.section .text
.code16
.global _start

_start:
    # Disable interrupts.
    cli

    # Set segments to zero.
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    # We have a stack at 0x7c00 growing downward.
    # The reason 0x7c00 is commonly chosen is that the BIOS loads the boot sector at
    # physical address 0x7c00. So if we put the stack pointer at 0x7c00, the stack grows
    # downward, away from our boot code.
    movw $0x7c00, %sp

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
    xorl %eax, %eax  # 0 -> %eax
    # 4096       = page size in bytes
    # 4096*3     = size of 3 pages in bytes
    # (4096*3)/4 = number of 32-bit words in three pages
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

    # Now jump into 64-bit code.
    ljmp $CODE64, $long_mode_entry

.code64

long_mode_entry:
    # Reload data segments. Mostly ignored in 64-bit mode,
    # but SS should still contain a valid data selector.
    movw $DATA, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    call kernel_main

hang:
    hlt
    jmp hang

# .quad emits 8 bytes. So with .align 8, the gdt label starts at a clean 8-byte 
# boundary.
# Strictly speaking, the CPU can load a GDT that is not 8-byte aligned.  But
# alignment is the natural layout, avoids surprises, and makes each descriptor
# sit at an address divisble by 8.
.align 8

gdt:
    # Null descriptor
    .quad 0x0000000000000000

    # 32-bit code descriptor:
    # base=0, limit=4GiB, executable, readable, present
    .quad 0x00cf9a000000ffff

    # Data descriptor:
    # base=0, limit=4GiB, writable, present
    .quad 0x00cf92000000ffff

    # 64-bit code descriptor:
    # L bit set, D bit clear
    .quad 0x00af9a000000ffff

gdt_end:

# In real/protected mode, the `lgdt` operand is:
#  - 16bit limit
#  - 32bit base 
gdt_desc:
    # last valid byte offset inside the table
    # if the GDT is 32 bytes long, this means
    # the bytes are numbered 0-31, and we wnat 31
    .word gdt_end - gdt - 1
    # base address of the GDT (Global Descriptor Table)
    .long gdt 

