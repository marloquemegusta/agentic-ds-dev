import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "tools" / "scenario_to_replay.py"
spec = importlib.util.spec_from_file_location("scenario_to_replay", TOOL)
s2r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s2r)

A, B = 1, 2


class PackRunsTest(unittest.TestCase):
    def test_rle_merges_equal_frames(self):
        frames = [(0, False, 0, 0)] * 3 + [(A, False, 0, 0)] * 2 + [(A, True, 10, 20)]
        self.assertEqual(s2r.pack_runs(frames), [[3, 0, 0, 0, 0], [2, A, 0, 0, 0], [1, A, 1, 10, 20]])

    def test_untouched_coordinates_do_not_split_runs(self):
        frames = [(0, False, 5, 5), (0, False, 9, 9)]
        self.assertEqual(s2r.pack_runs(frames), [[2, 0, 0, 0, 0]])

    def test_touch_move_splits_runs(self):
        frames = [(0, True, 1, 1), (0, True, 2, 1)]
        self.assertEqual(len(s2r.pack_runs(frames)), 2)


class BinaryTest(unittest.TestCase):
    def test_layout_and_round_trip(self):
        runs = [(10, 0, 0, 0, 0), (2, A | B, 1, 255, 191), (70000, 0x0800, 0, 0, 0)]
        blob = s2r.encode_bin(runs)
        self.assertEqual(blob[:4], b"DSR1")
        self.assertEqual(blob[4:8], (3).to_bytes(4, "little"))
        self.assertEqual(len(blob), 8 + 12 * 3)
        # second run: count=2, keys=3, touching=1, pad=0, x=255, y=191
        self.assertEqual(blob[20:32], bytes([2, 0, 0, 0, 3, 0, 1, 0, 255, 0, 191, 0]))
        self.assertEqual(s2r.decode_bin(blob), runs)

    def test_c_header(self):
        text = s2r.encode_c([(4, A, 0, 0, 0), (1, 0, 1, 7, 8)], "g_demo")
        self.assertIn("static const ds_replay_run_t g_demo[]", text)
        self.assertIn("{ 4u, 0x0001, 0, 0, 0, 0 },", text)
        self.assertIn("{ 1u, 0x0000, 1, 0, 7, 8 },", text)
        self.assertIn("#define G_DEMO_COUNT 2u", text)
        self.assertIn("#define G_DEMO_FRAMES 5u", text)
        self.assertIn('#include "dsagent/ds_replay.h"', text)
        self.assertIn('#include "x/y.h"', s2r.encode_c([(1, 0, 0, 0, 0)], "n", "x/y.h"))
        with self.assertRaises(s2r.ReplayError):
            s2r.encode_c([(1, 0, 0, 0, 0)], "bad name")


class TraceTest(unittest.TestCase):
    def write(self, data):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        self.addCleanup(os.unlink, handle.name)
        json.dump(data, handle)
        handle.close()
        return handle.name

    def test_load_ok(self):
        path = self.write({"version": 1, "frames": 3, "replay_safe": True, "runs": [[3, 1, 0, 0, 0]]})
        self.assertEqual(s2r.load_trace(path), [(3, 1, 0, 0, 0)])

    def test_replay_unsafe_refused_unless_forced(self):
        path = self.write({"version": 1, "frames": 1, "replay_safe": False, "runs": [[1, 0, 0, 0, 0]]})
        with self.assertRaises(s2r.ReplayError):
            s2r.load_trace(path)
        self.assertEqual(s2r.load_trace(path, force=True), [(1, 0, 0, 0, 0)])

    def test_cli_exit_codes(self):
        path = self.write({"version": 1, "frames": 1, "replay_safe": False, "runs": [[1, 0, 0, 0, 0]]})
        out = tempfile.mktemp(suffix=".dsr")
        self.addCleanup(lambda: os.path.exists(out) and os.unlink(out))
        self.assertEqual(s2r.main([path, "--format", "bin", "-o", out]), 2)
        self.assertFalse(os.path.exists(out))
        self.assertEqual(s2r.main([path, "--format", "bin", "-o", out, "--force"]), 0)
        self.assertEqual(s2r.decode_bin(Path(out).read_bytes()), [(1, 0, 0, 0, 0)])

    def test_frame_count_mismatch_and_bad_keys(self):
        with self.assertRaises(s2r.ReplayError):
            s2r.load_trace(self.write({"frames": 9, "replay_safe": True, "runs": [[3, 0, 0, 0, 0]]}))
        with self.assertRaises(s2r.ReplayError):
            s2r.validate_runs([[1, 0x2000, 0, 0, 0]])


