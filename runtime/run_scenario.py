#!/usr/bin/env python3
"""Run deterministic DS input scenarios against the headless DeSmuME ABI.

usage: run_scenario.py ROM.nds SCENARIO.json OUTPUT_DIR LIBRARY.so [MAP_FILE]

See references/scenario-format.md for the scenario JSON format.
"""

import ctypes
import hashlib
import json
import os
import struct
import sys
import zlib
from pathlib import Path


WIDTH = 256
HEIGHT = 384
RGB_SIZE = WIDTH * HEIGHT * 3
BUTTON_BITS = {
    "A": 1 << 0,
    "B": 1 << 1,
    "SELECT": 1 << 2,
    "START": 1 << 3,
    "RIGHT": 1 << 4,
    "LEFT": 1 << 5,
    "UP": 1 << 6,
    "DOWN": 1 << 7,
    "R": 1 << 8,
    "L": 1 << 9,
    "X": 1 << 10,
    "Y": 1 << 11,
}
# Backward-compatible map location used by older projects.
LEGACY_MAP = Path(".ds-game-dev") / "build" / "build" / "game-blocksds.map"
DELTA_KEYS = ("min_abs_delta", "min_delta", "max_delta", "max_abs_delta")
VALUE_KEYS = ("equals", "min_value", "max_value")


def log(message: str) -> None:
    print(message, flush=True)


def png_bytes(rgb: bytes) -> bytes:
    rows = b"".join(b"\x00" + rgb[y * WIDTH * 3:(y + 1) * WIDTH * 3] for y in range(HEIGHT))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def configure(lib):
    lib.desmume_init.restype = ctypes.c_int
    lib.desmume_open.argtypes = [ctypes.c_char_p]
    lib.desmume_open.restype = ctypes.c_int
    lib.desmume_resume.argtypes = []
    lib.desmume_cycle.argtypes = [ctypes.c_int]
    lib.desmume_screenshot.argtypes = [ctypes.POINTER(ctypes.c_ubyte)]
    lib.desmume_input_set_touch_pos.argtypes = [ctypes.c_uint16, ctypes.c_uint16]
    lib.desmume_input_release_touch.argtypes = []
    lib.desmume_input_keypad_update.argtypes = [ctypes.c_uint16]
    lib.desmume_input_keypad_get.restype = ctypes.c_uint16
    lib.desmume_memory_read_long.argtypes = [ctypes.c_uint32]
    lib.desmume_memory_read_long.restype = ctypes.c_uint32
    lib.desmume_free.argtypes = []


def button_bit(name: str) -> int:
    try:
        return BUTTON_BITS[name.upper()]
    except KeyError as error:
        raise ValueError(f"unknown button: {name}") from error


def capture(lib, path: Path) -> tuple[str, bytes]:
    raw = (ctypes.c_ubyte * RGB_SIZE)()
    lib.desmume_screenshot(raw)
    rgb = bytes(raw)
    path.write_bytes(png_bytes(rgb))
    return hashlib.sha256(rgb).hexdigest(), rgb


# ---------------------------------------------------------------- state ----

def map_symbol_address(map_path: Path, symbol: str) -> int:
    """Resolve a linked symbol address from a GNU ld map file.

    Looks for an input-section line (.bss.NAME / .data.NAME / .rodata.NAME);
    the address is on the same line or on the following one. Falls back to the
    global symbol table lines ("0xADDR   NAME").
    """
    sections = {f".{kind}.{symbol}" for kind in ("bss", "data", "rodata")}
    lines = map_path.read_text(encoding="utf-8", errors="replace").splitlines()
    for index, line in enumerate(lines):
        fields = line.split()
        if not fields or fields[0] not in sections:
            continue
        if len(fields) >= 2 and fields[1].startswith("0x"):
            return int(fields[1], 16)
        if index + 1 < len(lines):
            nxt = lines[index + 1].split()
            if nxt and nxt[0].startswith("0x"):
                return int(nxt[0], 16)
    for line in lines:
        fields = line.split()
        if len(fields) == 2 and fields[0].startswith("0x") and fields[1] == symbol:
            return int(fields[0], 16)
    raise ValueError(f"symbol {symbol!r} not found in {map_path}")


