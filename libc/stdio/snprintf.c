//============================================================================
/// @file       snprintf.c
/// @brief      Write formatted output to a sized buffer.
//============================================================================

#include <libc/stdio.h>

int
snprintf(char *buf, size_t n, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = vsnprintf(buf, n, format, args);
    va_end(args);
    return result;
}