class ScenarioTest(unittest.TestCase):
    def sim(self, steps, **extra):
        return s2r.simulate_scenario({"steps": steps, **extra})

    def test_button_down_up_and_default_frames(self):
        runs = self.sim([{"frames": 2}, {"button_down": "A", "frames": 3}, {"button_up": "A"}])
        # up step has no frames key -> default 1 frame
        self.assertEqual(runs, [(2, 0, 0, 0, 0), (3, A, 0, 0, 0), (1, 0, 0, 0, 0)])

    def test_other_buttons_stay_held(self):
        runs = self.sim([{"button_down": "A", "frames": 1}, {"button_down": "B", "frames": 1},
                         {"button_up": "A", "frames": 1}])
        self.assertEqual([r[1] for r in runs], [A, A | B, B])

    def test_release_flush_frames(self):
        runs = self.sim([{"button_down": "A", "frames": 1},
                         {"button_up": "A", "release_flush_frames": 2, "frames": 1}])
        self.assertEqual(runs, [(1, A, 0, 0, 0), (3, 0, 0, 0, 0)])

    def test_tap_stays_until_release(self):
        runs = self.sim([{"tap": {"x": 10, "y": 20}, "frames": 2}, {"frames": 1},
                         {"release": True, "frames": 1}])
        self.assertEqual(runs, [(3, 0, 1, 10, 20), (1, 0, 0, 0, 0)])

    def test_touch_alias(self):
        self.assertEqual(self.sim([{"touch": {"x": 1, "y": 2}, "frames": 1}]), [(1, 0, 1, 1, 2)])

    def test_drag_interpolates_one_frame_per_point(self):
        runs = self.sim([{"drag": {"from": {"x": 0, "y": 10}, "to": {"x": 30, "y": 10}, "frames": 4},
                          "frames": 0}])
        self.assertEqual(runs, [(1, 0, 1, 0, 10), (1, 0, 1, 10, 10), (1, 0, 1, 20, 10),
                                (1, 0, 1, 30, 10)])

    def test_drag_single_frame_and_touch_persists(self):
        runs = self.sim([{"drag": {"from": {"x": 5, "y": 6}, "to": {"x": 50, "y": 60}, "frames": 1},
                          "frames": 1}])
        self.assertEqual(runs, [(2, 0, 1, 5, 6)])

    def test_tap_grid(self):
        runs = self.sim([{"tap_grid": {"count": 3, "columns": 2, "x": 10, "y": 20, "spacing_x": 30,
                                       "spacing_y": 40, "hold": ["R"], "hold_frames": 2,
                                       "gap_frames": 1}, "frames": 0}])
        R = 1 << 8
        self.assertEqual(runs, [(2, R, 1, 10, 20), (1, 0, 0, 0, 0),
                                (2, R, 1, 40, 20), (1, 0, 0, 0, 0),
                                (2, R, 1, 10, 60), (1, 0, 0, 0, 0)])

    def test_tap_grid_defaults_and_clamp(self):
        runs = self.sim([{"tap_grid": {"count": 1, "x": 999, "y": -5}, "frames": 0}])
        self.assertEqual(runs, [(2, 0, 1, 255, 0), (1, 0, 0, 0, 0)])

    def test_tap_grid_keeps_base_keys(self):
        runs = self.sim([{"button_down": "A", "frames": 1},
                         {"tap_grid": {"count": 1, "x": 1, "y": 1, "hold": ["B"]}, "frames": 0}])
        self.assertEqual(runs, [(1, A, 0, 0, 0), (2, A | B, 1, 1, 1), (1, A, 0, 0, 0)])

    def test_ignored_annotations(self):
        runs = self.sim([{"comment": "x", "frames": 2, "capture": "c", "state_capture": "s"}])
        self.assertEqual(runs, [(2, 0, 0, 0, 0)])

    def test_rejected_steps(self):
        for key in ("wait_until", "poke"):
            with self.assertRaises(s2r.ReplayError):
                self.sim([{key: {}, "frames": 1}])
        with self.assertRaises(s2r.ReplayError):
            self.sim([{"frames": 1}], start_state="save.dst")
        with self.assertRaises(s2r.ReplayError):
            self.sim([{"bogus": 1}])

    def test_unknown_button(self):
        with self.assertRaises(s2r.ReplayError):
            self.sim([{"button_down": "Q"}])


if __name__ == "__main__":
    unittest.main()
