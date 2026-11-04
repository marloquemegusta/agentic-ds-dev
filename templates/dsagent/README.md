# dsagent - ROM-side kit for agents

Plain C99, no float, libnds only. Copy this folder into the game as
`source/dsagent/` (add `arm9/source` to `INCLUDEDIRS`, which the skill's build
template already does) and `#include "dsagent/ds_perf.h"`. Every piece is
compiled out unless its flag is defined, so shipping builds pay nothing.
Flags go in the Makefile `DEFINES` (the skill build passes `DEFINES` through).

| Piece | Flag | What it gives |
| --- | --- | --- |
| `ds_log.h` | `-DDS_AGENT_LOG` | `DS_LOG(fmt, ...)` -> `nocashMessage()`; a patched DeSmuME writes it to `debug.log` |
| `ds_perf.[hc]` | `-DDS_PERF=1` | per-stage frame profiler, window report to SD + `DS_LOG`, RAM struct `g_ds_perf` |
| `ds_replay.[hc]` | `-DDS_REPLAY=1` | on-device input replay from a compiled-in table or a `.dsr` on SD |
| `ds_crash.[hc]` | `-DDS_CRASHLOG=1` | exception handler that logs registers to SD and `DS_LOG` |

`project/include/ds_log.h` in the project template is a copy of `ds_log.h`.

## Integration
```c
#include "dsagent/ds_perf.h"
#include "dsagent/ds_replay.h"
#include "dsagent/ds_crash.h"

ds_crash_init("/mygame_crash.log");
ds_perf_init("/mygame_perf.log", 120, stage_names, 3);   // window of 120 frames
ds_replay_config_t cfg = { g_replay, G_REPLAY_COUNT, "/mygame.dsr", "/mygame_perf.log",
                           DS_REPLAY_DONE_PASSTHROUGH };
ds_replay_init(&cfg);
for (;;) {
    swiWaitForVBlank();
    ds_perf_begin_frame();            // right after the vblank wait
    ds_input_scan();                  // replaces scanKeys()
    if (ds_keys_down() & KEY_A) ...   // ds_keys_held/down/up, ds_touch_read(&t)
    update(); ds_perf_mark(0);        // ticks since the previous mark -> stage 0
    draw();   ds_perf_mark(1);
    ds_perf_end_frame();              // before the next vblank wait
}
```
Without the flags `ds_input_scan()` and friends are inline pass-throughs to
`scanKeys()/keysHeld()/touchRead()` and the perf/crash calls vanish.

## Perf
Units are bus ticks: 33514 = 1 ms, 560190 = one 59.826 Hz frame (the budget).
Per window it logs `PERF w=N frames=F avg=.. max=.. over=<frames > budget>
slow=<frames whose period spanned >1 vblank> name=avg/max ...`. It uses timers
2+3 (`DS_PERF_TIMER`) and the VBlank IRQ. DeSmuME numbers are only for A/B
comparison; 60 FPS is certified on the console. The emulator reads `g_ds_perf`
(magic `PERF`, 32-bit words, see the struct) through scenario `state`.

## Replay
Generate data with `tools/scenario_to_replay.py`: `input_trace.json` (from a
runner run) or `--from-scenario s.json`, to `--format c --name g_replay`
(compiled in) or `--format bin -o game.dsr` (copy to the SD). `.dsr` layout is
in `ds_replay.h`. Replay frame k is what the k-th `ds_input_scan()` sees.
**The ROM must be deterministic**: logic driven by the frame counter, constant
`srand`, no RTC/timers/SD contents in game logic; otherwise a replay measures
something different every run. Mirror `g_ds_replay` (magic `RPLY`: active, done,
error, frame, total_frames). On the last frame it logs `REPLAY_DONE frames=N`,
sets `done`, appends the line to `done_log_path` and then passes real input
through, loops or powers off (`DS_REPLAY_DONE_*`). The game should draw
"REPLAY_DONE" on screen when `ds_replay_done()` so the user sees it finished.
If the data cannot be loaded it logs `REPLAY_ERROR`, sets `error` and keeps real input.

## Crash
`ds_crash_init(path)` logs `r0-r15` to the SD file, then runs the libnds default
screen. If FAT is unavailable (emulator, no card) it only logs through `DS_LOG`.

## Hardware workflow
1. Build the variant: `DEFINES=-DDS_PERF=1 -DDS_REPLAY=1 -DDS_CRASHLOG=1` (no `DS_AGENT_LOG` needed on console).
2. Upload with the skill's upload script (needs the user's confirmation).
3. The user only opens the ROM and waits until the screen shows `REPLAY_DONE`; no playing.
4. Fetch `/mygame_perf.log` (and `/mygame_crash.log` if it crashed) with the
   fetch-device-log script and read average, max, `over` and `slow` per window.
5. Rebuild without the flags before delivering the normal ROM.
SD writes need a working FAT (`fatInitDefault`); a failure is logged once and never crashes.
