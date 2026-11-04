# Nintendo DS performance architecture

Hardware budgets, memory rules and rendering patterns by game type. These are
design targets, not guarantees: certify frame time on the console
(`hardware-workflow.md`), never in the emulator.

## 1. Frame budget

The ARM946E-S runs at 67.028 MHz; the bus at 33.514 MHz. One frame at the native
59.826 Hz is 16.715 ms:

| Counter | Per frame |
| :--- | :--- |
| `cpuGetTiming()` bus ticks (33.514 MHz) | **560,190** (33,514 = 1 ms) |
| ARM9 CPU cycles (67.028 MHz) | ~1,120,000 |
| Timer at `BUS_CLOCK / 1024` | ~547 (545 at exactly 60 Hz) |

Always name the counter next to the number and state which interval a profiler
measures. 263 scanlines per frame (0..191 visible); work may continue in VBlank, so
`REG_VCOUNT` is telemetry, not a deadline.

Splitting the budget by stage (simulation, background restore or streaming,
entity composition, DMA/VRAM writes, presentation) is useful. Any split is an
unverified example for your workload: measure it, do not copy numbers. Counters
must not overlap and must not count the VBlank wait as CPU work.

## 2. Game types

| Type | Typical games | Key techniques |
| :--- | :--- | :--- |
| A. Software framebuffer, many entities | Swarms, bullet hells, destructible terrain | Bitmap modes (`MODE_FB0/FB1`, 8-bit bitmap BG), dirty-block restore, spatial grid |
| B. Hardware tilemaps and OAM sprites | Platformers, RPGs, fighting, scrollers | Text/affine BG layers, 128 OAM sprites, palette swaps, VBlank OAM update |
| C. 3D fixed-function | Racing, dungeon crawlers, low-poly | Geometry FIFO, display lists, culling, packed vertices, texture VRAM banks |

Prefer type B hardware features whenever the game fits; a software framebuffer
costs CPU for every pixel touched.

## 3. Memory hierarchy

1. **ITCM (32 KB):** zero-wait instruction memory. Place hot inner loops there:
   `ITCM_CODE __attribute__((target("arm"))) void f(...)`. BlocksDS builds ARM9
   code as Thumb by default; hot loops usually want ARM mode.
2. **DTCM (16 KB):** zero-wait data. Keep small hot tables, ramps and the stack
   pressure in mind; it is small.
3. **Main RAM (4 MB):** reached through the ARM9 caches (8 KB I-cache, 4 KB
   D-cache, write-back). Misses cost bus wait states.
4. **VRAM (banks A-I, 656 KB):** shared by the 2D engines, 3D and the CPU/DMA.
   - Writes while a bank is mapped to a display being scanned out can contend
     with the display. Draw into a bank that is not currently displayed
     (the back buffer, see section 5A) or write during VBlank.
   - VRAM does not support reliable 8-bit CPU writes on hardware: use 16- or
     32-bit writes (or DMA). Emulators may accept byte writes; verify on the DS.
   - Unaligned 32-bit access is not fixed up by the ARM946E-S. An unaligned `LDR`
     returns the aligned word rotated by `8 * (addr & 3)` bits; an unaligned `STR`
     writes to `addr & ~3`. Access unaligned data as halfwords, or use aligned
     words, `memcpy` or DMA.

## 4. Cache coherency (D-cache and DMA)

The data cache is write-back and DMA bypasses it.

- Before DMA reads main RAM that the CPU wrote: `DC_FlushRange(src, len)`.
  Without it the DMA may read stale RAM.
- Before the CPU reads main RAM that DMA wrote: `DC_InvalidateRange(dst, len)`.
  Make sure no dirty lines in that range will be written back over the DMA data.
- RAM to RAM: choose `memcpy` or DMA by measurement. Cached `memcpy` often wins
  for small or moderate sizes; DMA has setup, bus and coherency costs. Prefer
  removing the copy (hardware scrolling, tile streaming, drawing in place).
- Hardware divider and root: `div32`, `mod32`, `sqrt32`. C `/` and `%` call a
  library routine; avoid them in hot loops, or use shifts and reciprocal tables.
- No `float`/`double` in per-frame code (soft-float); use 8.8 or 12.12 fixed point.

## 5. Patterns for a software framebuffer (type A)

Examples; adapt to the game and verify cost on the DS.

### A. Back buffer in a non-displayed VRAM bank

Map two banks to LCD (`VRAM_A_LCD`, `VRAM_B_LCD`) and flip which one the engine
shows with `videoSetMode(MODE_FB0)` / `MODE_FB1` at VBlank. The CPU writes only
the bank that is not displayed, so no copy is needed and presentation costs
nothing:

```c
lcdMainOnBottom();
vramSetBankA(VRAM_A_LCD);
vramSetBankB(VRAM_B_LCD);
videoSetMode(MODE_FB0);
/* at VBlank */
videoSetMode(s_fb_idx ? MODE_FB1 : MODE_FB0);
s_fb_idx ^= 1;
g_back = s_fb_idx ? (uint16_t *)VRAM_B : (uint16_t *)VRAM_A;  /* write here */
```

`MODE_FB0/FB1` shows the raw bank and disables BGs, sprites and 3D on that engine.
Writes must be 16/32-bit (section 3).

### B. 8-bit bitmap background on the other screen

`videoSetModeSub(MODE_5_2D); vramSetBankC(VRAM_C_SUB_BG); bgInitSub(3, BgType_Bmp8, BgSize_B8_256x256, 0, 0);`
halves the buffer (48 KB instead of 96 KB) and the DMA to present it, at the
price of a 256-colour shared palette (`BG_PALETTE_SUB`) that you budget across
sprites, terrain and UI. Write it with 16/32-bit stores; flush the cache before
DMA from main RAM.

### C. Word-wide blitting

Store sprite frames as 8-bit palettized data padded to 4 bytes. Test four pixels
at once: skip a word that is zero; store a fully opaque word with one 32-bit
store; handle an unaligned destination by assembling aligned words or 16-bit
halves (not byte stores to VRAM). Measure the zero/opaque ratios of your art
before choosing this; the benefit depends on them.

### D. Dirty-rectangle restore

Do not clear or redraw the whole screen. Track 8x8 blocks that changed in a bit
mask (e.g. 24 words of 32 bits for 256x192), have every dynamic visual mark the
blocks it covers, and restore only those from a clean background cache with
burst copies. With page flipping keep one mask per buffer, since each buffer
needs the previous frame's dirt too.

### E. Spatial partitioning

Pairwise tests scale as O(N^2) (at N = 384 that is ~147,000 pairs per frame).
Use a uniform grid whose cell size is the largest interaction radius, build it
in O(N) with head/next index arrays each frame, and query the 3x3 neighbourhood
for avoidance, range queries and hit tests.

## 6. Telemetry

Measure stages separately with `cpuStartTiming`/`cpuGetTiming` or the
`templates/dsagent/ds_perf` kit; label units; keep headroom for audio,
interrupts and transfer variance. Count frames over budget and frames that spanned
more than one VBlank, not just averages. Use DeSmuME only for A/B comparison of
the same scenario; validate the exact ROM on the DS before claiming 60 FPS, and
mark the result unverified if hardware was unavailable.
