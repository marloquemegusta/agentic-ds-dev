/* ds_perf.c - see ds_perf.h. Compiled to nothing unless DS_PERF=1. */
#include "ds_perf.h"

#if DS_PERF

#include <stdio.h>
#include <string.h>
#include <nds.h>
#include <fat.h>
#include "ds_log.h"

volatile ds_perf_t g_ds_perf;

static const char *s_path;
static const char *const *s_names;
static int s_stage_count;
static int s_fat_tried;
static int s_fat_ok;
static uint32_t s_frame_start;
static uint32_t s_last_mark;
static uint32_t s_last_begin_vbl;
static int s_have_prev;     /* a previous begin_frame exists */
static int s_skip_period;   /* ignore the next period (SD write happened) */
static int s_max_stage_used = -1;

static void ds_perf_vblank(void)
{
    g_ds_perf.vblank_count++;
}

void ds_perf_init(const char *log_path, uint32_t window_frames,
                  const char *const *stage_names, int stage_count)
{
    memset((void *)&g_ds_perf, 0, sizeof g_ds_perf);
    g_ds_perf.magic = DS_PERF_MAGIC;
    g_ds_perf.window_frames = window_frames ? window_frames : 120u;
    s_path = log_path;
    s_names = stage_names;
    s_stage_count = stage_count > DS_PERF_MAX_STAGES ? DS_PERF_MAX_STAGES : stage_count;
    s_have_prev = 0;
    s_skip_period = 0;
    s_max_stage_used = -1;

    if (log_path && !s_fat_tried) {
        s_fat_tried = 1;
        s_fat_ok = fatInitDefault() ? 1 : 0;
        if (!s_fat_ok)
            DS_LOG("PERF: fatInitDefault failed, log only via DS_LOG");
    }

    cpuStartTiming(DS_PERF_TIMER);
    irqSet(IRQ_VBLANK, ds_perf_vblank);
    irqEnable(IRQ_VBLANK);
}

void ds_perf_begin_frame(void)
{
    uint32_t now = cpuGetTiming();
    uint32_t vbl = g_ds_perf.vblank_count;

    if (s_have_prev && !s_skip_period && (vbl - s_last_begin_vbl) > 1u)
        g_ds_perf.cur_slow_frames++;
    s_skip_period = 0;
    s_have_prev = 1;
    s_last_begin_vbl = vbl;
    s_frame_start = now;
    s_last_mark = now;
}

void ds_perf_mark(int stage_id)
{
    uint32_t now = cpuGetTiming();
    uint32_t d = now - s_last_mark;

    s_last_mark = now;
    if ((unsigned)stage_id >= DS_PERF_MAX_STAGES)
        return;
    if (stage_id > s_max_stage_used)
        s_max_stage_used = stage_id;
    g_ds_perf.cur_stage_sum[stage_id] += d;
    if (d > g_ds_perf.cur_stage_max[stage_id])
        g_ds_perf.cur_stage_max[stage_id] = d;
}

static void ds_perf_emit(void)
{
    char line[320];
    int n, i;
    volatile ds_perf_t *p = &g_ds_perf;

    n = snprintf(line, sizeof line,
                 "PERF w=%lu frames=%lu avg=%lu max=%lu over=%lu slow=%lu",
                 (unsigned long)p->windows_done, (unsigned long)p->last_frames,
                 (unsigned long)p->last_avg, (unsigned long)p->last_max,
                 (unsigned long)p->last_over_budget, (unsigned long)p->last_slow_frames);
    for (i = 0; i <= s_max_stage_used && n > 0 && n < (int)sizeof line - 40; i++) {
        const char *name = (i < s_stage_count && s_names && s_names[i]) ? s_names[i] : NULL;
        if (name)
            n += snprintf(line + n, sizeof line - n, " %s=%lu/%lu", name,
                          (unsigned long)p->last_stage_avg[i], (unsigned long)p->last_stage_max[i]);
        else
            n += snprintf(line + n, sizeof line - n, " s%d=%lu/%lu", i,
                          (unsigned long)p->last_stage_avg[i], (unsigned long)p->last_stage_max[i]);
    }
    DS_LOG("%s", line);

    if (s_path && s_fat_ok) {
        FILE *f = fopen(s_path, "a");
        if (f) {
            fputs(line, f);
            fputc('\n', f);
            fclose(f);
            p->sd_ok = 1;
        } else if (!p->sd_ok) {
            DS_LOG("PERF: cannot open %s", s_path);
        }
    }
    s_skip_period = 1; /* the SD write must not count as a missed frame */
}

void ds_perf_end_frame(void)
{
    uint32_t now = cpuGetTiming();
    uint32_t total = now - s_frame_start;
    volatile ds_perf_t *p = &g_ds_perf;
    int i;

    /* time after the last mark belongs to no stage; total still covers it */
    p->cur_frames++;
    p->frames_total++;
    p->cur_sum += total;
    if (total > p->cur_max)
        p->cur_max = total;
    if (total > DS_PERF_BUDGET_TICKS)
        p->cur_over_budget++;

    if (p->cur_frames >= p->window_frames) {
        uint32_t frames = p->cur_frames;
        p->last_frames = frames;
        p->last_avg = p->cur_sum / frames;
        p->last_max = p->cur_max;
        p->last_over_budget = p->cur_over_budget;
        p->last_slow_frames = p->cur_slow_frames;
        for (i = 0; i < DS_PERF_MAX_STAGES; i++) {
            p->last_stage_avg[i] = p->cur_stage_sum[i] / frames;
            p->last_stage_max[i] = p->cur_stage_max[i];
            p->cur_stage_sum[i] = 0;
            p->cur_stage_max[i] = 0;
        }
        p->cur_frames = 0;
        p->cur_sum = 0;
        p->cur_max = 0;
        p->cur_over_budget = 0;
        p->cur_slow_frames = 0;
        p->windows_done++;
        ds_perf_emit();
    }
}

#endif /* DS_PERF */
