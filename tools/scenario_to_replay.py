#!/usr/bin/env python3
"""Convert a runner input trace (or a simple scenario) into an on-device replay.

Input (one of):
  input_trace.json            {"version":1,"frames":N,"replay_safe":bool,
                               "runs":[[count, keys, touching, x, y], ...]}
  --from-scenario FILE.json   simple scenario; input is simulated with the same
                              per-frame semantics as runtime/run_scenario.py

Output:
  --format c    C header for ds_replay.h: static const ds_replay_run_t NAME[]
                plus NAME_COUNT and NAME_FRAMES macros (use --name, --include).
  --format bin  .dsr file, little endian:
                  "DSR1" | u32 run_count | run_count * 12-byte runs
                  run = u32 count, u16 keys, u8 touching, u8 pad(0), u16 x, u16 y
                keys use the libnds KEY_* bit layout (bit0=A 1=B 2=SELECT 3=START
                4=RIGHT 5=LEFT 6=UP 7=DOWN 8=R 9=L 10=X 11=Y).

Exit codes: 0 ok, 2 refused/invalid input (e.g. replay_safe is false without
--force, or a scenario uses wait_until/poke/start_state).
Python 3 standard library only.
"""
import argparse
import json
import re
import struct
import sys

MAGIC = b"DSR1"
BUTTON_BITS = {
    "A": 1 << 0, "B": 1 << 1, "SELECT": 1 << 2, "START": 1 << 3,
    "RIGHT": 1 << 4, "LEFT": 1 << 5, "UP": 1 << 6, "DOWN": 1 << 7,
    "R": 1 << 8, "L": 1 << 9, "X": 1 << 10, "Y": 1 << 11,
}
# Steps keys that only annotate or sample; they do not change the input.
IGNORED_STEP_KEYS = {"comment", "note", "capture", "capture_sequence", "capture_every",
                     "state_capture"}
SIMULATED_STEP_KEYS = {"button_down", "button_up", "release_flush_frames", "tap", "touch",
                       "tap_grid", "drag", "release", "frames"}
REJECTED_STEP_KEYS = {"wait_until", "poke", "start_state"}
SCREEN_W, SCREEN_H = 256, 192


class ReplayError(Exception):
    """Invalid or unsupported input; the CLI exits with status 2."""


def button_bit(name):
    try:
        return BUTTON_BITS[str(name).upper()]
    except KeyError:
        raise ReplayError("unknown button %r" % (name,))


def pack_runs(frames):
    """Run-length encode per-frame (keys, touching, x, y) tuples.

    Untouched frames normalise x,y to 0 so a moving-but-released stylus does
    not split runs. Returns a list of [count, keys, touching, x, y].
    """
    runs = []
    for keys, touching, x, y in frames:
        touching = 1 if touching else 0
        if not touching:
            x = y = 0
        item = (keys & 0xFFFF, touching, x, y)
        if runs and tuple(runs[-1][1:]) == item:
            runs[-1][0] += 1
        else:
            runs.append([1, *item])
    return runs


def _check_u16(value, what):
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 0xFFFF:
        raise ReplayError("%s out of range (0..65535): %r" % (what, value))


def validate_runs(runs):
    out = []
    for i, run in enumerate(runs):
        if not isinstance(run, (list, tuple)) or len(run) != 5:
            raise ReplayError("run %d must be [count, keys, touching, x, y]" % i)
        count, keys, touching, x, y = run
        if not isinstance(count, int) or isinstance(count, bool) or not 1 <= count <= 0xFFFFFFFF:
            raise ReplayError("run %d: count must be a positive integer" % i)
        _check_u16(keys, "run %d keys" % i)
        if keys & ~0x0FFF:
            raise ReplayError("run %d: keys has bits outside A..Y (0x0FFF)" % i)
        if touching not in (0, 1, True, False):
            raise ReplayError("run %d: touching must be 0 or 1" % i)
        _check_u16(x, "run %d x" % i)
        _check_u16(y, "run %d y" % i)
        out.append((count, keys, int(touching), x, y))
    return out


def load_trace(path, force=False):
    with open(path, "r", encoding="utf-8-sig") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or "runs" not in data:
        raise ReplayError("%s is not an input_trace.json (missing 'runs')" % path)
    if data.get("version", 1) != 1:
        raise ReplayError("unsupported input_trace version %r" % (data.get("version"),))
    if not data.get("replay_safe", False) and not force:
        raise ReplayError(
            "trace is not replay_safe (the run used wait_until/poke/start_state or other "
            "non-replayable input); refusing. Use --force to convert it anyway.")
    runs = validate_runs(data["runs"])
    if "frames" in data and data["frames"] != sum(r[0] for r in runs):
        raise ReplayError("trace 'frames' (%r) does not match the sum of run counts (%d)"
                          % (data["frames"], sum(r[0] for r in runs)))
    return runs


