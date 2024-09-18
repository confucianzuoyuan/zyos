//============================================================================
/// @file       paging.c
/// @brief      基于分页的内存管理(Paged memory management).
//============================================================================

#include <core.h>
#include <libc/stdlib.h>
#include <libc/string.h>
#include <kernel/x86/cpu.h>
#include <kernel/interrupt/interrupt.h>
#include <kernel/mem/pmap.h>
#include <kernel/mem/paging.h>
#include "kmem.h"

// add_pte addflags
#define CONTAINS_TABLE     (1 << 0)

// Page shift constants
#define PAGE_SHIFT         12       // 1<<12 = 4KiB
#define PAGE_SHIFT_LARGE   21       // 1<<21 = 2MiB

// 物理页编号常量(Page frame number constants)
#define PFN_INVALID        ((uint32_t)-1)

// 一些辅助的宏
#define PADDR_TO_PF(a)     ((pf_t *)(pfdb.pf + ((a) >> PAGE_SHIFT)))
#define PF_TO_PADDR(pf)    ((uint64_t)((pf) - pfdb.pf) << PAGE_SHIFT)
#define PFN_TO_PF(pfn)     ((pf_t *)((pfn) + pfdb.pf))
#define PF_TO_PFN(pf)      ((uint32_t)((pf) - pfdb.pf))
#define PTE_TO_PADDR(pte)  ((pte) & ~PGMASK_OFFSET)

// 页框类型(Page frame types)
enum
{
    PFTYPE_RESERVED  = 0,
    PFTYPE_AVAILABLE = 1,
    PFTYPE_ALLOCATED = 2,
};

/// pf(page frame)结构体表示物理页数据库中的一条记录
typedef struct pf
{
    uint32_t prev;          ///< 可用列表上前一个物理页编号的索引(Index of prev pfn on available list)
    uint32_t next;          ///< 可用列表上下一个物理页编号的索引(Index of next pfn on available list)
    uint16_t refcount;      ///< 对本页的引用计数(Number of references to this page)
    uint16_t sharecount;    ///< 共享本页的进程数量(Number of processes sharing page)
    uint16_t flags;
    uint8_t  type;          ///< 物理页的类型(PFTYPE of page frame)
    uint8_t  reserved0;
    uint64_t reserved1;
    uint64_t reserved2;
} pf_t;

STATIC_ASSERT(sizeof(pf_t) == 32, "Unexpected page frame size");

/// pfdb(page frame database)结构体描述了物理页数据库的状态
struct pfdb
{
    pf_t    *pf;          ///< 指向物理页组成的数组的指针
    uint32_t count;       ///< 物理页数据库中物理页的数量
    uint32_t avail;       ///< 物理页数据库中可用物理页的数量
    uint32_t head;        ///< 可用物理页列表头部的索引(Index of available frame list head)
    uint32_t tail;        ///< 可用物理页列表尾部的索引(Index of available frame list tail)
};

static struct pfdb  pfdb;      // 全局物理页数据库(Global page frame database)
static pagetable_t  kpt;       // 内核页表(所有物理内存)
static pagetable_t *active_pt; // 当前活跃的页表(Currently active page table)

// TODO: 支持多核

/// 保留一个内存表模块对齐过的内存区域
static void *
reserve_region(const pmap_t *map, uint64_t size, uint32_t alignshift)
{
    const pmapregion_t *r = map->region;
    const pmapregion_t *t = map->region + map->count;
    for (; r < t; r++) {

        // 跳过保留内存区域和太小的内存区域
        if (r->type != PMEMTYPE_USABLE)
            continue;
        if (r->size < size)
            continue;

        // 在内存区域中，找到第一个对齐的字节的地址
        uint64_t paddr = r->addr + (1 << alignshift) - 1;
        paddr >>= alignshift;
        paddr <<= alignshift;

        // 如果内存区域在对齐之后太小了，就忽略它
        if (paddr + size > r->addr + r->size)
            continue;

        // 将已经对齐的内存区域作为保留内存，并返回内存区域的地址。
        pmap_add(paddr, size, PMEMTYPE_RESERVED);
        return (void *)paddr;
    }
    return NULL;
}

