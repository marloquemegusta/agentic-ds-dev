# Bundled DeSmuME agent (overlay agent-2)

The skill owns the headless DeSmuME runtime: pinned upstream commit
(`runtime/SOURCE-VERSION`), patches (`runtime/patches/`, see its README), the
scenario runner (`runtime/run_scenario.py`) and the evidence format
(`scenario-format.md`). Projects provide only ROMs and scenarios.

## Capabilities and limits

- Headless, audio disabled, ARM9 GDB stub. Interpreter speed is roughly 70-80
  emulated frames per second.
- Exports `desmume_agent_version()` (`"agent-2"`; `check-toolchain.ps1` prints it),
  `desmume_agent_debug_read`, `desmume_agent_set_jit`, `desmume_agent_set_rtc_fixed`.
- **Debug capture:** text the ROM writes to the no$gba debug registers
  (`nocashMessage`, `DS_LOG`) is stored per scenario in `debug.log`.
  `%r0%..%r15%`, `%sp%`, `%lr%`, `%pc%`, `%frame%`, `%scanline%` are expanded.
- **RTC:** fixed at 2026-01-01 00:00:00 by default and advanced by emulated
  frames, so `time()` is reproducible in the emulator only. Hardware is not
  deterministic in this respect (see `hardware-workflow.md`).
- **JIT:** `--jit` / `-Jit` enables the x64 dynarec. It froze a real ROM
  (dungeonds, around frame 20) and was not faster. Experimental: never use it for
  evidence. The GDB stub turns it off.
- Runner: one process runs many scenarios; repeated emulator init segfaults, so it
  reopens the ROM per scenario. Frames never captured skip GPU rendering (8-frame
  lead before captures; hashes verified identical). Savestates are bound to the ROM sha256.
- Cannot validate: audio, SD/FAT, DSi, hardware timing or compatibility.
  DeSmuME frame timing never certifies performance (budget: 560,190
  `cpuGetTiming()` bus ticks per frame); use it for A/B only.

## Entry points

```powershell
.\scripts\run-scenario.ps1  -ProjectPath <repo> -ScenarioPath <scenario>
.\scripts\run-scenarios.ps1 -ProjectPath <repo> [-Filter <wildcard>] [-Tag <tag>]
.\scripts\validate-gdb.ps1  -RomPath <rom> -ProjectPath <repo>
```

Read `result.json` first, then `debug.log`, then captures (`SKILL.md`, evidence rules).

## Rebuilding the runtime

`scripts/build-runtime.ps1` (WSL only): clones upstream into
`~/.cache/ds-agent-desmume`, checks out the pinned commit, applies
`desmume-agent`, `desmume-keypad-contract`, `desmume-agent-2` in that order,
copies `gdb_agent.cpp`/`gdb_thread.cpp`, builds outside `/mnt/c`, copies
`libdesmume.so` to `runtime/bin/` and updates its line in `runtime/SHA256SUMS`.
Patches are byte-exact (`-text` in `.gitattributes`; some upstream files are
CRLF); do not reformat them. The GitHub release may lag this build; commit the
new `SHA256SUMS` together with any patch change. `setup.ps1` verifies downloads
against it.
