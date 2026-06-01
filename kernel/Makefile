stage2.elf: boot.o
	$(LD) -T stage2.ld -o $@ boot.o

kernel.elf: kernel.o
	$(LD) -T kernel.ld -o $@ kernel.o

stage2.bin: stage2.elf
	$(OBJCOPY) -O binary $< $@

kernel.bin: kernel.elf
	$(OBJCOPY) -O binary $< $@

os.img: stage1.bin stage2.bin kernel.bin
	cat stage1.bin stage2.bin kernel.bin > os.img
