//============================================================================
/// @file       pmap.c
/// @brief      物理内存映射：描述可用和保留的物理内存区域(pmap: physical memory map)
/// @details    在这个文件的代码执行之前，boot代码已经填充了大部分的内存映射，填充的内存区域
///             由BIOS提供
//============================================================================

#include <core.h>
#include <libc/stdlib.h>
#include <libc/string.h>
#include <kernel/mem/pmap.h>
#include "kmem.h"

// Pointer to the BIOS-generated memory map.
// 指向BIOS生成的内存映射的指针
// KMEM_TABLE_BIOS == Mem.Table in mem.inc == 0x00070000
// 0x70000这个地址保存了memory zone的数量
static pmap_t *map         = (pmap_t *)KMEM_TABLE_BIOS;
static bool    initialized = false;

/// Add a memory region to the end of the memory map.
/// 在内存映射的尾部添加一个内存区域
static void
add_region(uint64_t addr, uint64_t size, enum pmemtype type)
{
    pmapregion_t *r = map->region + map->count;
    r->addr  = addr;
    r->size  = size;
    r->type  = (int32_t)type;
    r->flags = 0;

    // 内存区域数量加一
    ++map->count;
}

/// 比较两个内存区域记录，返回比较结果
/// 两块内存只有起始地址和尺寸都一样是，才是一样的。
static int
cmp_region(const void *a, const void *b)
{
    const pmapregion_t *r1 = (const pmapregion_t *)a;
    const pmapregion_t *r2 = (const pmapregion_t *)b;
    if (r1->addr > r2->addr)
        return +1;
    if (r1->addr < r2->addr)
        return -1;
    if (r1->size > r2->size)
        return +1;
    if (r1->size < r2->size)
        return -1;
    return 0;
}

/// Remove a region from the memory map and shift all subsequent regions
/// down by one.
/// 从memory map中删除一个内存区域，然后将后面的内存区域都向前移动一个位置
///     +----------------+----------------+----------------+----------------+
///     | pmapregion_t0  | pmapregion_t1  | pmapregion_t2  | pmapregion_t3  |
///     +----------------+----------------+----------------+----------------+
///     |                |                                 |
///     |                |                                 |
///     v                v                                 v
///    r=0             r+1=1                             term=3
/// 执行完函数之后变为：
///     +----------------+----------------+----------------+
///     | pmapregion_t1  | pmapregion_t2  | pmapregion_t3  |
///     +----------------+----------------+----------------+
static inline void
collapse(pmapregion_t *r, pmapregion_t *term)
{
    if (r + 1 < term)
        // dst = r, src = r + 1
        memmove(r, r + 1, (term - r) * sizeof(pmapregion_t));
    // 内存区域的数量减1
    --map->count;
}

/// Insert a new, uninitialized memory region record after an existing record
/// in the memory map.
/// 在已存在的内存区域记录后面插入一个新的，未初始化的内存区域记录
///     +----------------+----------------+----------------+----------------+
///     | pmapregion_t0  | pmapregion_t1  | pmapregion_t2  | pmapregion_t3  |
///     +----------------+----------------+----------------+----------------+
///     |                |                |                |
///     |                |                |                |
///     v                v                v                v
///    r=0             r+1=1            r+2=2            term=3
/// 执行完函数之后变为：
///     +----------------+----------------+----------------+----------------+----------------+
///     | pmapregion_t0  | uninitialized  | pmapregion_t1  | pmapregion_t2  | pmapregion_t3  |
///     +----------------+----------------+----------------+----------------+----------------+
static inline void
insertafter(pmapregion_t *r, pmapregion_t *term)
{
    if (r + 1 < term)
        memmove(r + 2, r + 1, (term - (r + 1)) * sizeof(pmapregion_t));
    ++map->count;
}

/// Re-sort all unsorted region records starting from the requested record.
/// 从指定的某个记录开始，对所有未排序的内存区域记录进行重新排序
static void
resort(pmapregion_t *r, pmapregion_t *term)
{
    while (r + 1 < term) {
        if (cmp_region(r, r + 1) < 0)
            break;
        pmapregion_t tmp = r[0];
        r[0] = r[1];
        r[1] = tmp;
        r++;
    }
}

