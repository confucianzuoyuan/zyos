//============================================================================
/// @file   core.h
/// @brief  Core include file.
//============================================================================

#pragma once

// Standard headers included by all code in the project.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

//----------------------------------------------------------------------------
// Macros
//----------------------------------------------------------------------------

/// Force a function to be inline, even in debug mode.
#define __forceinline        inline __attribute__((always_inline))

/// Return the number of elements in the C array.
#define arrsize(x)           ((int)(sizeof(x) / sizeof(x[0])))

/// Generic min/max routines
#define min(a, b)            ((a) < (b) ? (a) : (b))
#define max(a, b)            ((a) > (b) ? (a) : (b))

// Division macros, rounding (a/b) up or down
#define div_dn(a, b)         ((a) / (b))
#define div_up(a, b)         (((a) + (b) - 1) / (b))

// Alignment macros, align a to the nearest multiple of b.
#define align_dn(a, b)       (div_dn(a, b) * (b))
#define align_up(a, b)       (div_up(a, b) * (b))

// Typed pointer arithmetic. Pointer p +/- offset o, cast to t*.
#define ptr_add(t, p, o)     ((t *)((uint8_t *)(p) + (o)))
#define ptr_sub(t, p, o)     ((t *)((uint8_t *)(p) - (o)))

/// Compile-time static assertion
#define STATIC_ASSERT(a, b)  _Static_assert(a, b)

/// Forced structure packing (use only when absolutely necessary)
#define PACKSTRUCT           __attribute__((packed, aligned(1)))
