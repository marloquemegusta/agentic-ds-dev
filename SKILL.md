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

## 60 FPS Performance Architecture & Hardware Budgets

All game systems targeting the Nintendo DS must strictly adhere to its hardware budgets to guarantee 60 FPS (59.826 Hz):

1. **Hardware Budget:**
   - 1 frame = **16.71 ms** = **560,190 ARM9 CPU cycles** (@ 67.028 MHz) = **280,095 ticks** (Timer 0 @ 33.514 MHz BUS_CLOCK) or **545 ticks** with ClockDivider_1024.
   - Total scanlines = 263 (lines 0..191 active display, lines 192..262 VBlank).
   - CPU rendering and simulation must complete before scanline 192 (`REG_VCOUNT < 192`) to avoid dropping to 30 FPS.

2. **Prohibition of Unaccelerated Full-Screen 16-bit Software Framebuffers:**
   - The ARM9 lacks an FPU and the 16-bit EWRAM bus has severe bandwidth limits.
   - Never rasterize full-screen 16-bit bitmaps (256×192 = 49,152 pixels) on both screens every frame via software loops without hardware delegation or dirty caching.

3. **Core Rendering Rules:**
   - **Hardware BG Layers for Backgrounds:** Delegate tilemap drawing and scrolling to the 2D hardware GPU (BG0..BG3 in Mode 0/1/2/5). Scrolling via registers (`REG_BGxHOFS`/`VOFS`) costs **0 CPU cycles**.
   - **Hardware OAM for Sprites:** Use the 128 hardware sprite entries for dynamic characters, enemies, projectiles, and hazards. Hardware compositing and transparency cost **0 CPU cycles**.
   - **Pre-Baking Static Shadows & World Elements:** Static object shadows (walls, pillars) must be pre-composited into the world cache once at startup (`floor_cache_build`), never evaluated in real-time loops.
   - **Zero-Copy Double Buffering:** When using framebuffer modes (`MODE_FB0`/`MODE_FB1`), render directly into the offscreen VRAM bank (`VRAM_A` / `VRAM_B`) and flip the hardware register on VBlank. Never render to EWRAM and DMA copy the full screen when VRAM page flipping is available.
   - **Zero Software Division in Hot Loops:** The ARM9 lacks a hardware divide instruction. Never divide (`/`) in inner rendering loops; use bit shifts (`>>`), fixed-point multiplications, or precomputed Look-Up Tables (LUTs).
   - **32-Bit Memory Transfers & Hardware Alignment:** Use 32-bit aligned words (`uint32_t`) or `memcpy`/DMA to utilize the ARM9 `ldmia`/`stmia` burst engine. **CRITICAL:** The ARM946E-S does NOT support unaligned 32-bit memory access (an unaligned `LDR` performs a hardware rotation by 16 bits swapping halfwords; an unaligned `STR` writes to `addr & ~3` overwriting previous pixels). Always access unaligned pixel data as clean 16-bit halfwords (`uint16_t`).

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
