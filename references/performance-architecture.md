# Nintendo DS High-Performance Architecture & Engineering Contracts
*Hardware Budgets, Memory Contracts, and Rendering Patterns by Game Archetype*

---

## 1. The Game Archetype Catalog

The Nintendo DS features an ARM946E-S application processor clocked at 67.028 MHz with dual 2D/3D hardware graphics engines, tightly-coupled memories (TCM), and 656 KB of remappable VRAM. Because the hardware offers vastly different execution characteristics depending on rendering mode, the SDK organizes performance contracts into **Game Archetypes**:

- **Archetype 1: 2D High-Entity Swarms & Software Framebuffers (Current Focus)**
  *Applies to:* Tower Defense, RTS swarms, bullet hells, particle-heavy arenas, dynamic destructible terrain, and continuous dual-screen vertical battlefields.
  *Key Technique:* Mode FB0/FB1 direct hardware double-buffering, Sub-Engine Mode 5 8-bit bitmap pipeline, 32-bit quad blitting, 8x8 dirty block restoration, and spatial hashing.
- **Archetype 2: 2D Hardware Tilemaps & OAM Sprites (Catalog Expansion)**
  *Applies to:* Traditional platformers, top-down RPGs, fighting games, and side-scrolling action.
  *Key Technique:* Hardware text/affine background layers, 128 hardware OAM sprite engine, palette swapping, and VBlank OAM DMA updates.
- **Archetype 3: 3D Fixed-Function Geometry & Texturing (Catalog Expansion)**
  *Applies to:* 3D racing, first-person dungeon crawlers, polygon action, and low-poly 3D models.
  *Key Technique:* Geometry engine FIFO commands, display lists, vertex culling, packed vertex coordinates, and texture VRAM bank allocation.

---

## 2. Hardware Performance Budget (The 60 FPS Golden Rule)

### ARM9 Frame Budget
Under the standard hardware configuration, Timer 0 configured with `ClockDivider_1024` gives:
$$\text{Timer Frequency} = \frac{33.514\text{ MHz}}{1024} \approx 32,728\text{ Hz}$$
$$\text{Frame Budget @ 60 FPS} = \frac{32,728}{60} = \mathbf{545\text{ ticks}}.$$

### Golden Subsystem Budget Breakdown (545 ticks total)
| Subsystem Phase | Target Budget (60 FPS) | Description |
| :--- | :--- | :--- |
| **S (Simulation & Logic)** | $\le 100$ ticks | Movement, pathfinding, spatial hash, and combat. |
| **R (Background Restore)** | $\le 80$ ticks | 8x8 dirty grid block restoration from clean cache. |
| **E (Entity Blitting)** | $\le 300$ ticks | Sprite blitting, alpha test, and drawing. |
| **P (Presentation & DMA)**| $\le 50$ ticks | Hardware page flips and 48 KB DMA transfers. |
| **Headroom (Safety Margin)** | $\ge 15$ ticks | Unforeseen audio mixing or interrupt jitter. |

---

## 3. Memory Hierarchy & Latency Characteristics

1. **ITCM (32 KB, Instruction Tightly Coupled Memory):**
   - 0 wait states, 64-bit wide bus directly to the ARM9 execution pipeline.
   - **Rule:** Place critical inner loops, blitters, and dirty restorers in ITCM using:
     `ITCM_CODE __attribute__((target("arm"))) void function_name(...)`
2. **DTCM (16 KB, Data Tightly Coupled Memory):**
   - 0 wait states, single-cycle 32-bit read/write.
   - **Rule:** Store critical lookup tables, conversion ramps, and active 256-color palettes in DTCM.
3. **Main RAM (4 MB):**
   - Cached through ARM9 L1 cache: 8 KB Instruction Cache, 4 KB Data Cache (Write-Back).
   - Direct accesses or cache misses incur bus wait states.
4. **VRAM (Banks A–I, 656 KB total):**
   - Accessible by 2D engines, 3D engine, and ARM9 CPU/DMA.
   - **Contention Rule:** CPU writes directly to active VRAM during display scanout cause memory wait states. Never write directly to VRAM in real-time unless using dedicated hardware double buffering or VBlank DMA.

---

## 4. The Cache Coherency Contract (D-Cache vs. DMA)

The ARM946E-S Data Cache is a **Write-Back** cache. CPU writes to memory reside in cache lines and are only committed to physical Main RAM when evicted.

### Critical Failure Mode:
DMA controllers on the Nintendo DS bypass the ARM9 cache and read **directly from physical Main RAM**. If the CPU modifies a memory buffer in RAM and triggers a DMA transfer without flushing the cache, the DMA controller reads **stale physical memory (typically zeros or garbage)**.

### Mandatory Rules:
1. **DMA to VRAM Flush:**
   Whenever CPU writes to a Main RAM frame backbuffer transferred via DMA to VRAM:
   ```c
   DC_FlushRange(g_top_backbuffer, SCREEN_W * SCREEN_H);
   dmaCopyWords(1, g_top_backbuffer, s_top_vram, SCREEN_W * SCREEN_H);
   ```
