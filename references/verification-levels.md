# Verification levels

Pick the lowest level that can falsify the hypothesis. Summary table and the
change-type mapping are in `SKILL.md`; this file gives the detail.

| Level | Commands | Typical cost | Proves | Does not prove |
| :--- | :--- | :--- | :--- | :--- |
| L0 build | `build-project.ps1 -ProjectPath P` | 3-4 s no-op, 6-7 s clean (mid-size game); first run after Docker start is slower | Compiles, links, `new_warnings=0`; writes ELF/map/buildinfo sidecars | Any behaviour |
| L1 host tests | `run-host-tests.ps1 -ProjectPath P [-Filter f]` | seconds per C test; ~30 s extra on a cold WSL | Pure logic, with ASan/UBSan, on the host | Anything that touches libnds, timing or rendering; Python mirrors of C code test the mirror, not the C |
| L2 scenario | `run-scenario.ps1 -ProjectPath P -ScenarioPath S` | wall time ~ frames / 70-80 per second, plus start-up | The asserted state transitions through real input in the real ROM; `debug.log` shows what the ROM reported | Anything not asserted; performance; audio |
| L3 suite | `run-scenarios.ps1 -ProjectPath P` | sum of scenarios, one process | No regression across scenarios | Hardware behaviour |
| L4 hardware | `hardware-workflow.md` | user time: upload, open ROM, wait | Frame cost on the DS, SD I/O, crashes, audio, feel | Other ROM versions |

## Per level

**L0.** Compare `warnings=` and `new_warnings=` in `DS_BUILD`. Any new warning
blocks the change. A build for a variant (`-Variant perf`) is not a substitute
for the default build.

**L1.** Use it for decisions that are pure functions of inputs: math, state
transitions, parsers, collision predicates, tables. If the logic is tangled with
libnds calls, extract it (see `host-tests.md`) rather than skipping L1 or
asserting on source text.

**L2.** Ingredients: a state struct reachable by symbol, steps that perform the
real gesture, `state_capture` before/after, `state_changes` assertions, and
`wait_until` for transitions. Check `debug.log` for ROM-side errors and
`result.json.warnings`. Actors must really cross the geometry under test; do not
test collision or occlusion in open ground. Use `start_state` savestates to skip
long set-up (not replayable on hardware). Do the input preflight once
(`SKILL.md`).

**L3.** Run before merge, or after shared-code changes. Iterate with `-Filter` or
`-Tag`; read `DS_SUITE_NONPASS` and the failing `result.json` files, not every
manifest. Scenarios with `"suite": false` are skipped.

**L4.** Required for per-frame loops, render, DMA, memory layout and audio. The
user's time is the expensive part: batch several questions into one replay run
and keep the upload count low.

## Reporting

State which levels ran, the exact commands, the verdict lines, and which levels
were skipped and why. Mark hardware-only claims as unverified until L4 ran on the
exact ROM.
