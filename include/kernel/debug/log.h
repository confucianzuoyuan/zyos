//============================================================================
/// @file       log.c
/// @brief      Kernel logging module.
//============================================================================

#pragma once

#include <core.h>
#include <stdarg.h>

//----------------------------------------------------------------------------
//  @enum       loglevel_t
/// @brief      A log level indicates the importance of a logged message.
//----------------------------------------------------------------------------
typedef enum loglevel
{
    LOG_CRIT,       ///< Critical error, occurs just prior to crashing
    LOG_ERR,        ///< Serious error in software or hardware
    LOG_WARNING,    ///< Warning about a significant issue
    LOG_INFO,       ///< Informational message
    LOG_DEBUG,      ///< Used for kernel debugging
    LOG_DEFAULT,    ///< Default kernel logging level
} loglevel_t;

//----------------------------------------------------------------------------
//  @typedef    log_callback
/// @brief      Callback handler called when a message is logged.
/// @param[in]  level   The log level of the message.
/// @param[in]  msg     The null-terminated string containing the logged
///                     message.
//----------------------------------------------------------------------------
typedef void (*log_callback)(loglevel_t level, const char *msg);

//----------------------------------------------------------------------------
//  @function   log_addcallback
/// @brief      Add a callback handler for log messages.
/// @param[in]  maxlevel    Issue callback for log calls up to and including
///                         this log level.
/// @param[in]  cb          The callback function
//----------------------------------------------------------------------------
void
log_addcallback(loglevel_t maxlevel, log_callback cb);

//----------------------------------------------------------------------------
//  @function   log_removecallback
/// @brief      Remove a callback handler for log messages.
/// @param[in]  cb          The callback function
//----------------------------------------------------------------------------
void
log_removecallback(log_callback cb);

//----------------------------------------------------------------------------
//  @function   log
/// @brief      Log a message to the kernel log buffer.
/// @param[in]  level   The importance level of the logged message.
/// @param[in]  str     The null-terminated string to be printed.
//----------------------------------------------------------------------------
void
log(loglevel_t level, const char *str);

//----------------------------------------------------------------------------
//  @function   logf
/// @brief      Log a printf-formatted message to the kernel log buffer.
/// @param[in]  level   The importance level of the logged message.
/// @param[in]  format  The null-terminated format string used to format the
///                     text to be printed.
/// @param[in]  ...     Variable arguments list to be initialized with
///                     va_start.
//----------------------------------------------------------------------------
void
logf(loglevel_t level, const char *format, ...);

//----------------------------------------------------------------------------
//  @function   logvf
/// @brief      Log a printf-formatted string using a variable argument list.
/// @param[in]  level   The importance level of the logged message.
/// @param[in]  format  The null-terminated format string used to format the
///                     text to be printed.
/// @param[in]  args    Variable arguments list to be initialized with
///                     va_start.
//----------------------------------------------------------------------------
void
logvf(loglevel_t level, const char *format, va_list args);
