---
name: ds-game-dev
description: Use when working on a Nintendo DS / NDS homebrew game (C, libnds, BlocksDS): building ROMs, testing in headless DeSmuME, writing scenarios, profiling, debugging with GDB, or uploading to a DS over FTP.
metadata:
  short-description: Offline Nintendo DS build, test, profile and upload workflow
---

# Nintendo DS game development

Run the bundled scripts yourself; do not ask the user for toolchain commands.
Host: Windows 10/11, PowerShell, Docker (BlocksDS container) and WSL2 (headless
DeSmuME, GDB, gcc for host tests). Run `scripts/check-toolchain.ps1` first; if
Docker or WSL2 is missing, report it and stop before changing the system. If the
image is not loaded use `scripts/load-blocksds-image.ps1` (never pull during an
offline run). Setup details: `README.md`.

## What the emulator can and cannot prove

- Proves: deterministic input handling, game state (memory read by symbol),
  logic, rendering output at capture time, crashes in the interpreter.
- Does not prove: hardware performance (bus, DMA and VRAM costs differ), audio,
  SD/FAT behaviour, DSi or real timing, "feel". Never report 60 FPS from
  emulator numbers. The ROM's own perf counters are comparable A/B only.
- `PASS` proves only what the scenario asserted. A changed screen, pixel diff or
  hash is not a correctness claim.

## Commands (run from the skill dir; `-ProjectPath` is the project or worktree)

| Script | Key parameters / output |
| :--- | :--- |
| `check-toolchain.ps1` | `[-ProjectPath]`; `DS_CHECK` lines, `DS_TOOLCHAIN=PASS\|INCOMPLETE` |
| `scaffold-project.ps1` | `-ProjectPath [-Title]`; layout, `project.json`, starter ROM source, smoke scenario, C test |
| `build-project.ps1` | `-ProjectPath [-Variant name] [-Define NAME=VAL] [-OutputRom] [-Clean]`; `DS_BUILD=PASS ... warnings= new_warnings=` |
| `run-host-tests.ps1` | `-ProjectPath [-Filter] [-TailLines]`; `DS_HOST_TESTS=PASS\|FAIL` |
| `run-scenario.ps1` | `-ScenarioPath [-ProjectPath] [-RomPath] [-OutputPath] [-MapPath] [-StatesDir] [-Jit] [-NoSkipRender]`; `DSM_SCENARIO_RESULT=` |
| `run-scenarios.ps1` | `-ProjectPath [-Filter 'wild*'] [-Tag] [-RomPath] [-OutputPath] [-StatesDir] ...`; one process, `DSM_SUITE_RESULT=`, `DS_SUITE_NONPASS=` |
| `validate-gdb.ps1` | `-RomPath [-ProjectPath] [-ElfPath] [-Breakpoint main] [-Port] [-Frames] [-TimeoutSeconds]` |
| `upload-rom.ps1` | `-ProjectPath -RomPath (-ConfirmUpload \| -DryRun) [-RemoteName]`; `FTP_UPLOAD_RESULT=` |
| `fetch-device-log.ps1` | `-ProjectPath -RemoteFile /x.log [-OutDir] [-Delete]`; `DEVICE_LOG_RESULT=` |
| `setup.ps1`, `build-runtime.ps1` | Install / rebuild the DeSmuME runtime (`README.md`, `references/desmume-agent.md`) |

`run-scenario(s)` default the ROM to `project.json` `rom`. Exit codes: 0 pass,
1 fail or no assertions, 2 error. Scenario format: `references/scenario-format.md`.
The first WSL call can cost ~30 s (cold start); the scripts keep WSL warm after that.

## Project contract: `.ds-game-dev/project.json`

| Key | Meaning |
| :--- | :--- |
| `title`, `rom`, `outputRom` | Game title; ROM path in the project; ROM name the build produces |
| `buildTemplate` | `skill-default` or a project path to a BlocksDS Makefile tree |
| `blocksdsImage` | Docker image (default `skylyrac/blocksds:slim-latest`) |
| `copy` | `[{source, destination}]` project dirs/files copied into the build tree |
| `defines` | Project-wide compile defines (`NAME=VAL` or `-DNAME`) |
| `variants` | `{name: {defines: [...]}}`; `-Variant name` builds `<rom stem>-<name>.nds` in its own tree |
| `hostTests` | Extra commands run by `run-host-tests.ps1` (cmd.exe, project root); `tests/c/test_*.c` are found automatically |
| `scenarioDirectory` | Where `run-scenarios.ps1` looks (default `scenarios`) |
| `romUploadName` | Remote file name on the SD card; do not override it unless asked |
| `icon` | Optional banner icon |

Build products: the ROM plus `.ds-game-dev/build/out/<rom stem>.{elf,map,buildinfo.json}`
(sha256, variant, defines, warning totals). Scenarios and GDB resolve symbols from
them and refuse a mismatching ROM. The build is incremental (~3-4 s no-op, ~6-7 s
clean for a mid-size game); the warning ledger reports the total even on
incremental builds. New project: ask before scaffolding, then draft the project's
`AGENTS.md`/`DESIGN.md` and wait for approval. For walkthroughs and status
documents follow the project's `AGENTS.md`.

## Verification levels (detail: `references/verification-levels.md`)

| Level | What | Proves |
| :--- | :--- | :--- |
| L0 | `build-project.ps1`, 0 new warnings | It compiles and links |
| L1 | `run-host-tests.ps1` | Pure logic. Prefer C tests (gcc + ASan/UBSan, `references/host-tests.md`) over Python mirrors or regex-on-source, which do not test the C |
| L2 | Targeted scenario(s): state assertions + `debug.log` | The changed behaviour through real input in the ROM |
| L3 | `run-scenarios.ps1`, full suite | No regressions; run once before merge |
| L4 | Hardware (`references/hardware-workflow.md`) | Performance, audio, SD, feel |