void
page_init()
{
    // 获取物理内存映射(physical memory map)
    const pmap_t *map = pmap();
    if (map->last_usable == 0)
        fatal();

    // pfdb.count = 物理页的数量
    pfdb.count = map->last_usable / PAGE_SIZE;
    // 物理页数据库的大小
    uint64_t pfdbsize = pfdb.count * sizeof(pf_t);

    // 将物理页数据库的大小向上取整到最近的2M的倍数，例如 3MB ---> 4MB
    pfdbsize  += PAGE_SIZE_LARGE - 1;
    pfdbsize >>= PAGE_SHIFT_LARGE;
    pfdbsize <<= PAGE_SHIFT_LARGE;

    // 寻找一段连续的，2MB对齐的，足够大的内存区域，用来保存整个物理页数据库
    pfdb.pf = (pf_t *)reserve_region(map, pfdbsize, PAGE_SHIFT_LARGE);
    if (pfdb.pf == NULL)
        fatal();

    // 初始化内核的页表
    kmem_init(&kpt);
    // CR3是页目录基址寄存器
    // mov cr3, rdi
    set_pagetable(kpt.proot);
    active_pt = &kpt;

    // Create the page frame database in the newly mapped virtual memory.
    // 在新的映射好的虚拟内存中创建物理页数据库
    memzero(pfdb.pf, pfdbsize);

    // Initialize available page frame list.
    // 初始化可用物理页列表
    pfdb.avail = 0;
    pfdb.head  = PFN_INVALID;
    pfdb.tail  = PFN_INVALID;

    // Traverse the memory table, adding page frame database entries for each
    // region in the table.
    // 遍历内存表，为表中的每一个内存区域添加物理页数据库项
    for (uint64_t r = 0; r < map->count; r++) {
        const pmapregion_t *region = &map->region[r];

        // 忽略不能使用的内存区域
        if (region->type != PMEMTYPE_USABLE)
            continue;

        // 创建一个page frame(物理页，页帧)的链表，每个物理页的大小是4KB
        // pfn0 = region->addr / 4096
        uint64_t pfn0 = region->addr >> PAGE_SHIFT;
        // pfnN = (region->addr + region->size) / 4096
        uint64_t pfnN = (region->addr + region->size) >> PAGE_SHIFT;
        for (uint64_t pfn = pfn0; pfn < pfnN; pfn++) {
            pf_t *pf = PFN_TO_PF(pfn); // ((pf_t *)((pfn) + pfdb.pf))
            pf->prev = pfn - 1;
            pf->next = pfn + 1;
            pf->type = PFTYPE_AVAILABLE;
        }

        // 将链表连接到可用物理页列表
        if (pfdb.tail == PFN_INVALID)
            pfdb.head = pfn0;
        else
            pfdb.pf[pfdb.tail].next = pfn0;
        pfdb.pf[pfn0].prev     = pfdb.tail;
        pfdb.pf[pfnN - 1].next = PFN_INVALID;
        pfdb.tail              = pfnN - 1;

        // 更新可用物理页的总数
        pfdb.avail += (uint32_t)(pfnN - pfn0);
    }

    // TODO: 编写缺页异常Install page fault handler
}

static pf_t *
pfalloc()
{
    // 先抛出致命异常，后面我们再添加交换(swapping)
    if (pfdb.avail == 0)
        fatal();

    // 从数据库中抓取第一个可用的物理页
    pf_t *pf = PFN_TO_PF(pfdb.head);

    // 更新可用物理页列表
    pfdb.head = pfdb.pf[pfdb.head].next;
    if (pfdb.head != PFN_INVALID)
        pfdb.pf[pfdb.head].prev = PFN_INVALID;

    // 初始化然后返回物理页
    memzero(pf, sizeof(pf_t));
    pf->refcount = 1;
    pf->type     = PFTYPE_ALLOCATED;
    return pf;
}

