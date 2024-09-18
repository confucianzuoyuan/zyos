//============================================================================
/// @file       strcmp.c
/// @brief      比较两个字符串
//============================================================================

#include <core.h>

int
strcmp(const char *str1, const char *str2)
{
    int i = 0;
    for (; str1[i] && str2[i]; i++) {
        if (str1[i] == str2[i])
            continue;
        return (int)str1[i] - (int)str2[i];
    }
    return (int)str1[i] - (int)str2[i];
}
