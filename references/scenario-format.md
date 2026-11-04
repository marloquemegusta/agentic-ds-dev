# Scenario JSON format

Used by `scripts/run-scenario.ps1` / `runtime/run_scenario.py`. Files may be UTF-8
with or without BOM. The whole scenario is validated before the emulator starts;
any problem is reported at once and ends the scenario as `ERROR` (exit 2).

## Top level

Unknown top-level keys are rejected.

| key | meaning |
| --- | --- |
| `steps` (required) | List of step objects, run in order. |
| `assertions` | `screen_changes` (or one `screen_changed`) and `state_changes`. |
| `state` | Memory sampling config (below). |
| `evidence_only` | `true` = the scenario only produces captures. Without assertions it then PASSes with warning `evidence_only`; without it, no assertions = `NO_ASSERTIONS` (exit 1). |
| `start_state` | Name of a savestate loaded right after opening the ROM (below). |
| `suite` | `false` = skipped when more than one scenario is run together. |
| `render_all_frames` | `true` = never skip GPU rendering (below). |
| `name`, `description`, `comment`, `note`, `tags`, `rom` | Annotations. |

A `wait_until` step counts as an assertion (its timeout fails the scenario).

## Steps (all keys optional, applied in this order)

Unknown step keys are rejected, as are combinations that silently do nothing:
`tap`/`touch`/`drag`/`tap_grid` together with `release`, `tap` with `touch`, and
`button_down` + `button_up` of the same button in one step.

| key | meaning |
| --- | --- |
| `button_down` / `button_up` | Press / release one button (A B SELECT START RIGHT LEFT UP DOWN R L X Y). Other held buttons stay held. |
| `release_flush_frames` | With `button_up`: extra frames right after the release (default 0). |
| `tap` (alias `touch`) | `{x, y}` start touching the lower screen (stays until `release`). |
| `tap_grid` | `{count, columns, x, y, spacing_x, spacing_y, hold, hold_frames, gap_frames}` taps `count` points row by row from `(x, y)`; each tap holds the `hold` buttons for `hold_frames` (default 2), then releases for `gap_frames` (default 1). |
| `drag` | `{from:{x,y}, to:{x,y}, frames}` interpolated touch drag, one frame per point. |
| `release` | Release the touch. |
| `poke` | `{symbol, offset, type, value}` write memory (test setup). `symbol` is a `state.symbols` alias (default `default_symbol`), `type` as for fields. Marks the input trace `replay_safe: false`. |
| `frames` | Frames to advance (default 1; default 0 in a step with `wait_until`). The held keypad is re-asserted every frame. |
| `wait_until` | `{field, <equals\|not_equals\|min_value\|max_value>, timeout_frames}` runs frame by frame (after `frames`) until the `state` field satisfies every check. Timeout = scenario FAIL `wait_until:<field>` and the run stops there. The event records `waited_frames`. |
| `capture_sequence` + `capture_every` | Save `NAME_0000.png`, `NAME_0001.png`, ... every N frames of this step (filmstrip). |
| `capture` | Save `NAME.png` after the frames (used by `screen_changes`). |
| `state_capture` | Sample all `state` fields under this name. |
| `save_state` | Write a savestate `<states_dir>/NAME.dst` (+ `NAME.json` with the ROM sha256). |
| `comment`, `note` | Annotations. |

Touch coordinates are lower-screen coordinates: x 0..255, y 0..191. Captures are
256x384 with the lower screen at y 192..383, so subtract 192 from a capture y.
Names of captures, samples and states use letters, digits, `_ - .`.

## `state`

| key | meaning |
| --- | --- |
| `symbols` | `{alias: linker_symbol}` (or `symbol: "name"` for one, alias `state`). |
| `default_symbol` | Alias used by fields given as a bare offset (default `state`). |
| `fields` | `{name: offset \| {symbol, offset, type}}`, read at `symbol address + offset`. |
| `map` / `elf` | Explicit symbol file, relative to the scenario file (legacy `map_path`: relative to its parent dir). |

Field `type`: `u8 s8 u16 s16 u32 s32` (default `s32`, the old behaviour). Unknown
keys in `state` or in a field spec are rejected.

### Symbol resolution

1. Explicit: `state.elf` / `state.map`, CLI `--elf` / `--map` (or the 5th legacy
   argument / `DS_MAP_PATH`). Used as given, no consistency check.
2. Build sidecar: `.ds-game-dev/build/out/<rom stem>.buildinfo.json`, searched
   upwards from the ROM. If its `romSha256` differs from the ROM, the scenario
   ends `ERROR map_mismatch` (rebuild or pass `--map`/`--elf`).
3. Legacy `.ds-game-dev/build/build/game-blocksds.map` next to the ROM:
   works, warns `map_unverified`.

The ELF `.symtab` is preferred (it has static symbols), then the `.map`. A name
that matches several local statics is an error (`ambiguous_symbol`) listing the
addresses. `result.json` records which source was used.

## Assertions

Unknown keys are rejected, and every referenced capture or sample must be produced
by some step.

- `screen_changes`: `[{from, to, min_changed_pixels}]` between two `capture`s
  (pixels where any channel differs; default minimum 1).
