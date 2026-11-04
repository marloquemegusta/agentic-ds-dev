# DeSmuME headless agent: parches y build

`runtime/bin/libdesmume.so` es DeSmuME (upstream `b3915949700be824253a35affa7f7b8248e84e46`)
con la interfaz headless y el stub GDB ARM9/ARM7. Overlay actual: **agent-2**
(`desmume_agent_version()` devuelve `"agent-2"`).

## Contenido (se aplican en este orden sobre upstream limpio)

| Fichero | Contenido |
| :--- | :--- |
| `desmume-agent.patch` | Interfaz headless: audio dummy, API exportada, `meson.build` con gdb-stub. |
| `desmume-keypad-contract.patch` | Contrato de entrada: `KEYINPUT` activo-bajo sincronizado con el ABI de teclado y lecturas inline de ARM9 (`MMU.h`). |
| `desmume-agent-2.patch` | Overlay agent-2: captura de debug no$gba, `desmume_agent_set_jit`, RTC fijo, `desmume_agent_version`. |
| `gdb_agent.cpp`, `gdb_thread.cpp` | Ficheros nuevos, se copian a `desmume/src/frontend/interface/`. |

Los parches deben conservar sus bytes exactos (algunos ficheros upstream, como `MMU.h`, usan CRLF):
`.gitattributes` los marca `-text`. Se aplican con `git apply` (sin `--ignore-whitespace`).

## ABI anadido en agent-2

- `const char* desmume_agent_version(void)`: `"agent-2"`.
- `int desmume_agent_debug_read(char* buf, int cap)`: vacia (hasta `cap-1` bytes, NUL final) el buffer
  circular de 64 KB con la salida de debug de la ROM y devuelve los bytes copiados.
  Captura escrituras ARM9/ARM7 a los registros no$gba: `0x04FFFA10` (cadena cruda),
  `0x04FFFA14` (cadena con `%param%`), `0x04FFFA18` (cadena con `%param%` + LF), `0x04FFFA1C` (un caracter).
  Cada cadena (max. 256 bytes) se guarda con `\n` final si no lo traia. `%param%` soportados:
  `%r0%`..`%r15%`, `%sp%`, `%lr%`, `%pc%`, `%frame%`, `%scanline%`, `%%`; el resto pasa tal cual.
  Estos registros ya no generan el spam `undefined register 04FFFA14h`.
- `void desmume_agent_set_jit(int enabled)`: activa/desactiva el dynarec x64 (compilado: `x64-JIT SSE2`).
  Llamar tras `desmume_init` y antes de `desmume_open`. **Aviso:** con la ROM de prueba
  (`dungeonds.nds`) el JIT se congela tras ~20 frames; no usarlo por defecto. El stub GDB lo apaga solo.
- `void desmume_agent_set_rtc_fixed(int enabled)`: **por defecto 1**. El RTC arranca el 2026-01-01 00:00:00
  y avanza con los frames emulados (~59,83 fps), de modo que `time()` es reproducible. `0` = hora del host.

## Reconstruir

`scripts/build-runtime.ps1` hace todo desde cero en WSL (clona upstream en
`~/.cache/ds-agent-desmume/src`, fija el commit de `runtime/SOURCE-VERSION`, aplica los parches,
compila fuera de `/mnt/c` y copia el `.so` a `runtime/bin/`, actualizando `runtime/SHA256SUMS`).
`scripts/setup.ps1` descarga el binario precompilado cuando no hace falta reconstruir.
