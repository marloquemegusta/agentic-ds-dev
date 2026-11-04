/* Minimal Nintendo DS game: text console on both screens plus a probe struct
 * that headless scenarios read from RAM (see scenarios/smoke.json). */
#include <stdint.h>
#include <stdio.h>
#include <nds.h>

#include "ds_log.h"
#include "logic.h"

/* Scenarios assert on this struct: keep the field order (each is an int32). */
volatile struct {
    int32_t frame;
    int32_t presses_a;
    int32_t last_keys;
    int32_t touch_x;
    int32_t touch_y;
} g_probe;

int main(void)
{
    PrintConsole top;
    int32_t clicks = 0;

    videoSetMode(MODE_0_2D);
    vramSetBankA(VRAM_A_MAIN_BG);
    consoleInit(&top, 0, BgType_Text4bpp, BgSize_T_256x256, 31, 0, true, true);
    consoleDemoInit(); /* sub screen */

    consoleSelect(&top);
    printf("Top screen\nPress A, touch the bottom screen.\n");
    DS_LOG("boot");

    while (1) {
        touchPosition touch;
        uint32_t down, held;

        swiWaitForVBlank();
        scanKeys();
        down = keysDown();
        held = keysHeld();

        g_probe.frame++;
        g_probe.last_keys = (int32_t)held;
        if (down & KEY_A) {
            g_probe.presses_a++;
            clicks = clamp_i32(clicks + 1, 0, 999);
            DS_LOG("A pressed, count=%ld", (long)g_probe.presses_a);
        }
        if (held & KEY_TOUCH) {
            touchRead(&touch);
            g_probe.touch_x = touch.px;
            g_probe.touch_y = touch.py;
        }

        consoleClear();
        printf("frame %ld\nA presses %ld (clamped %ld)\nkeys %04lX\ntouch %ld,%ld\n",
                (long)g_probe.frame, (long)g_probe.presses_a, (long)clicks,
                (unsigned long)held & 0xFFFu, (long)g_probe.touch_x, (long)g_probe.touch_y);
    }
    return 0;
}
