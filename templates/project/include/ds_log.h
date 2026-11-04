/* ds_log.h - agent-readable debug log for Nintendo DS (plain C99, no float).
 *
 * DS_LOG(fmt, ...) formats into a static buffer and sends it to the no$gba
 * debug channel with nocashMessage(). A patched DeSmuME captures those
 * messages into debug.log so an agent can read them after a headless run.
 *
 * Define DS_AGENT_LOG (e.g. -DDS_AGENT_LOG in the Makefile DEFINES) to enable.
 * Without it DS_LOG compiles to nothing (arguments are not evaluated).
 */
#ifndef DS_LOG_H
#define DS_LOG_H

#ifdef DS_AGENT_LOG
#include <stdarg.h>
#include <stdio.h>
#include <nds/debug.h>

#ifndef DS_LOG_BUFFER_SIZE
#define DS_LOG_BUFFER_SIZE 192
#endif

static inline void ds_log_printf(const char *fmt, ...)
{
    static char buf[DS_LOG_BUFFER_SIZE];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    nocashMessage(buf);
}
#define DS_LOG(...) ds_log_printf(__VA_ARGS__)
#else
#define DS_LOG(...) ((void)0)
#endif

#endif /* DS_LOG_H */
