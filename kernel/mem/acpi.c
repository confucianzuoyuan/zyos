//============================================================================
/// @file       acpi.c
/// @brief      Advanced configuration and power interface (ACPI) tables.
///             高级配置和电源接口表
//============================================================================

#include <core.h>
#include <libc/string.h>
#include <kernel/debug/log.h>
#include <kernel/mem/acpi.h>
#include <kernel/mem/paging.h>
#include <kernel/mem/pmap.h>
#include <kernel/x86/cpu.h>
#include "kmem.h"

#define SIGNATURE_RSDP      0x2052545020445352ll // "RSD PTR "
#define SIGNATURE_MADT      0x43495041           // "APIC"
#define SIGNATURE_BOOT      0x544F4F42           // "BOOT"字符串的小端序存储方式，也就是"TOOB"
#define SIGNATURE_FADT      0x50434146           // "FACP"
#define SIGNATURE_HPET      0x54455048           // "HPET"
#define SIGNATURE_MCFG      0x4746434D           // "MCFG"
#define SIGNATURE_SRAT      0x54415253           // "SRAT"
#define SIGNATURE_SSDT      0x54445353           // "SSDT"
#define SIGNATURE_WAET      0x54454157           // "WAET"

// Page alignment macros
// 页对齐的宏

// 向下对齐，例如：a=1 那么对齐到 0；a=7999 那么对齐到 4096
#define PAGE_ALIGN_DOWN(a)  ((a) & ~(PAGE_SIZE - 1))
// 向上对齐，例如：a=4001 那么对齐到 4096
#define PAGE_ALIGN_UP(a)    (((a) + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1))

/// 这个结构体用来追踪boot loader产生的临时页表的状态
/// ACPI 代码会更新这个结构体来访问存储在 ACPI 中的内存
typedef struct btable
{
    page_t *root;           ///< 顶层页表(PML4)
    page_t *next_page;      ///< 当分配时要使用的下一个页
    page_t *term_page;      ///< 刚好越过上一个可用页(Just beyond the last available page)
} btable_t;

/// 在ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）中，RSDP（Root System Description Pointer）是一个数据结构，它提供了找到其他ACPI表（如RSDT或XSDT）的方法。
/// RSDP包含了一个指向RSDT或XSDT的指针，这两个表包含了系统中其他ACPI表的地址。因此，操作系统或其他ACPI兼容的软件可以通过查找和解析RSDP来找到系统中所有的ACPI表。
/// 通常，BIOS在POST（Power-On Self-Test，开机自检）过程中，将RSDP存放在内存地址0xE0000–0xFFFFF之间的某个位置。然后，操作系统在启动过程中，会搜索这个内存区域来找到RSDP。
struct acpi_rsdp
{
    char     signature[8];  ///< 包含字符串 "RSD PTR "
    uint8_t  checksum;      ///< Covers up to (and including) ptr_rsdt
    char     oemid[6];      ///< 由 OEM 提供
    uint8_t  revision;      ///< 0=1.0, 1=2.0, 2=3.0
    uint32_t ptr_rsdt;      ///< 指向RSDT表的32位的指针

    // 下面的字段在ACPI1.0中不存在
    uint32_t length;        ///< RSDT table length, including header
    uint64_t ptr_xsdt;      ///< 指向XSDT表的64位的指针
    uint8_t  checksum_ex;   ///< Covers entire rsdp structure
    uint8_t  reserved[3];
} PACKSTRUCT;

struct acpi_rsdt
{
    struct acpi_hdr hdr;
    uint32_t        ptr_table[1]; ///< 指向其它ACPI表的指针
} PACKSTRUCT;

struct acpi_xsdt
{
    struct acpi_hdr hdr;
    uint64_t        ptr_table[1]; ///< 指向其它ACPI表的指针
} PACKSTRUCT;

struct acpi
{
    int                     version; // ACPI version (1, 2 or 3)
    const struct acpi_rsdp *rsdp;
    const struct acpi_rsdt *rsdt;
    const struct acpi_xsdt *xsdt;
    const struct acpi_fadt *fadt;
    const struct acpi_madt *madt;
    const struct acpi_mcfg *mcfg;
};

static struct acpi acpi;

