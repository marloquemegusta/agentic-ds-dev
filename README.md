# Agentic Nintendo DS Development Skill (`agentic-ds-dev`)

Autonomous Nintendo DS development skill designed for AI coding agents (Codex, Antigravity, Claude Code, etc.) and developers.

It bundles:
* **Dockerized BlocksDS toolchain** for isolated, reproducible ROM compilation.
* **Headless DeSmuME runtime** with an automated input engine (buttons, touch coordinates, frame advancement, screenshots, and visual diff assertions).
* **ARM9 GDB remote debugging** stub integration.
* **Scaffolding and contracts** for test-driven homebrew development.

---

## Prerequisites

- **Windows 10 / 11** with PowerShell.
- **WSL 2** with Python 3 (runs the headless DeSmuME ABI and GDB stub).
- **Docker Desktop** (used to compile ROMs via the official BlocksDS container).

---

## Quick Start / Setup

Clone this skill into your local skills directory:

```bash
git clone https://github.com/marloquemegusta/agentic-ds-dev.git
cd agentic-ds-dev
```

Bootstrap the runtime environment:

```powershell
.\scripts\setup.ps1
```

Verify that all tools and runtimes are operational:

```powershell
.\scripts\check-toolchain.ps1
```

---

## Workflow & Scripts

| Script | Description |
|---|---|
| `.\scripts\setup.ps1` | Bootstraps headless DeSmuME binaries from Releases & prepares BlocksDS Docker image. |
| `.\scripts\check-toolchain.ps1` | Verifies WSL2, Docker, Python, BlocksDS container, and DeSmuME runtime status. |
| `.\scripts\scaffold-project.ps1 -ProjectPath <path>` | Scaffolds a new standard DS homebrew project layout. |
| `.\scripts\build-project.ps1 -ProjectPath <path>` | Builds the Nintendo DS ROM (`.nds`) using BlocksDS, incrementally (`-Clean` forces a full rebuild). |
| `.\scripts\run-scenario.ps1 -RomPath <rom> -ScenarioPath <scenario> -OutputPath <out>` | Runs a deterministic headless test scenario with touch/buttons and collects PNG captures. |
| `.\scripts\validate-gdb.ps1 -RomPath <rom>` | Spawns DeSmuME with ARM9 GDB stub and validates register reads and breakpoints. |
| `.\scripts\upload-rom.ps1 -ProjectPath <path> -RomPath <rom> -ConfirmUpload` | Uploads the built ROM over FTP with the project's `romUploadName`; refuses stale ROMs and checks the port first. |
| `.\scripts\fetch-device-log.ps1 -ProjectPath <path> -RemoteFile /<file>.log` | Downloads a log the ROM wrote to the SD card (profiling, crash reports) into `artifacts/device-logs/`. |

---

## Architecture & Binary Distribution

To keep this repository lightweight (< 1 MB) and fast to clone:
* Precompiled Linux x86_64 binaries (`libdesmume.so` and `desmume-agent`) are hosted as release assets on [GitHub Releases](https://github.com/marloquemegusta/agentic-ds-dev/releases).
* Source patches and instructions to recompile the headless DeSmuME runtime from upstream are available in `runtime/patches/`.
* BlocksDS is pulled automatically from Docker Hub (`skylyrac/blocksds:slim-latest`).