def resolve_map_path(state_config: dict, scenario_path: Path, cli_map: str | None,
                     rom: Path) -> Path:
    """scenario state.map > CLI arg / DS_MAP_PATH env > default build map.

    The default is looked up next to the ROM first (build-project.ps1 drops
    the ROM in the project root), then next to the scenario's parent dir.
    """
    scenario_dir = scenario_path.parent
    if "map" in state_config:
        return (scenario_dir / state_config["map"]).resolve()
    if "map_path" in state_config:  # legacy key, relative to the scenario's parent dir
        return (scenario_dir.parent / state_config["map_path"]).resolve()
    if cli_map:
        return Path(cli_map)
    if os.environ.get("DS_MAP_PATH"):
        return Path(os.environ["DS_MAP_PATH"])
    candidates = [(rom.parent / LEGACY_MAP).resolve(), (scenario_dir.parent / LEGACY_MAP).resolve()]
    return next((path for path in candidates if path.exists()), candidates[0])


def read_state(lib, bases: dict, fields: dict, default_symbol: str) -> dict:
    values = {}
    for name, spec in fields.items():
        if isinstance(spec, dict):
            symbol, offset = spec["symbol"], spec["offset"]
        else:
            symbol, offset = default_symbol, spec
        value = int(lib.desmume_memory_read_long(bases[symbol] + int(offset)))
        values[name] = value - 0x100000000 if value & 0x80000000 else value
    return values


def check_state_assertion(samples: dict, assertion: dict) -> dict:
    field = assertion["field"]
    is_delta = any(key in assertion for key in DELTA_KEYS)
    if "at" in assertion:
        before = None
        after = samples[assertion["at"]][field]
        delta = None
        if is_delta:
            raise ValueError(f"delta checks need from/to, not 'at': {assertion}")
    else:
        before = samples[assertion["from"]][field]
        after = samples[assertion["to"]][field]
        delta = after - before
    if "min_abs_delta" in assertion:
        passed = abs(delta) >= int(assertion["min_abs_delta"])
    elif "min_delta" in assertion:
        passed = delta >= int(assertion["min_delta"])
    elif "max_delta" in assertion:
        passed = delta <= int(assertion["max_delta"])
    elif "max_abs_delta" in assertion:
        passed = abs(delta) <= int(assertion["max_abs_delta"])
    elif "equals" in assertion:
        passed = after == int(assertion["equals"])
    elif "min_value" in assertion:
        passed = after >= int(assertion["min_value"])
    elif "max_value" in assertion:
        passed = after <= int(assertion["max_value"])
    else:
        raise ValueError(f"unsupported state assertion: {assertion}")
    result = {"field": field, "after": after, "passed": passed}
    if "at" in assertion:
        result["at"] = assertion["at"]
    else:
        result.update({"from": assertion["from"], "to": assertion["to"],
                       "before": before, "delta": delta})
    for key in DELTA_KEYS + VALUE_KEYS:
        if key in assertion:
            result[key] = assertion[key]
    return result


def state_label(result: dict) -> str:
    where = result["at"] if "at" in result else f"{result['from']}->{result['to']}"
    return f"state:{where}.{result['field']}"


# ----------------------------------------------------------------- main ----

