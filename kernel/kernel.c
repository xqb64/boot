#define VGA_BUFFER_SIZE (80 * 25 * 2)

unsigned char *VGA = (unsigned char *) 0xB8000;

static void clear_vga(void)
{
  for (int i = 0; i < VGA_BUFFER_SIZE; i++) {
    VGA[i] = 0;
  }
}

static int strlen(char *s)
{
  int len;

  len = 0;

  while (*s++ != '\0') {
    len++;
  }

  return len;
}

void kprintf(char *s)
{
  for (int i = 0; i < strlen(s); i++) {
    VGA[2 * i] = s[i];
    VGA[(2 * i) + 1] = 0x0F;
  }
}

__attribute__((noreturn)) void kmain(void)
{
  clear_vga();
  kprintf("Hello, world!");
  for (;;) {
    asm volatile("hlt");
  }
}

__attribute__((noreturn, section(".text.entry"))) void _start(void)
{
  kmain();
}
