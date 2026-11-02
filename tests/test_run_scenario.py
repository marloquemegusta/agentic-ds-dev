import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
from run_scenario import check_state_assertion, map_symbol_address


class ScenarioStateAssertionsTest(unittest.TestCase):
    def test_resolves_linker_map_bss_symbol(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "game.map"
            path.write_text(" .bss.other 0x02001000 0x4\n"
                            " .bss.g_nav_state\n"
                            "                0x02001004 0x28 build/main.o\n")
            self.assertEqual(map_symbol_address(path, "g_nav_state"), 0x02001004)

    def test_checks_actual_position_delta(self):
        samples = {"spawn": {"x": 1000}, "walk": {"x": 1800}}
        result = check_state_assertion(samples, {
            "from": "spawn", "to": "walk", "field": "x", "min_abs_delta": 512,
        })
        self.assertTrue(result["passed"])
        self.assertEqual(result["delta"], 800)

    def test_checks_wall_stop_with_bounded_delta(self):
        samples = {"at_wall": {"x": 4200}, "after_hold": {"x": 4200}}
        result = check_state_assertion(samples, {
            "from": "at_wall", "to": "after_hold", "field": "x", "max_abs_delta": 0,
        })
        self.assertTrue(result["passed"])

    def test_value_range_enforces_both_bounds(self):
        samples = {"stop": {"x": 0}}

        def check(value):
            samples["stop"]["x"] = value
            return check_state_assertion(samples, {
                "at": "stop", "field": "x", "min_value": 161000, "max_value": 163000,
            })["passed"]

        self.assertTrue(check(162000))
        self.assertFalse(check(180480), "above max_value must fail even though min_value holds")
        self.assertFalse(check(150000))

    def test_delta_range_enforces_both_bounds(self):
        samples = {"a": {"y": 0}, "b": {"y": 900}}
        result = check_state_assertion(samples, {
            "from": "a", "to": "b", "field": "y", "min_delta": 100, "max_delta": 500,
        })
        self.assertFalse(result["passed"])

    def test_assertion_without_check_is_rejected(self):
        with self.assertRaises(ValueError):
            check_state_assertion({"s": {"x": 1}}, {"at": "s", "field": "x"})


if __name__ == "__main__":
    unittest.main()
