//============================================================================
/// @file       paging.h
/// @brief      基于分页的内存管理(Paged memory management).
//============================================================================

#pragma once

#include <core.h>

// 页大小常量
#define PAGE_SIZE        0x1000       // 4KB
#define PAGE_SIZE_LARGE  0x200000     // 2MB
#define PAGE_SIZE_HUGE   0x40000000   // 1GB

// 页表项标志位(Page table entry flags)
#define PF_PRESENT       (1 << 0)   // 页在表中(Page is present in the table)
#define PF_RW            (1 << 1)   // 读写(Read-Write)
#define PF_USER          (1 << 2)   // 允许用户模式访问(User-mode (CPL==3) access allowed)
#define PF_PWT           (1 << 3)   // Page write-thru
#define PF_PCD           (1 << 4)   // 禁用缓存(Cache disable)
#define PF_ACCESS        (1 << 5)   // 表明页是否被访问(Indicates whether page was accessed)
#define PF_DIRTY         (1 << 6)   // 表明4K大小的页是否被写(Indicates whether 4K page was written)
#define PF_PS            (1 << 7)   // 页大小(Page size (valid for PD and PDPT only))
#define PF_GLOBAL        (1 << 8)   // 表明页是否被全局缓存(Indicates the page is globally cached)
#define PF_SYSTEM        (1 << 9)   // 页被内核使用了(Page used by the kernel)

// 虚拟地址位掩码和移位(Virtual address bitmasks and shifts)
#define PGSHIFT_PML4E    39
#define PGSHIFT_PDPTE    30
#define PGSHIFT_PDE      21
#define PGSHIFT_PTE      12
#define PGMASK_ENTRY     0x1ff
#define PGMASK_OFFSET    0x3ff

// Virtual address subfield accessors
#define PML4E(a)         (((a) >> PGSHIFT_PML4E) & PGMASK_ENTRY)
#define PDPTE(a)         (((a) >> PGSHIFT_PDPTE) & PGMASK_ENTRY)
#define PDE(a)           (((a) >> PGSHIFT_PDE) & PGMASK_ENTRY)
#define PTE(a)           (((a) >> PGSHIFT_PTE) & PGMASK_ENTRY)

// 页表项帮手(Page table entry helpers)
#define PGPTR(pte)       ((page_t *)((pte) & ~PGMASK_OFFSET))

//----------------------------------------------------------------------------
//  @union      page_t
/// @brief      页表页记录(A pagetable page record).
/// @details    如果这一页包含的是一张页表，那么会包含512条页表项。
///             否则这一页包含4096个字节的内存。
//----------------------------------------------------------------------------
typedef union page
{
    uint64_t entry[PAGE_SIZE / sizeof(uint64_t)]; // entry[512]
    uint8_t  memory[PAGE_SIZE];                   // memory[4096]
} page_t;

//----------------------------------------------------------------------------
//  @struct     pagetable_t
/// @brief      页表结构体
/// @details    保存所有的页表项(每个页表项是虚拟地址到物理地址的映射)
//----------------------------------------------------------------------------
typedef struct pagetable
{
    uint64_t proot;     ///< 根页表项的物理地址(Physical address of root page table (PML4T) entry)
    uint64_t vroot;     ///< 根页表项的虚拟地址(Virtual address of root page table (PML4T) entry)
    uint64_t vnext;     ///< 页表中下一页的虚拟地址(Virtual address to use for table's next page)
    uint64_t vterm;     ///< 用来保存页表的页的数量的上限(Boundary of pages used to store the table)
} pagetable_t;

//----------------------------------------------------------------------------
//  @function   page_init
/// @brief      初始化页框(page frame)数据库
/// @details    页框数据库用来管理内核已经知道的所有内存页的物理内存
//----------------------------------------------------------------------------
void
page_init();

//----------------------------------------------------------------------------
//  @function   pagetable_create
/// @brief      Create a new page table that can be used to associate virtual
///             addresses with physical addresses. The page table includes
///             protected mappings for kernel memory.
/// @param[in]  pt      A pointer to the pagetable structure that will hold
///                     the page table.
/// @param[in]  vaddr   The virtual address within the new page table where
///                     the page table will be mapped.
/// @param[in]  size    Maximum size of the page table in bytes. Must be a
///                     multiple of PAGE_SIZE.
/// @returns    A handle to the created page table.
//----------------------------------------------------------------------------
void
pagetable_create(pagetable_t *pt, void *vaddr, uint64_t size);

//----------------------------------------------------------------------------
//  @function   pagetable_destroy
/// @brief      Destroy a page table.
/// @param[in]  pt      A handle to the page table to destroy.
//----------------------------------------------------------------------------
void
pagetable_destroy(pagetable_t *pt);

//----------------------------------------------------------------------------
//  @function   pagetable_activate
/// @brief      Activate a page table on the CPU, so all virtual memory
///             operations are performed relative to the page table.
/// @param[in]  pt      A handle to the activated page table. Pass NULL to
///                     activate the kernel page table.
//----------------------------------------------------------------------------
void
pagetable_activate(pagetable_t *pt);

//----------------------------------------------------------------------------
//  @function   page_alloc
/// @brief      Allocate one or more pages contiguous in virtual memory.
/// @param[in]  pt      Handle to the page table from which to allocate the
///                     page(s).
/// @param[in]  vaddr   The virtual address of the first allocated page.
/// @param[in]  count   The number of contiguous virtual memory pages to
///                     allocate.
/// @returns    A virtual memory pointer to the first page allocated.
//----------------------------------------------------------------------------
void *
page_alloc(pagetable_t *pt, void *vaddr, int count);

//----------------------------------------------------------------------------
//  @function   page_free
/// @brief      Free one or more contiguous pages from virtual memory.
/// @param[in]  pt      Handle to ehte page table from which to free the
///                     page(s).
/// @param[in]  vaddr   The virtual address of the first allocated page.
/// @param[in]  count   The number of contiguous virtual memory pages to free.
//----------------------------------------------------------------------------
void
page_free(pagetable_t *pt, void *vaddr, int count);
