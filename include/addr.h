#pragma once

#include <stdint.h>

#include "linked.h"
#include "limits.h"
#include "atomic.h"
#include "sync.h"

typedef uintptr_t physaddr_t;
typedef void *virtaddr_t;
typedef void *kernaddr_t;

struct page
{
    struct
    {
        struct dlist_node list;
        int8_t order;
    };
    struct
    {
        kref_t refcount;
        spinlock_t lock;
    };
};

extern struct page *const page_data;

static inline physaddr_t virt_to_phys(virtaddr_t v)
{
    if (v == NULL)
        return (physaddr_t)NULL;
    return (physaddr_t)v - KERNEL_LOGICAL_BASE;
}

static inline virtaddr_t phys_to_virt(physaddr_t p)
{
    if (p == (physaddr_t)NULL)
        return NULL;
    return (virtaddr_t)(p + KERNEL_LOGICAL_BASE);
}
