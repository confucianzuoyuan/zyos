#pragma once

#include <stdint.h>

typedef volatile struct {
    volatile uint32_t var;
} atomic32_t;

typedef volatile struct {
    volatile uint64_t var;
} atomic64_t;

typedef atomic32_t kref_t;

static inline uint32_t atomic_read32(atomic32_t *a)
{
    return __atomic_load_n(&a->var, __ATOMIC_SEQ_CST);
}