# Partial ROM (only the cartridge files a test needs)

Goal: upload a few-MB ROM instead of the full one (~56 MB of `nitrofiles`) to debug one mechanic, with a guarantee that nothing it needs is missing.

## Contract + catalog

- `<project>\.ds-game-dev\partial\catalogo.json`: concept -> patterns under `nitrofiles/` (`"dir/"` = folder, `*` wildcard, or a file).
  A pattern may be `{"patron": "remate/parroco_*", "con": "remates"}` (only if the contract also has `remates`) and a concept or pattern may be `"opcional": true` (the game has a fallback; not counted as missing).
  ```json
  { "conceptos": {
      "luz":     { "opcional": true, "archivos": ["arpg_luz/"] },
      "parroco": { "archivos": ["chars/exvoto_parroco_run.bin", { "patron": "remate/parroco_*", "con": "remates" }] } } }
  ```
- Contract `<project or anywhere>\...\partial\<name>.txt`: concept names separated by spaces/lines, `#` comments, optional `archivo: <path>` lines for a loose file. The catalog is read from the contract's folder. Unknown concept = error listing the valid ones.
- **Coverage:** every file in `nitrofiles/` must match some concept, otherwise the build fails naming it ("add it to the catalog").

## Build + verify (the normal way)

```powershell
powershell -NonInteractive -ExecutionPolicy Bypass -File scripts\build-partial-rom.ps1 -ProjectPath <wt> -Variant <v> -Contract <name|path> -Scenarios 'scenarios\foo_*.json' [-OutputRom <path>] [-Look]
```

- `-Scenarios` is mandatory (files or patterns, relative to the project): they must play everything the ROM is for. The verification proves only what they open.
- It calls `build-project.ps1 -Contract <file>` (own tree `<v>-<name>`, output `<rom>-<v>-<name>.nds`, or `-OutputRom`), which copies only the contract's files and injects `scripts/partial/nitro_probe.c` into the build tree (+ `-Wl,--wrap=fopen -Wl,--wrap=open`). Nothing is needed in the game; normal builds are untouched.
- The probe records every `nitro:/` path the game tries to open (`g_nitro_trace`) and every one that fails (`g_nitro_missing`). The script plays each scenario (temp copy with `state.elf` on the partial ELF and a final `state_capture` of the symbol) and prints `PARTIAL_VERIFY=PASS|FAIL`. FAIL (exit 1) lists `FALTA <file> (scenario; anade: <concepts>)` and `PARTIAL_MISSING ...`.
- Not failures: files whose concept is optional, and files that do not exist in the full `nitrofiles/` either (reported, not the contract's fault).
- Optional game hook: `void nitro_missing_hook(const char *path)` (weak in the probe) is called once per failed path.
- Code is never trimmed: only `nitrofiles`. The game must tolerate a missing file.

Upload: `upload-rom.ps1 -ProjectPath <wt> -RomPath <rom> -ConfirmUpload` (remote name stays `romUploadName`).

## Starting a contract

`build-partial-rom.ps1 ... -Record -Scenarios <...>`: builds with the probe and the full `nitrofiles/`, plays the scenarios and prints `PARTIAL_RECORD concepts: ...`. It only sees what they touch (finishers never done are missing): edit by hand, then verify.
`build-project.ps1 -NitroTrace` is that same probe build (tree `<v>-trace`).