def simulate_scenario(scenario):
    """Per-frame input of a simple scenario, mirroring runtime/run_scenario.py.

    Per step, in this order: button_down, button_up (+release_flush_frames),
    tap/touch, tap_grid, drag, release, then `frames` (default 1). The held
    keypad and the stylus persist between steps; tap stays until release.
    """
    if not isinstance(scenario, dict) or not isinstance(scenario.get("steps"), list):
        raise ReplayError("scenario needs a 'steps' list")
    if scenario.get("start_state"):
        raise ReplayError("scenario uses start_state; cannot be replayed")
    frames = []
    keypad = 0
    touch = None  # (x, y) or None

    def cycle():
        frames.append((keypad, touch is not None, *(touch or (0, 0))))

    for index, step in enumerate(scenario["steps"]):
        if not isinstance(step, dict):
            raise ReplayError("step %d is not an object" % index)
        for key in step:
            if key in REJECTED_STEP_KEYS:
                raise ReplayError("step %d uses %r; cannot be replayed" % (index, key))
            if key not in SIMULATED_STEP_KEYS and key not in IGNORED_STEP_KEYS:
                raise ReplayError("step %d has unknown key %r" % (index, key))
        if "button_down" in step:
            keypad |= button_bit(step["button_down"])
        if "button_up" in step:
            keypad &= ~button_bit(step["button_up"])
            for _ in range(max(0, int(step.get("release_flush_frames", 0)))):
                cycle()
        if "tap" in step or "touch" in step:
            point = step["tap"] if "tap" in step else step["touch"]
            touch = (int(point["x"]), int(point["y"]))
        if "tap_grid" in step:
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
                touch = (max(0, min(SCREEN_W - 1, x)), max(0, min(SCREEN_H - 1, y)))
                keypad = base | hold
                for _ in range(hold_frames):
                    cycle()
                keypad = base
                touch = None
                for _ in range(gap_frames):
                    cycle()
        if "drag" in step:
            drag = step["drag"]
            start, end = drag["from"], drag["to"]
            drag_frames = max(1, int(drag.get("frames", 1)))
            for n in range(drag_frames):
                ratio = n / max(1, drag_frames - 1)
                touch = (round(start["x"] + (end["x"] - start["x"]) * ratio),
                         round(start["y"] + (end["y"] - start["y"]) * ratio))
                cycle()
        if "release" in step:
            touch = None
        for _ in range(int(step.get("frames", 1))):
            cycle()
    return validate_runs(pack_runs(frames))


def encode_bin(runs):
    out = bytearray(MAGIC)
    out += struct.pack("<I", len(runs))
    for count, keys, touching, x, y in runs:
        out += struct.pack("<IHBBHH", count, keys, touching, 0, x, y)
    return bytes(out)


def decode_bin(blob):
    if blob[:4] != MAGIC:
        raise ReplayError("not a DSR1 file")
    (n,) = struct.unpack_from("<I", blob, 4)
    if len(blob) != 8 + 12 * n:
        raise ReplayError("DSR1 size mismatch")
    runs = []
    for i in range(n):
        count, keys, touching, _pad, x, y = struct.unpack_from("<IHBBHH", blob, 8 + 12 * i)
        runs.append((count, keys, touching, x, y))
    return runs


def encode_c(runs, name, include="dsagent/ds_replay.h"):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise ReplayError("--name must be a C identifier, got %r" % name)
    total = sum(r[0] for r in runs)
    guard = "DS_REPLAY_DATA_%s_H" % name.upper()
    lines = [
        "/* Generated by tools/scenario_to_replay.py - do not edit. */",
        "#ifndef %s" % guard,
        "#define %s" % guard,
        '#include "%s"' % include,
        "",
        "#define %s_COUNT %du" % (name.upper(), len(runs)),
        "#define %s_FRAMES %du" % (name.upper(), total),
        "/* { count, keys, touching, pad, x, y } */",
        "static const ds_replay_run_t %s[] = {" % name,
    ]
    for count, keys, touching, x, y in runs:
        lines.append("    { %du, 0x%04X, %d, 0, %d, %d }," % (count, keys, touching, x, y))
    lines += ["};", "", "#endif", ""]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("trace", nargs="?", help="input_trace.json from the runner")
    src.add_argument("--from-scenario", metavar="FILE", help="simple scenario json to simulate")
    parser.add_argument("--format", choices=("c", "bin"), required=True)
    parser.add_argument("--name", default="g_replay", help="C identifier for --format c")
    parser.add_argument("--include", default="dsagent/ds_replay.h",
                        help="header that declares ds_replay_run_t (default: dsagent/ds_replay.h)")
    parser.add_argument("-o", "--output", help="output file (default: stdout for c, required for bin)")
    parser.add_argument("--force", action="store_true", help="convert a trace even if replay_safe is false")
    args = parser.parse_args(argv)
    try:
        if args.from_scenario:
            with open(args.from_scenario, "r", encoding="utf-8-sig") as handle:
                runs = simulate_scenario(json.load(handle))
        else:
            runs = load_trace(args.trace, force=args.force)
        if not runs:
            raise ReplayError("no frames to replay")
        if args.format == "bin":
            if not args.output:
                raise ReplayError("--format bin needs -o/--output")
            with open(args.output, "wb") as handle:
                handle.write(encode_bin(runs))
        else:
            text = encode_c(runs, args.name, args.include)
            if args.output:
                with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(text)
            else:
                sys.stdout.write(text)
    except (ReplayError, OSError, ValueError, KeyError) as exc:
        print("scenario_to_replay: %s" % exc, file=sys.stderr)
        return 2
    print("scenario_to_replay: %d runs, %d frames" % (len(runs), sum(r[0] for r in runs)),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
