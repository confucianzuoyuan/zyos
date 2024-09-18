//============================================================================
/// @file       kmem.c
/// @brief      内核物理(和虚拟)memory map.
//============================================================================

#include <core.h>
#include <libc/string.h>
#include <kernel/x86/cpu.h>
#include <kernel/interrupt/interrupt.h>
#include <kernel/mem/paging.h>
#include <kernel/mem/pmap.h>
#include "kmem.h"
#include <kernel/device/tty.h>


/// Return flags for large-page leaf entries in level 3 (PDPT) and level 2
/// (PDT) tables.
/// 为PDPT(第三层)的大页面叶子项和PDT(第二层)页表返回标志位
static uint64_t
get_pdflags(uint32_t memtype)
{
    switch (memtype)
    {
        case PMEMTYPE_ACPI_NVS:
        case PMEMTYPE_UNCACHED:
            return PF_PRESENT | PF_GLOBAL | PF_SYSTEM |
                   PF_RW | PF_PS | PF_PWT | PF_PCD;

        case PMEMTYPE_BAD:
        case PMEMTYPE_UNMAPPED:
            return 0;

        case PMEMTYPE_USABLE:
        case PMEMTYPE_RESERVED:
        case PMEMTYPE_ACPI:
            return PF_PRESENT | PF_GLOBAL | PF_SYSTEM | PF_RW | PF_PS;

        default:
            fatal();
            return 0;
    }
}

/// Return flags for entries in level 1 (PT) tables.
/// 返回PT(第一层)页表项的标志位
static uint64_t
get_ptflags(uint32_t memtype)
{
    switch (memtype)
    {
        case PMEMTYPE_ACPI_NVS:
        case PMEMTYPE_UNCACHED:
            return PF_PRESENT | PF_GLOBAL | PF_SYSTEM |
                   PF_RW | PF_PWT | PF_PCD;

        case PMEMTYPE_BAD:
        case PMEMTYPE_UNMAPPED:
            return 0;

        case PMEMTYPE_USABLE:
        case PMEMTYPE_RESERVED:
        case PMEMTYPE_ACPI:
            return PF_PRESENT | PF_GLOBAL | PF_SYSTEM | PF_RW;

        default:
            fatal();
            return 0;
    }
}

/// Allocate the next available page in the kernel page table and return
/// its virtual address.
/// 在内核页表中分配下一个可用的物理页，然后返回它的虚拟内存地址
static inline uint64_t
alloc_page(pagetable_t *pt)
{
    if (pt->vnext >= pt->vterm)
        fatal();

    uint64_t vaddr = pt->vnext;
    pt->vnext += PAGE_SIZE;
    return vaddr | PF_SYSTEM | PF_PRESENT | PF_RW;
}

/// Create a 1GiB page entry in the kernel page table.
/// 在内核页表中创建一个1GB的页表项
static void
create_huge_page(pagetable_t *pt, uint64_t addr, uint32_t memtype)
{
    uint64_t pml4te = PML4E(addr);
    uint64_t pdpte  = PDPTE(addr);

    page_t *pml4t = (page_t *)pt->proot;
    if (pml4t->entry[pml4te] == 0)
        pml4t->entry[pml4te] = alloc_page(pt);

    page_t *pdpt = PGPTR(pml4t->entry[pml4te]);
    pdpt->entry[pdpte] = addr | get_pdflags(memtype);
}

/// Create a 2MiB page entry in the kernel page table.
/// 在内核页表中创建一个2MB的页表项
static void
create_large_page(pagetable_t *pt, uint64_t addr, uint32_t memtype)
{
    uint64_t pml4te = PML4E(addr);
    uint64_t pdpte  = PDPTE(addr);
    uint64_t pde    = PDE(addr);

    page_t *pml4t = (page_t *)pt->proot;
    if (pml4t->entry[pml4te] == 0)
        pml4t->entry[pml4te] = alloc_page(pt);

    page_t *pdpt = PGPTR(pml4t->entry[pml4te]);
    if (pdpt->entry[pdpte] == 0)
        pdpt->entry[pdpte] = alloc_page(pt);

    page_t *pdt = PGPTR(pdpt->entry[pdpte]);
    pdt->entry[pde] = addr | get_pdflags(memtype);
}