2. **RAM-to-RAM Transfers:**
   For copying data between two Main RAM buffers (e.g., ground cache to screen backbuffer), **always use CPU `memcpy()`** rather than DMA. CPU `memcpy` operates inside the cache, executes at full 32-bit burst speed, and guarantees 100% data coherency without cache flushes.

---

## 5. Architectural Contract: Archetype 1 (High-Entity Swarms & Direct Framebuffers)

### A. Bottom Screen Hardware VRAM Double-Buffering
- Map Bank A and Bank B to the Main 2D Engine in Direct Framebuffer mode:
  ```c
  lcdMainOnBottom();
  vramSetBankA(VRAM_A_LCD);
  vramSetBankB(VRAM_B_LCD);
  videoSetMode(MODE_FB0);
  ```
- Alternate display registers at VBlank without memory copies:
  ```c
  videoSetMode(s_bot_fb_idx ? MODE_FB1 : MODE_FB0);
  s_bot_fb_idx ^= 1;
  g_backbuffer = s_bot_fb_idx ? (uint16_t *)VRAM_B : (uint16_t *)VRAM_A;
  ```
- **Cost:** 0 ticks for presentation (`P = 0` on bottom screen).

### B. Top Screen Native 8-bit Bitmap Pipeline (`BgType_Bmp8`)
- Configure Sub-Engine in 2D Mode 5 and initialize an 8-bit bitmap on Bank C:
  ```c
  videoSetModeSub(MODE_5_2D);
  vramSetBankC(VRAM_C_SUB_BG);
  int bg = bgInitSub(3, BgType_Bmp8, BgSize_B8_256x256, 0, 0);
  ```
- Populate the 256-color palette in `BG_PALETTE_SUB`. 130–180 colors for sprites + 20 terrain colors + 15 UI phosphors.
- **Benefits:**
  - Screen buffer payload is **48 KB** instead of 96 KB.
  - DMA presentation time drops from 192 ticks to **48 ticks** (-75%).
  - Blitter operates without runtime software palette lookups.

### C. Direct 32-bit Quad Blitting
- Store master sprite animation frames as 8-bit palettized arrays padded to 4-byte boundaries.
- **Quad Optimization Rules:**
  1. **Quad Zero Skip:** In sprite bounding boxes, ~25–40% of 4-pixel chunks are transparent. Check 4 pixels simultaneously:
     ```c
     uint32_t qval = quad_src[q];
     if (qval == 0) continue; // 4 pixels skipped in 1 ARM cycle
     ```
  2. **Quad Opaque Store:** When all 4 pixels are non-zero (typically >40% of sprite interiors):
     ```c
     if ((qval & 0xFF) && (qval & 0xFF00) && (qval & 0xFF0000) && (qval & 0xFF000000)) {
         dst32[q] = qval; // 4 pixels written in 1 instruction (STR)
     }
     ```
  3. **Unaligned Fallback:** If destination X is not 4-byte aligned, load 32-bit words from source and store non-zero bytes individually.

### D. Deduplicated Dirty Block Restoration (8x8 Grid)
- Never clear full screens or redraw all background tiles every frame.
- Divide the $256 \times 192$ screen into $32 \times 24$ blocks of $8 \times 8$ pixels.
- Track dirty regions using an array of 24 32-bit mask words:
  `uint32_t s_dirty_mask[DIRTY_GRID_H];`
- **The Contract:** Every dynamic visual entity (enemies, bullets, bullet darts, casings, blood chunks, muzzle flashes, dragged UI) **must** call:
  `tiles_dirty_mark_rect(x, y, w, h, is_bottom, buf_idx);`
- On the next frame, traverse mask words and restore dirty runs from clean background cache using burst `memcpy`.
- Under VRAM double-buffering, maintain separate mask arrays per buffer (`s_dirty_mask_bot[2]`).

### E. Spatial Partitioning for Swarm Simulation
- Pairwise comparisons between $N$ entities scale as $O(N^2)$. At $N = 384$, $384^2 = 147,456$ iterations—impossible at 66 MHz.
- Implement a 2D uniform spatial grid with cell size equal to maximum interaction radius (e.g., $16 \times 16$ px cells $\implies 16 \times 24$ grid).
- Build head-pointer list in $O(N)$:
  ```c
  for (int cell = 0; cell < GRID_CELLS; cell++) s_grid_heads[cell] = -1;
  for (int i = 0; i < MAX_ENEMIES; i++) {
      if (!g_enemies[i].active) continue;
      int c = cell_index(g_enemies[i].x, g_enemies[i].y);
      s_grid_next[i] = s_grid_heads[c];
      s_grid_heads[c] = i;
  }
  ```
- Flocking avoidance, range queries, and collision hit-scans query only the local $3 \times 3$ neighborhood, reducing candidate iterations by >92%.

---

## 6. Verification and Telemetry Standards

Every high-performance DS project must implement deterministic telemetry:
1. **Timer 0 Subsystem Profiler:** Measure elapsed ticks across simulation, background restore, entity blit, and DMA presentation.
2. **Compact HUD Metric String:** Render instantaneous and 1-second rolling averages on-screen:
   `FPS:60 T:482 B:24 P:48 S:45 E:128`
3. **Automated Stress Scenarios:** Include stress scenarios in `scenarios/` with maximum entity populations to verify that frame time does not exceed 545 ticks.
