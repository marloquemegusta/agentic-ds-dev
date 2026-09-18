#!/usr/bin/env python3
"""Run deterministic DS input scenarios against the headless DeSmuME ABI."""

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
    lib.desmume_free.argtypes = []


def set_button(lib, keypad: int, name: str, pressed: bool) -> int:
    try:
        bit = BUTTON_BITS[name.upper()]
    except KeyError as error:
        raise ValueError(f"unknown button: {name}") from error
    keypad = keypad | bit if pressed else keypad & ~bit
    lib.desmume_input_keypad_update(keypad)
    return keypad


def capture(lib, path: Path) -> tuple[str, bytes]:
    raw = (ctypes.c_ubyte * RGB_SIZE)()
    lib.desmume_screenshot(raw)
    rgb = bytes(raw)
    path.write_bytes(png_bytes(rgb))
    return hashlib.sha256(rgb).hexdigest(), rgb


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: run_scenario.py ROM.nds SCENARIO.json OUTPUT_DIR LIBRARY.so", file=sys.stderr)
        return 2
    rom = Path(sys.argv[1])
    scenario_path = Path(sys.argv[2])
    output = Path(sys.argv[3])
    lib_path = Path(sys.argv[4])
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    output.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    os.environ.setdefault("ALSOFT_DRIVERS", "null")
    lib = ctypes.CDLL(str(lib_path))
    configure(lib)
    if lib.desmume_init() != 0 or lib.desmume_open(str(rom).encode()) != 1:
        raise RuntimeError("DeSmuME failed to initialize or open ROM")
    lib.desmume_resume()

    events = []
    captures = {}
    capture_pixels = {}
    keypad = 0
    try:
        for index, step in enumerate(scenario["steps"]):
            if "button_down" in step:
                keypad = set_button(lib, keypad, step["button_down"], True)
                events.append({"step": index, "action": "button_down", "button": step["button_down"]})
            if "button_up" in step:
                keypad = set_button(lib, keypad, step["button_up"], False)
                events.append({"step": index, "action": "button_up", "button": step["button_up"]})
            if "tap" in step:
                point = step["tap"]
                lib.desmume_input_set_touch_pos(point["x"], point["y"])
                events.append({"step": index, "action": "tap", "x": point["x"], "y": point["y"]})
            if "drag" in step:
                drag = step["drag"]
                start = drag["from"]
                end = drag["to"]
                drag_frames = max(1, int(drag.get("frames", 1)))
                for frame in range(drag_frames):
                    ratio = frame / max(1, drag_frames - 1)
                    x = round(start["x"] + (end["x"] - start["x"]) * ratio)
                    y = round(start["y"] + (end["y"] - start["y"]) * ratio)
                    lib.desmume_input_set_touch_pos(x, y)
                    lib.desmume_cycle(0)
                events.append({"step": index, "action": "drag", "from": start, "to": end,
                               "frames": drag_frames})
            if "release" in step:
                lib.desmume_input_release_touch()
                events.append({"step": index, "action": "release"})
            for _ in range(step.get("frames", 1)):
                lib.desmume_cycle(0)
            events.append({"step": index, "action": "frame_advance", "frames": step.get("frames", 1),
                           "keypad": int(lib.desmume_input_keypad_get())})
            if "capture" in step:
                name = step["capture"]
                digest, _ = capture(lib, output / f"{name}.png")
                captures[name] = {"sha256": digest, "path": f"{name}.png"}
                capture_pixels[name] = _
    finally:
        lib.desmume_free()

    assertions = scenario["assertions"]
    checks = assertions.get("screen_changes", [assertions["screen_changed"]])
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
    changed = all(result["changed"] for result in screen_results)
    first_result = screen_results[0]
    manifest = {
        "scenario": scenario_path.name,
        "captures": captures,
        "events": events,
        "assertions": {"screen_changed": changed,
                        "changed_pixels": first_result["changed_pixels"],
                        "min_changed_pixels": first_result["min_changed_pixels"],
                        "screen_changes": screen_results},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    with (output / "events.jsonl").open("w", encoding="utf-8") as handle:
        for event in events:
            handle.write(json.dumps(event, separators=(",", ":")) + "\n")
    if not changed:
        print("DSM_SCENARIO_RESULT=FAIL reason=screen_unchanged")
        return 1
    print(f"DSM_SCENARIO_RESULT=PASS captures={len(captures)} events={len(events)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
