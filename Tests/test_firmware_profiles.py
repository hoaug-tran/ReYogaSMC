"""Native profiles must be reproducible and reject unreviewed or malformed input."""
import copy
import importlib.util
import json
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("firmware_generator", ROOT / "Scripts/generate_firmware_profiles.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)
class FirmwareProfilesTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((ROOT / "HardwareProfiles/legion7-16achg6.json").read_text(encoding="utf-8"))
    def test_generated_header_is_current(self):
        profiles = [json.loads(path.read_text(encoding="utf-8")) for path in (ROOT / "HardwareProfiles").glob("*.json")]
        self.assertEqual(generator.render(profiles), generator.OUTPUT.read_text(encoding="utf-8"))
    def test_missing_reviewed_hash_is_rejected(self):
        self.profile["reviewed_aml_hashes"] = []
        with self.assertRaises(ValueError): generator.render([self.profile])
    def test_duplicate_firmware_hash_is_rejected(self):
        duplicate = copy.deepcopy(self.profile)
        duplicate["id"] = "different-profile"
        with self.assertRaises(ValueError): generator.render([self.profile, duplicate])
    def test_bad_units_and_fields_are_rejected(self):
        for field, scale in [("BAD!", 1), ("FANS", 0), ("FANS", -1), ("FANS", 1001), ("FANS", True), ("FANS", 1.5)]:
            with self.subTest(field=field, scale=scale):
                bad = copy.deepcopy(self.profile)
                bad["native_telemetry"][0] = {"field": field, "scale": scale}
                with self.assertRaises(ValueError): generator.render([bad])
    def test_unrelated_profiles_do_not_enable_native_reads(self):
        unrelated = {"id": "unreviewed", "kind": "acpi"}
        self.assertEqual(generator.render([self.profile]), generator.render([self.profile, unrelated]))
    def test_incomplete_sensor_layout_is_rejected(self):
        self.profile["native_telemetry"].pop()
        with self.assertRaises(ValueError): generator.render([self.profile])

    def test_native_fields_use_reviewed_absolute_namespace(self):
        rendered = generator.render([self.profile])
        self.assertIn(self.profile["ec_path"].replace("\\", "\\\\") + ".FANS", rendered)
        self.profile["ec_path"] = "EC0"
        with self.assertRaises(ValueError): generator.render([self.profile])
