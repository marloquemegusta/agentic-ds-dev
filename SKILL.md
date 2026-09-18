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
declared source/assets into an isolated build tree, runs `make`, and writes the
requested ROM output.

Run the host test commands declared in `project.json` with
`scripts/run-host-tests.ps1` before and after the change. A build passing is
not a behavioral test.

## DeSmuME scenarios and evidence

Use `scripts/run-scenario.ps1` with the current ROM, a project-owned scenario,
and an output directory under `artifacts/`. Scenarios support `tap`, explicit
`release`, `button_down`, `button_up`, `drag`, frame counts, captures, event
traces, state assertions, and targeted visual assertions.

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

## GDB and runtime diagnostics

Use `scripts/validate-gdb.ps1 -RomPath <rom>` only for a concrete diagnostic hypothesis. The
runtime exposes ARM9 GDB remote debugging; it does not prove source-level
symbols, audio, physical timing, or hardware compatibility.

## DS upload

Build and validation do not upload automatically. Upload only after explicit
user confirmation immediately before the external mutation. Use
`scripts/upload-rom.ps1 -ProjectPath <repo> -RomPath <rom> -ConfirmUpload`.

The skill provides default FTP settings without a password. Project-local
overrides may be supplied through an ignored config file. On connection or
verification failure, do not retry blindly: report the exact failure and ask
the user to validate the IP, port, path, and device availability.

After upload, report the ROM path, commit/build identity, remote target, and
that audio and physical behavior still require listening on the DS.

## Boundaries

- Product meaning, visual language, controls, and UX acceptance criteria come
  from the project's `DESIGN.md`.
- Implementation invariants come from `TECHNICAL.md`.
- Worktrees, branches, commits, merge permission, and repository ownership come
  from the project's `AGENTS.md`.
- Do not use Android, ADB, melonDS, or NO$GBA unless the project explicitly
  authorizes a distinct diagnostic workflow.
- Do not claim physical audio or DS/DSi compatibility from emulation.

## High-Performance 60 FPS Architectural Contracts

The Nintendo DS ARM9 CPU (67 MHz) and memory bus require strict architectural
discipline to achieve 60 FPS. Naive PC-style rendering (per-pixel loops, 16-bit
software framebuffers, $O(N^2)$ simulation loops, unmanaged DMA) will fail to
exceed 10-15 FPS.

Before writing simulation, rendering, or memory management code, agents MUST
consult:
- **`references/performance-architecture.md`**: The canonical reference for
  hardware budgets (545 ticks @ 60 FPS), D-cache coherency rules, and rendering
  archetypes.

### Game Archetype Catalog Overview
1. **Archetype 1: 2D High-Entity Swarms & Software Framebuffers** (e.g. Tower Defense, RTS swarms):
   - **VRAM Double-Buffering:** Use Main Engine `MODE_FB0`/`MODE_FB1` alternating Banks A & B for zero-cost page flips.
   - **Native 8-bit Sub-Engine:** Use Sub-Engine Mode 5 (`BgType_Bmp8`) with hardware 256-color palette (`BG_PALETTE_SUB`) to cut DMA payload to 48 KB.
   - **Direct 32-bit Quad Blitting:** Pad sprite rows to 4-byte boundaries; skip transparent quads in 1 cycle (`qval == 0`), store 4 opaque pixels in 1 instruction (`STR`).
   - **8x8 Deduplicated Dirty Grid:** Never clear whole screens; restore only modified 8x8 blocks via burst `memcpy` from ground cache.
   - **Cache Coherency:** Always call `DC_FlushRange()` before triggering DMA from Main RAM to VRAM. For RAM-to-RAM copies, use CPU `memcpy()`.
   - **Spatial Partitioning:** Use uniform spatial grids to keep entity separation and hit tests at $O(N)$ instead of $O(N^2)$.
2. **Archetype 2: 2D Hardware Tilemaps & OAM Sprites (Platformers, RPGs):**
   - Utilize native hardware background scrolling engines and 128 hardware OAM sprites.
3. **Archetype 3: 3D Fixed-Function Geometry (Racers, 3D Action):**
   - Utilize geometry engine display lists, vertex packing, and dual 3D VRAM bank allocation.
