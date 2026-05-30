TOOLPREFIX ?= x86_64-elf-

CC      := $(TOOLPREFIX)gcc
LD      := $(TOOLPREFIX)ld
OBJCOPY := $(TOOLPREFIX)objcopy
QEMU    := qemu-system-x86_64

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

LDFLAGS := \
	-m elf_x86_64 \
	-T linker.ld \
	-nostdlib

OBJS := boot.o kernel.o

.PHONY: all run clean

all: os.img

boot.o: boot.s
	$(CC) $(ASFLAGS) -c $< -o $@

kernel.o: kernel.c
	$(CC) $(CFLAGS) -c $< -o $@

kernel.elf: linker.ld $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

os.img: kernel.elf
	$(OBJCOPY) -O binary $< $@
	@test $$(stat -c%s $@) -eq 512 || \
		(echo "error: os.img must be exactly 512 bytes for this boot-sector version"; exit 1)

run: os.img
	$(QEMU) -drive format=raw,file=os.img -no-reboot -no-shutdown

clean:
	rm -f *.o kernel.elf os.img