- `state_changes`: `{field, from, to, <check>}` for deltas, or `{field, at, <check>}`
  for an absolute value. Checks: `min_abs_delta`, `min_delta`, `max_delta`,
  `max_abs_delta` (need from/to) and `equals`, `not_equals`, `min_value`,
  `max_value` (value at `to`, or at `at`). All checks present must hold.

## Savestates

`save_state` writes `<states_dir>/NAME.dst` and `NAME.json`; a later scenario
with `"start_state": "NAME"` starts from it (same `--states-dir`). `states_dir`
defaults to `<out>/_states` (the suite root in a multi-scenario run); in a suite,
scenarios run in command-line order, so list the saver first. A state saved from
a different ROM is refused (`ERROR state_rom_mismatch`); a missing one is
`ERROR state_missing`. Loading was verified frame-identical against continuing the
original run. Scenarios using `start_state` or `poke` are not replayable on
hardware (`replay_safe: false` in the trace).

## Skipping GPU render

Frames whose picture is never captured are run without GPU rendering
(`desmume_skip_next_frame`): default on, off with `--no-skip-render` or
`"render_all_frames": true`. The 3D pipeline lags a few frames, so the 8 frames
before every capture (`RENDER_LEAD`) are always rendered; with that margin the
capture hashes were identical to a fully rendered run on 12 dungeonds scenarios,
without it they were not. `wait_until` frames are always rendered. The gain is
small (about 5-10% on dungeonds, where ARM emulation dominates).

## Example

```json
{
  "name": "move_up",
  "state": {
    "elf": "../build/game.elf",
    "symbols": { "nav": "g_nav_state" },
    "default_symbol": "nav",
    "fields": { "y": 4, "moving": { "symbol": "nav", "offset": 20, "type": "u8" } }
  },
  "steps": [
    { "wait_until": { "field": "moving", "equals": 0, "timeout_frames": 120 },
      "capture": "idle", "state_capture": "idle" },
    { "button_down": "UP", "frames": 12, "capture": "up", "state_capture": "up",
      "capture_sequence": "walk", "capture_every": 4 },
    { "button_up": "UP", "frames": 2, "state_capture": "stopped" }
  ],
  "assertions": {
    "screen_changes": [{ "from": "idle", "to": "up", "min_changed_pixels": 100 }],
    "state_changes": [
      { "from": "idle", "to": "up", "field": "y", "min_abs_delta": 1000 },
      { "at": "up", "field": "moving", "equals": 1 },
      { "at": "stopped", "field": "moving", "equals": 0 }
    ]
  }
}
```

## Command line and results

```
run_scenario.py --rom R --lib L --out OUT [--map M] [--elf E] [--states-dir D]
                [--no-skip-render] [--jit] SCENARIO [SCENARIO ...]
run_scenario.py ROM SCENARIO OUT LIB [MAP]          # legacy form, still works
```

Several scenarios run in one process (the emulator library is initialised once
and the ROM reopened per scenario; calling init/free repeatedly crashes).
One scenario writes directly into `OUT`; several write `OUT/<scenario stem>/`
plus `OUT/suite.json`.

stdout carries only `DSM_` lines (the emulator's own chatter goes to
`emulator.log` per scenario, diagnostics to stderr):

```
DSM_SCENARIO_RESULT=<PASS|FAIL|NO_ASSERTIONS|ERROR> name=<stem> frames=N wall_ms=N [failed=a,b] [reason=...]
DSM_SCENARIO_WARNING=<stem>:<code>
DSM_SCENARIO_ERROR=<stem>: <message>
DSM_SUITE_RESULT=<PASS|FAIL|ERROR> total=N pass=N fail=N error=N wall_ms=N     (several scenarios only)
```

Exit code: 0 all PASS, 1 any FAIL / NO_ASSERTIONS, 2 any ERROR (dominates).
`ERROR` = the scenario could not run (invalid scenario, `map_mismatch`,
`ambiguous_symbol`, `symbol_not_found`, `state_missing`, `state_rom_mismatch`,
`exception`); `FAIL` = it ran and an assertion or `wait_until` failed.

Per scenario directory:

| file | content |
| --- | --- |
| `result.json` | Compact verdict for agents: `name`, `status`, `failed` (each `{check, expected, actual}`), `error {code, message}`, `warnings`, `frames`, `wall_ms`, `captures`, `map` (symbol source), `debug_capture`, `skip_render`. |
| `manifest.json`, `events.jsonl` | Full detail: captures with sha256, `capture_sequences`, events (each with `step` and `frame`), assertion results, `state_samples`. Always written, even on errors. |
| `input_trace.json` | `{"version":1,"frames":N,"runs":[[count,keys,touching,x,y],...]}`: run-length input actually applied per emulated frame (keys: bit0=A, 1=B, 2=SELECT, 3=START, 4=RIGHT, 5=LEFT, 6=UP, 7=DOWN, 8=R, 9=L, 10=X, 11=Y; x,y are 0,0 when not touching). `"replay_safe": false` + reasons when `poke`/`start_state` were used. |
| `debug.log` | no$gba debug text the ROM printed, when the library exports `desmume_agent_debug_read` (also up to 200 `debug` events); otherwise `debug_capture: false`. |
| `emulator.log` | Emulator console output. |
| `*.png` | Captures (256x384, zlib level 6). |

Warnings: `map_unverified`, `no_assertions`, `evidence_only`, `jit_unsupported`,
`capture_stale_frame:<name>` (the capture follows a non-rendered frame; rare).
