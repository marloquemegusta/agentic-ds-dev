# Hardware workflow (performance, crashes, SD I/O)

The emulator cannot certify hardware performance. Budget: 560,190
`cpuGetTiming()` bus ticks per frame (33.514 MHz, 59.826 Hz); 33,514 ticks = 1 ms.
The ROM-side kit is `templates/dsagent/` (its README has the API).

## Setup (once per project)

1. Copy `templates/dsagent/` to `source/dsagent/`; wire `ds_crash_init`,
   `ds_perf_init/begin_frame/mark/end_frame`, `ds_replay_init` and
   `ds_input_scan()` (replaces `scanKeys()`) as shown in that README.
2. Add a variant to `project.json`:
   `"variants": {"perf": {"defines": ["DS_PERF=1", "DS_REPLAY=1", "DS_CRASHLOG=1"]}}`.
   Build with `build-project.ps1 -ProjectPath P -Variant perf`; the ROM is
   `<rom stem>-perf.nds`. Add `DS_AGENT_LOG` only for emulator runs.
3. Draw `REPLAY_DONE` on screen when `ds_replay_done()` is true.

## Replay data

1. Write a scenario that performs the situation to measure (idle, sustained
   movement, busiest scene) and run it once; the run writes `input_trace.json`.
   Scenarios using `poke` or `start_state` have `replay_safe: false` and are
   refused unless `--force`; do not force them for measurements.
2. Convert:
   - compiled in: `python tools/scenario_to_replay.py <out>/input_trace.json --format c --name g_replay -o source/replay_data.h`
     (or `--from-scenario s.json` for simple scenarios);
   - from the SD: `--format bin -o game.dsr`, copied to the card (path set in
     `ds_replay_config_t`; layout in `ds_replay.h`).
3. Replay frame k is what the k-th `ds_input_scan()` sees.

**The ROM must be deterministic** during the replay: logic driven by the frame
counter, constant `srand` seed, no `time()`, RTC, timers or SD contents in game
logic. The emulator fixes the RTC, the console does not; a non-deterministic ROM
measures a different run each time and the A/B comparison is void.

## Loop

1. Build the perf variant; `upload-rom.ps1 -DryRun`, then ask the user to confirm
   the upload (`SKILL.md`, DS upload). Tell them it is a perf variant.
2. The user opens the ROM and waits for `REPLAY_DONE`. No playing.
3. `fetch-device-log.ps1 -ProjectPath P -RemoteFile /<game>_perf.log` (add
   `-Delete` only after asking). Also fetch `/<game>_crash.log` if it crashed.
4. Read the log. Each window line:
   `PERF w=N frames=F avg=.. max=.. over=<frames > budget> slow=<frames spanning >1 vblank> name=avg/max ...`
   Judge by `over` and `slow`, then `max`, then `avg`; use the per-stage names to
   find the cost. `REPLAY_DONE frames=N` confirms the run completed.
5. Change one thing, rebuild the same variant, replay, compare against the
   previous log. Record device, ROM sha256/commit and which counter each number is.
6. Rebuild the default variant, run L0-L3, and tell the user which ROM is which
   before delivering it.

If hardware is unavailable, report "emulator-only, hardware unverified". The
emulator's own `g_ds_perf` counters (read via scenario `state`) are comparable
only between runs of the same scenario.

## Crash logs

`ds_crash_init(path)` writes `r0-r15` to the SD file and `DS_LOG`, then shows the
libnds exception screen. Map the PC to source with the ELF sidecar
(`.ds-game-dev/build/out/<stem>.elf`, same variant and commit as the uploaded ROM)
using `arm-none-eabi-addr2line` in the BlocksDS container, or reproduce in
`validate-gdb.ps1`. Without a working FAT the write is skipped silently.
