/* ===========================================================================
 *  hello.c — the same CPU, now programmed in C instead of hand-written asm
 * ---------------------------------------------------------------------------
 *  Proof that the core is a real compiler target: this is ordinary C, compiled
 *  by riscv GCC, linked with crt0.s + link.ld, and run on the datapath. It
 *  talks to the memory-mapped devices through volatile pointers — exactly how
 *  firmware drives hardware registers on a real microcontroller.
 *
 *  Build:  make cprog            (needs the riscv-none/elf GCC toolchain)
 *  Run:    make cprog-run
 * =========================================================================== */

#include <stdint.h>

/* the memory-mapped devices decoded in dmem.v */
#define UART   ((volatile uint32_t *)0x10000000u)
#define CYCLES ((volatile uint32_t *)0x10000004u)
#define HALT   ((volatile uint32_t *)0x10000008u)

static void putc(char c)      { *UART = (uint32_t)(uint8_t)c; }
static void puts(const char *s) { while (*s) putc(*s++); }

/* print an unsigned integer in decimal, using the core's own div/rem */
static void putu(uint32_t v)
{
    char buf[10];
    int  n = 0;
    if (v == 0) { putc('0'); return; }
    while (v) { buf[n++] = '0' + (v % 10u); v /= 10u; }
    while (n) putc(buf[--n]);
}

/* a tiny recursive function, so the call/return path (jal/jalr + stack) runs */
static uint32_t fib(uint32_t n)
{
    return (n < 2) ? n : fib(n - 1) + fib(n - 2);
}

int main(void)
{
    puts("Hello from C on my RISC-V CPU!\n");

    puts("fib(15) = ");
    putu(fib(15));
    putc('\n');

    return 0;   /* crt0 turns this into a HALT with exit code 0 */
}
