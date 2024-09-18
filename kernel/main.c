//============================================================================
/// @file       main.c
/// @brief      The kernel's main entry point.
/// @details    This file contains the function kmain(), which is the first
///             function called by the kernel's start code in start.asm.
//============================================================================

#include <kernel/device/keyboard.h>
#include <kernel/device/pci.h>
#include <kernel/device/timer.h>
#include <kernel/device/tty.h>
#include <kernel/interrupt/exception.h>
#include <kernel/interrupt/interrupt.h>
#include <kernel/mem/acpi.h>
#include <kernel/mem/paging.h>
#include <kernel/mem/pmap.h>
#include <kernel/syscall/syscall.h>
#include <kernel/x86/cpu.h>
#include <kernel/spinlock.h>
#include "shell.h"

#if defined(__linux__)
#error "This code must be compiled with a cross-compiler."
#endif

#define TTY_CONSOLE 0

static spin_lock_t test_lock = { 0 };

void cpu_init(void)
{
    int i, j;
    unsigned int CpuFacName[4] = {0, 0, 0, 0};
    char FactoryName[17] = {0};

    // vendor_string
    get_cpuid(0, 0, &CpuFacName[0], &CpuFacName[1], &CpuFacName[2], &CpuFacName[3]);

    *(unsigned int *)&FactoryName[0] = CpuFacName[1];
    *(unsigned int *)&FactoryName[4] = CpuFacName[3];
    *(unsigned int *)&FactoryName[8] = CpuFacName[2];

    FactoryName[12] = '\0';
    tty_printf(TTY_CONSOLE, "\033[e]%s\033[-]\t%#010x\t%#010x\t%#010x\n", FactoryName, CpuFacName[1], CpuFacName[3], CpuFacName[2]);

    // brand_string
    for (i = 0x80000002; i < 0x80000005; i++)
    {
        get_cpuid(i, 0, &CpuFacName[0], &CpuFacName[1], &CpuFacName[2], &CpuFacName[3]);
        *(unsigned int *)&FactoryName[0] = CpuFacName[0];
        *(unsigned int *)&FactoryName[4] = CpuFacName[1];
        *(unsigned int *)&FactoryName[8] = CpuFacName[2];
        *(unsigned int *)&FactoryName[12] = CpuFacName[3];

        FactoryName[16] = '\0';
        tty_printf(TTY_CONSOLE, "%s\n", FactoryName);
    }

    // version information type, family, model, and stepping id
    get_cpuid(1, 0, &CpuFacName[0], &CpuFacName[1], &CpuFacName[2], &CpuFacName[3]);
    tty_printf(TTY_CONSOLE, "Family Code:%#010x\n", (CpuFacName[0] >> 8 & 0xF));
    tty_printf(TTY_CONSOLE, "Extended Family:%#010x\n", (CpuFacName[0] >> 20 & 0xFF));
    tty_printf(TTY_CONSOLE, "Model Number:%#010x\n", (CpuFacName[0] >> 4 & 0xF));
    tty_printf(TTY_CONSOLE, "Extended Model:%#010x\n", (CpuFacName[0] >> 16 & 0xF));
    tty_printf(TTY_CONSOLE, "Processor Type:%#010x\n", (CpuFacName[0] >> 12 & 0x3));
    tty_printf(TTY_CONSOLE, "Stepping ID:%#010x\n", (CpuFacName[0] & 0xF));

    // get linear/physical address size
    get_cpuid(0x80000008, 0, &CpuFacName[0], &CpuFacName[1], &CpuFacName[2], &CpuFacName[3]);
    tty_printf(TTY_CONSOLE, "Physical Address size:%#08d\n", (CpuFacName[0] & 0xFF));
    tty_printf(TTY_CONSOLE, "Linear Address size:%#08d\n", (CpuFacName[0] >> 8 & 0xFF));

    // max cpuid operation code
    get_cpuid(0, 0, &CpuFacName[0], &CpuFacName[1], &CpuFacName[2], &CpuFacName[3]);
    tty_printf(TTY_CONSOLE, "MAX Basic Operation Code:%#010x\n", (CpuFacName[0]));

    get_cpuid(0x80000000, 0, &CpuFacName[0], &CpuFacName[1], &CpuFacName[2], &CpuFacName[3]);
    tty_printf(TTY_CONSOLE, "MAX Extended Operation Code:%#010x\n", (CpuFacName[0]));
}

void kmain()
{
    // Memory initialization
    acpi_init();
    pmap_init();
    page_init();

    // Interrupt initialization
    interrupts_init();
    exceptions_init();

    // Device initialization
    tty_init();
    kb_init();
    timer_init(20); // 20Hz

    // System call initialization
    syscall_init();

    // Let the games begin
    enable_interrupts();

    // Display a welcome message on the virtual console.
    tty_set_textcolor(TTY_CONSOLE, TEXTCOLOR_LTGRAY, TEXTCOLOR_BLACK);
    tty_clear(TTY_CONSOLE);
    tty_print(TTY_CONSOLE, "Welcome to \033[e]ZYOS\033[-] (v0.1).\n");
    tty_print(TTY_CONSOLE, "Hello World.\n");

    spin_lock(test_lock);
    tty_print(TTY_CONSOLE, "page region\n");
    tty_printf(TTY_CONSOLE, "cr3: %#016X\n", read_cr3());
    const pmap_t *map = pmap();
    for (int i = 0; i < 3; i++) {
        tty_printf(TTY_CONSOLE, "Region %d Type: %d\n", (i), (map->region[i].type));
        tty_printf(TTY_CONSOLE, "Region %d Base Address: %#016X\n", (i), (map->region[i].addr));
        tty_printf(TTY_CONSOLE, "Region %d Size: %#016X\n", (i), (map->region[i].size));
    }
    spin_unlock(test_lock);

    cpu_init();
    // Launch the interactive test shell.
    kshell();
}
