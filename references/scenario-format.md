# Scenario JSON format

Used by `scripts/run-scenario.ps1` / `runtime/run_scenario.py`. Files may be
UTF-8 with or without BOM.

## Top level

- `steps` (required): list of step objects, run in order.
- `state` (optional): memory sampling config, see below.
- `assertions` (optional): `screen_changes` (or a single `screen_changed`) and
  `state_changes`. With no assertions the run still passes but prints
  `DSM_SCENARIO_WARNING=no_assertions` and records `"warnings"` in the manifest.

## Steps (all keys optional, applied in this order)

Unknown step keys make the run fail before the emulator starts (`comment` and
`note` are allowed for annotations). A skipped action could otherwise let a
test pass without doing anything.

| key | meaning |
| --- | --- |
| `button_down` / `button_up` | Press / release one button (A B SELECT START RIGHT LEFT UP DOWN R L X Y). Only that button's bit changes; other held buttons stay held. |
| `release_flush_frames` | With `button_up`: extra frames run right after the release (default 0). They count in the frame total and are logged in the event. |
| `tap` (alias `touch`) | `{x, y}` start touching the lower screen (stays until `release`). |
| `tap_grid` | `{count, columns, x, y, spacing_x, spacing_y, hold, hold_frames, gap_frames}` taps `count` points row by row from `(x, y)`. Each tap holds the `hold` buttons (e.g. `["R"]`) for `hold_frames` (default 2), then releases the touch for `gap_frames` (default 1). |
| `drag` | `{from:{x,y}, to:{x,y}, frames}` interpolated touch drag, one frame per point. |
| `release` | Release the touch. |
| `frames` | Frames to advance (default 1). The held keypad is re-asserted every frame. |
| `capture_sequence` + `capture_every` | Save `NAME_0000.png`, `NAME_0001.png`, ... every N frames of this step (filmstrip). |
| `capture` | Save `NAME.png` after the frames (used by `screen_changes`). |
| `state_capture` | Sample the `state` fields after the frames under this name. |

## `state`

- `map`: linker map path relative to the scenario file. Resolution order:
  `state.map` > 5th CLI arg / `-MapPath` / env `DS_MAP_PATH` > default
  `.ds-game-dev/build/build/game-blocksds.map` next to the ROM, then under
  `<scenario_dir>/..`. (Legacy key
  `map_path`, relative to the scenario's parent directory, is also accepted.)
- `symbols`: `{alias: linker_symbol}` (or `symbol: "name"` for one, alias `state`).
- `default_symbol`: alias used by fields given as a bare offset (default `state`).
- `fields`: `{name: offset | {symbol: alias, offset: n}}`; each is read as a
  signed 32-bit word at `symbol address + offset`.

## Assertions

- `screen_changes`: `[{from, to, min_changed_pixels}]` between two `capture`s.
- `state_changes`: `{field, from, to, <check>}` for deltas, or `{field, at, <check>}`
  for an absolute value. Checks: `min_abs_delta`, `min_delta`, `max_delta`,
  `max_abs_delta` (need from/to) and `equals`, `min_value`, `max_value`
  (value at `to`, or at `at`).

## Example

```json
{
  "name": "move_up",
  "state": {
    "map": "../build/game.map",
    "symbols": { "nav": "g_nav_state" },
    "default_symbol": "nav",
    "fields": { "y": 4, "moving": { "symbol": "nav", "offset": 20 } }
  },
  "steps": [
    { "frames": 60, "capture": "idle", "state_capture": "idle" },
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

## Output

`manifest.json` (captures, `capture_sequences`, events, `frames`, assertion
results, `state_samples`, `warnings`, `error`) and `events.jsonl` are always
written, even on exceptions. Every event carries `step` and `frame`. The last
line is `DSM_SCENARIO_RESULT=PASS ...` or `DSM_SCENARIO_RESULT=FAIL reason=...
failed=<checks>`.
