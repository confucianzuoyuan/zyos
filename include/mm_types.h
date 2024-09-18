#pragma once

#include <stdint.h>
#include <stddef.h>

#include "limits.h"
#include "linked.h"
#include "addr.h"

typedef uint64_t pte_t;

struct page_table
{
    pte_t pages[512];
} __attribute__((packed, aligned(PAGE_SIZE)));

struct mmap_region
{
    uintptr_t base;
    size_t len;
    enum mmap_region_flags
    {
        MMAP_NONE,
        MMAP_NOMAP
    } flags;
};

struct mmap_type
{
    uint32_t count;
    struct mmap_region *regions;
};

struct mmap
{
    physaddr_t highest_mapped;
    struct mmap_type available;
    struct mmap_type reserved;
};

struct zone
{
    struct slist_node list;
    physaddr_t pa_start;
    size_t len;
    struct page *free_lists[MAX_ORDER];
};
