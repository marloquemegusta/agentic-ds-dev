---
name: ds-game-dev
description: Develop Nintendo DS games end to end on Windows with the bundled offline BlocksDS and DeSmuME toolchain, project scaffolding, host tests, scenarios, UX evidence, GDB, and confirmed DS upload.
metadata:
  short-description: Complete offline Nintendo DS development workflow
---

# Nintendo DS Game Development

This skill is the complete DS development workflow. Use its bundled scripts,
runtime, container image, templates, scenarios, and validators; do not ask the
user to know DS toolchain commands.

## Supported host and offline package

- Supported host: Windows 10/11, PowerShell, plus Docker Desktop (normally with
  WSL2 integration) or Docker Engine and WSL2 installed separately. Docker is
  the offline BlocksDS container backend; WSL2 runs the bundled DeSmuME/GDB
  runtime.
- The package contains a pinned BlocksDS image at `images/blocksds-slim-latest.tar`,
  a pinned headless DeSmuME runtime, its source and GDB overlay, runners, and
  generic scenario contracts.
- Run `scripts/check-toolchain.ps1` first. It reports whether Docker and WSL2,
  Python, the BlocksDS image, and the DeSmuME runtime are available.
- If the image is not loaded, use `scripts/load-blocksds-image.ps1`; do not
  pull from the network during an offline run.
- If Docker/WSL2 is missing, explain the host requirement and stop before making
  system changes.

## Project contract and onboarding

For an existing project, inspect `AGENTS.md`, `DESIGN.md`, `TECHNICAL.md`,
`STATUS.md`, `README.md`, and `.ds-game-dev/project.json` when present.

The standard project layout is:

```text
source/ include/ tests/ scenarios/ tools/ artifacts/
AGENTS.md DESIGN.md TECHNICAL.md STATUS.md README.md
.ds-game-dev/project.json
```

If the project is new or this contract is incomplete, ask whether the user
wants onboarding before creating or changing files. With approval, run
`scripts/scaffold-project.ps1` and ask the product questions needed to draft
`AGENTS.md` and `DESIGN.md`; show those drafts and wait for approval before
writing them.

## Autonomous development loop

For a feature, improvement, bug fix, or UI change, complete the available
build, host tests, scenario, capture, log, and diagnosis loop autonomously.
Do not ask the user to perform a step that the skill can perform. Stop only
when the remaining evidence needs human listening, physical hardware, or a
product decision.

1. Identify the user-visible or technical hypothesis.
2. Read the project contract and relevant source/tests.
3. Run the smallest relevant host test and add or update a project test when
   the changed logic needs one.
4. Build the current ROM with `scripts/build-project.ps1`.
5. Run a project-owned scenario with `scripts/run-scenario.ps1` when the
   behavior is observable.
6. Read `manifest.json`, `events.jsonl`, `emulator.log`, and relevant PNGs.
7. For UI changes, perform the UX evidence loop below and iterate on defects.
8. Update `STATUS.md` only with facts supported by the evidence.
9. Report facts, inferences, proposals, and physical validation boundaries
   separately.

## Build and host tests

Use `scripts/build-project.ps1 -ProjectPath <repo>`. It reads the project's
`.ds-game-dev/project.json`, loads the bundled BlocksDS image, copies the
declared source/assets into an isolated build tree, runs `make -j`, and writes the
requested ROM output. The build is incremental: only changed files are copied
and recompiled (a no-change build takes ~2-3 s). The tree is rebuilt from
scratch automatically when the template, `project.json` or the image change,
or a source file is deleted; pass `-Clean` to force it.

Run the host test commands declared in `project.json` with
`scripts/run-host-tests.ps1` before and after the change. A build passing is
not a behavioral test.

## DeSmuME scenarios and evidence

Use `scripts/run-scenario.ps1` with the current ROM, a project-owned scenario,
and an output directory under `artifacts/`. Scenarios support `tap`, explicit
`release`, `button_down`, `button_up`, `drag`, frame counts, captures, event
traces, state assertions, and targeted visual assertions.

Scenarios can read game memory: a `state` block maps names to offsets of a linked
symbol (resolved from the linker `.map`; pass `-MapPath` or set `DS_MAP_PATH`),
`state_capture` samples it, and `assertions.state_changes` checks deltas
(`min_abs_delta`, `min_delta`, ...) or absolute values (`at` + `equals`,
`min_value`, `max_value`). `capture_sequence`/`capture_every` save filmstrips.
A scenario with no assertions passes with `DSM_SCENARIO_WARNING=no_assertions`;
do not treat that as evidence. Full format: `references/scenario-format.md`.

For every observable behavior, require a host-side contract test and a real
input scenario that performs the modified gesture. Read the manifest first,
then events, logs, and relevant captures. A `PASS`, `screen_changed`, pixel
difference, or screenshot hash alone never proves the hypothesis.

### Mandatory controller-input preflight

Before using `button_down` / `button_up` as evidence for a gameplay, menu, or
pause behavior, validate the controller path against the current ROM. The
runner's `desmume_input_keypad_get()` only proves that the emulator frontend
accepted a bitmask; it does **not** prove that the ROM consumed that button via
`scanKeys()` / `keysDown()`.

