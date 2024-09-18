/* start.asm 中的入口点 */
ENTRY(_start)

SECTIONS
{
    /*
     * We'll be loading the kernel ELF file at 0x00300000. We'd like to
     * set up our page tables so that the virtual and physical addresses of
     * the kernel code are the same ("identity-mapping").  To do this,
     * we need to ensure the code section lines up with its address in
     * memory once loaded.  The code section begins at offset 0x1000, so
     * we make sure the start address is 0x00301000.
     *
     * Note that ld must be passed a command-line argument of
     * -z max-page-size=0x1000.  Otherwise the kernel file will be too large.
     */

    KERNEL_VMA = 0x00301000;

    . = KERNEL_VMA;

    /*************************************************************************
     * .text
     *
     * 代码和只读数据段
     ************************************************************************/
    .text : ALIGN(4K)
    {
        *(.start)       /* 在 start.asm 中定义，必须放在最前面！ */
        *(.text)
        *(.rodata*)
    }

    /*************************************************************************
     * .data
     *
     * 已初始化的可读写数据段
     ************************************************************************/
    .data : ALIGN(4K)
    {
        *(.data)
    }

    /*************************************************************************
     * .bss
     *
     * 未初始化的可读写数据段
     ************************************************************************/
    .bss : ALIGN(4K)
    {
        _BSS_START = ABSOLUTE(.);
        *(.bss)
        *(COMMON)
    }
    _BSS_SIZE = ABSOLUTE(.) - _BSS_START;
}
