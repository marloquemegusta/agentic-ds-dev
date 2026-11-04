/* ds_crash.h - crash log to SD for Nintendo DS (plain C99, no float).
 *
 * With -DDS_CRASHLOG=1, ds_crash_init("/mygame_crash.log") installs an
 * exception handler. On a CPU exception it appends the registers r0-r15 and a
 * message to that file on the SD and to DS_LOG, then chains to the libnds
 * default handler, which shows the usual crash screen. Without the flag every
 * call compiles to nothing. If the SD cannot be opened (no card, emulator) it
 * only logs an error through DS_LOG.
 * Call ds_crash_init() once at startup, after fatInitDefault() if the game
 * already calls it (it calls it itself otherwise).
 */
#ifndef DS_CRASH_H
#define DS_CRASH_H

#ifndef DS_CRASHLOG
#define DS_CRASHLOG 0
#endif

#if DS_CRASHLOG
void ds_crash_init(const char *log_path);
#else
#define ds_crash_init(log_path) ((void)0)
#endif

#endif /* DS_CRASH_H */
