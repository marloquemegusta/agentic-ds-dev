# agentic-ds-dev

A skill for AI coding agents (and developers) that build Nintendo DS homebrew in
C with libnds and BlocksDS on Windows. It bundles:

- a Dockerized BlocksDS toolchain (incremental builds, build variants);
- a headless DeSmuME runtime with scripted input, memory-state assertions,
  captures, debug-log capture, savestates and an ARM9 GDB stub;
- host-test support (C tests with sanitizers), a ROM-side kit for on-device
  profiling, replay and crash logs, and FTP upload to a DS.

The agent entry point is `SKILL.md`; detailed material is in `references/`.

## Prerequisites

- Windows 10/11 with PowerShell.
- WSL 2 with `python3` (runs DeSmuME and GDB) and `gcc` (C host tests).
- Docker Desktop, or Docker Engine plus WSL 2 (BlocksDS container).

## Setup

```powershell
.\scripts\setup.ps1             # download the DeSmuME runtime, load the BlocksDS image
.\scripts\check-toolchain.ps1   # DS_TOOLCHAIN=PASS when everything is usable
```

`setup.ps1` downloads the runtime from the GitHub release (`-ReleaseTag`) and
verifies it against `runtime/SHA256SUMS`; it fails on a mismatch unless
`-AllowUnverified` is given. The release can lag the local `agent-2` build: after
patch changes, or if `check-toolchain.ps1` reports an older `agent_version`, run
`.\scripts\build-runtime.ps1` (WSL; applies `runtime/patches/` to the pinned
DeSmuME commit and updates `SHA256SUMS`). See `references/desmume-agent.md`.

## Scripts

| Script | Purpose |
| :--- | :--- |
| `setup.ps1` | Install the runtime and the BlocksDS image |
| `check-toolchain.ps1 [-ProjectPath]` | Verify Docker, image, WSL, runtime, gcc |
| `scaffold-project.ps1 -ProjectPath [-Title]` | Create the layout, `project.json` and starter files |
| `build-project.ps1 -ProjectPath [-Variant] [-Define] [-Clean]` | Build the ROM |
| `run-host-tests.ps1 -ProjectPath [-Filter]` | Run `hostTests` commands and `tests/c/test_*.c` |
| `run-scenario.ps1 -ScenarioPath [-ProjectPath] [-RomPath] [-OutputPath]` | Run one scenario |
| `run-scenarios.ps1 -ProjectPath [-Filter] [-Tag]` | Run many scenarios in one process |
| `validate-gdb.ps1 -RomPath` | ARM9 GDB breakpoint and register check |
| `upload-rom.ps1 -ProjectPath -RomPath (-DryRun \| -ConfirmUpload)` | FTP upload (needs user confirmation) |
| `fetch-device-log.ps1 -ProjectPath -RemoteFile` | Download a log written to the SD card |
| `build-runtime.ps1` | Rebuild `libdesmume.so` from the pinned upstream plus patches |

## Layout

| Path | Content |
| :--- | :--- |
| `SKILL.md` | Agent instructions |
| `references/` | `scenario-format`, `verification-levels`, `host-tests`, `hardware-workflow`, `performance-architecture`, `desmume-agent` |
| `templates/project/` | Starter game, smoke scenario, example C test |
| `templates/dsagent/` | ROM-side kit: `ds_log`, `ds_perf`, `ds_replay`, `ds_crash` |
| `templates/host-test/ds_test.h` | Single-header C test harness |
| `templates/blocksds-test/` | Default BlocksDS build template |
| `tools/scenario_to_replay.py` | Scenario or input trace to on-device replay |
| `runtime/` | Runner, patches, prebuilt binaries (`bin/` is fetched by `setup.ps1`) |

## Tests

`python -m unittest discover tests` (runner and replay converter).
