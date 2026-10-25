"""Automated validation of all hardware profile JSON files in HardwareProfiles/"""
import glob
import json
import os
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

class TestProfileSchemas(unittest.TestCase):
    def test_all_json_profiles(self):
        profiles_dir = os.path.join(os.path.dirname(__file__), "..", "HardwareProfiles")
        json_files = glob.glob(os.path.join(profiles_dir, "*.json"))
        self.assertGreater(len(json_files), 0, "No profile JSON files found")

        for path in json_files:
            filename = os.path.basename(path)
            with self.subTest(file=filename):
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)

                for key in REQUIRED_KEYS_COMMON:
                    self.assertIn(key, data, f"{filename} missing required key '{key}'")

                self.assertEqual(data["schema_version"], 1)
                self.assertIsInstance(data["id"], str)
                self.assertIsInstance(data["name"], str)
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

if __name__ == "__main__":
    unittest.main()
