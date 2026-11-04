/* ds_crash.c - see ds_crash.h. Compiled to nothing unless DS_CRASHLOG=1. */
#include "ds_crash.h"

#if DS_CRASHLOG

#include <stdio.h>
#include <nds.h>
#include <fat.h>
#include "ds_log.h"

static const char *s_path;
static int s_fat_ok;
static VoidFn s_default_handler;

static void ds_crash_handler(void)
{
    int i;

    DS_LOG("CRASH exception r0=%08lX pc=%08lX", (unsigned long)exceptionRegisters[0],
           (unsigned long)exceptionRegisters[15]);
    if (s_path && s_fat_ok) {
        FILE *f = fopen(s_path, "a");
        if (f) {
            fputs("CRASH: CPU exception\n", f);
            for (i = 0; i < 16; i++)
                fprintf(f, "r%d=%08lX%s", i, (unsigned long)exceptionRegisters[i],
                        (i % 4 == 3) ? "\n" : " ");
            fclose(f);
        }
    }
    if (s_default_handler)
        s_default_handler(); /* libnds crash screen */
}

void ds_crash_init(const char *log_path)
{
    s_path = log_path;
    if (log_path) {
        s_fat_ok = fatInitDefault() ? 1 : 0;
        if (!s_fat_ok)
            DS_LOG("CRASH: fatInitDefault failed, crash log only via DS_LOG");
    }
    defaultExceptionHandler();      /* installs the default handler in exceptionC */
    s_default_handler = exceptionC; /* remember it, then put ours in front */
    setExceptionHandler(ds_crash_handler);
}

#endif /* DS_CRASHLOG */