static void
pffree(pf_t *pf)
{
    if (pf->type != PFTYPE_ALLOCATED)
        fatal();

    // 重新初始化物理页记录
    memzero(pf, sizeof(pf_t));
    pf->prev = PFN_INVALID;
    pf->next = pfdb.head;
    pf->type = PFTYPE_AVAILABLE;

    // 更新数据库中的可用物理页列表
    uint32_t pfn = PF_TO_PFN(pf);
    pfdb.pf[pfdb.head].prev = pfn;
    pfdb.head               = pfn;

    pfdb.avail++;
}

static uint64_t
pgalloc()
{
    // 从db中分配一个物理页，然后计算物理页的物理内存地址。
    pf_t    *pf    = pfalloc();
    uint64_t paddr = PF_TO_PADDR(pf);

    // 总是将新分配的页清零
    memzero((void *)paddr, PAGE_SIZE);

    // 返回物理页的物理内存地址
    return paddr;
}

static void
pgfree(uint64_t paddr)
{
    pf_t *pf = PADDR_TO_PF(paddr);
    if (--pf->refcount == 0)
        pffree(pf);
}

static void
pgfree_recurse(page_t *page, int level)
{
    // 如果我们在PT层级，那么将叶子页表归还给物理页数据库。
    if (level == 1) {
        for (uint64_t e = 0; e < 512; e++) {
            uint64_t paddr = PTE_TO_PADDR(page->entry[e]);
            if (paddr == 0)
                continue;
            pf_t *pf = PADDR_TO_PF(paddr);
            if (pf->type == PFTYPE_ALLOCATED)
                pgfree(paddr);
        }
    }

    // 如果我们位于PD层以及PD层以上的层，那么递归的遍历孩子页表，直到到达PT层
    else {
        for (uint64_t e = 0; e < 512; e++) {
            if (page->entry[e] & PF_SYSTEM) // 永不释放系统页表
                continue;
            page_t *child = PGPTR(page->entry[e]);
            if (child == NULL)
                continue;
            pgfree_recurse(child, level - 1);
        }
    }
}

/// 在页表中添加一项(键值对：虚拟地址 ---> 物理地址)
/// pte：page table entry
static void
add_pte(pagetable_t *pt, uint64_t vaddr, uint64_t paddr, uint32_t pflags,
        uint32_t addflags)
{
    // 如果虚拟地址空间耗尽了，报错
    if ((addflags & CONTAINS_TABLE) && (vaddr >= pt->vterm))
        fatal();

    // 当我们添加新的页表项时，跟踪添加到页表的页
    uint64_t added[3];
    int      count = 0;

    // 将虚拟地址分解为分层表组件
    uint32_t pml4e = PML4E(vaddr); // (((vaddr) >> 39) & 0x1ff)
    uint32_t pdpte = PDPTE(vaddr); // (((vaddr) >> 30) & 0x1ff)
    uint32_t pde   = PDE(vaddr);   // (((vaddr) >> 21) & 0x1ff)
    uint32_t pte   = PTE(vaddr);   // (((vaddr) >> 12) & 0x1ff)

    // 遍历页表层级一直到对底层，创建页表需要的新的页
    page_t *pml4t = (page_t *)pt->proot;
    if (pml4t->entry[pml4e] == 0) {
        uint64_t pgaddr = pgalloc();
        added[count++]      = pgaddr;
        pml4t->entry[pml4e] = pgaddr | PF_PRESENT | PF_RW;
    }
    else if (pml4t->entry[pml4e] & PF_SYSTEM) {
        // 系统页表不能被修改。只检查PML4的根页表，因为检查更底层的页表没必要
        fatal();
    }

    page_t *pdpt = PGPTR(pml4t->entry[pml4e]);
    if (pdpt->entry[pdpte] == 0) {
        uint64_t pgaddr = pgalloc();
        added[count++]     = pgaddr;
        pdpt->entry[pdpte] = pgaddr | PF_PRESENT | PF_RW;
    }

    page_t *pdt = PGPTR(pdpt->entry[pdpte]);
    if (pdt->entry[pde] == 0) {
        uint64_t pgaddr = pgalloc();
        added[count++]  = pgaddr;
        pdt->entry[pde] = pgaddr | PF_PRESENT | PF_RW;
    }

    // 添加页表项
    page_t *ptt = PGPTR(pdt->entry[pde]);
    ptt->entry[pte] = paddr | pflags;

    // 如果添加新的一项需要页表增长，需要保证同时添加页表的新的页
    for (int i = 0; i < count; i++) {
        add_pte(pt, pt->vnext, added[i], PF_PRESENT | PF_RW, CONTAINS_TABLE);
        pt->vnext += PAGE_SIZE;
    }
}

