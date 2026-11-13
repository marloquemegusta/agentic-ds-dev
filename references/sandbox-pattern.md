# Sandbox mailbox pattern

Use it to put the game into a precise scene (actors at exact coordinates, enemies
parked, a known HP) before a scenario captures it. Plain `poke` of single values
is too slow to write by hand; a mailbox lets one scenario step write a whole record.

## Shape

1. The game exposes a global, non-static structure (a symbol in the ELF), for
   example `g_sandbox`, with a `seq` / `ack` pair and the fields to fill.
2. The game polls the mailbox: when `seq != ack` it copies the fields into its
   live state, then sets `ack = seq`.
3. The scenario declares the fields in `state.fields`, writes them with a `poke`
   list (one element per field, in order), and increments `seq` in the LAST
   element, so the game never sees a half-written record in the same frame.
4. The next step does `wait_until` on `ack` (equals the new `seq`), then captures.

```json
{ "poke": [
    { "field": "player_x", "value": 384 },
    { "field": "enemy0_x", "value": 512 },
    { "field": "seq", "value": 1 } ] },
  { "wait_until": { "field": "ack", "equals": 1, "timeout_frames": 60 }, "capture": "scene" }
```

## Rules

- Build only in a variant. The mailbox and its poll code live behind a define set
  by a variant in `.ds-game-dev/project.json`, e.g. `"variants": {"sandbox":
  {"defines": ["DS_SANDBOX=1"]}}`, built with `build-project.ps1 -Variant sandbox`.
  Never compile it into the production ROM; the default build must not contain the
  symbol's poll code.
- Fix the offsets. The C struct carries `_Static_assert(offsetof(...) == N, ...)`
  for every field the scenario uses, and a host test (`tests/c/`) checks the same
  offsets. A moved field then fails the build or the host test, not a scenario.
- Declare each field once in `state.fields` with its real type (`u8`, `s16`, ...).
  The runner rejects a value that does not fit it, before the emulator starts.
- Write `seq` last and wait on `ack`. Never capture before `wait_until` passes.
- The scenario sets up the scene; the captures show what it is meant to show.
  Place actors so they really cross the wall, trigger or line of sight under test
  (scenario-format rule: no occlusion tests in open ground). Park enemies (zero
  speed or a `state` flag) so their position does not drift during the wait.
- Name captures after what the geometry produces, not after what was intended.
- Mailbox writes are not replayable on hardware: the trace is `replay_safe: false`.
  Use the sandbox for evidence of logic and rendering in the emulator, and keep
  hardware performance runs on a production-variant scenario.
