import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ProfileSchemaTests(unittest.TestCase):
    def test_common_metadata_and_embedded_hotkey_references(self):
        profiles = [json.loads(path.read_text(encoding='utf-8')) for path in (ROOT / 'HardwareProfiles').glob('*.json')]
        ids = [profile['id'] for profile in profiles]
        self.assertEqual(len(ids), len(set(ids)))
        hotkeys = []
        for profile in profiles:
            self.assertEqual(profile['schema_version'], 1)
            self.assertIn(profile['kind'], ('acpi', 'rgb'))
            self.assertIsInstance(profile['name'], str)
            self.assertIsInstance(profile['sources'], list)
            if 'hotkeys' in profile:
                hotkeys.append(profile['hotkeys'])
                self.assertIn(profile['id'], profile['hotkeys']['matchProfiles'])
                self.assertTrue(set(profile['hotkeys']['matchProfiles']).issubset(ids))
        self.assertTrue(hotkeys)
        self.assertEqual(len({item['id'] for item in hotkeys}), len(hotkeys))