| Type of change | Minimum level |
| :--- | :--- |
| Docs, comments | none; L0 if a code file was touched |
| Scenario-only edit | Run the edited scenario |
| Pure logic, math, data tables | L0 + L1 |
| Gameplay, input, state machine, UI | L0 + L1 (if logic is extractable) + L2 |
| Rendering, assets, palette, layout | L0 + L2 with captures reviewed |
| Shared code, refactor, before merge | L0 + L1 + L3 |
| Per-frame loops, render, DMA, memory, audio | the above + L4 |

Spend the least that proves the hypothesis: iterate with one scenario or one
`-Filter`, run the suite once before merge, do not rebuild or re-run what did not
change. Skip a level only if its prerequisite does not exist, and say so.

## Evidence rules

- Read `result.json` first (status, failed checks with expected/actual,
  warnings), then `debug.log` (ROM `DS_LOG` output), then captures, only when an
  assertion cannot express the check. Do not read full manifests by default.
- `NO_ASSERTIONS` is a failure unless the scenario sets `evidence_only`, and an
  evidence-only run proves nothing.
- Assert state, not pixels: expose a `g_probe`-style struct (template
  `source/main.c`) and read its fields via `state`. Make sure the actor
  coordinates really cross the wall, trigger or hitbox the scenario claims to
  test, and name captures after what they show.
- No synthetic mockups presented as game evidence. Contact sheets, crops or GIFs
  assembled from real captures are fine if labelled as derived.
- Report facts, inferences and unverified (hardware) items separately.
- UI changes: capture the initial state, perform the real gesture, capture the
  result, review layout, clipping and hitboxes against the project's `DESIGN.md`,
  fix and repeat. Use a close-up for small details.

### Input preflight (once per project and runtime version, not per scenario)

The emulator accepting a keypad bitmask does not prove the ROM reads it. Run a
scenario against the project's ROM where a button press and a touch each change
a probe field (the template's `g_probe.presses_a`, `last_keys`, `touch_x/y`),
asserted with `state_changes`. If it fails, every button/touch result is invalid:
fix the runtime/input boundary before changing game controls. Re-run it after
updating the runtime or the input code. `scenarios/*.template.json` are
illustrative, not proof.

Touch: x 0..255, y 0..191 (lower screen). Captures are 256x384 with the lower
screen at y >= 192, so subtract 192 from a capture y. `tap` holds until
`release`; release between independent taps.

## Performance rules (detail: `references/performance-architecture.md`)

- Budget: one frame at 59.826 Hz = **560,190 `cpuGetTiming()` bus ticks**
  (33.514 MHz); 33,514 ticks = 1 ms, not a frame. Always name the counter.
- No `float`/`double` in per-frame code; use fixed point (8.8 / 12.12). Use the
  hardware divider and root (`div32`, `mod32`, `sqrt32`); avoid C `/` and `%` in hot loops.
- No unaligned 32-bit access; use 16-bit halfwords, `memcpy` or DMA. VRAM needs
  16/32-bit writes on hardware, not 8-bit.
- Main RAM to DMA: `DC_FlushRange` the source first; `DC_InvalidateRange` the
  destination before the CPU reads DMA-written RAM.
- OAM: 128 sprites, 32 affine matrices, per-scanline sprite limits.
- `MODE_FB0/FB1` shows a raw VRAM bank and disables BGs, sprites and 3D on that engine.
- Measure on the DS. A feature that looks fine but drops below 60 FPS on the
  console is not done.

## Hardware loop (detail: `references/hardware-workflow.md`)

Build a `perf` variant (`DS_PERF`, `DS_REPLAY`, `DS_CRASHLOG` from
`templates/dsagent/`) with a replay generated from a scenario's `input_trace.json`.
After the user confirms the upload, they only open the ROM and wait for
`REPLAY_DONE`; then run `fetch-device-log.ps1` and read average, max, `over` and
`slow`. Compare A/B on the same replay. Rebuild the default variant before delivering.

## GDB

`validate-gdb.ps1` exposes ARM9 GDB for a concrete hypothesis (crash location,
breakpoint, registers). It needs the ELF sidecar for symbols and proves nothing
about audio, timing or hardware. Hardware-only crashes: the `ds_crash` log on the SD.

## DS upload

- Only after explicit user confirmation, valid for that one upload. Run
  `upload-rom.ps1 ... -DryRun` first (checks sha, staleness, variant), then
  `-ConfirmUpload`. Upload the ROM built from the worktree you worked in.
- It refuses `ROM_UNKNOWN` (sha differs from the last build) and `ROM_STALE`.
  `FTP_UNREACHABLE` means the DS is not running its FTP server: ask the user to
  open it; do not retry blindly. Settings come from `config/ftp.json`, the
  project's `romUploadName`, an optional gitignored `.ds-game-dev/ftp.local.json`,
  then parameters.
- Report remote file, size, branch, commit and variant from `FTP_UPLOAD_RESULT`,
  and what the user should look for on the console. Flag a non-default variant
  (perf, debug) to the user as such.

## Boundaries

- Product decisions: the project's `DESIGN.md`. Invariants: `TECHNICAL.md`.
  Process, branches, commits, merges: `AGENTS.md`. Do not invent product behaviour.
- Changes to this skill go on a branch/worktree of the skill repo
  (`agentic-ds-dev.wt-<name>`), never on its `main` checkout.
- No Android/ADB, melonDS or NO$GBA unless the project authorizes it.
- The runtime's `--jit` is experimental (it froze a real ROM); never use it for evidence.
