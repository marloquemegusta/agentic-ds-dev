import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
import run_scenario as rs  # noqa: E402
from run_scenario import check_state_assertion, map_symbol_address  # noqa: E402

REAL_ELF = Path("C:/codexlocal/dungeonds/.ds-game-dev/build/build/game-blocksds.elf")
if not REAL_ELF.exists():
    REAL_ELF = Path("/mnt/c/codexlocal/dungeonds/.ds-game-dev/build/build/game-blocksds.elf")


def scenario(**extra):
    base = {"steps": [{"frames": 1, "capture": "a"}, {"frames": 1, "capture": "b"}],
            "assertions": {"screen_changes": [{"from": "a", "to": "b"}]}}
    base.update(extra)
    return base


def problems_of(data) -> str:
    try:
        rs.validate_scenario(data)
    except rs.ScenarioError as error:
        return str(error)
    return ""


class ScenarioStateAssertionsTest(unittest.TestCase):
    def test_resolves_linker_map_bss_symbol(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "game.map"
            path.write_text(" .bss.other 0x02001000 0x4\n"
                            " .bss.g_nav_state\n"
                            "                0x02001004 0x28 build/main.o\n")
            self.assertEqual(map_symbol_address(path, "g_nav_state"), 0x02001004)

    def test_ambiguous_map_symbol_is_an_error(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "game.map"
            path.write_text(" .bss.s_cache 0x02001000 0x4 a.o\n .bss.s_cache 0x02002000 0x4 b.o\n")
            with self.assertRaises(rs.RunnerError) as caught:
                map_symbol_address(path, "s_cache")
            self.assertEqual(caught.exception.code, "ambiguous_symbol")
            self.assertIn("02002000", str(caught.exception))

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

    def test_not_equals(self):
        self.assertTrue(check_state_assertion({"s": {"x": 1}}, {"at": "s", "field": "x", "not_equals": 2})["passed"])
        self.assertFalse(check_state_assertion({"s": {"x": 2}}, {"at": "s", "field": "x", "not_equals": 2})["passed"])

    def test_assertion_without_check_is_rejected(self):
        with self.assertRaises(ValueError):
            check_state_assertion({"s": {"x": 1}}, {"at": "s", "field": "x"})


class PixelCountTest(unittest.TestCase):
    def test_counts_pixels_not_bytes(self):
        first = bytes(3 * 10)
        second = bytearray(first)
        second[0:3] = b"\x01\x02\x03"  # one pixel, three channels differ
        second[12] = 9                # one pixel, one channel differs
        self.assertEqual(rs.count_changed_pixels(first, bytes(second)), 2)
        self.assertEqual(rs.count_changed_pixels(first, first), 0)

    def test_png_is_valid_and_level_six(self):
        data = rs.png_bytes(bytes(rs.RGB_SIZE))
        self.assertTrue(data.startswith(b"\x89PNG"))


class FakeLib:
    """Memory-backed stand-in for the typed read/write exports."""

    def __init__(self, memory: bytes):
        self.memory = bytearray(memory)

    def _read(self, address, size, signed):
        return int.from_bytes(self.memory[address:address + size], "little", signed=signed)

    def desmume_memory_read_byte(self, a): return self._read(a, 1, False)
    def desmume_memory_read_byte_signed(self, a): return self._read(a, 1, True)
    def desmume_memory_read_short(self, a): return self._read(a, 2, False)
    def desmume_memory_read_short_signed(self, a): return self._read(a, 2, True)
    def desmume_memory_read_long(self, a): return self._read(a, 4, False)
    def desmume_memory_read_long_signed(self, a): return self._read(a, 4, True)

    def desmume_memory_write_byte(self, a, v): self.memory[a:a + 1] = v.to_bytes(1, "little")
    def desmume_memory_write_short(self, a, v): self.memory[a:a + 2] = v.to_bytes(2, "little")
    def desmume_memory_write_long(self, a, v): self.memory[a:a + 4] = v.to_bytes(4, "little")


class TypedFieldsTest(unittest.TestCase):
    def test_every_type_decodes_the_same_bytes(self):
        lib = FakeLib(b"\xfe\xff\xff\xff" + bytes(4))
        expect = {"u8": 254, "s8": -2, "u16": 65534, "s16": -2, "u32": 4294967294, "s32": -2}
        for kind, value in expect.items():
            self.assertEqual(rs.read_typed(lib, 0, kind), value, kind)

    def test_field_spec_forms_and_default_type(self):
        lib = FakeLib(b"\xff\xff\xff\xff\x07\x00\x00\x00")
        bases = {"nav": 0}
        fields = {"bare": 0, "unsigned": {"symbol": "nav", "offset": 0, "type": "u32"},
                  "byte": {"symbol": "nav", "offset": 4, "type": "u8"}}
        self.assertEqual(rs.read_state(lib, bases, fields, "nav"), {"bare": -1, "unsigned": 4294967295, "byte": 7})

    def test_poke_writes_and_rejects_out_of_range(self):
        lib = FakeLib(bytes(8))
        rs.write_typed(lib, 4, "s16", -2)
        self.assertEqual(rs.read_typed(lib, 4, "u16"), 65534)
        with self.assertRaises(ValueError):
            rs.write_typed(lib, 0, "u8", 256)


class ValidationTest(unittest.TestCase):
    def test_valid_scenario_passes(self):
        self.assertEqual(problems_of(scenario()), "")

    def test_unknown_keys_everywhere(self):
        self.assertIn("unknown top-level keys ['bogus']", problems_of(scenario(bogus=1)))
        self.assertIn("unknown keys ['screen_change']", problems_of(scenario(assertions={"screen_change": []})))
        data = scenario()
        data["assertions"]["screen_changes"][0]["min_pixels"] = 5
        self.assertIn("min_pixels", problems_of(data))
        data = scenario(steps=[{"frames": 1, "capture": "a"}, {"frames": 1, "capturee": "b"}])
        self.assertIn("unknown keys ['capturee']", problems_of(data))

    def test_unknown_state_keys(self):
        state = {"symbol": "g", "fields": {"x": {"offset": 0, "typ": "u8"}}, "extra": 1}
        text = problems_of(scenario(state=state))
        self.assertIn("unknown keys ['typ']", text)
        self.assertIn("state: unknown keys ['extra']", text)
        state = {"symbol": "g", "fields": {"x": {"offset": 0, "type": "float"}}}
        self.assertIn("unknown type", problems_of(scenario(state=state)))

    def test_assertions_must_reference_produced_names(self):
        data = scenario(assertions={"screen_changes": [{"from": "a", "to": "missing"}]})
        self.assertIn("'missing' is never produced", problems_of(data))
        state = {"symbol": "g", "fields": {"x": 0}}
        data = scenario(state=state, assertions={"state_changes": [{"at": "ghost", "field": "x", "equals": 1}]})
        self.assertIn("'ghost' is never produced", problems_of(data))
        data = scenario(state=state, assertions={"state_changes": [{"at": "s", "field": "y", "equals": 1}]})
        self.assertIn("'y' is not in state.fields", problems_of(data))

    def test_touch_with_release_is_rejected(self):
        for key, value in (("tap", {"x": 1, "y": 1}), ("touch", {"x": 1, "y": 1}),
                           ("drag", {"from": {"x": 1, "y": 1}, "to": {"x": 2, "y": 2}}),
                           ("tap_grid", {"count": 1, "x": 1, "y": 1})):
            text = problems_of(scenario(steps=[{key: value, "release": True}]))
            self.assertIn("cancels itself", text, key)

    def test_button_down_and_up_same_step(self):
        self.assertIn("cancel out", problems_of(scenario(steps=[{"button_down": "A", "button_up": "a"}])))
        self.assertEqual(problems_of(scenario(steps=[{"button_down": "A", "button_up": "B"},
                                                      {"frames": 1, "capture": "a"}, {"capture": "b"}])), "")

    def test_touch_coordinates_must_be_on_lower_screen(self):
        text = problems_of(scenario(steps=[{"tap": {"x": 100, "y": 250}}]))
        self.assertIn("outside the lower screen", text)
        self.assertIn("subtract 192", text)
        self.assertIn("outside", problems_of(scenario(steps=[{"tap": {"x": 256, "y": 0}}])))
        self.assertIn("outside", problems_of(scenario(steps=[{"tap_grid": {"count": 4, "columns": 4, "x": 200, "y": 10, "spacing_x": 40}}])))
        self.assertEqual(problems_of(scenario(steps=[{"tap": {"x": 255, "y": 191}}, {"capture": "a"}, {"capture": "b"}])), "")

    def test_wait_until_and_poke_checks(self):
        state = {"symbol": "g", "fields": {"x": 0}}
        steps = [{"wait_until": {"field": "x", "equals": 1}}]
        self.assertIn("timeout_frames", problems_of(scenario(state=state, steps=steps)))
        steps = [{"wait_until": {"field": "x", "timeout_frames": 5}}]
        self.assertIn("needs one of", problems_of(scenario(state=state, steps=steps)))
        steps = [{"poke": {"offset": 0, "type": "u8", "value": 300}}]
        self.assertIn("does not fit", problems_of(scenario(state=state, steps=steps)))
        steps = [{"wait_until": {"field": "x", "equals": 1, "timeout_frames": 5}},
                 {"poke": {"offset": 0, "value": 1}}, {"capture": "a"}, {"capture": "b"}]
        self.assertEqual(problems_of(scenario(state=state, steps=steps)), "")

    def test_state_names(self):
        self.assertIn("start_state", problems_of(scenario(start_state="../x")))
        self.assertIn("save_state", problems_of(scenario(steps=[{"save_state": "a b"}])))


class ClassifyAndExitTest(unittest.TestCase):
    def ctx(self, **extra):
        data = {"error": None, "failed": [], "warnings": [], "assertion_count": 1, "scenario": {"steps": []}}
        data.update(extra)
        return data

    def test_status_matrix(self):
        self.assertEqual(rs.classify(self.ctx()), "PASS")
        self.assertEqual(rs.classify(self.ctx(failed=["x"])), "FAIL")
        self.assertEqual(rs.classify(self.ctx(error={"code": "exception", "message": "boom"})), "ERROR")
        self.assertEqual(rs.classify(self.ctx(assertion_count=0)), "NO_ASSERTIONS")

    def test_evidence_only_passes_with_warning(self):
        ctx = self.ctx(assertion_count=0, scenario={"steps": [], "evidence_only": True})
        self.assertEqual(rs.classify(ctx), "PASS")
        self.assertIn("evidence_only", ctx["warnings"])

    def test_wait_until_counts_as_assertion(self):
        ctx = self.ctx(assertion_count=0, scenario={"steps": [{"wait_until": {}}]})
        self.assertEqual(rs.classify(ctx), "PASS")

    def test_exit_codes(self):
        self.assertEqual(rs.exit_code(["PASS", "PASS"]), 0)
        self.assertEqual(rs.exit_code(["PASS", "FAIL"]), 1)
        self.assertEqual(rs.exit_code(["PASS", "NO_ASSERTIONS"]), 1)
        self.assertEqual(rs.exit_code(["FAIL", "ERROR"]), 2)
        self.assertEqual(rs.exit_code([]), 0)


class InputTraceTest(unittest.TestCase):
    def test_run_length_encoding(self):
        trace = rs.InputTrace()
        for _ in range(3):
            trace.add(0, False, 5, 5)          # coordinates are ignored when not touching
        for _ in range(2):
            trace.add(16, False, 0, 0)
        trace.add(16, True, 10, 20)
        trace.add(16, True, 10, 20)
        trace.add(16, True, 11, 20)
        data = trace.to_json()
        self.assertEqual(data["frames"], 8)
        self.assertEqual(data["runs"], [[3, 0, 0, 0, 0], [2, 16, 0, 0, 0], [2, 16, 1, 10, 20], [1, 16, 1, 11, 20]])
        self.assertNotIn("replay_safe", data)
        self.assertFalse(trace.to_json(False, ["poke"])["replay_safe"])


class RenderPlanTest(unittest.TestCase):
    def test_distance_to_next_capture(self):
        steps = [{"frames": 100}, {"frames": 10}, {"frames": 5, "capture": "a"}, {"frames": 3}]
        self.assertEqual(rs.cycles_to_next_capture(steps), [15, 5, rs.INF, rs.INF])

    def test_sequence_samples_count(self):
        steps = [{"frames": 20}, {"frames": 4, "capture_sequence": "s"}]
        self.assertEqual(rs.cycles_to_next_capture(steps)[0], 1)

    def test_pre_cycles(self):
        step = {"button_up": "A", "release_flush_frames": 2, "tap_grid": {"count": 2, "hold_frames": 2, "gap_frames": 1}}
        self.assertEqual(rs.step_pre_cycles(step), 2 + 2 * 3)


class SymbolSourceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.rom = self.root / "game.nds"
        self.rom.write_bytes(b"ROM")
        self.sha = hashlib.sha256(b"ROM").hexdigest()
        self.scenario = self.root / "scenarios" / "s.json"
        self.scenario.parent.mkdir()
        self.out = self.root / ".ds-game-dev" / "build" / "out"
        self.out.mkdir(parents=True)

    def info(self, sha):
        (self.root / "b.map").write_text(" .bss.g 0x02000010 0x4 a.o\n")
        (self.out / "game.buildinfo.json").write_text(json.dumps({
            "rom": "game.nds", "romSha256": sha, "elf": str(self.root / "missing.elf"), "map": str(self.root / "b.map")}))

    def test_buildinfo_match(self):
        self.info(self.sha)
        warnings = []
        src = rs.resolve_symbol_source(self.rom, self.sha, self.scenario, {}, None, None, warnings)
        self.assertEqual(src["source"], "buildinfo")
        self.assertEqual(rs.resolve_address(src, "g"), 0x02000010)
        self.assertEqual(warnings, [])

    def test_buildinfo_mismatch_is_error(self):
        self.info("0" * 64)
        with self.assertRaises(rs.RunnerError) as caught:
            rs.resolve_symbol_source(self.rom, self.sha, self.scenario, {}, None, None, [])
        self.assertEqual(caught.exception.code, "map_mismatch")

    def test_explicit_map_skips_the_check(self):
        self.info("0" * 64)
        warnings = []
        src = rs.resolve_symbol_source(self.rom, self.sha, self.scenario, {}, str(self.root / "b.map"), None, warnings)
        self.assertEqual(src["source"], "explicit")
        self.assertEqual(warnings, [])

    def test_legacy_fallback_warns(self):
        legacy = self.root / ".ds-game-dev" / "build" / "build"
        legacy.mkdir(parents=True)
        (legacy / "game-blocksds.map").write_text(" .bss.g 0x02000020 0x4 a.o\n")
        warnings = []
        src = rs.resolve_symbol_source(self.rom, self.sha, self.scenario, {}, None, None, warnings)
        self.assertEqual(src["source"], "legacy")
        self.assertEqual(warnings, ["map_unverified"])

    def test_windows_path_conversion(self):
        if rs.os.name != "nt":
            self.assertEqual(str(rs.host_path("C:\\a\\b.elf")), "/mnt/c/a/b.elf")
        self.assertEqual(rs.host_path("rel/x").as_posix(), "rel/x")


@unittest.skipUnless(REAL_ELF.exists(), "dungeonds ELF not available")
class ElfParserTest(unittest.TestCase):
    def test_finds_known_symbols(self):
        symbols = rs.elf_symbols(REAL_ELF)
        self.assertEqual(symbols["g_perf"], [0x0228e3ec])
        self.assertEqual(rs.elf_symbol_address(REAL_ELF, "g_nav_state"), 0x0228fd94)

    def test_missing_symbol(self):
        with self.assertRaises(LookupError):
            rs.elf_symbol_address(REAL_ELF, "no_such_symbol_xyz")

    def test_agrees_with_map(self):
        map_file = REAL_ELF.with_suffix(".map")
        if map_file.exists():
            self.assertEqual(rs.elf_symbol_address(REAL_ELF, "g_perf"), map_symbol_address(map_file, "g_perf"))


if __name__ == "__main__":
    unittest.main()
