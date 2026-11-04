/* ds_replay.c - see ds_replay.h. .dsr layout is documented there and in
 * tools/scenario_to_replay.py: "DSR1", u32 run_count, then 12-byte runs
 * { u32 count; u16 keys; u8 touching; u8 pad; u16 x; u16 y } little endian. */
#include "ds_replay.h"

volatile ds_replay_state_t g_ds_replay;

#if DS_REPLAY

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fat.h>
#include "ds_log.h"

static const ds_replay_run_t *s_runs;
static uint32_t s_run_count;
static int s_owns_runs;           /* s_runs was malloc'ed from a .dsr */
static ds_replay_config_t s_cfg;
static uint32_t s_run_idx;
static uint32_t s_run_left;
static uint32_t s_held, s_down, s_up, s_prev;
static touchPosition s_touch;
static int s_marker_logged;

static uint32_t ds_replay_total(const ds_replay_run_t *r, uint32_t n)
{
    uint32_t total = 0, i;
    for (i = 0; i < n; i++)
        total += r[i].count;
    return total;
}

/* Little-endian field readers: the file is LE, the ARM9 is LE too, but keep
 * the parse independent from alignment. */
static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static bool ds_replay_load_file(const char *path)
{
    FILE *f;
    uint8_t head[8];
    uint8_t rec[12];
    uint32_t n, i;
    ds_replay_run_t *runs;

    if (!fatInitDefault()) {
        DS_LOG("REPLAY_ERROR fatInitDefault failed");
        return false;
    }
    f = fopen(path, "rb");
    if (!f) {
        DS_LOG("REPLAY_ERROR cannot open %s", path);
        return false;
    }
    if (fread(head, 1, 8, f) != 8 || memcmp(head, "DSR1", 4) != 0) {
        DS_LOG("REPLAY_ERROR bad header in %s", path);
        fclose(f);
        g_ds_replay.error = 2;
        return false;
    }
    n = rd32(head + 4);
    if (n == 0 || n > 1000000u || !(runs = (ds_replay_run_t *)malloc(n * sizeof *runs))) {
        DS_LOG("REPLAY_ERROR bad run count %lu", (unsigned long)n);
        fclose(f);
        g_ds_replay.error = 2;
        return false;
    }
    for (i = 0; i < n; i++) {
        if (fread(rec, 1, 12, f) != 12) {
            DS_LOG("REPLAY_ERROR truncated at run %lu", (unsigned long)i);
            free(runs);
            fclose(f);
            g_ds_replay.error = 2;
            return false;
        }
        runs[i].count = rd32(rec);
        runs[i].keys = rd16(rec + 4);
        runs[i].touching = rec[6];
        runs[i].pad = 0;
        runs[i].x = rd16(rec + 8);
        runs[i].y = rd16(rec + 10);
    }
    fclose(f);
    s_runs = runs;
    s_run_count = n;
    s_owns_runs = 1;
    return true;
}

static void ds_replay_rewind(void)
{
    s_run_idx = 0;
    s_run_left = s_run_count ? s_runs[0].count : 0;
    g_ds_replay.frame = 0;
}

bool ds_replay_init(const ds_replay_config_t *cfg)
{
    memset((void *)&g_ds_replay, 0, sizeof g_ds_replay);
    g_ds_replay.magic = DS_REPLAY_MAGIC;
    memset(&s_cfg, 0, sizeof s_cfg);
    if (cfg)
        s_cfg = *cfg;
    s_runs = NULL;
    s_run_count = 0;
    s_prev = s_held = s_down = s_up = 0;
    s_marker_logged = 0;

    if (s_cfg.dsr_path && ds_replay_load_file(s_cfg.dsr_path)) {
        /* loaded from SD */
    } else if (s_cfg.table && s_cfg.table_count) {
        s_runs = s_cfg.table;
        s_run_count = s_cfg.table_count;
        s_owns_runs = 0;
    }
    if (!s_runs) {
        if (!g_ds_replay.error)
            g_ds_replay.error = 1;
        DS_LOG("REPLAY_ERROR no replay data, using real input");
        return false;
    }
    g_ds_replay.total_frames = ds_replay_total(s_runs, s_run_count);
    g_ds_replay.active = 1;
    ds_replay_rewind();
    DS_LOG("REPLAY_START frames=%lu runs=%lu", (unsigned long)g_ds_replay.total_frames,
           (unsigned long)s_run_count);
    return true;
}

static void ds_replay_finish(void)
{
    g_ds_replay.done = 1;
    if (!s_marker_logged) {
        s_marker_logged = 1;
        DS_LOG("REPLAY_DONE frames=%lu", (unsigned long)g_ds_replay.total_frames);
        if (s_cfg.done_log_path && fatInitDefault()) {
            FILE *f = fopen(s_cfg.done_log_path, "a");
            if (f) {
                fprintf(f, "REPLAY_DONE frames=%lu\n", (unsigned long)g_ds_replay.total_frames);
                fclose(f);
            }
        }
    }
    if (s_cfg.on_done == DS_REPLAY_DONE_POWEROFF)
        systemShutDown();
}

void ds_input_scan(void)
{
    scanKeys(); /* keep libnds' own state fresh (real input after the replay) */

    if (g_ds_replay.active && !(g_ds_replay.done && s_cfg.on_done != DS_REPLAY_DONE_LOOP)) {
        const ds_replay_run_t *r;

        if (g_ds_replay.done) { /* LOOP: start over */
            g_ds_replay.done = 0;
            ds_replay_rewind();
        }
        while (s_run_left == 0 && s_run_idx + 1 < s_run_count) {
            s_run_idx++;
            s_run_left = s_runs[s_run_idx].count;
        }
        if (s_run_left > 0) {
            r = &s_runs[s_run_idx];
            s_held = r->keys & 0x0FFFu;
            s_touch.px = 0;
            s_touch.py = 0;
            if (r->touching) {
                s_held |= KEY_TOUCH;
                s_touch.px = r->x;
                s_touch.py = r->y;
            }
            s_down = s_held & ~s_prev;
            s_up = s_prev & ~s_held;
            s_prev = s_held;
            s_run_left--;
            g_ds_replay.frame++;
            if (s_run_left == 0 && s_run_idx + 1 >= s_run_count)
                ds_replay_finish();
            return;
        }
        ds_replay_finish();
    }
    /* pass-through */
    s_held = keysHeld();
    s_down = keysDown();
    s_up = keysUp();
    s_prev = s_held;
}

uint32_t ds_keys_held(void) { return s_held; }
uint32_t ds_keys_down(void) { return s_down; }
uint32_t ds_keys_up(void) { return s_up; }

void ds_touch_read(touchPosition *touch)
{
    if (g_ds_replay.active && !(g_ds_replay.done && s_cfg.on_done != DS_REPLAY_DONE_LOOP)) {
        memset(touch, 0, sizeof *touch);
        touch->px = s_touch.px;
        touch->py = s_touch.py;
        return;
    }
    touchRead(touch);
}

#endif /* DS_REPLAY */
