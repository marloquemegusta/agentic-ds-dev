/* ds_replay.h - on-device input replay for Nintendo DS (plain C99, no float).
 *
 * The game calls ds_input_scan() once per frame INSTEAD of scanKeys() and reads
 * input through ds_keys_held()/ds_keys_down()/ds_keys_up()/ds_touch_read().
 * Without -DDS_REPLAY=1 these are thin pass-throughs to libnds. With it, the
 * input comes from a recorded run so hardware measurements need no human.
 *
 * DETERMINISM: a replay only means something if the ROM is deterministic.
 * Drive logic from the frame counter, not timers/RTC; seed rand() with a
 * constant; do not depend on SD contents or uninitialised memory.
 *
 * Replay data = run-length records, same layout as the runner input trace
 * (tools/scenario_to_replay.py generates them):
 *   count frames, keys (libnds KEY_* bits: 0=A 1=B 2=SELECT 3=START 4=RIGHT
 *   5=LEFT 6=UP 7=DOWN 8=R 9=L 10=X 11=Y), touching flag, x, y.
 * Binary .dsr file, little endian:
 *   "DSR1" | u32 run_count | run_count * { u32 count; u16 keys; u8 touching;
 *   u8 pad; u16 x; u16 y }   (12 bytes per run, same as ds_replay_run_t)
 * Replay frame k is what the k-th ds_input_scan() call after start returns.
 */
#ifndef DS_REPLAY_H
#define DS_REPLAY_H

#include <stdint.h>
#include <stdbool.h>
#include <nds.h>

#ifndef DS_REPLAY
#define DS_REPLAY 0
#endif

typedef struct {
    uint32_t count;     /* frames this run lasts */
    uint16_t keys;      /* held buttons, KEY_* bits 0..11 */
    uint8_t  touching;  /* 1 = stylus down */
    uint8_t  pad;
    uint16_t x;         /* touch px 0..255 */
    uint16_t y;         /* touch py 0..191 */
} ds_replay_run_t;

enum {
    DS_REPLAY_DONE_PASSTHROUGH = 0, /* after the last frame use real input */
    DS_REPLAY_DONE_LOOP        = 1, /* restart from frame 0 (marker logged once) */
    DS_REPLAY_DONE_POWEROFF    = 2  /* systemShutDown() after logging */
};

typedef struct {
    const ds_replay_run_t *table;  /* compiled-in replay, or NULL */
    uint32_t table_count;          /* number of runs in table */
    const char *dsr_path;          /* .dsr on the SD (preferred when set and loadable) */
    const char *done_log_path;     /* SD file that gets "REPLAY_DONE frames=N", or NULL */
    int on_done;                   /* DS_REPLAY_DONE_* */
} ds_replay_config_t;

/* RAM mirror readable by the emulator runner (symbol g_ds_replay). */
#define DS_REPLAY_MAGIC 0x594C5052u /* bytes 'R','P','L','Y' (little endian) */
typedef struct {
    uint32_t magic;
    uint32_t active;        /* 1 while replaying */
    uint32_t done;          /* 1 once the last frame has been consumed */
    uint32_t error;         /* 0 ok, 1 no data/load failed, 2 bad file */
    uint32_t frame;         /* frames consumed so far */
    uint32_t total_frames;
} ds_replay_state_t;
extern volatile ds_replay_state_t g_ds_replay;

#if DS_REPLAY
/* Configure and start the replay. Call once before the first ds_input_scan().
 * Never crashes: if the data cannot be loaded, error is set, REPLAY_ERROR is
 * logged and the game keeps using real input. Returns true when replaying. */
bool ds_replay_init(const ds_replay_config_t *cfg);
void ds_input_scan(void);
uint32_t ds_keys_held(void);
uint32_t ds_keys_down(void);
uint32_t ds_keys_up(void);
void ds_touch_read(touchPosition *touch);
static inline bool ds_replay_done(void) { return g_ds_replay.done != 0; }
#else
static inline bool ds_replay_init(const ds_replay_config_t *cfg) { (void)cfg; return false; }
static inline void ds_input_scan(void) { scanKeys(); }
static inline uint32_t ds_keys_held(void) { return keysHeld(); }
static inline uint32_t ds_keys_down(void) { return keysDown(); }
static inline uint32_t ds_keys_up(void) { return keysUp(); }
static inline void ds_touch_read(touchPosition *touch) { touchRead(touch); }
static inline bool ds_replay_done(void) { return false; }
#endif

#endif /* DS_REPLAY_H */
