//============================================================================
/// @file       pmap.h
/// @brief      物理内存映射：用来描述可用和保留的物理内存
/// @details    多数映射是从系统启动时BIOS提供的数据中推导出来的
//============================================================================

#pragma once

#include <core.h>

//----------------------------------------------------------------------------
//  @enum       pmemtype
/// @brief      物理内存的类型
//----------------------------------------------------------------------------
enum pmemtype
{
    PMEMTYPE_USABLE   = 1,   ///< BIOS报告可用
    PMEMTYPE_RESERVED = 2,   ///< BIOS报告或者推测出保留的内存
    PMEMTYPE_ACPI     = 3,   ///< 用于 ACPI 表或者代码
    PMEMTYPE_ACPI_NVS = 4,   ///< 用于 ACPI non-volatile storage.
    PMEMTYPE_BAD      = 5,   ///< BIOS报告为坏内存
    PMEMTYPE_UNCACHED = 6,   ///< 标记为不可缓存的(Marked as uncacheable, usually for I/O)
    PMEMTYPE_UNMAPPED = 7,   ///< 标记为不要映射
};

//----------------------------------------------------------------------------
//  @struct     pmapregion_t
/// @brief      一段连续的内存区域
//----------------------------------------------------------------------------
struct pmapregion
{
    uint64_t addr;               ///< 基地址
    uint64_t size;               ///< 内存区域的大小
    int32_t  type;               ///< 内存类型(参见 memtype enum)
    uint32_t flags;              ///< 标志位(当前未使用)
};
typedef struct pmapregion pmapregion_t;

//----------------------------------------------------------------------------
//  @struct     pmap_t
/// @brief      memory map描述了可用和保留的物理内存区域
/// @details    memory map中没有间隙
//----------------------------------------------------------------------------
struct pmap
{
    uint64_t     count;          ///< memory map中的内存区域(Memory regions in the memory map)
    uint64_t     last_usable;    ///< 最后一个可用内存区域的尾部(End of last usable region)
    pmapregion_t region[1];      ///< An array of 'count' memory regions
};

/// ```c
/// struct pmap
/// {
///     uint64_t     count;          ///< memory map中的内存区域(Memory regions in the memory map)
///     uint64_t     last_usable;    ///< 最后一个可用内存区域的尾部(End of last usable region)
///     pmapregion_t region[1];      ///< An array of 'count' memory regions
/// };
/// ```
typedef struct pmap pmap_t;

//----------------------------------------------------------------------------
//  @function   pmap_init
/// @brief      使用BIOS在boot loading期间安装的数据来初始化物理内存映射
//----------------------------------------------------------------------------
void
pmap_init();

//----------------------------------------------------------------------------
//  @function   pmap_add
/// @brief      将一段内存区域添加到物理内存映射
/// @param[in]  addr    区域的起始地址
/// @param[in]  size    区域的大小
/// @param[in]  type    要添加的内存的类型
//----------------------------------------------------------------------------
void
pmap_add(uint64_t addr, uint64_t size, enum pmemtype type);

//----------------------------------------------------------------------------
//  @function   pmap
/// @brief      返回指向当前物理内存映射的指针
/// @returns    指向物理内存映射的指针
//----------------------------------------------------------------------------
const pmap_t *
pmap();