// 删除虚拟内存地址vaddr对应的页表项
static uint64_t
remove_pte(pagetable_t *pt, uint64_t vaddr)
{
    // 计算出虚拟内存地址的层级页表组件
    uint32_t pml4e = PML4E(vaddr);
    uint32_t pdpte = PDPTE(vaddr);
    uint32_t pde   = PDE(vaddr);
    uint32_t pte   = PTE(vaddr);

    // 遍历页表层级，寻找物理页
    page_t *pml4t = (page_t *)pt->proot;
    page_t *pdpt  = PGPTR(pml4t->entry[pml4e]);
    page_t *pdt   = PGPTR(pdpt->entry[pdpte]);
    page_t *ptt   = PGPTR(pdt->entry[pde]);
    page_t *pg    = PGPTR(ptt->entry[pte]);

    // 清除虚拟地址的页表项
    ptt->entry[pte] = 0;

    // 将删除的物理页对应的TLB项置为无效
    // TLB是个硬件哈希表：key_虚拟内存地址 ----> value_物理内存地址
    if (pt == active_pt)
        invalidate_page((void *)vaddr);

    // 返回删除的页表项的物理内存地址
    return (uint64_t)pg;
}

void
pagetable_create(pagetable_t *pt, void *vaddr, uint64_t size)
{
    if (size % PAGE_SIZE != 0)
        fatal();

    // Allocate a page from the top level of the page table hierarchy.
    // 在测试程序中：
    // vroot = vaddr = 0x8000000000
    // vnext = 0x8000000000 + 0x1000
    // vterm = 0x8000000000 + 1024 * 0x1000
    pt->proot = pgalloc();
    pt->vroot = (uint64_t)vaddr;
    pt->vnext = (uint64_t)vaddr + PAGE_SIZE;
    pt->vterm = (uint64_t)vaddr + size;

    // Install the kernel's page table into the created page table.
    // 将内核的页表安装到创建的页表中
    page_t *src = (page_t *)kpt.proot;
    page_t *dst = (page_t *)pt->proot;
    for (int i = 0; i < 512; i++)
        dst->entry[i] = src->entry[i];
}

void
pagetable_destroy(pagetable_t *pt)
{
    if (pt->proot == 0)
        fatal();

    // 从PML4表中递归的删除所有物理页
    pgfree_recurse((page_t *)pt->proot, 4);

    // 使所有页表中的物理页的TLB项都失效
    if (pt == active_pt) {
        for (uint64_t vaddr = pt->vroot; vaddr < pt->vterm;
             vaddr += PAGE_SIZE) {
            invalidate_page((void *)vaddr);
        }
    }

    memzero(pt, sizeof(pagetable_t));
}

void
pagetable_activate(pagetable_t *pt)
{
    if (pt == NULL)
        pt = &kpt;
    if (pt->proot == 0)
        fatal();

    set_pagetable(pt->proot);
    active_pt = pt;
}

void *
page_alloc(pagetable_t *pt, void *vaddr_in, int count)
{
    for (uint64_t vaddr = (uint64_t)vaddr_in; count--; vaddr += PAGE_SIZE) {
        uint64_t paddr = pgalloc();
        add_pte(pt, vaddr, paddr, PF_PRESENT | PF_RW, 0);
    }
    return vaddr_in;
}

void
page_free(pagetable_t *pt, void *vaddr_in, int count)
{
    for (uint64_t vaddr = (uint64_t)vaddr_in; count--; vaddr += PAGE_SIZE) {
        uint64_t paddr = remove_pte(pt, vaddr);
        pgfree(paddr);
    }
}
