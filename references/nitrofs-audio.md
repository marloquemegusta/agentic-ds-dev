# NitroFS & Streaming Audio (BlocksDS + Maxmod)

Nintendo DS Main RAM (`ewram`) is **4 MB**, while a `.nds` ROM can hold tens of megabytes in **NitroFS** (`nitro:/`). Use NitroFS whenever static assets approach the `ewram` ceiling (`section '.bss' is not within region 'ewram'`).

## 1. Main RAM vs NitroFS Decision Rule

| Asset type | Where it goes | Why |
| :--- | :--- | :--- |
| Hot combat SFX (< 30 KB total), physics/lookup tables | Main RAM (or Maxmod `soundbank.bin` loaded via `mmLoadEffect`) | Zero-latency trigger, minimal footprint |
| BGM loops, boss themes, multi-biome maps, large UI screens | **NitroFS (`nitro:/`)** | Zero static `ewram` cost; streamed or loaded on demand |

## 2. Project Setup (`.ds-game-dev/project.json` & `Makefile`)

1. **`.ds-game-dev/project.json` (`copy`):**
   ```json
   { "source": "nitrofiles", "destination": "nitrofiles" },
   { "source": "assets/sfx/baked", "destination": "audio" }
   ```
2. **Project `Makefile` (`templates/blocksds-test/Makefile`):**
   ```makefile
   NITROFSDIR := nitrofiles
   AUDIODIRS := audio
   LIBDIRS := $(BLOCKSDS)/libs/maxmod
   LIBS := -lmm9 -lnds9
   ```
   *(In BlocksDS, `nitroFSInit` is included in `-lnds9`; no `-lfilesystem` flag is needed).*

## 3. Runtime Pattern (Zero `float`, Host-Testable)

- Guard `<nds.h>`, `<filesystem.h>`, `<maxmod9.h>`, and `"soundbank.h"` with `#ifdef ARM9` so host C tests compile without BlocksDS headers.
- Initialize once at startup:
  1. `if (!nitroFSInit(NULL))` → log/flag failure (never fail silently).
  2. `mmInitDefault("nitro:/soundbank.bin");` and `mmLoadEffect(SFX_...)` for each SFX.
  3. Open `fopen("nitro:/bgm.raw", "rb")` and start `mmStreamOpen(&st)` with `MM_STREAM_8BIT_MONO` (11,025 Hz signed 8-bit PCM, scaled to ~40–45% amplitude so SFX punch above it), `buffer_length = 2048`, `manual = true`.
- Call `mmStreamUpdate()` once per frame in the main loop (never inside an IRQ).
- Use `mmEffectEx()` for SFX (supports `rate = 1024` pitch jitter, `volume 0..255`, `panning 0..255`) and `mmEffectCancel(handle)` to cut charge loops on fire/cancel/death.

## 4. Verification

- **L0:** `build-project.ps1` passes with 0 new warnings.
- **L2 (DeSmuME):** verify `nitroFSInit` succeeds when DeSmuME launches the `.nds`.
- **L4 (Hardware):** verify on real DS that streaming from NitroFS introduces no frame drops (`PERF_PROFILE`) and that BGM/SFX balance works on the console speakers.
