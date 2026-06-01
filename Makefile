TOOLPREFIX ?= x86_64-elf-

CC      := $(TOOLPREFIX)gcc
LD      := $(TOOLPREFIX)ld
OBJCOPY := $(TOOLPREFIX)objcopy
QEMU    := qemu-system-x86_64

STAGE2_SECTORS := 32
KERNEL_SECTORS := 128

STAGE2_LBA := 1
KERNEL_LBA := 33

CFLAGS := \
	-std=gnu11 \
	-ffreestanding \
	-fno-builtin \
	-fno-stack-protector \
	-fno-pic \
	-fno-pie \
	-fno-asynchronous-unwind-tables \
	-fno-unwind-tables \
	-m64 \
	-mno-red-zone \
	-Os \
	-Wall \
	-Wextra

ASFLAGS := \
	-ffreestanding \
	-fno-pic \
	-fno-pie \
	-m64

STAGE1_ASFLAGS := \
	-ffreestanding \
	-fno-pic \
	-fno-pie \
	-m32

.PHONY: all run clean

all: os.img

stage1.o: boot/stage1.s
	$(CC) $(STAGE1_ASFLAGS) -c $< -o $@

stage1.bin: stage1.o
	$(LD) -m elf_i386 -Ttext 0x7c00 --oformat binary -o $@ $<
	@test $$(stat -c%s $@) -eq 512 || \
		(echo "error: stage1.bin must be exactly 512 bytes"; exit 1)

stage2.o: boot/stage2.s
	$(CC) $(ASFLAGS) -c $< -o $@

stage2.elf: boot/stage2.ld stage2.o
	$(LD) -m elf_x86_64 -T boot/stage2.ld -nostdlib -o $@ stage2.o

stage2.bin: stage2.elf
	$(OBJCOPY) -O binary $< $@
	@test $$(stat -c%s $@) -le $$((512 * $(STAGE2_SECTORS))) || \
		(echo "error: stage2.bin is larger than $(STAGE2_SECTORS) sectors"; exit 1)

kernel.o: kernel/kernel.c
	$(CC) $(CFLAGS) -c $< -o $@

kernel.elf: kernel/kernel.ld kernel.o
	$(LD) -m elf_x86_64 -T kernel/kernel.ld -nostdlib -o $@ kernel.o

kernel.bin: kernel.elf
	$(OBJCOPY) -O binary $< $@
	@test $$(stat -c%s $@) -le $$((512 * $(KERNEL_SECTORS))) || \
		(echo "error: kernel.bin is larger than $(KERNEL_SECTORS) sectors"; exit 1)

os.img: stage1.bin stage2.bin kernel.bin
	dd if=/dev/zero of=$@ bs=512 count=$$((1 + $(STAGE2_SECTORS) + $(KERNEL_SECTORS)))
	dd if=stage1.bin of=$@ bs=512 seek=0 conv=notrunc
	dd if=stage2.bin of=$@ bs=512 seek=$(STAGE2_LBA) conv=notrunc
	dd if=kernel.bin of=$@ bs=512 seek=$(KERNEL_LBA) conv=notrunc

run: os.img
	$(QEMU) -drive format=raw,file=os.img -no-reboot -no-shutdown

clean:
	rm -f \
		*.o \
		*.elf \
		*.bin \
		os.img

format:
	clang-format kernel/*.c kernel/*.h -style=file:.clang-format -i