Create or run a small project-owned input-contract scenario whose button press
causes a uniquely observable, asserted state change in that ROM (for example a
dedicated input-test screen, a mode label, or a menu transition). Do not reuse
the generic `input-contract.template.json` as proof: it is illustrative and
may name a different ROM. Inspect the before/after captures and assert the
specific transition. If this preflight fails, classify all button-driven
scenario results as invalid and diagnose the runtime/input boundary before
changing game controls or adding touch-only workarounds.

Touch needs the same treatment: use a capture that proves the intended hitbox
was activated, not merely a changed screen. Account for the DS lower-screen
coordinate space explicitly and include a release between independent taps.

### UX evidence loop

For every UI change:

1. Capture the relevant initial state.
2. Execute the real modified gesture.
3. Capture the resulting state and any needed menu, boundary, scroll, or
   edited-surface states.
4. Review layout, clipping, overlap, labels, legibility, hitboxes, feedback,
   focus, and interaction clarity against the project's `DESIGN.md`.
5. If a defect is found, fix it and repeat the scenario and review.

Do not declare the loop complete while a known visual defect remains. Explain
what each capture proves. Use a close-up when the affected surface is too small
to judge at native resolution.

### Technical walkthroughs

When a milestone or session changes rendering, assets, runtime behavior, or a workflow,
write or update its canonical document under `walkthroughs/<session-or-feature>/` and
add it to `walkthroughs/README.md`. A walkthrough is a teaching and handoff
document, not a short changelog. Explain enough context that another developer
can understand the original failure, the reasoning behind the implementation,
and how to reproduce and verify the result without relying on chat history.

For a substantial technical change, include:

1. A plain-language summary and the user-visible problem being solved.
2. The relevant geometry/data flow, key dimensions and coordinate/anchor
   conventions, then how the runtime consumes the generated data.
3. The investigated alternatives and failed attempts, their observable
   symptoms, root causes, and the change that resolved each one. Distinguish
   confirmed causes from hypotheses.
4. Durable invariants in `TECHNICAL.md`; product decisions in `DESIGN.md`,
   workflow rules in this skill/`AGENTS.md`, and verified milestone facts in
   `STATUS.md`. The walkthrough explains these sources rather than duplicating
   them as competing specifications.
5. Reproduction commands, test/build/scenario results, artifacts, current
   limitations, and the next validation needed.

Walkthroughs for a visual or graphical change must embed several relevant
images, not merely link to an artifact directory. Prefer actual captures from
the built ROM plus a real asset/orientation sheet or an enlarged crop where
details are hard to judge. Store committed images next to the walkthrough and
use relative Markdown image links. Add a short caption stating what each image
shows and what it does *not* prove. Review every embedded image at native size
and use close-ups for clipping, pivots, seams, and shadows. Synthetic gameplay
screens or mockups must not be presented as game evidence; any derived crop or
asset contact sheet must be clearly identified as such. Do not link only to
gitignored `artifacts/` files if the walkthrough should work in a clean clone.

Keep the walkthrough as verbose as the lesson requires: document measurements,
API/version-specific pitfalls, memory/performance trade-offs, and unresolved
risks when they materially explain the design. Never upgrade an emulator
`PASS`, pixel difference, or screenshot hash into a stronger claim than the
scenario actually asserted.

### Prohibition of Synthetic Offline Mockups
All gameplay simulations, combat animations, and scene/tile mockups MUST be executed
directly inside the real game engine by compiling the ROM (`scripts/build-project.ps1`)
and running a headless DeSmuME scenario (`scripts/run-scenario.ps1`). Generating
mockups, gameplay animations, or preview GIFs via offline scripts (PIL, Python canvas,
or synthetic frame compositors) outside the compiled binary is strictly prohibited.
Evidence must always reflect the actual ARM9 C engine, simulation physics, particles,
and rendering pipeline.

## Performance: measure on the DS, compare in the emulator

DeSmuME is for repeatable behavior and relative A/B comparisons only. Its
frame timing does not certify DS/DSi performance: memory-bus, DMA, and VRAM
costs differ on hardware, and a frame that looks cheap in the emulator can blow
the budget on the console. Never report "60 FPS" from emulator numbers.

### Budget (one frame at 59.826 Hz = 16.715 ms)

| Counter | Units per frame |
| :--- | :--- |
| ARM9 CPU cycles (67.028 MHz) | ~1,120,000 |
| `cpuGetTiming()` / BUS_CLOCK ticks (33.514 MHz) | **560,190** |
| Timer at `ClockDivider_1024` | ~547 (545 at exactly 60 Hz) |

Always name the counter with the number; 33,514 bus ticks is 1 ms, not a frame.
There are 263 scanlines (0..191 visible, 192..262 VBlank); work may continue
during VBlank, so `REG_VCOUNT` is telemetry, not a deadline.

### Hardware profiling loop

1. Measure the exact ROM on the target device before editing. Split frame cost
   by stage (simulation, BG/tile streaming, sprite or bitmap composition,
   DMA/VRAM writes, VBlank wait) with `cpuStartTiming`/`cpuGetTiming`, and have
   the ROM append per-window averages, maxima and frames-over-one-VBlank to a
   log on the SD card behind a compile-time flag that is off by default.
