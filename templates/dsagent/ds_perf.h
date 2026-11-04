/* ds_perf.h - per-stage frame profiler for Nintendo DS (plain C99, no float).
 *
 * Units are ARM9 bus ticks from cpuGetTiming():
 *   33514 ticks = 1 ms, 560190 ticks = one frame at 59.826 Hz (the budget).
 * DeSmuME is only good for A/B comparisons; certify 60 FPS on real hardware.
 *
 * Enable with -DDS_PERF=1. Otherwise every call below compiles to nothing.
 *
 * Usage:
 *   ds_perf_init("/mygame_perf.log", 120, names, 3);   // once at start
 *   while (1) {
 *       swiWaitForVBlank();
 *       ds_perf_begin_frame();         // right after the vblank wait
 *       update();   ds_perf_mark(0);   // ticks since previous mark -> stage 0
 *       render();   ds_perf_mark(1);
 *       ds_perf_end_frame();           // BEFORE the next vblank wait
 *   }
 * Per window of N frames it records average and max ticks per stage and for
 * the whole frame, frames over budget, and "slow" frames: frames whose period
 * (begin_frame to begin_frame) spanned more than one vblank (a missed 60 FPS).
 * One text line per window is appended to the SD file and sent to DS_LOG.
 * SD failure (no card, emulator) is logged once and never crashes.
 */
#ifndef DS_PERF_H
#define DS_PERF_H

#include <stdint.h>

#define DS_PERF_BUDGET_TICKS 560190u
#define DS_PERF_TICKS_PER_MS 33514u
#define DS_PERF_MAX_STAGES   16

#ifndef DS_PERF
#define DS_PERF 0
#endif

#if DS_PERF

#define DS_PERF_MAGIC 0x46524550u /* bytes 'P','E','R','F' (little endian) */

/* Timer pair used by cpuStartTiming (uses DS_PERF_TIMER and DS_PERF_TIMER+1). */
#ifndef DS_PERF_TIMER
#define DS_PERF_TIMER 2
#endif

/* RAM mirror readable by the emulator runner (symbol g_ds_perf). All fields
 * are 32-bit words. "last_*" hold the most recent finished window. */
typedef struct {
    uint32_t magic;          /* DS_PERF_MAGIC */
    uint32_t window_frames;
    uint32_t windows_done;
    uint32_t frames_total;
    uint32_t last_frames;
    uint32_t last_avg;       /* avg work ticks per frame (begin..end) */
    uint32_t last_max;
    uint32_t last_over_budget;
    uint32_t last_slow_frames;
    uint32_t last_stage_avg[DS_PERF_MAX_STAGES];
    uint32_t last_stage_max[DS_PERF_MAX_STAGES];
    /* running window */
    uint32_t cur_frames;
    uint32_t cur_sum;
    uint32_t cur_max;
    uint32_t cur_over_budget;
    uint32_t cur_slow_frames;
    uint32_t cur_stage_sum[DS_PERF_MAX_STAGES];
    uint32_t cur_stage_max[DS_PERF_MAX_STAGES];
    /* internals */
    uint32_t vblank_count;   /* incremented by the VBlank IRQ */
    uint32_t sd_ok;          /* 1 once a window line was written to the SD */
} ds_perf_t;

extern volatile ds_perf_t g_ds_perf;

/* log_path: file on the SD (e.g. "/game_perf.log"), NULL = DS_LOG only.
 * window_frames: frames per report line (0 = 120).
 * stage_names/stage_count: optional labels (may be NULL/0).
 * Starts cpuStartTiming(DS_PERF_TIMER) and hooks the VBlank IRQ to count
 * vblanks. Calls fatInitDefault() when log_path is set. */
void ds_perf_init(const char *log_path, uint32_t window_frames,
                  const char *const *stage_names, int stage_count);
void ds_perf_begin_frame(void);
void ds_perf_mark(int stage_id);
void ds_perf_end_frame(void);

#else /* !DS_PERF */

#define ds_perf_init(path, window, names, count) ((void)sizeof(names))
#define ds_perf_begin_frame()                    ((void)0)
#define ds_perf_mark(stage_id)                   ((void)0)
#define ds_perf_end_frame()                      ((void)0)

#endif
#endif /* DS_PERF_H */
