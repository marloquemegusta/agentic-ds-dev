// Sonda de ROM parcial (la inyecta build-project.ps1 en el arbol de build; nunca vive en el juego).
// Redirige fopen/open (-Wl,--wrap) y anota cada ruta nitro:/ que el juego intenta abrir
// (g_nitro_trace) y cada una que falla (g_nitro_missing). Rutas relativas a nitrofiles/, acabadas en 0.
// El emulador lee los globales por simbolo (build-partial-rom.ps1).
// El juego puede definir nitro_missing_hook(path): se llama una vez por ruta fallida.
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>

#define NITRO_TRACE_DATA 12284
#define NITRO_MISSING_DATA 2044

struct NitroTrace { uint32_t len; char data[NITRO_TRACE_DATA]; };
struct NitroMissing { uint32_t len; char data[NITRO_MISSING_DATA]; };
struct NitroTrace g_nitro_trace;
struct NitroMissing g_nitro_missing;

FILE *__real_fopen(const char *path, const char *mode);
int __real_open(const char *path, int flags, ...);

__attribute__((weak)) void nitro_missing_hook(const char *path) { (void)path; }

// Devuelve 1 si la ruta es nueva en la lista.
static int nitro_list_add(uint32_t *len, char *data, uint32_t cap, const char *p) {
    const uint32_t n = (uint32_t)strlen(p) + 1;
    if (n == 1 || *len + n > cap) return 0;
    for (uint32_t i = 0; i < *len;) {
        const char *e = data + i;
        if (strcmp(e, p) == 0) return 0;
        i += (uint32_t)strlen(e) + 1;
    }
    memcpy(data + *len, p, n);
    *len += n;
    return 1;
}

static const char *nitro_rel(const char *path) {
    if (!path || strncmp(path, "nitro:", 6) != 0) return 0;
    const char *p = path + 6;
    while (*p == '/') p++;
    return p;
}

static void nitro_note(const char *path, int ok) {
    const char *p = nitro_rel(path);
    if (!p) return;
    nitro_list_add(&g_nitro_trace.len, g_nitro_trace.data, NITRO_TRACE_DATA, p);
    if (!ok && nitro_list_add(&g_nitro_missing.len, g_nitro_missing.data, NITRO_MISSING_DATA, p))
        nitro_missing_hook(p);
}

FILE *__wrap_fopen(const char *path, const char *mode) {
    FILE *f = __real_fopen(path, mode);
    nitro_note(path, f != 0);
    return f;
}

int __wrap_open(const char *path, int flags, ...) {
    va_list ap;
    va_start(ap, flags);
    const int mode = va_arg(ap, int);
    va_end(ap);
    const int fd = __real_open(path, flags, mode);
    nitro_note(path, fd >= 0);
    return fd;
}