def run(rom: Path, scenario_path: Path, output: Path, lib_path: Path,
        cli_map: str | None, ctx: dict) -> bool:
    """Execute the scenario. Fills ctx (events, captures, ...); returns pass/fail."""
    events = ctx["events"]
    captures = ctx["captures"]
    capture_pixels = {}
    state_samples = ctx["state_samples"]
    sequences = ctx["sequences"]
    frame = 0  # emulated frames cycled so far

    scenario = json.loads(scenario_path.read_text(encoding="utf-8-sig"))
    output.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    os.environ.setdefault("ALSOFT_DRIVERS", "null")
    lib = ctypes.CDLL(str(lib_path))
    configure(lib)
    try:
        if lib.desmume_init() != 0 or lib.desmume_open(str(rom).encode()) != 1:
            raise RuntimeError("DeSmuME failed to initialize or open ROM")
        lib.desmume_resume()

        state_config = scenario.get("state")
        state_bases = {}
        default_symbol = "state"
        if state_config:
            map_path = resolve_map_path(state_config, scenario_path, cli_map, rom)
            ctx["map_path"] = str(map_path)
            symbols = state_config["symbols"] if "symbols" in state_config else {"state": state_config["symbol"]}
            state_bases = {name: map_symbol_address(map_path, symbol) for name, symbol in symbols.items()}
            default_symbol = state_config.get("default_symbol", "state")

        keypad = 0

        def cycle() -> None:
            nonlocal frame
            lib.desmume_input_keypad_update(keypad)  # re-assert held buttons every frame
            lib.desmume_cycle(0)
            frame += 1

        def event(index: int, action: str, **fields) -> None:
            events.append({"step": index, "frame": frame, "action": action, **fields})

        for index, step in enumerate(scenario["steps"]):
            if "button_down" in step:
                keypad |= button_bit(step["button_down"])
                lib.desmume_input_keypad_update(keypad)
                event(index, "button_down", button=step["button_down"], keypad=keypad)
            if "button_up" in step:
                # Clear only this button; every other held button stays in the
                # mask and is re-asserted on each frame. The patched runtime
                # applies the mask to KEYINPUT on the next cycle, so no extra
                # flush is needed by default. "release_flush_frames" requests
                # extra frames (counted in the frame budget and logged).
                keypad &= ~button_bit(step["button_up"])
                lib.desmume_input_keypad_update(keypad)
                flush = max(0, int(step.get("release_flush_frames", 0)))
                for _ in range(flush):
                    cycle()
                event(index, "button_up", button=step["button_up"], keypad=keypad,
                      flush_frames=flush)
            if "tap" in step or "touch" in step:
                point = step["tap"] if "tap" in step else step["touch"]
                lib.desmume_input_set_touch_pos(point["x"], point["y"])
                event(index, "tap", x=point["x"], y=point["y"])
            if "drag" in step:
                drag = step["drag"]
                start = drag["from"]
                end = drag["to"]
                drag_frames = max(1, int(drag.get("frames", 1)))
                for n in range(drag_frames):
                    ratio = n / max(1, drag_frames - 1)
                    x = round(start["x"] + (end["x"] - start["x"]) * ratio)
                    y = round(start["y"] + (end["y"] - start["y"]) * ratio)
                    lib.desmume_input_set_touch_pos(x, y)
                    cycle()
                event(index, "drag", **{"from": start, "to": end, "frames": drag_frames})
            if "release" in step:
                lib.desmume_input_release_touch()
                event(index, "release")

            frames = int(step.get("frames", 1))
            seq_name = step.get("capture_sequence")
            every = max(1, int(step.get("capture_every", 1)))
            for n in range(frames):
                cycle()
                if seq_name and n % every == 0:
                    count = sequences.get(seq_name, 0)
                    capture(lib, output / f"{seq_name}_{count:04d}.png")
                    sequences[seq_name] = count + 1
            event(index, "frame_advance", frames=frames, keypad=int(lib.desmume_input_keypad_get()))
            if "capture" in step:
                name = step["capture"]
                digest, pixels = capture(lib, output / f"{name}.png")
                captures[name] = {"sha256": digest, "path": f"{name}.png"}
                capture_pixels[name] = pixels
            if "state_capture" in step:
                if not state_config:
                    raise ValueError("state_capture requires scenario.state")
                name = step["state_capture"]
                state_samples[name] = read_state(lib, state_bases, state_config["fields"], default_symbol)
                event(index, "state_capture", name=name, state=state_samples[name])
        ctx["frames"] = frame
    finally:
        lib.desmume_free()

    assertions = scenario.get("assertions") or {}
    checks = assertions.get("screen_changes")
    if checks is None:
        checks = [assertions["screen_changed"]] if "screen_changed" in assertions else []
    screen_results = []
    for check in checks:
        first = captures[check["from"]]
        second = captures[check["to"]]
        changed_pixels = sum(a != b for a, b in zip(
            capture_pixels[check["from"]], capture_pixels[check["to"]],
        )) // 3
        min_changed = check.get("min_changed_pixels", 1)
        screen_results.append({
            "from": check["from"], "to": check["to"],
            "changed": first["sha256"] != second["sha256"] and changed_pixels >= min_changed,
            "changed_pixels": changed_pixels, "min_changed_pixels": min_changed,
        })
    state_results = [check_state_assertion(state_samples, check)
                     for check in assertions.get("state_changes", [])]
    screen_ok = all(r["changed"] for r in screen_results)
    state_ok = all(r["passed"] for r in state_results)
    summary = {"screen_changed": screen_ok, "screen_changes": screen_results,
               "state_changed": state_ok, "state_changes": state_results}
    if screen_results:
        summary["changed_pixels"] = screen_results[0]["changed_pixels"]
        summary["min_changed_pixels"] = screen_results[0]["min_changed_pixels"]
    ctx["assertions"] = summary
    ctx["failed"] = ([f"screen:{r['from']}->{r['to']}" for r in screen_results if not r["changed"]] +
                     [state_label(r) for r in state_results if not r["passed"]])
    if not screen_results and not state_results:
        ctx["warnings"].append("no_assertions")
        log("DSM_SCENARIO_WARNING=no_assertions")
    return not ctx["failed"]