static void
read_fadt(const struct acpi_hdr *hdr)
{
    const struct acpi_fadt *fadt = (const struct acpi_fadt *)hdr;
    acpi.fadt = fadt;
}

static void
read_madt(const struct acpi_hdr *hdr)
{
    const struct acpi_madt *madt = (const struct acpi_madt *)hdr;
    acpi.madt = madt;
}

static void
read_mcfg(const struct acpi_hdr *hdr)
{
    const struct acpi_mcfg *mcfg = (const struct acpi_mcfg *)hdr;
    acpi.mcfg = mcfg;
}

static void
read_table(const struct acpi_hdr *hdr)
{
    switch (hdr->signature.dword)
    {
        case SIGNATURE_FADT:
            read_fadt(hdr); break;

        case SIGNATURE_MADT:
            read_madt(hdr); break;

        case SIGNATURE_MCFG:
            read_mcfg(hdr); break;

        default:
            break;
    }
}

/// @brief 检测虚拟地址`addr`是否有对应的物理内存地址
/// @param btable 
/// @param addr 
/// @return 
static bool
is_mapped(btable_t *btable, uint64_t addr)
{
    uint64_t pml4te = PML4E(addr);
    uint64_t pdpte  = PDPTE(addr);
    uint64_t pde    = PDE(addr);
    uint64_t pte    = PTE(addr);

    page_t *pml4t = btable->root;
    if (pml4t->entry[pml4te] == 0)
        return false;

    page_t *pdpt = PGPTR(pml4t->entry[pml4te]);
    if (pdpt->entry[pdpte] == 0)
        return false;
    if (pdpt->entry[pdpte] & PF_PS)
        return true;

    page_t *pdt = PGPTR(pdpt->entry[pdpte]);
    if (pdt->entry[pde] == 0)
        return false;
    if (pdt->entry[pde] & PF_PS)
        return true;

    page_t *pt = PGPTR(pdt->entry[pde]);
    return pt->entry[pte] != 0;
}

static uint64_t
alloc_page(btable_t *btable)
{
    if (btable->next_page == btable->term_page)
        fatal();

    page_t *page = btable->next_page++;
    memzero(page, sizeof(page_t));
    return (uint64_t)page | PF_PRESENT | PF_RW;
}

static void
create_page(btable_t *btable, uint64_t addr, uint64_t flags)
{
    uint64_t pml4te = PML4E(addr);
    uint64_t pdpte  = PDPTE(addr);
    uint64_t pde    = PDE(addr);
    uint64_t pte    = PTE(addr);

    page_t *pml4t = btable->root;
    if (pml4t->entry[pml4te] == 0)
        pml4t->entry[pml4te] = alloc_page(btable);

    page_t *pdpt = PGPTR(pml4t->entry[pml4te]);
    if (pdpt->entry[pdpte] == 0)
        pdpt->entry[pdpte] = alloc_page(btable);

    page_t *pdt = PGPTR(pdpt->entry[pdpte]);
    if (pdt->entry[pde] == 0)
        pdt->entry[pde] = alloc_page(btable);

    page_t *pt = PGPTR(pdt->entry[pde]);
    pt->entry[pte] = addr | flags;
}

static void
map_range(btable_t *btable, uint64_t addr, uint64_t size, uint64_t flags)
{
    // 计算页对齐的内存块
    uint64_t begin = PAGE_ALIGN_DOWN(addr);
    uint64_t term  = PAGE_ALIGN_UP(addr + size);

    // 如果需要，在boot页表中创建新的页来覆盖地址范围
    for (uint64_t addr = begin; addr < term; addr += PAGE_SIZE) {
        if (!is_mapped(btable, addr))
            create_page(btable, addr, flags);
    }
}

static void
map_table(btable_t *btable, const struct acpi_hdr *hdr)
{
    uint64_t addr  = (uint64_t)hdr;
    uint64_t flags = PF_PRESENT | PF_RW;

    // 首先映射表头，否则无法读取表头的长度
    map_range(btable, addr, sizeof(struct acpi_hdr), flags);

    // 既然我们可以读取表头的长度，那么接下来映射整个ACPI表。
    uint64_t size = hdr->length;
    map_range(btable, addr, size, flags);

    // 计算页对齐的ACPI表，然后添加到BIOS生成的内存表
    pmap_add(PAGE_ALIGN_DOWN(addr),
             PAGE_ALIGN_UP(addr + hdr->length) - PAGE_ALIGN_DOWN(addr),
             PMEMTYPE_ACPI);
}

