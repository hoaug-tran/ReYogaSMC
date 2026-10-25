"""Check integration boundaries that broke during the app directory migration."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ProjectStructureTests(unittest.TestCase):
    def test_build_and_sign_scripts_reference_existing_app_inputs(self):
        workflow = (ROOT / '.github/workflows/main.yml').read_text()
        adapter = re.search(r'swiftc[^\n]*? (\S*HardwareSupport.swift)', workflow).group(1)
        self.assertTrue((ROOT / adapter).is_file(), adapter)
        signing = (ROOT / 'Scripts/sign-app.sh').read_text()
        entitlement = re.search(r'\$sign_root/([^"\n]+\.entitlements)', signing).group(1)
        self.assertTrue((ROOT / entitlement).is_file(), entitlement)
        brand = (ROOT / 'Scripts/render-brand.swift').read_text()
        catalogue = re.search(r'root.appendingPathComponent\("([^"\n]+AppIcon.appiconset)"\)', brand).group(1)
        self.assertTrue((ROOT / catalogue / 'Contents.json').is_file(), catalogue)

    def test_typed_localizations_exist_in_both_languages(self):
        catalogue = (ROOT / 'ReYogaSMCApp/LocalizedKey.swift').read_text()
        keys = set(re.findall(r'case \w+ = "([A-Z_]+)"', catalogue))
        for language in ('en', 'vi'):
            strings = (ROOT / f'{language}.lproj/Localizable.strings').read_text()
            translated = set(re.findall(r'^"([^"\n]+)"\s*=', strings, re.MULTILINE))
            self.assertEqual(keys - translated, set(), language)

    def test_oem_candidates_do_not_select_the_first_matching_model(self):
        source = (ROOT / 'ReYogaSMC/ReYogaVPC/IdeaVPC.cpp').read_text()
        self.assertIn('ReYogaFirmware::select', source)
        matcher = (ROOT / 'ReYogaSMC/FirmwareIdentity.hpp').read_text()
        self.assertIn('strcmp(result.profile->id, profile.id)', matcher)
        self.assertIn('MatchState::ambiguous', matcher)

    def test_build_metadata_runs_after_plist_generation(self):
        project = (ROOT / 'ReYogaSMC.xcodeproj/project.pbxproj').read_text()
        phase = project.split('6F89849C254941090016FF59 /* Add Source Revision */ = {', 1)[1].split('\n\t\t};', 1)[0]
        self.assertIn('"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"', phase.split('inputPaths = (', 1)[1].split(');', 1)[0])

    def test_ui_fixture_covers_live_battery_report(self):
        fixture = json.loads((ROOT / 'Tests/ui-fixture.json').read_text())
        battery = fixture['AppleSmartBattery']
        self.assertGreater(battery['AppleRawMaxCapacity'], 0)
        self.assertLessEqual(battery['AppleRawCurrentCapacity'], battery['AppleRawMaxCapacity'])
