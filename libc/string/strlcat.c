//============================================================================
/// @file       strlcat.c
/// @brief      将一个字符串拼接到另一个字符串的末尾
//============================================================================

#include <core.h>

size_t
strlcat(char *dst, const char *src, size_t dstsize)
{
    char       *d  = dst;
    const char *dt = dst + dstsize - 1;
    while (d < dt && *d) {
        d++;
    }

    const char *s = src;
    while (d < dt && *s) {
        *d++ = *s++;
    }

    if (dstsize > 0) {
        *d = 0;
    }

    return (size_t)(d - dst);
}