static void
read_xsdt(btable_t *btable)
{
    const struct acpi_xsdt *xsdt = acpi.xsdt;
    const struct acpi_hdr  *xhdr = &xsdt->hdr;

    logf(LOG_INFO,
         "[acpi] oem='%.6s' tbl='%.8s' rev=%#x creator='%.4s'",
         xhdr->oemid, xhdr->oemtableid, xhdr->oemrevision, xhdr->creatorid);

    // 读取XSDT表引用的每一张表
    int tables = (int)(xhdr->length - sizeof(*xhdr)) / sizeof(uint64_t);
    for (int i = 0; i < tables; i++) {
        const struct acpi_hdr *hdr =
            (const struct acpi_hdr *)xsdt->ptr_table[i];
        map_table(btable, hdr);
        logf(LOG_INFO, "[acpi] Found %.4s table at %#lx.",
             hdr->signature.bytes, (uint64_t)hdr);
        read_table(hdr);
    }
}

static void
read_rsdt(btable_t *btable)
{
    const struct acpi_rsdt *rsdt = acpi.rsdt;
    const struct acpi_hdr  *rhdr = &rsdt->hdr;

    logf(LOG_INFO,
         "[acpi] oem='%.6s' tbl='%.8s' rev=%#x creator='%.4s'",
         rhdr->oemid, rhdr->oemtableid, rhdr->oemrevision, rhdr->creatorid);

    // 读取RSDT表引用的每一张表
    int tables = (int)(rhdr->length - sizeof(*rhdr)) / sizeof(uint32_t);
    for (int i = 0; i < tables; i++) {
        const struct acpi_hdr *hdr =
            (const struct acpi_hdr *)(uintptr_t)rsdt->ptr_table[i];
        map_table(btable, hdr);
        logf(LOG_INFO, "[acpi] Found %.4s table at %#lx.",
             hdr->signature.bytes, (uint64_t)hdr);
        read_table(hdr);
    }
}

static const struct acpi_rsdp *
find_rsdp(uint64_t addr, uint64_t size)
{
    // 扫描内存来寻找一个 8 字节大小的 RSDP 签名。
    // 需要保证对齐到 16 字节边界。
    const uint64_t *ptr  = (const uint64_t *)addr;
    const uint64_t *term = (const uint64_t *)(addr + size);
    for (; ptr < term; ptr += 2) {
        if (*ptr == SIGNATURE_RSDP)
            return (const struct acpi_rsdp *)ptr;
    }
    return NULL;
}

