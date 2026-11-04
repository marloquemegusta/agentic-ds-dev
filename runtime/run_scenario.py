#!/usr/bin/env python3
"""Run deterministic DS input scenarios against the headless DeSmuME ABI.

usage:
  run_scenario.py --rom ROM.nds --lib LIB.so --out OUT_DIR [--map M] [--elf E]
                  [--states-dir D] [--no-skip-render] [--jit] SCENARIO.json [SCENARIO.json ...]
  run_scenario.py ROM.nds SCENARIO.json OUTPUT_DIR LIBRARY.so [MAP_FILE]     (legacy form)

stdout carries only DSM_ lines; diagnostics go to stderr. Exit codes:
0 = every scenario passed, 1 = some FAIL / NO_ASSERTIONS, 2 = some ERROR (dominates).
See references/scenario-format.md for the scenario JSON format.
"""

import argparse
import ctypes
import hashlib
import json
import os
import re
import struct
import sys
import time
import zlib
from pathlib import Path


WIDTH = 256
HEIGHT = 384
RGB_SIZE = WIDTH * HEIGHT * 3
TOUCH_MAX_X = WIDTH - 1
TOUCH_MAX_Y = 191  # lower screen only; captures are 256x384 with the lower screen at y 192..383
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
VALUE_KEYS = ("equals", "not_equals", "min_value", "max_value")
CHECK_KEYS = DELTA_KEYS + VALUE_KEYS
# type -> (read export, ctypes return type, write export)
MEMORY_TYPES = {
    "u8": ("desmume_memory_read_byte", ctypes.c_uint8, "desmume_memory_write_byte"),
    "s8": ("desmume_memory_read_byte_signed", ctypes.c_int8, "desmume_memory_write_byte"),
    "u16": ("desmume_memory_read_short", ctypes.c_uint16, "desmume_memory_write_short"),
    "s16": ("desmume_memory_read_short_signed", ctypes.c_int16, "desmume_memory_write_short"),
    "u32": ("desmume_memory_read_long", ctypes.c_uint32, "desmume_memory_write_long"),
    "s32": ("desmume_memory_read_long_signed", ctypes.c_int32, "desmume_memory_write_long"),
}
TYPE_RANGES = {"u8": (0, 0xff), "s8": (-0x80, 0x7f), "u16": (0, 0xffff), "s16": (-0x8000, 0x7fff),
               "u32": (0, 0xffffffff), "s32": (-0x80000000, 0x7fffffff)}
DEFAULT_TYPE = "s32"
TOP_KEYS = {"name", "description", "rom", "comment", "note", "tags", "suite", "evidence_only",
            "state", "steps", "assertions", "start_state", "render_all_frames"}
# Every key a step may carry. Anything else is a typo or an action from a
# project fork; failing on it avoids a silently skipped action passing a test.
STEP_KEYS = {
    "button_down", "button_up", "release_flush_frames", "tap", "touch", "tap_grid",
    "drag", "release", "frames", "capture", "capture_sequence", "capture_every",
    "state_capture", "comment", "note", "wait_until", "poke", "save_state",
}
ASSERTION_KEYS = {"screen_changes", "screen_changed", "state_changes"}
SCREEN_KEYS = {"from", "to", "min_changed_pixels"}
STATE_ASSERT_KEYS = {"field", "from", "to", "at"} | set(CHECK_KEYS)
STATE_CONFIG_KEYS = {"map", "map_path", "elf", "symbols", "symbol", "default_symbol", "fields"}
FIELD_SPEC_KEYS = {"symbol", "offset", "type"}
WAIT_KEYS = {"field", "equals", "not_equals", "min_value", "max_value", "timeout_frames"}
POKE_KEYS = {"symbol", "offset", "type", "value"}
NAME_RE = re.compile(r"^[A-Za-z0-9_.\-]+$")
DEBUG_EVENT_CAP = 200
DEBUG_BUF = 65536

# Output streams for DSM_ lines (stdout) and diagnostics (stderr). main() points
# them at duplicated fds, because the emulator itself prints to fd 1 / fd 2.
_out = sys.stdout
_err = sys.stderr


def log(message: str) -> None:
    print(message, file=_out, flush=True)


def elog(message: str) -> None:
    print(message, file=_err, flush=True)


