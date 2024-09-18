//============================================================================
/// @file       strlcpy.c
/// @brief      Copies one string to another.
//============================================================================

#include <core.h>

size_t
strlcpy(char *dst, const char *src, size_t dstsize)
{
    char       *d  = dst;
    const char *dt = dst + dstsize - 1;
    const char *s  = src;
    while (d < dt && *s) {
        *d++ = *s++;
    }

    if (dstsize > 0) {
        *d = 0;
    }

    return (size_t)(d - dst);
}