void
acpi_init()
{
    // 初始化由boot loader生成的临时页表的状态。
    // 当我们扫描ACPI表时，会更新这个临时页表。
    // KMEM_BOOT_PAGETABLE == 0x00010000
    // KMEM_BOOT_PAGETABLE_LOADED == 0x00014000
    // KMEM_BOOT_PAGETABLE_END == 0x00020000
    btable_t btable =
    {
        .root      = (page_t *)KMEM_BOOT_PAGETABLE,
        .next_page = (page_t *)KMEM_BOOT_PAGETABLE_LOADED,
        .term_page = (page_t *)KMEM_BOOT_PAGETABLE_END,
    };

    // 扫描扩展BIOS和系统ROM内存区域来寻找ACPI RSDP表
    // 0x0009f800 ~ 0x0009f800 + 0x00000800
    acpi.rsdp = find_rsdp(KMEM_EXTENDED_BIOS, KMEM_EXTENDED_BIOS_SIZE);
    if (acpi.rsdp == NULL)
        // 0x000c0000 ~ 0x000c0000 + 0x00040000
        acpi.rsdp = find_rsdp(KMEM_SYSTEM_ROM, KMEM_SYSTEM_ROM_SIZE);

    // 如果没有找到ACPI的那些表，致命错误退出。
    if (acpi.rsdp == NULL) {
        logf(LOG_CRIT, "[acpi] No ACPI tables found.");
        fatal();
    }

    acpi.version = acpi.rsdp->revision + 1;
    logf(LOG_INFO, "[acpi] ACPI %d.0 RSDP table found at %#lx.",
         acpi.version, (uintptr_t)acpi.rsdp);

    // 优先使用ACPI2.0版本的XSDT表来寻找其它表
    if (acpi.version > 1) {
        acpi.xsdt = (const struct acpi_xsdt *)acpi.rsdp->ptr_xsdt;
        if (acpi.xsdt == NULL) {
            logf(LOG_INFO, "[acpi] No XSDT table found.");
        }
        else {
            logf(LOG_INFO, "[acpi] Found XSDT table at %#lx.",
                 (uintptr_t)acpi.xsdt);
            map_table(&btable, &acpi.xsdt->hdr);
            read_xsdt(&btable);
        }
    }

    // 如果XSDT为NULL，那么退回到ACPI1.0的RSDT表
    if (acpi.xsdt == NULL) {
        acpi.rsdt = (const struct acpi_rsdt *)(uintptr_t)acpi.rsdp->ptr_rsdt;
        if (acpi.rsdt == NULL) {
            logf(LOG_CRIT, "[acpi] No RSDT table found.");
            fatal();
        }
        else {
            logf(LOG_INFO, "[acpi] Found RSDT table at %#lx.",
                 (uintptr_t)acpi.rsdt);
            map_table(&btable, &acpi.rsdt->hdr);
            read_rsdt(&btable);
        }
    }

    // 保留本地APIC内存映射IO地址
    if (acpi.madt != NULL) {
        pmap_add(PAGE_ALIGN_DOWN(acpi.madt->ptr_local_apic), PAGE_SIZE,
                 PMEMTYPE_UNCACHED);
    }

    // 保留 I/O APIC 内存映射 I/O 地址。
    const struct acpi_madt_io_apic *io = NULL;
    while ((io = acpi_next_io_apic(io)) != NULL) {
        pmap_add(PAGE_ALIGN_DOWN(io->ptr_io_apic), PAGE_SIZE,
                 PMEMTYPE_UNCACHED);
    }
}

int
acpi_version()
{
    return acpi.version;
}

const struct acpi_fadt *
acpi_fadt()
{
    return acpi.fadt;
}

const struct acpi_madt *
acpi_madt()
{
    return acpi.madt;
}

static const void *
madt_find(enum acpi_madt_type type, const void *prev)
{
    const struct acpi_madt *madt = acpi.madt;
    if (madt == NULL)
        return NULL;

    const void *term = (const uint8_t *)madt + madt->hdr.length;

    const void *ptr;
    if (prev == NULL) {
        ptr = madt + 1;
    }
    else {
        ptr = (const uint8_t *)prev +
              ((const struct acpi_madt_hdr *)prev)->length;
    }

    while (ptr < term) {
        const struct acpi_madt_hdr *hdr = (const struct acpi_madt_hdr *)ptr;
        if (hdr->type == type)
            return hdr;
        ptr = (const uint8_t *)hdr + hdr->length;
    }

    return NULL;
}

const struct acpi_madt_local_apic *
acpi_next_local_apic(const struct acpi_madt_local_apic *prev)
{
    return (const struct acpi_madt_local_apic *)madt_find(
        ACPI_MADT_LOCAL_APIC, prev);
}

const struct acpi_madt_io_apic *
acpi_next_io_apic(const struct acpi_madt_io_apic *prev)
{
    return (const struct acpi_madt_io_apic *)madt_find(
        ACPI_MADT_IO_APIC, prev);
}

const struct acpi_madt_iso *
acpi_next_iso(const struct acpi_madt_iso *prev)
{
    return (const struct acpi_madt_iso *)madt_find(
        ACPI_MADT_ISO, prev);
}

const struct acpi_mcfg_addr *
acpi_next_mcfg_addr(const struct acpi_mcfg_addr *prev)
{
    const struct acpi_mcfg *mcfg = acpi.mcfg;
    if (mcfg == NULL)
        return NULL;

    const struct acpi_mcfg_addr *ptr;
    if (prev == NULL)
        ptr = (const struct acpi_mcfg_addr *)(mcfg + 1);
    else
        ptr = prev + 1;

    const uint8_t *term = (const uint8_t *)mcfg + mcfg->hdr.length;
    if ((const uint8_t *)ptr < term)
        return ptr;
    else
        return NULL;
}