/// Create a 4KiB page entry in the kernel page table.
/// 在内核页表中创建一个4KB页表项
static void
create_small_page(pagetable_t *pt, uint64_t addr, uint32_t memtype)
{
    uint64_t pml4te = PML4E(addr);
    uint64_t pdpte  = PDPTE(addr);
    uint64_t pde    = PDE(addr);
    uint64_t pte    = PTE(addr);

    page_t *pml4t = (page_t *)pt->proot;
    if (pml4t->entry[pml4te] == 0)
        pml4t->entry[pml4te] = alloc_page(pt);

    page_t *pdpt = PGPTR(pml4t->entry[pml4te]);
    if (pdpt->entry[pdpte] == 0)
        pdpt->entry[pdpte] = alloc_page(pt);

    page_t *pdt = PGPTR(pdpt->entry[pdpte]);
    if (pdt->entry[pde] == 0)
        pdt->entry[pde] = alloc_page(pt);

    page_t *ptt = PGPTR(pdt->entry[pde]);
    ptt->entry[pte] = addr | get_ptflags(memtype);
}

/// Map a region of memory into the kernel page table, using the largest
/// page sizes possible.
/// 将一个内存区域映射到内核页表，尽可能使用大的页面
static void
map_region(pagetable_t *pt, const pmap_t *map, const pmapregion_t *region)
{
    // Don't map bad (or unmapped) memory.
    // 不要映射损坏的(或者未映射)的内存
    if (region->type == PMEMTYPE_UNMAPPED || region->type == PMEMTYPE_BAD)
        return;

    // Don't map reserved regions beyond the last usable physical address.
    // 不要映射越过最后一个可用物理内存地址的保留区域
    if (region->type == PMEMTYPE_RESERVED &&
        region->addr >= map->last_usable)
        return;

    uint64_t addr = region->addr;
    uint64_t term = region->addr + region->size;

    // Create a series of pages that cover the region. Try to use the largest
    // page sizes possible to keep the page table small.
    while (addr < term) {
        uint64_t remain = term - addr;

        // 可能的话，创建一个巨大的页(1GB)
        if ((addr & (PAGE_SIZE_HUGE - 1)) == 0 &&
            (remain >= PAGE_SIZE_HUGE)) {
            create_huge_page(pt, addr, region->type);
            addr += PAGE_SIZE_HUGE;
        }

        // 如果可能的话，创建一个大的页(2MB)
        else if ((addr & (PAGE_SIZE_LARGE - 1)) == 0 &&
                 (remain >= PAGE_SIZE_LARGE)) {
            create_large_page(pt, addr, region->type);
            addr += PAGE_SIZE_LARGE;
        }

        // 创建一个小的页(4KB)
        else {
            create_small_page(pt, addr, region->type);
            addr += PAGE_SIZE;
        }
    }
}

void
kmem_init(pagetable_t *pt)
{
    // 将所有的内核页表内存置为0
    // [0x20000, 0x70000)
    memzero((void *)KMEM_KERNEL_PAGETABLE, KMEM_KERNEL_PAGETABLE_SIZE);

    // 初始化内核页表
    // proot = 0x00020000
    // vroot = 0x00020000
    // vnext = 0x00020000 + 0x1000
    // vterm = 0x00070000
    pt->proot = KMEM_KERNEL_PAGETABLE;
    pt->vroot = KMEM_KERNEL_PAGETABLE;
    pt->vnext = KMEM_KERNEL_PAGETABLE + PAGE_SIZE;
    pt->vterm = KMEM_KERNEL_PAGETABLE_END;

    // For each region in the physical memory map, create appropriate page
    // table entries.
    // 为物理内存映射中的每一个内存区域，创建合适的页表项
    const pmap_t *map = pmap();
    for (uint64_t r = 0; r < map->count; r++)
        map_region(pt, map, &map->region[r]);
}
