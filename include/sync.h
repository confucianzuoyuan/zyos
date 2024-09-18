#pragma once

#include <stdbool.h>

#include "atomic.h"

typedef volatile uint64_t spinlock_t;

typedef volatile struct
{
    atomic64_t readers;
    spinlock_t rd_lock;
    spinlock_t wr_lock;
} rwspin_lock_t;

void spin_lock(volatile spinlock_t *lock);
void spin_unlock(volatile spinlock_t *lock);
bool spin_try_lock(volatile spinlock_t *lock);