def main() -> int:
    if len(sys.argv) not in (5, 6):
        print("usage: run_scenario.py ROM.nds SCENARIO.json OUTPUT_DIR LIBRARY.so [MAP_FILE]",
              file=sys.stderr)
        return 2
    rom = Path(sys.argv[1])
    scenario_path = Path(sys.argv[2])
    output = Path(sys.argv[3])
    lib_path = Path(sys.argv[4])
    cli_map = sys.argv[5] if len(sys.argv) == 6 and sys.argv[5] else None
    ctx = {"events": [], "captures": {}, "state_samples": {}, "sequences": {},
           "warnings": [], "assertions": {}, "failed": [], "frames": 0, "error": None}
    ok = False
    try:
        ok = run(rom, scenario_path, output, lib_path, cli_map, ctx)
    except Exception as error:  # manifest must be written even on failure
        ctx["error"] = f"{type(error).__name__}: {error}"
        print(f"DSM_SCENARIO_ERROR={ctx['error']}", file=sys.stderr, flush=True)
    finally:
        try:
            output.mkdir(parents=True, exist_ok=True)
            manifest = {
                "scenario": scenario_path.name,
                "captures": ctx["captures"],
                "capture_sequences": ctx["sequences"],
                "events": ctx["events"],
                "frames": ctx["frames"],
                "assertions": ctx["assertions"],
                "state_samples": ctx["state_samples"],
                "warnings": ctx["warnings"],
                "error": ctx["error"],
            }
            if "map_path" in ctx:
                manifest["map_path"] = ctx["map_path"]
            (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            with (output / "events.jsonl").open("w", encoding="utf-8") as handle:
                for item in ctx["events"]:
                    handle.write(json.dumps(item, separators=(",", ":")) + "\n")
        except OSError as error:
            print(f"DSM_SCENARIO_ERROR=cannot write manifest: {error}", file=sys.stderr, flush=True)
    if ctx["error"]:
        log("DSM_SCENARIO_RESULT=FAIL reason=exception")
        return 1
    if not ok:
        log("DSM_SCENARIO_RESULT=FAIL reason=assertion_failed failed=" + ",".join(ctx["failed"]))
        return 1
    log(f"DSM_SCENARIO_RESULT=PASS captures={len(ctx['captures'])} events={len(ctx['events'])}"
        f" frames={ctx['frames']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