class RunnerError(Exception):
    """A run problem with a stable machine-readable code (status ERROR)."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class ScenarioError(ValueError):
    """The scenario file itself is malformed (exit 2, before the emulator starts)."""


# ------------------------------------------------------------ images ----

def png_bytes(rgb: bytes) -> bytes:
    rows = b"".join(b"\x00" + rgb[y * WIDTH * 3:(y + 1) * WIDTH * 3] for y in range(HEIGHT))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def count_changed_pixels(first: bytes, second: bytes) -> int:
    """Pixels (not bytes) where any of the 3 channels differs."""
    if first == second:
        return 0
    return sum(1 for r, g, b in zip(
        (x ^ y for x, y in zip(first[0::3], second[0::3])),
        (x ^ y for x, y in zip(first[1::3], second[1::3])),
        (x ^ y for x, y in zip(first[2::3], second[2::3])),
    ) if r or g or b)


def capture(lib, path: Path) -> tuple[str, bytes]:
    raw = (ctypes.c_ubyte * RGB_SIZE)()
    lib.desmume_screenshot(raw)
    rgb = bytes(raw)
    path.write_bytes(png_bytes(rgb))
    return hashlib.sha256(rgb).hexdigest(), rgb


# --------------------------------------------------------- lib binding ----

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
    for read_name, restype, write_name in MEMORY_TYPES.values():
        getattr(lib, read_name).argtypes = [ctypes.c_int]
        getattr(lib, read_name).restype = restype
    lib.desmume_memory_write_byte.argtypes = [ctypes.c_int, ctypes.c_ubyte]
    lib.desmume_memory_write_short.argtypes = [ctypes.c_int, ctypes.c_ushort]
    lib.desmume_memory_write_long.argtypes = [ctypes.c_int, ctypes.c_ulong]
    lib.desmume_savestate_save.argtypes = [ctypes.c_char_p]
    lib.desmume_savestate_save.restype = ctypes.c_int
    lib.desmume_savestate_load.argtypes = [ctypes.c_char_p]
    lib.desmume_savestate_load.restype = ctypes.c_int
    lib.desmume_skip_next_frame.argtypes = []
    lib.desmume_free.argtypes = []
    # Optional exports of the patched agent library; absent in older builds.
    if hasattr(lib, "desmume_agent_version"):
        lib.desmume_agent_version.restype = ctypes.c_char_p
    if hasattr(lib, "desmume_agent_set_jit"):
        lib.desmume_agent_set_jit.argtypes = [ctypes.c_int]
    if hasattr(lib, "desmume_agent_debug_read"):
        lib.desmume_agent_debug_read.argtypes = [ctypes.c_char_p, ctypes.c_int]
        lib.desmume_agent_debug_read.restype = ctypes.c_int


def button_bit(name: str) -> int:
    try:
        return BUTTON_BITS[name.upper()]
    except (KeyError, AttributeError) as error:
        raise ValueError(f"unknown button: {name}") from error


def read_typed(lib, address: int, kind: str = DEFAULT_TYPE) -> int:
    """Read one value of the given type (u8,s8,u16,s16,u32,s32) from emulated memory."""
    return int(getattr(lib, MEMORY_TYPES[kind][0])(address))


def write_typed(lib, address: int, kind: str, value: int) -> None:
    low, high = TYPE_RANGES[kind]
    if not low <= value <= high:
        raise ValueError(f"poke value {value} does not fit type {kind}")
    mask = (1 << (int(kind[1:]))) - 1
    getattr(lib, MEMORY_TYPES[kind][2])(address, value & mask)


# ---------------------------------------------------------- validation ----

def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _check_point(point, where: str, problems: list) -> None:
    if not isinstance(point, dict) or not {"x", "y"} <= set(point):
        problems.append(f"{where}: needs an object with x and y")
        return
    x, y = point["x"], point["y"]
    if not (_is_int(x) and _is_int(y)):
        problems.append(f"{where}: x and y must be integers")
    elif not (0 <= x <= TOUCH_MAX_X and 0 <= y <= TOUCH_MAX_Y):
        problems.append(
            f"{where}: touch ({x},{y}) is outside the lower screen (x 0..{TOUCH_MAX_X}, y 0..{TOUCH_MAX_Y}). "
            f"Captures are {WIDTH}x{HEIGHT} with the LOWER screen at y 192..383: subtract 192 from capture y.")


def _check_field_spec(name: str, spec, aliases: set, default_symbol: str, problems: list) -> None:
    where = f"state.fields.{name}"
    if _is_int(spec):
        if default_symbol not in aliases:
            problems.append(f"{where}: bare offset needs default_symbol {default_symbol!r} to be one of {sorted(aliases)}")
        return
    if not isinstance(spec, dict):
        problems.append(f"{where}: must be an integer offset or {{symbol, offset, type}}")
        return
    unknown = sorted(set(spec) - FIELD_SPEC_KEYS)
    if unknown:
        problems.append(f"{where}: unknown keys {unknown} (allowed: {sorted(FIELD_SPEC_KEYS)})")
    if "offset" not in spec or not _is_int(spec["offset"]):
        problems.append(f"{where}: needs an integer offset")
    if spec.get("symbol", default_symbol) not in aliases:
        problems.append(f"{where}: symbol {spec.get('symbol', default_symbol)!r} is not declared in state.symbols {sorted(aliases)}")
    if spec.get("type", DEFAULT_TYPE) not in MEMORY_TYPES:
        problems.append(f"{where}: unknown type {spec.get('type')!r} (use {', '.join(MEMORY_TYPES)})")


def _check_name(value, where: str, problems: list) -> None:
    if not isinstance(value, str) or not NAME_RE.match(value):
        problems.append(f"{where}: must be a name made of letters, digits, '_', '-', '.' (got {value!r})")


def validate_scenario(scenario) -> None:
    """Reject a malformed scenario before the emulator starts (raises ScenarioError)."""
    problems: list[str] = []
    if not isinstance(scenario, dict):
        raise ScenarioError("scenario must be a JSON object")
    unknown = sorted(set(scenario) - TOP_KEYS)
    if unknown:
        problems.append(f"unknown top-level keys {unknown} (allowed: {sorted(TOP_KEYS)})")
    steps = scenario.get("steps")
    if not isinstance(steps, list):
        raise ScenarioError("scenario.steps must be a list")

    # state block ---------------------------------------------------------
    state = scenario.get("state")
    aliases: set = set()
    fields: dict = {}
    default_symbol = "state"
    if state is not None:
        if not isinstance(state, dict):
            problems.append("state must be an object")
        else:
            unknown = sorted(set(state) - STATE_CONFIG_KEYS)
            if unknown:
                problems.append(f"state: unknown keys {unknown} (allowed: {sorted(STATE_CONFIG_KEYS)})")
            if isinstance(state.get("symbols"), dict):
                aliases = set(state["symbols"])
            elif isinstance(state.get("symbol"), str):
                aliases = {"state"}
            else:
                problems.append("state needs 'symbols' ({alias: symbol}) or 'symbol'")
            default_symbol = state.get("default_symbol", "state")
            fields = state.get("fields") if isinstance(state.get("fields"), dict) else {}
            if not fields:
                problems.append("state.fields must be a non-empty object")
            for name, spec in fields.items():
                _check_field_spec(name, spec, aliases, default_symbol, problems)

    # steps ---------------------------------------------------------------
    captures: set = set()
    samples: set = set()
    for index, step in enumerate(steps):
        where = f"step {index}"
        if not isinstance(step, dict):
            problems.append(f"{where} must be an object")
            continue
        unknown = sorted(set(step) - STEP_KEYS)
        if unknown:
            problems.append(f"{where}: unknown keys {unknown}")
        for key in ("tap", "touch", "tap_grid", "drag"):
            if key in step and "release" in step:
                problems.append(f"{where}: '{key}' together with 'release' cancels itself (the touch is released "
                                f"at once); put 'release' in a later step")
        if "tap" in step and "touch" in step:
            problems.append(f"{where}: use either 'tap' or 'touch', not both")
        for key in ("tap", "touch"):
            if key in step:
                _check_point(step[key], f"{where}.{key}", problems)
        if "drag" in step:
            drag = step["drag"]
            if not isinstance(drag, dict) or not {"from", "to"} <= set(drag):
                problems.append(f"{where}.drag: needs from and to")
            else:
                _check_point(drag["from"], f"{where}.drag.from", problems)
                _check_point(drag["to"], f"{where}.drag.to", problems)
        if "tap_grid" in step:
            grid = step["tap_grid"]
            if not isinstance(grid, dict) or not {"count", "x", "y"} <= set(grid):
                problems.append(f"{where}.tap_grid: needs count, x and y")
            else:
                try:
                    count = max(1, int(grid["count"]))
                    columns = max(1, int(grid.get("columns", count)))
                    _check_point({"x": int(grid["x"]), "y": int(grid["y"])}, f"{where}.tap_grid start", problems)
                    last = count - 1
                    _check_point({"x": int(grid["x"]) + (last % columns) * int(grid.get("spacing_x", 0)),
                                  "y": int(grid["y"]) + (last // columns) * int(grid.get("spacing_y", 0))},
                                 f"{where}.tap_grid last point", problems)
                    for name in grid.get("hold", []):
                        button_bit(name)
                except (ValueError, TypeError) as error:
                    problems.append(f"{where}.tap_grid: {error}")
        for key in ("button_down", "button_up"):
            if key in step:
                try:
                    button_bit(step[key])
                except ValueError as error:
                    problems.append(f"{where}: {error}")
        if ("button_down" in step and "button_up" in step and isinstance(step["button_down"], str)
                and isinstance(step["button_up"], str)
                and step["button_down"].upper() == step["button_up"].upper()):
            problems.append(f"{where}: button_down and button_up of {step['button_down']} in one step cancel out")
        if "frames" in step and not (_is_int(step["frames"]) and step["frames"] >= 0):
            problems.append(f"{where}.frames must be an integer >= 0")
        if "capture_every" in step and not (_is_int(step["capture_every"]) and step["capture_every"] >= 1):
            problems.append(f"{where}.capture_every must be an integer >= 1")
        if "capture_every" in step and "capture_sequence" not in step:
            problems.append(f"{where}: capture_every without capture_sequence does nothing")
        for key in ("capture", "capture_sequence", "state_capture", "save_state"):
            if key in step:
                _check_name(step[key], f"{where}.{key}", problems)
        if isinstance(step.get("capture"), str):
            captures.add(step["capture"])
        if "state_capture" in step:
            if state is None:
                problems.append(f"{where}: state_capture requires scenario.state")
            elif isinstance(step["state_capture"], str):
                samples.add(step["state_capture"])
        if "wait_until" in step:
            wait = step["wait_until"]
            if not isinstance(wait, dict):
                problems.append(f"{where}.wait_until must be an object")
            else:
                unknown = sorted(set(wait) - WAIT_KEYS)
                if unknown:
                    problems.append(f"{where}.wait_until: unknown keys {unknown}")
                if state is None:
                    problems.append(f"{where}.wait_until requires scenario.state")
                elif wait.get("field") not in fields:
                    problems.append(f"{where}.wait_until: field {wait.get('field')!r} is not in state.fields")
                if not any(key in wait for key in VALUE_KEYS):
                    problems.append(f"{where}.wait_until: needs one of {list(VALUE_KEYS)}")
                if not (_is_int(wait.get("timeout_frames")) and wait["timeout_frames"] > 0):
                    problems.append(f"{where}.wait_until: timeout_frames (integer > 0) is required")
                for key in VALUE_KEYS:
                    if key in wait and not _is_int(wait[key]):
                        problems.append(f"{where}.wait_until.{key} must be an integer")
        if "poke" in step:
            poke = step["poke"]
            if not isinstance(poke, dict):
                problems.append(f"{where}.poke must be an object")
            else:
                unknown = sorted(set(poke) - POKE_KEYS)
                if unknown:
                    problems.append(f"{where}.poke: unknown keys {unknown}")
                if state is None:
                    problems.append(f"{where}.poke requires scenario.state (for symbol resolution)")
                elif poke.get("symbol", default_symbol) not in aliases:
                    problems.append(f"{where}.poke: symbol {poke.get('symbol', default_symbol)!r} not in state.symbols {sorted(aliases)}")
                kind = poke.get("type", DEFAULT_TYPE)
                if kind not in MEMORY_TYPES:
                    problems.append(f"{where}.poke: unknown type {kind!r}")
                if not _is_int(poke.get("offset")):
                    problems.append(f"{where}.poke: integer offset required")
                if not _is_int(poke.get("value")):
                    problems.append(f"{where}.poke: integer value required")
                elif kind in TYPE_RANGES and not TYPE_RANGES[kind][0] <= poke["value"] <= TYPE_RANGES[kind][1]:
                    problems.append(f"{where}.poke: value {poke['value']} does not fit {kind}")
    if "start_state" in scenario:
        _check_name(scenario["start_state"], "start_state", problems)

    # assertions ----------------------------------------------------------
    assertions = scenario.get("assertions", {})
    if assertions is None:
        assertions = {}
    if not isinstance(assertions, dict):
        problems.append("scenario.assertions must be an object")
    else:
        unknown = sorted(set(assertions) - ASSERTION_KEYS)
        if unknown:
            problems.append(f"assertions: unknown keys {unknown} (allowed: {sorted(ASSERTION_KEYS)})")
        screen = assertions.get("screen_changes")
        if screen is None and "screen_changed" in assertions:
            screen = [assertions["screen_changed"]]
        if screen is not None and not isinstance(screen, list):
            problems.append("assertions.screen_changes must be a list")
            screen = []
        for n, check in enumerate(screen or []):
            where = f"assertions.screen_changes[{n}]"
            if not isinstance(check, dict):
                problems.append(f"{where} must be an object")
                continue
            unknown = sorted(set(check) - SCREEN_KEYS)
            if unknown:
                problems.append(f"{where}: unknown keys {unknown} (allowed: {sorted(SCREEN_KEYS)})")
            for key in ("from", "to"):
                if check.get(key) not in captures:
                    problems.append(f"{where}.{key}: capture {check.get(key)!r} is never produced by any step "
                                    f"(captures: {sorted(captures)})")
        checks = assertions.get("state_changes", [])
        if not isinstance(checks, list):
            problems.append("assertions.state_changes must be a list")
            checks = []
        for n, check in enumerate(checks):
            where = f"assertions.state_changes[{n}]"
            if not isinstance(check, dict):
                problems.append(f"{where} must be an object")
                continue
            unknown = sorted(set(check) - STATE_ASSERT_KEYS)
            if unknown:
                problems.append(f"{where}: unknown keys {unknown} (allowed: {sorted(STATE_ASSERT_KEYS)})")
            if state is None:
                problems.append(f"{where}: needs scenario.state")
            elif check.get("field") not in fields:
                problems.append(f"{where}.field: {check.get('field')!r} is not in state.fields {sorted(fields)}")
            present = [key for key in CHECK_KEYS if key in check]
            if not present:
                problems.append(f"{where}: needs one of {list(CHECK_KEYS)}")
            if "at" in check and ("from" in check or "to" in check):
                problems.append(f"{where}: use 'at' or 'from'+'to', not both")
            elif "at" not in check and not ("from" in check and "to" in check):
                problems.append(f"{where}: needs 'at' or both 'from' and 'to'")
            if "at" in check and any(key in check for key in DELTA_KEYS):
                problems.append(f"{where}: delta checks need from/to, not 'at'")
            for key in ("at", "from", "to"):
                if key in check and check[key] not in samples:
                    problems.append(f"{where}.{key}: state sample {check[key]!r} is never produced by any "
                                    f"state_capture (samples: {sorted(samples)})")
            for key in present:
                if not _is_int(check[key]):
                    problems.append(f"{where}.{key} must be an integer")
    if problems:
        raise ScenarioError("invalid scenario: " + "; ".join(problems))


# ---------------------------------------------------------------- ELF ----

_ELF_CACHE: dict = {}


def elf_symbols(elf_path: Path) -> dict:
    """Parse the .symtab of a 32-bit little-endian ELF: {name: [address, ...]} (defined symbols)."""
    key = str(elf_path)
    if key in _ELF_CACHE:
        return _ELF_CACHE[key]
    data = Path(elf_path).read_bytes()
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        raise ValueError(f"{elf_path} is not a 32-bit little-endian ELF")
    shoff, = struct.unpack_from("<I", data, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x2E)
    sections = [struct.unpack_from("<IIIIIIIIII", data, shoff + i * shentsize) for i in range(shnum)]
    table: dict = {}
    for _name, kind, _flags, _addr, offset, size, link, _info, _align, entsize in sections:
        if kind != 2:  # SHT_SYMTAB
            continue
        str_off, str_size = sections[link][4], sections[link][5]
        strtab = data[str_off:str_off + str_size]
        for i in range(size // (entsize or 16)):
            st_name, st_value, _st_size, _st_info, _st_other, st_shndx = struct.unpack_from(
                "<IIIBBH", data, offset + i * (entsize or 16))
            if st_name == 0 or st_shndx == 0:  # unnamed / undefined
                continue
            end = strtab.index(b"\0", st_name)
            table.setdefault(strtab[st_name:end].decode("utf-8", "replace"), set()).add(st_value)
    result = {name: sorted(values) for name, values in table.items()}
    _ELF_CACHE[key] = result
    return result


def elf_symbol_address(elf_path: Path, symbol: str) -> int:
    addresses = elf_symbols(elf_path).get(symbol)
    if not addresses:
        raise LookupError(f"symbol {symbol!r} not found in {elf_path}")
    if len(addresses) > 1:
        raise RunnerError("ambiguous_symbol", f"symbol {symbol!r} is ambiguous in {elf_path}: "
                          + ", ".join(f"0x{a:08x}" for a in addresses)
                          + " (several local statics share the name; rename one or use a unique symbol)")
    return addresses[0]


def map_symbol_address(map_path: Path, symbol: str) -> int:
    """Resolve a linked symbol address from a GNU ld map file.

    Looks for input-section lines (.bss.NAME / .data.NAME / .rodata.NAME); the
    address is on the same line or on the following one. Falls back to the
    global symbol table lines ("0xADDR   NAME"). Several distinct addresses
    (local statics with the same name) are an error, not a silent first match.
    """
    sections = {f".{kind}.{symbol}" for kind in ("bss", "data", "rodata")}
    lines = Path(map_path).read_text(encoding="utf-8", errors="replace").splitlines()
    found = set()
    for index, line in enumerate(lines):
        fields = line.split()
        if not fields or fields[0] not in sections:
            continue
        if len(fields) >= 2 and fields[1].startswith("0x"):
            found.add(int(fields[1], 16))
        elif index + 1 < len(lines):
            nxt = lines[index + 1].split()
            if nxt and nxt[0].startswith("0x"):
                found.add(int(nxt[0], 16))
    if not found:
        for line in lines:
            fields = line.split()
            if len(fields) == 2 and fields[0].startswith("0x") and fields[1] == symbol:
                found.add(int(fields[0], 16))
    if not found:
        raise LookupError(f"symbol {symbol!r} not found in {map_path}")
    if len(found) > 1:
        raise RunnerError("ambiguous_symbol", f"symbol {symbol!r} is ambiguous in {map_path}: "
                          + ", ".join(f"0x{a:08x}" for a in sorted(found)))
    return found.pop()


# ------------------------------------------------- symbol source lookup ----

def host_path(text: str) -> Path:
    """Convert a Windows path (C:\\dir\\f) to /mnt/c/dir/f when running inside WSL/Linux."""
    match = re.match(r"^([A-Za-z]):[\\/](.*)$", text)
    if match and os.name != "nt":
        return Path("/mnt/" + match.group(1).lower() + "/" + match.group(2).replace("\\", "/"))
    return Path(text)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def find_buildinfo(rom: Path) -> Path | None:
    """Walk up from the ROM directory looking for .ds-game-dev/build/out/<stem>.buildinfo.json."""
    name = Path(".ds-game-dev") / "build" / "out" / f"{rom.stem}.buildinfo.json"
    for folder in [rom.resolve().parent, *rom.resolve().parent.parents]:
        if (folder / name).is_file():
            return folder / name
    return None


def resolve_symbol_source(rom: Path, rom_sha: str, scenario_path: Path, state_config: dict,
                          cli_map: str | None, cli_elf: str | None, warnings: list) -> dict:
    """Pick where symbol addresses come from.

    Order: explicit (scenario state.map/elf, CLI --map/--elf, DS_MAP_PATH) >
    build sidecar <rom>.buildinfo.json (sha-verified) > legacy map next to the
    ROM (unverified, warns map_unverified).
    Returns {kind, source, elf, map}; paths are Path or None.
    """
    scenario_dir = scenario_path.parent
    if "elf" in state_config:
        return {"kind": "elf", "source": "explicit", "elf": (scenario_dir / state_config["elf"]).resolve(), "map": None}
    if "map" in state_config:
        return {"kind": "map", "source": "explicit", "elf": None, "map": (scenario_dir / state_config["map"]).resolve()}
    if "map_path" in state_config:  # legacy key, relative to the scenario's parent dir
        return {"kind": "map", "source": "explicit", "elf": None, "map": (scenario_dir.parent / state_config["map_path"]).resolve()}
    if cli_elf:
        return {"kind": "elf", "source": "explicit", "elf": Path(cli_elf), "map": None}
    if cli_map:
        return {"kind": "map", "source": "explicit", "elf": None, "map": Path(cli_map)}
    if os.environ.get("DS_MAP_PATH"):
        return {"kind": "map", "source": "explicit", "elf": None, "map": Path(os.environ["DS_MAP_PATH"])}
    info_path = find_buildinfo(rom)
    if info_path:
        info = json.loads(info_path.read_text(encoding="utf-8-sig"))
        if str(info.get("romSha256", "")).lower() != rom_sha:
            raise RunnerError("map_mismatch",
                              f"{info_path} describes a different ROM build (romSha256 {info.get('romSha256')} != "
                              f"{rom_sha} of {rom}). Rebuild, or pass --map/--elf explicitly.")
        elf = host_path(info["elf"]) if info.get("elf") else None
        map_file = host_path(info["map"]) if info.get("map") else None
        return {"kind": "buildinfo", "source": "buildinfo",
                "elf": elf if elf and elf.exists() else None,
                "map": map_file if map_file and map_file.exists() else None}
    candidates = [(rom.parent / LEGACY_MAP).resolve(), (scenario_dir.parent / LEGACY_MAP).resolve()]
    map_file = next((path for path in candidates if path.exists()), candidates[0])
    elf = map_file.with_suffix(".elf")
    warnings.append("map_unverified")
    return {"kind": "legacy", "source": "legacy", "elf": elf if elf.exists() else None, "map": map_file}


def resolve_address(source: dict, symbol: str) -> int:
    """ELF first (handles static symbols), then the linker map."""
    problems = []
    if source.get("elf"):
        try:
            return elf_symbol_address(source["elf"], symbol)
        except (LookupError, OSError, ValueError, struct.error) as error:
            problems.append(str(error))
    if source.get("map"):
        try:
            return map_symbol_address(source["map"], symbol)
        except (LookupError, OSError) as error:
            problems.append(str(error))
    raise RunnerError("symbol_not_found", f"cannot resolve symbol {symbol!r}: " + ("; ".join(problems) or "no ELF or map available"))


# ---------------------------------------------------------------- state ----

def field_parts(spec, default_symbol: str) -> tuple[str, int, str]:
    """(symbol alias, offset, type) of a field spec: int offset or {symbol, offset, type}."""
    if isinstance(spec, dict):
        return spec.get("symbol", default_symbol), int(spec["offset"]), spec.get("type", DEFAULT_TYPE)
    return default_symbol, int(spec), DEFAULT_TYPE


def read_field(lib, bases: dict, spec, default_symbol: str) -> int:
    symbol, offset, kind = field_parts(spec, default_symbol)
    return read_typed(lib, bases[symbol] + offset, kind)


def read_state(lib, bases: dict, fields: dict, default_symbol: str) -> dict:
    return {name: read_field(lib, bases, spec, default_symbol) for name, spec in fields.items()}


VALUE_CHECKS = {
    "equals": lambda value, expected: value == expected,
    "not_equals": lambda value, expected: value != expected,
    "min_value": lambda value, limit: value >= limit,
    "max_value": lambda value, limit: value <= limit,
}


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
    # Every check present must hold, so a range like min_value + max_value is
    # enforced on both ends instead of only the first key found.
    checks = {
        "min_abs_delta": lambda limit: abs(delta) >= limit,
        "min_delta": lambda limit: delta >= limit,
        "max_delta": lambda limit: delta <= limit,
        "max_abs_delta": lambda limit: abs(delta) <= limit,
        **{key: (lambda limit, fn=fn: fn(after, limit)) for key, fn in VALUE_CHECKS.items()},
    }
    present = [key for key in checks if key in assertion]
    if not present:
        raise ValueError(f"unsupported state assertion: {assertion}")
    passed = all(checks[key](int(assertion[key])) for key in present)
    result = {"field": field, "after": after, "passed": passed}
    if "at" in assertion:
        result["at"] = assertion["at"]
    else:
        result.update({"from": assertion["from"], "to": assertion["to"],
                       "before": before, "delta": delta})
    for key in CHECK_KEYS:
        if key in assertion:
            result[key] = assertion[key]
    return result


def state_label(result: dict) -> str:
    where = result["at"] if "at" in result else f"{result['from']}->{result['to']}"
    return f"state:{where}.{result['field']}"


# --------------------------------------------------------- input trace ----

class InputTrace:
    """Run-length encoded per-frame input: runs of [count, keys, touching, x, y]."""

    def __init__(self):
        self.runs: list = []
        self.frames = 0

    def add(self, keys: int, touching: bool, x: int, y: int) -> None:
        item = [int(keys), 1 if touching else 0, int(x) if touching else 0, int(y) if touching else 0]
        self.frames += 1
        if self.runs and self.runs[-1][1:] == item:
            self.runs[-1][0] += 1
        else:
            self.runs.append([1] + item)

    def to_json(self, replay_safe: bool = True, reasons: list | None = None) -> dict:
        data = {"version": 1, "frames": self.frames, "runs": self.runs}
        if not replay_safe:
            data["replay_safe"] = False
            data["replay_unsafe_reasons"] = reasons or []
        return data


# -------------------------------------------------------- render plan ----

# Frames rendered before every capture. Skipping GPU rendering is not free of
# side effects: the 3D pipeline lags a few frames, so a capture is only
# identical to a fully rendered run when the last frames before it are rendered
# too (measured on dungeonds: skipping the 3rd-last frame already changes the
# picture, the 4th-last does not). 8 leaves a safety margin.
RENDER_LEAD = 8
INF = 1 << 30


def step_pre_cycles(step: dict) -> int:
    """Cycles a step runs before its 'frames' loop (flush, tap_grid, drag)."""
    total = max(0, int(step.get("release_flush_frames", 0))) if "button_up" in step else 0
    if "tap_grid" in step:
        grid = step["tap_grid"]
        total += max(0, int(grid["count"])) * (max(1, int(grid.get("hold_frames", 2))) + max(0, int(grid.get("gap_frames", 1))))
    if "drag" in step:
        total += max(1, int(step["drag"].get("frames", 1)))
    return total


def step_frames(step: dict) -> int:
    return int(step.get("frames", 0 if "wait_until" in step else 1))


def cycles_to_next_capture(steps: list) -> list:
    """E[i] = cycles between the end of step i and the next capture (INF if none).

    wait_until frames count as 0 (their real length only makes the distance
    larger, so the plan stays conservative).
    """
    after = [INF] * len(steps)
    for i in range(len(steps) - 2, -1, -1):
        nxt = steps[i + 1]
        pre, frames = step_pre_cycles(nxt), step_frames(nxt)
        best = INF
        if nxt.get("capture_sequence") and frames > 0:
            best = pre + 1
        if "capture" in nxt:
            best = min(best, pre + frames)
        else:
            best = min(best, pre + frames + after[i + 1])
        after[i] = best
    return after


# ----------------------------------------------------------------- run ----

def run(rom: Path, rom_sha: str, scenario_path: Path, output: Path, lib, opts: dict, ctx: dict) -> None:
    """Execute one scenario with an already-loaded library. Fills ctx; raises on errors."""
    events = ctx["events"]
    captures = ctx["captures"]
    capture_pixels = {}
    state_samples = ctx["state_samples"]
    sequences = ctx["sequences"]
    trace: InputTrace = ctx["trace"]

    scenario = json.loads(scenario_path.read_text(encoding="utf-8-sig"))
    ctx["scenario"] = scenario
    validate_scenario(scenario)
    output.mkdir(parents=True, exist_ok=True)

    skip_render = bool(opts.get("skip_render", True)) and not scenario.get("render_all_frames", False)
    ctx["skip_render"] = skip_render
    state_config = scenario.get("state")
    state_bases = {}
    default_symbol = "state"
    fields: dict = {}
    states_dir = Path(opts["states_dir"])
    unsafe: list = ctx["replay_unsafe"]

    # Resolve symbols before touching the emulator so map errors fail fast.
    if state_config:
        source = resolve_symbol_source(rom, rom_sha, scenario_path, state_config, opts.get("map"),
                                       opts.get("elf"), ctx["warnings"])
        ctx["symbol_source"] = {"source": source["source"], "elf": str(source["elf"]) if source["elf"] else None,
                                "map": str(source["map"]) if source["map"] else None}
        symbols = state_config["symbols"] if "symbols" in state_config else {"state": state_config["symbol"]}
        state_bases = {alias: resolve_address(source, symbol) for alias, symbol in symbols.items()}
        ctx["symbol_addresses"] = {alias: f"0x{addr:08x}" for alias, addr in state_bases.items()}
        default_symbol = state_config.get("default_symbol", "state")
        fields = state_config["fields"]

    start_state = scenario.get("start_state")
    if start_state:
        state_file = states_dir / f"{start_state}.dst"
        meta_file = states_dir / f"{start_state}.json"
        if not state_file.is_file():
            raise RunnerError("state_missing", f"start_state {start_state!r}: {state_file} does not exist "
                              f"(run the scenario that has save_state {start_state!r} first, same --states-dir)")
        meta = json.loads(meta_file.read_text(encoding="utf-8")) if meta_file.is_file() else {}
        if meta.get("rom_sha256") != rom_sha:
            raise RunnerError("state_rom_mismatch", f"savestate {start_state!r} was saved from a different ROM "
                              f"({meta.get('rom_sha256')} != {rom_sha}); regenerate it")
        unsafe.append("start_state")

    # The library is initialised once per process (see run_all); each scenario reopens the ROM.
    if opts.get("jit") and not hasattr(lib, "desmume_agent_set_jit"):
        ctx["warnings"].append("jit_unsupported")
    if lib.desmume_open(str(rom).encode()) != 1:
        raise RuntimeError("DeSmuME failed to open ROM")
    lib.desmume_resume()
    lib.desmume_input_keypad_update(0)
    lib.desmume_input_release_touch()
    if start_state:
        if not lib.desmume_savestate_load(str(states_dir / f"{start_state}.dst").encode()):
            raise RuntimeError(f"desmume_savestate_load failed for {start_state!r}")
        events.append({"step": -1, "frame": 0, "action": "start_state", "name": start_state})

    has_debug = hasattr(lib, "desmume_agent_debug_read")
    ctx["debug_capture"] = has_debug
    debug_lines = {"events": 0}
    keypad = 0
    touching = False
    touch_x = touch_y = 0
    frame = 0  # emulated frames cycled so far
    last_rendered = True

    def drain_debug() -> None:
        if not has_debug:
            return
        buf = ctypes.create_string_buffer(DEBUG_BUF)
        while True:
            count = lib.desmume_agent_debug_read(buf, DEBUG_BUF)
            if count <= 0:
                return
            text = buf.raw[:count].decode("utf-8", "replace")
            with (output / "debug.log").open("a", encoding="utf-8") as handle:
                handle.write(text)
            for line in text.splitlines():
                if debug_lines["events"] < DEBUG_EVENT_CAP:
                    events.append({"step": ctx["step"], "frame": frame, "action": "debug", "text": line})
                    debug_lines["events"] += 1
            if count < DEBUG_BUF:
                return

    plan = {"j": 0, "total": 0, "tail": INF, "seq": None, "every": 1, "frames": 0, "pre": 0}

    def needs_render() -> bool:
        """True when the next cycle lies within RENDER_LEAD frames of a capture."""
        j = plan["j"] + 1  # 1-based position of the cycle about to run in this step
        distance = plan["total"] - j + plan["tail"] + 1
        if plan["seq"] and plan["frames"] > 0:
            n = j - plan["pre"] - 1  # index in the frames loop (negative while still in pre-cycles)
            if n < 0:
                distance = min(distance, -n + 1)
            else:
                nxt = -(-n // plan["every"]) * plan["every"]
                if nxt < plan["frames"]:
                    distance = min(distance, nxt - n + 1)
        return distance <= RENDER_LEAD

    def cycle(render: bool | None = None) -> None:
        nonlocal frame, last_rendered
        if render is None:
            render = needs_render()
        plan["j"] += 1
        if skip_render and not render:
            lib.desmume_skip_next_frame()
        lib.desmume_input_keypad_update(keypad)  # re-assert held buttons every frame
        lib.desmume_cycle(0)
        trace.add(keypad, touching, touch_x, touch_y)
        frame += 1
        last_rendered = render or not skip_render

    def set_touch(x: int, y: int) -> None:
        nonlocal touching, touch_x, touch_y
        lib.desmume_input_set_touch_pos(x, y)
        touching, touch_x, touch_y = True, x, y

    def release_touch() -> None:
        nonlocal touching
        lib.desmume_input_release_touch()
        touching = False

    def event(index: int, action: str, **extra) -> None:
        events.append({"step": index, "frame": frame, "action": action, **extra})

    tails = cycles_to_next_capture(scenario["steps"])
    for index, step in enumerate(scenario["steps"]):
        ctx["step"] = index
        frames = step_frames(step)
        plan.update(j=0, pre=step_pre_cycles(step), frames=frames, seq=step.get("capture_sequence"),
                    every=max(1, int(step.get("capture_every", 1))),
                    tail=0 if "capture" in step else tails[index])
        plan["total"] = plan["pre"] + frames
        if "button_down" in step:
            keypad |= button_bit(step["button_down"])
            lib.desmume_input_keypad_update(keypad)
            event(index, "button_down", button=step["button_down"], keypad=keypad)
        if "button_up" in step:
            # Clear only this button; every other held button stays in the
            # mask and is re-asserted on each frame. "release_flush_frames"
            # requests extra frames (counted in the frame budget and logged).
            keypad &= ~button_bit(step["button_up"])
            lib.desmume_input_keypad_update(keypad)
            flush = max(0, int(step.get("release_flush_frames", 0)))
            for _ in range(flush):
                cycle()
            event(index, "button_up", button=step["button_up"], keypad=keypad, flush_frames=flush)
        if "tap" in step or "touch" in step:
            point = step["tap"] if "tap" in step else step["touch"]
            set_touch(point["x"], point["y"])
            event(index, "tap", x=point["x"], y=point["y"])
        if "tap_grid" in step:
            # Tap a grid of points one after another, optionally holding
            # buttons during each tap (e.g. a modifier that turns a tap
            # into a spawn). Each tap lasts hold_frames, then gap_frames
            # with the touch released; both count as emulated frames.
            grid = step["tap_grid"]
            count = max(0, int(grid["count"]))
            columns = max(1, int(grid.get("columns", count or 1)))
            hold = 0
            for name in grid.get("hold", []):
                hold |= button_bit(name)
            hold_frames = max(1, int(grid.get("hold_frames", 2)))
            gap_frames = max(0, int(grid.get("gap_frames", 1)))
            base = keypad
            for n in range(count):
                x = int(grid["x"]) + (n % columns) * int(grid.get("spacing_x", 0))
                y = int(grid["y"]) + (n // columns) * int(grid.get("spacing_y", 0))
                set_touch(x, y)
                keypad = base | hold
                for _ in range(hold_frames):
                    cycle()
                keypad = base
                release_touch()
                for _ in range(gap_frames):
                    cycle()
            event(index, "tap_grid", count=count, columns=columns, hold=grid.get("hold", []),
                  hold_frames=hold_frames, gap_frames=gap_frames)
        if "drag" in step:
            drag = step["drag"]
            start, end = drag["from"], drag["to"]
            drag_frames = max(1, int(drag.get("frames", 1)))
            for n in range(drag_frames):
                ratio = n / max(1, drag_frames - 1)
                set_touch(round(start["x"] + (end["x"] - start["x"]) * ratio),
                          round(start["y"] + (end["y"] - start["y"]) * ratio))
                cycle()
            event(index, "drag", **{"from": start, "to": end, "frames": drag_frames})
        if "release" in step:
            release_touch()
            event(index, "release")
        if "poke" in step:
            poke = step["poke"]
            alias = poke.get("symbol", default_symbol)
            kind = poke.get("type", DEFAULT_TYPE)
            address = state_bases[alias] + int(poke["offset"])
            write_typed(lib, address, kind, int(poke["value"]))
            if "poke" not in unsafe:
                unsafe.append("poke")
            event(index, "poke", symbol=alias, offset=int(poke["offset"]), type=kind,
                  value=int(poke["value"]), address=f"0x{address:08x}")

        seq_name = step.get("capture_sequence")
        every = max(1, int(step.get("capture_every", 1)))
        want_capture = "capture" in step
        for n in range(frames):
            cycle()
            if seq_name and n % every == 0:
                count = sequences.get(seq_name, 0)
                capture(lib, output / f"{seq_name}_{count:04d}.png")
                sequences[seq_name] = count + 1
        event(index, "frame_advance", frames=frames, keypad=int(lib.desmume_input_keypad_get()))

        if "wait_until" in step:
            wait = step["wait_until"]
            spec = fields[wait["field"]]
            timeout = int(wait["timeout_frames"])
            waited = 0
            while True:
                value = read_field(lib, state_bases, spec, default_symbol)
                if all(VALUE_CHECKS[key](value, int(wait[key])) for key in VALUE_CHECKS if key in wait):
                    satisfied = True
                    break
                if waited >= timeout:
                    satisfied = False
                    break
                cycle(True)  # wait length is unknown in advance: always render
                waited += 1
            condition = {key: wait[key] for key in VALUE_CHECKS if key in wait}
            event(index, "wait_until", field=wait["field"], condition=condition, waited_frames=waited,
                  timeout_frames=timeout, value=value, satisfied=satisfied)
            if not satisfied:
                label = f"wait_until:{wait['field']}"
                ctx["failed"].append(label)
                ctx["failed_details"].append({
                    "check": label, "expected": {**condition, "within_frames": timeout},
                    "actual": {"value": value, "waited_frames": waited}})
                ctx["aborted"] = True
                drain_debug()
                break
        if want_capture:
            if not last_rendered:
                ctx["warnings"].append(f"capture_stale_frame:{step['capture']}")
            name = step["capture"]
            digest, pixels = capture(lib, output / f"{name}.png")
            captures[name] = {"sha256": digest, "path": f"{name}.png"}
            capture_pixels[name] = pixels
        if "state_capture" in step:
            name = step["state_capture"]
            state_samples[name] = read_state(lib, state_bases, fields, default_symbol)
            event(index, "state_capture", name=name, state=state_samples[name])
        if "save_state" in step:
            name = step["save_state"]
            states_dir.mkdir(parents=True, exist_ok=True)
            target = states_dir / f"{name}.dst"
            if not lib.desmume_savestate_save(str(target).encode()):
                raise RuntimeError(f"desmume_savestate_save failed for {name!r}")
            (states_dir / f"{name}.json").write_text(json.dumps({
                "rom_sha256": rom_sha, "frame": frame, "scenario": scenario_path.name,
            }, indent=2) + "\n", encoding="utf-8")
            event(index, "save_state", name=name, path=str(target))
        drain_debug()
    ctx["frames"] = frame
    drain_debug()

    if ctx.get("aborted"):
        return  # a wait_until timed out: later captures/samples are not meaningful

    assertions = scenario.get("assertions") or {}
    checks = assertions.get("screen_changes")
    if checks is None:
        checks = [assertions["screen_changed"]] if "screen_changed" in assertions else []
    screen_results = []
    for check in checks:
        first = captures[check["from"]]
        second = captures[check["to"]]
        changed_pixels = count_changed_pixels(capture_pixels[check["from"]], capture_pixels[check["to"]])
        min_changed = check.get("min_changed_pixels", 1)
        screen_results.append({
            "from": check["from"], "to": check["to"],
            "changed": first["sha256"] != second["sha256"] and changed_pixels >= min_changed,
            "changed_pixels": changed_pixels, "min_changed_pixels": min_changed,
        })
    state_results = [check_state_assertion(state_samples, check)
                     for check in assertions.get("state_changes", [])]
    summary = {"screen_changed": all(r["changed"] for r in screen_results), "screen_changes": screen_results,
               "state_changed": all(r["passed"] for r in state_results), "state_changes": state_results}
    if screen_results:
        summary["changed_pixels"] = screen_results[0]["changed_pixels"]
        summary["min_changed_pixels"] = screen_results[0]["min_changed_pixels"]
    ctx["assertions"] = summary
    for r in screen_results:
        if not r["changed"]:
            label = f"screen:{r['from']}->{r['to']}"
            ctx["failed"].append(label)
            ctx["failed_details"].append({
                "check": label, "expected": {"min_changed_pixels": r["min_changed_pixels"]},
                "actual": {"changed_pixels": r["changed_pixels"]}})
    for r in state_results:
        if not r["passed"]:
            label = state_label(r)
            ctx["failed"].append(label)
            ctx["failed_details"].append({
                "check": label, "expected": {key: r[key] for key in CHECK_KEYS if key in r},
                "actual": {key: r[key] for key in ("before", "after", "delta") if key in r and r[key] is not None}})
    ctx["assertion_count"] = len(screen_results) + len(state_results)


# ----------------------------------------------------- scenario driver ----

def classify(ctx: dict) -> str:
    """PASS | FAIL | NO_ASSERTIONS | ERROR from a finished scenario context."""
    if ctx["error"]:
        return "ERROR"
    if ctx["failed"]:
        return "FAIL"
    scenario = ctx.get("scenario") or {}
    has_wait = any("wait_until" in step for step in scenario.get("steps", []) if isinstance(step, dict))
    if ctx.get("assertion_count", 0) == 0 and not has_wait:
        if scenario.get("evidence_only") is True:
            if "evidence_only" not in ctx["warnings"]:
                ctx["warnings"].append("evidence_only")
            return "PASS"
        if "no_assertions" not in ctx["warnings"]:
            ctx["warnings"].append("no_assertions")
        return "NO_ASSERTIONS"
    return "PASS"


def exit_code(statuses) -> int:
    statuses = list(statuses)
    if "ERROR" in statuses:
        return 2
    if any(s in ("FAIL", "NO_ASSERTIONS") for s in statuses):
        return 1
    return 0


def redirect_emulator_output(path: Path):
    """Send C-level stdout/stderr (emulator chatter) to a log file; returns a restore callable."""
    try:
        saved = (os.dup(1), os.dup(2))
        target = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    except OSError:
        return lambda: None
    os.dup2(target, 1)
    os.dup2(target, 2)
    os.close(target)

    def restore() -> None:
        try:
            ctypes.CDLL(None).fflush(None)
        except Exception:
            pass
        os.dup2(saved[0], 1)
        os.dup2(saved[1], 2)
        os.close(saved[0])
        os.close(saved[1])

    return restore


def run_one(rom: Path, rom_sha: str, scenario_path: Path, output: Path, lib, opts: dict) -> dict:
    """Run one scenario and write its output files. Returns the result.json dict."""
    ctx = {"events": [], "captures": {}, "state_samples": {}, "sequences": {}, "warnings": [],
           "assertions": {}, "failed": [], "failed_details": [], "frames": 0, "error": None,
           "trace": InputTrace(), "replay_unsafe": [], "step": -1, "debug_capture": False,
           "skip_render": False}
    started = time.perf_counter()
    output.mkdir(parents=True, exist_ok=True)
    restore = redirect_emulator_output(output / "emulator.log") if opts.get("capture_emulator_output", True) else (lambda: None)
    try:
        run(rom, rom_sha, scenario_path, output, lib, opts, ctx)
    except RunnerError as error:
        ctx["error"] = {"code": error.code, "message": str(error)}
    except ScenarioError as error:
        ctx["error"] = {"code": "invalid_scenario", "message": str(error)}
    except json.JSONDecodeError as error:
        ctx["error"] = {"code": "invalid_scenario", "message": f"scenario is not valid JSON: {error}"}
    except Exception as error:  # manifest must be written even on failure
        ctx["error"] = {"code": "exception", "message": f"{type(error).__name__}: {error}"}
    finally:
        restore()
    wall_ms = int((time.perf_counter() - started) * 1000)
    status = classify(ctx)
    name = (ctx.get("scenario") or {}).get("name") if isinstance(ctx.get("scenario"), dict) else None
    name = name or scenario_path.stem
    source = ctx.get("symbol_source")
    result = {
        "name": name, "scenario": scenario_path.name, "status": status,
        "failed": ctx["failed_details"], "error": ctx["error"], "warnings": ctx["warnings"],
        "frames": ctx["frames"], "wall_ms": wall_ms, "captures": sorted(ctx["captures"]),
        "map": source, "debug_capture": ctx["debug_capture"], "skip_render": ctx["skip_render"],
    }
    if source:
        result["symbol_addresses"] = ctx.get("symbol_addresses")
    try:
        manifest = {
            "scenario": scenario_path.name, "status": status,
            "captures": ctx["captures"], "capture_sequences": ctx["sequences"],
            "events": ctx["events"], "frames": ctx["frames"], "assertions": ctx["assertions"],
            "state_samples": ctx["state_samples"], "warnings": ctx["warnings"],
            "error": (f"{ctx['error']['code']}: {ctx['error']['message']}" if ctx["error"] else None),
            "skip_render": ctx["skip_render"], "debug_capture": ctx["debug_capture"],
        }
        if source:
            manifest["map_path"] = source.get("elf") or source.get("map")
            manifest["symbol_source"] = source
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        with (output / "events.jsonl").open("w", encoding="utf-8") as handle:
            for item in ctx["events"]:
                handle.write(json.dumps(item, separators=(",", ":")) + "\n")
        if ctx["trace"].frames:
            replay_safe = not ctx["replay_unsafe"]
            (output / "input_trace.json").write_text(
                json.dumps(ctx["trace"].to_json(replay_safe, ctx["replay_unsafe"]), separators=(",", ":")) + "\n",
                encoding="utf-8")
    except OSError as error:
        elog(f"DSM_SCENARIO_ERROR=cannot write outputs: {error}")
    return result


def print_result(result: dict, stem: str) -> None:
    line = f"DSM_SCENARIO_RESULT={result['status']} name={stem} frames={result['frames']} wall_ms={result['wall_ms']}"
    if result["failed"]:
        line += " failed=" + ",".join(item["check"] for item in result["failed"])
    if result["status"] == "ERROR":
        line += f" reason={result['error']['code']}"
        log(f"DSM_SCENARIO_ERROR={stem}: {result['error']['message']}".replace("\n", " "))
        elog(f"{stem}: {result['error']['message']}")
    elif result["status"] == "NO_ASSERTIONS":
        line += " reason=no_assertions"
    elif result["failed"]:
        line += " reason=assertion_failed"
    for warning in result["warnings"]:
        log(f"DSM_SCENARIO_WARNING={stem}:{warning}")
    log(line)


def run_all(rom: Path, scenarios: list, out: Path, lib_path: Path, opts: dict) -> int:
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    os.environ.setdefault("ALSOFT_DRIVERS", "null")
    multi = len(scenarios) > 1
    started = time.perf_counter()
    rom_sha = sha256_file(rom)
    opts = dict(opts)
    opts.setdefault("states_dir", str(out / "_states"))
    lib = ctypes.CDLL(str(lib_path))
    configure(lib)
    # init/free cannot be repeated in one process (the second init crashes), so
    # initialise once and reopen the ROM per scenario.
    if lib.desmume_init() != 0:
        raise RuntimeError("DeSmuME failed to initialize")
    if opts.get("jit") and hasattr(lib, "desmume_agent_set_jit"):
        lib.desmume_agent_set_jit(1)

    results = []
    skipped = []
    used_stems = set()
    for path in scenarios:
        path = Path(path)
        stem = path.stem
        while stem in used_stems:
            stem += "_"
        used_stems.add(stem)
        if multi:
            try:
                if json.loads(path.read_text(encoding="utf-8-sig")).get("suite") is False:
                    skipped.append(stem)
                    elog(f"skipping {stem}: \"suite\": false")
                    continue
            except (OSError, ValueError):
                pass  # reported as an ERROR by run_one
        output = out / stem if multi else out
        result = run_one(rom, rom_sha, path, output, lib, opts)
        print_result(result, stem)
        results.append((stem, result))
    lib.desmume_free()

    statuses = [r["status"] for _, r in results]
    code = exit_code(statuses)
    if multi:
        wall_ms = int((time.perf_counter() - started) * 1000)
        suite = {
            "status": "ERROR" if code == 2 else "FAIL" if code == 1 else "PASS",
            "total": len(results), "pass": statuses.count("PASS"),
            "fail": sum(s in ("FAIL", "NO_ASSERTIONS") for s in statuses), "error": statuses.count("ERROR"),
            "wall_ms": wall_ms, "skipped": skipped,
            "scenarios": [{"name": stem, "status": r["status"], "frames": r["frames"], "wall_ms": r["wall_ms"],
                           "failed": [item["check"] for item in r["failed"]], "dir": stem}
                          for stem, r in results],
        }
        out.mkdir(parents=True, exist_ok=True)
        (out / "suite.json").write_text(json.dumps(suite, indent=2) + "\n", encoding="utf-8")
        log(f"DSM_SUITE_RESULT={suite['status']} total={suite['total']} pass={suite['pass']} "
            f"fail={suite['fail']} error={suite['error']} wall_ms={wall_ms}")
    return code


def parse_args(argv: list):
    if len(argv) in (4, 5) and not any(arg.startswith("--") for arg in argv):
        # Legacy positional form: ROM SCENARIO OUT LIB [MAP]
        return argparse.Namespace(rom=argv[0], scenarios=[argv[1]], out=argv[2], lib=argv[3],
                                  map=argv[4] if len(argv) == 5 and argv[4] else None, elf=None,
                                  states_dir=None, no_skip_render=False, jit=False)
    parser = argparse.ArgumentParser(description="Run DS scenarios on headless DeSmuME.")
    parser.add_argument("--rom", required=True)
    parser.add_argument("--lib", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--map")
    parser.add_argument("--elf")
    parser.add_argument("--states-dir", dest="states_dir")
    parser.add_argument("--no-skip-render", action="store_true", dest="no_skip_render")
    parser.add_argument("--jit", action="store_true")
    parser.add_argument("scenarios", nargs="+")
    return parser.parse_args(argv)


def main(argv: list | None = None) -> int:
    global _out, _err
    argv = sys.argv[1:] if argv is None else argv
    try:
        args = parse_args(argv)
    except SystemExit:
        return 2
    # The emulator prints to fd 1/2; keep private copies for our own output and
    # let run_one() divert the C-level streams into emulator.log per scenario.
    _out = os.fdopen(os.dup(1), "w", encoding="utf-8", errors="replace")
    _err = os.fdopen(os.dup(2), "w", encoding="utf-8", errors="replace")
    opts = {"skip_render": not args.no_skip_render, "jit": args.jit, "map": args.map, "elf": args.elf}
    if args.states_dir:
        opts["states_dir"] = args.states_dir
    try:
        return run_all(Path(args.rom), args.scenarios, Path(args.out), Path(args.lib), opts)
    except Exception as error:
        log(f"DSM_SUITE_RESULT=ERROR total=0 pass=0 fail=0 error=1 wall_ms=0")
        log(f"DSM_SCENARIO_ERROR={type(error).__name__}: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

