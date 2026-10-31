"""Automated validation of all hardware profile JSON files in HardwareProfiles/"""
import json
import pathlib
import unittest

REQUIRED_KEYS_COMMON = {
    "schema_version",
    "kind",
    "id",
    "name"
}

REQUIRED_KEYS_ACPI = {
    "machine_types",
    "bios_families",
    "ec_path",
    "rpm_scale",
    "battery_conservation_mask",
    "battery_rapidcharge_mask",
    "native_telemetry"
}

ROOT = pathlib.Path(__file__).resolve().parents[1]


class TestProfileSchemas(unittest.TestCase):
    def test_all_json_profiles(self):
        json_files = sorted((ROOT / 'HardwareProfiles').glob('*.json'))
        self.assertGreater(len(json_files), 0, "No profile JSON files found")

        for path in json_files:
            filename = path.name
            with self.subTest(file=filename):
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)

                for key in REQUIRED_KEYS_COMMON:
                    self.assertIn(key, data, f"{filename} missing required key '{key}'")

                self.assertEqual(data["schema_version"], 1)
                self.assertIsInstance(data["id"], str)
                self.assertIsInstance(data["name"], str)
                self.assertIsInstance(data["sources"], list)
                self.assertIn(data["kind"], ["acpi", "rgb"])

                if data["kind"] == "acpi":
                    for key in REQUIRED_KEYS_ACPI:
                        self.assertIn(key, data, f"{filename} missing ACPI key '{key}'")

                    self.assertIsInstance(data["machine_types"], list)
                    self.assertGreater(len(data["machine_types"]), 0)
                    self.assertIsInstance(data["bios_families"], list)
                    self.assertGreater(len(data["bios_families"]), 0)
                    self.assertIsInstance(data["rpm_scale"], int)
                    self.assertIsInstance(data["battery_conservation_mask"], int)
                    self.assertIsInstance(data["battery_rapidcharge_mask"], int)
                    self.assertEqual(data["battery_conservation_mask"] & data["battery_rapidcharge_mask"], 0)

                    telemetry = data["native_telemetry"]
                    self.assertIsInstance(telemetry, list)
                    self.assertEqual(len(telemetry), 4, f"{filename} native_telemetry must have exactly 4 fields")
                    for item in telemetry:
                        self.assertIn("field", item)
                        self.assertIn("scale", item)
                        self.assertIsInstance(item["field"], str)
                        self.assertIsInstance(item["scale"], int)
                        self.assertRegex(item["field"], r"^[A-Z0-9_]{4}$")

                    if "reviewed_aml_hashes" in data:
                        self.assertTrue(data["reviewed_aml_hashes"])
                        for digest in data["reviewed_aml_hashes"]:
                            self.assertRegex(digest, r"^[a-f0-9]{64}$")

    def test_unique_ids_and_embedded_hotkey_references(self):
        profiles = [json.loads(path.read_text(encoding='utf-8')) for path in (ROOT / 'HardwareProfiles').glob('*.json')]
        ids = [profile['id'] for profile in profiles]
        self.assertEqual(len(ids), len(set(ids)))
        hotkeys = []
        for profile in profiles:
            if 'hotkeys' in profile:
                hotkeys.append(profile['hotkeys'])
                self.assertIn(profile['id'], profile['hotkeys']['matchProfiles'])
                self.assertTrue(set(profile['hotkeys']['matchProfiles']).issubset(ids))
        self.assertTrue(hotkeys)
        self.assertEqual(len({item['id'] for item in hotkeys}), len(hotkeys))


if __name__ == "__main__":
    unittest.main()