/// Find all overlapping memory regions in the memory map and collapse or
/// reorganize them.
/// 寻找memory map中所有重叠的内存区域然后折叠或者重新组织这些内存区域
static void
collapse_overlaps()
{
    pmapregion_t *curr = map->region;
    pmapregion_t *term = map->region + map->count;

    while (curr + 1 < term) {

        // Collapse empty entries.
        if (curr->size == 0) {
            collapse(curr, term--);
            continue;
        }

        pmapregion_t *next = curr + 1;

        uint64_t cl = curr->addr;
        uint64_t cr = curr->addr + curr->size;
        uint64_t nl = next->addr;
        uint64_t nr = next->addr + next->size;

        // No overlap? Then go to the next region.
        // 检测两块内存区域是否有重叠，如果没有那么继续寻找
        if (min(cr, nr) <= max(cl, nl)) {
            curr++;
            continue;
        }

        // 如果有重叠，处理5种对齐的情况：
        //   xxx    xxx    xxxx   xxx    xxxxx
        //   yyy    yyyy    yyy    yyy    yyy
        // 剩余的情形不可能发生，因为内存区域经过了排序

        if (cl == nl) { // 内存区域左边对齐
            if (cr == nr) { // 内存区域右边对齐，所以完全重叠
                if (next->type > curr->type) {
                    // 111  ->  222
                    // 222
                    collapse(curr, term--);
                }
                else {
                    // 222  ->  222
                    // 111
                    collapse(next, term--);
                }
            }
            else { /* if cr != nr */ // 左边对齐，右边没对齐，next区域包含了curr区域
                if (next->type > curr->type) {
                    // 111  ->  2222
                    // 2222
                    collapse(curr, term--);
                }
                else {
                    // 222  ->  222
                    // 1111 ->     1
                    next->size = nr - cr;
                    next->addr = cr;
                    resort(next, term);
                }
            }
        }

        else { /* if cl != nl */
            if (cr == nr) {
                if (next->type > curr->type) {
                    // 1111  ->  1
                    //  222  ->   222
                    curr->size = nl - cl;
                }
                else {
                    // 2222  ->  2222
                    //  111
                    collapse(next, term--);
                }
            }
            else if (cr < nr) {
                if (next->type > curr->type) {
                    // 1111  ->  1
                    //  2222 ->   2222
                    curr->size = nl - cl;
                }
                else {
                    // 2222  ->  2222
                    //  1111 ->      1
                    next->size = nr - cr;
                    next->addr = cr;
                    resort(next, term);
                }
            }
            else { /* if cr > nr */
                if (next->type > curr->type) {
                    // 11111  -> 1
                    //  222   ->  222
                    //        ->     1
                    curr->size = nl - cl;
                    insertafter(next, term++);
                    next[1].addr  = nr;
                    next[1].size  = cr - nr;
                    next[1].type  = curr->type;
                    next[1].flags = curr->flags;
                    resort(next + 1, term);
                }
                else {
                    // 22222  ->  22222
                    //  111
                    collapse(next, term--);
                }
            }
        }

    }
}

/// Find missing memory regions in the map, and fill them with entries of
/// the requested type.
/// 寻找丢失的内存区域，然后在这片区域填充指定类型的项
static void
fill_gaps(int32_t type)
{
    pmapregion_t *curr = map->region;
    pmapregion_t *term = map->region + map->count;

    while (curr + 1 < term) {
        pmapregion_t *next = curr + 1;

        uint64_t cr = curr->addr + curr->size;
        uint64_t nl = next->addr;

        if (cr == nl) {
            curr++;
            continue;
        }

        // Try to expand one of the neighboring entries if one of them has the
        // same type as the fill type.
        if (curr->type == type) {
            curr->size += nl - cr;
        }
        else if (next->type == type) {
            next->size += nl - cr;
            next->addr  = cr;
        }

        // Neither neighboring region has the fill type, so insert a new
        // region record.
        else {
            insertafter(curr, term++);
            next->addr  = cr;
            next->size  = nl - cr;
            next->type  = type;
            next->flags = 0;
        }
    }
}

/// Find adjacent memory entries of the same type and merge them.
/// 寻找相邻的，且类型相同的内存区域，然后合并它们
static void
consolidate_neighbors()
{
    pmapregion_t *curr = map->region;
    pmapregion_t *term = map->region + map->count;

    while (curr + 1 < term) {
        pmapregion_t *next = curr + 1;
        if (curr->type == next->type) {
            curr->size += next->size;
            collapse(next, term--);
        }
        else {
            curr++;
        }
    }
}

static void
update_last_usable()
{
    map->last_usable = 0;
    for (int i = map->count - 1; i >= 0; i--) {
        const pmapregion_t *r = &map->region[i];
        if (r->type == PMEMTYPE_USABLE) {
            map->last_usable = r->addr + r->size;
            break;
        }
    }
}

static void
normalize()
{
    // 按照地址对memory map排序
    qsort(map->region, map->count, sizeof(pmapregion_t),
          cmp_region);

    // 移除重叠区域，使用“保留”内存填充区域之间的空隙，压缩相邻且相同类型的区域，计算最后一个
    // 已用的内存区域的尾部地址
    collapse_overlaps();
    fill_gaps(PMEMTYPE_RESERVED);
    consolidate_neighbors();
    update_last_usable();
}

void
pmap_init()
{
    // 在boot过程中，位于KMEM_TABLE_BIOS的物理内存映射被BIOS报告的内存区域所更新
    // `pmap_init()`方法清理了BIOS memory map(排序，删除重叠的，等等)，
    // 然后添加一些额外的内存区域

    // 将VGA视频内存部分设置为不可缓存的
    // 这部分是内存映射寄存器，必须能够直接读写内存，所以禁用高速缓存
    // 0xA0000 ~ 0xA0000 + 0x20000
    add_region(KMEM_VIDEO, KMEM_VIDEO_SIZE, PMEMTYPE_UNCACHED);

    // 将内核以及内核的全局数据结构所在的内存设置为保留内存(reserved memory)
    // 0 ~ 0xA00000
    // 0 ~ 10M
    add_region(0, KMEM_KERNEL_IMAGE_END, PMEMTYPE_RESERVED);

    // 将内存的第一页标记为未映射的，这样解引用一个null指针永远报错
    // 0 ~ 4KB
    add_region(0, 0x1000, PMEMTYPE_UNMAPPED);

    // 修复memory map
    normalize();

    initialized = true;
}

const pmap_t *
pmap()
{
    return map;
}

void
pmap_add(uint64_t addr, uint64_t size, enum pmemtype type)
{
    add_region(addr, size, type);

    if (initialized)
        normalize();
}
