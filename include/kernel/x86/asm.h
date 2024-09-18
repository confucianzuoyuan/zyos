#pragma

#include <stdint.h>

static inline uint64_t msr_read(uint64_t msr)
{
    uint32_t low, high;
    asm volatile(
        "rdmsr"
        : "=a"(low), "=d"(high)
        : "c"(msr));
    return ((uint64_t)high << 32) | low;
}

static inline void msr_write(uint64_t msr, uint64_t value)
{
    uint32_t low = value & 0xFFFFFFFF;
    uint32_t high = value >> 32;
    asm volatile(
        "wrmsr"
        :
        : "c"(msr), "a"(low), "d"(high));
}

static inline void invlpg(uint64_t addr)
{
    asm volatile(
        "invlpg (%0)"
        :
        : "b"(addr)
        : "memory");
}

static inline void outb(uint16_t port, uint8_t val)
{
    asm volatile(
        "outb %0, %1"
        :
        : "a"(val), "Nd"(port));
}

/// %0和%1是占位符，%0 ---> ret, %1 ---> port
/// a ---> eax, d ---> edx
/// N ---> maybe constant
static inline uint8_t inb(uint16_t port)
{
    uint8_t ret;
    asm volatile(
        "inb %1, %0"
        : "a"(ret)
        : "Nd"(port));
    return ret;
}

static inline void cli(void)
{
    asm volatile(
        "cli"
        :
        :
        : "cc");
}

static inline void sti(void)
{
    asm volatile(
        "sti"
        :
        :
        : "cc");
}

static inline void irq_enable(void)
{
    sti();
}

static inline void irq_disable(void)
{
    cli();
}