2. Build, upload (see "DS upload"), and ask the user to play the specific
   repeatable situation (idle, sustained movement, busiest scene).
3. Download the log with
   `scripts/fetch-device-log.ps1 -ProjectPath <repo> -RemoteFile /<game>_perf.log`
   (`-Delete` removes it afterwards; ask first). The same script reads crash
   reports the ROM writes to the SD card.
4. Run controlled A/B changes one path at a time with the same workload, and
   check that movement, collision, visibility, actor order and controls stay
   correct. Record device, ROM identity, and the counters' start/end semantics.

If hardware is unavailable, report results as emulator-only and leave physical
performance unverified.

### Architecture rules (design targets, not guarantees)

- **Floating point:** the ARM9 has no FPU; `float`/`double` work through
  soft-float and are far too slow for per-frame game code. Use fixed point.
- **Division:** the ARM9 has a hardware divider and square root
  (`div32`/`mod32`/`sqrt32` in libnds). C `/` and `%` in hot loops still go
  through a slower library call: prefer shifts, reciprocal LUTs, or the hardware
  divider explicitly.
- **Backgrounds:** delegate scrolling scenery to hardware BG layers. Register
  scrolling is nearly free, but map/tile streaming and VRAM writes are not.
- **Sprites:** OAM gives 128 hardware sprites with free compositing, but
  `oamUpdate` costs time, sprites per scanline are limited, and there are only
  32 affine matrices.
- **Framebuffers:** never rasterize full-screen 16-bit bitmaps on both screens
  every frame in software without dirty tracking. `MODE_FB0`/`MODE_FB1` show a
  raw VRAM bank and disable BG, sprites and 3D on that screen; with a bitmap BG,
  draw straight into the back page in VRAM instead of copying a whole screen
  from main RAM.
- **Static work:** pre-bake static shadows and world elements once at load.
- **Alignment:** the ARM946E-S does not fix up unaligned 32-bit access. An
  unaligned `LDR` returns the aligned word rotated by `8 * (addr & 3)` bits and an
  unaligned `STR` writes to `addr & ~3`. Access unaligned pixel data as 16-bit
  halfwords; use aligned words, `memcpy` or DMA for bulk transfers.
- **Cache coherency:** call `DC_FlushRange()` on the source before DMA from main
  RAM, and `DC_InvalidateRange()` on the destination before the CPU reads memory
  that DMA wrote to main RAM.
- **Code placement:** BlocksDS builds ARM9 code as Thumb by default; mark hot
  inner loops `__attribute__((target("arm")))` and consider ITCM/DTCM.

Archetype-specific patterns (high-entity framebuffers, tilemap + OAM games,
3D geometry) and an example subsystem allocation are in
`references/performance-architecture.md`. Read it before writing rendering,
simulation, or memory-management code.

## GDB and runtime diagnostics

Use `scripts/validate-gdb.ps1 -RomPath <rom>` only for a concrete diagnostic hypothesis. The
runtime exposes ARM9 GDB remote debugging; it does not prove source-level
symbols, audio, physical timing, or hardware compatibility. For crashes that
only happen on hardware, have the ROM write a crash report to the SD card and
read it with `scripts/fetch-device-log.ps1`.

## DS upload

Build and validation do not upload automatically. Upload only after explicit
user confirmation immediately before the external mutation. Use
`scripts/upload-rom.ps1 -ProjectPath <worktree> -RomPath <rom> -ConfirmUpload`.

- FTP settings resolve from the skill's `config/ftp.json`, then the project's
  `.ds-game-dev/project.json` (`romUploadName`), then an optional gitignored
  `.ds-game-dev/ftp.local.json`, then explicit parameters. Do not pass
  `-RemoteName` unless the user asks: the project's name is the file the user
  opens on the console.
- The script refuses a ROM older than the project's sources (`ROM_STALE`),
  warns when the ROM is outside `-ProjectPath`, checks the port first
  (`FTP_UNREACHABLE` means the DS is not running its FTP server), and verifies
  the remote size.
- On failure, do not retry blindly: report the exact failure and ask the user
  to open the FTP server on the DS or validate IP, port and path.

After upload, report the remote file, size, branch and commit from
`FTP_UPLOAD_RESULT`, what the user should look for to recognize the new build,
and that audio and physical behavior still require testing on the DS.

## Boundaries

- Product meaning, visual language, controls, and UX acceptance criteria come
  from the project's `DESIGN.md`.
- Implementation invariants come from `TECHNICAL.md`.
- Worktrees, branches, commits, merge permission, and repository ownership come
  from the project's `AGENTS.md`.
- Changes to this skill go on a branch of the skill repository (for example a
  sibling worktree `agentic-ds-dev.wt-<name>`), never on its `main` checkout
  while other sessions may be using it.
- Do not use Android, ADB, melonDS, or NO$GBA unless the project explicitly
  authorizes a distinct diagnostic workflow.
- Do not claim physical audio or DS/DSi compatibility from emulation.
