//============================================================================
/// @file       strlen.c
/// @brief      返回字符串的长度
//============================================================================

#include <core.h>

size_t
strlen(const char *str)
{
    size_t len = 0;
    for (; str[len]; ++len) {
        // do nothing
    }
    return len;
}
