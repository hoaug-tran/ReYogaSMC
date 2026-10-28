"""Check integration boundaries that broke during the app directory migration."""
import json
import pathlib
import re
import unittest

try:
    from .source_tools import kernel_sources
except ImportError:
    from source_tools import kernel_sources

ROOT = pathlib.Path(__file__).resolve().parents[1]


def project_sources(project, phase_id):
    """Resolve Xcode group paths and build-file references to real source paths."""
    objects = dict(re.findall(
        r'^\s*([A-F0-9]{24})(?: /\* [^\n]*? \*/)? = (\{[^\n]*\};|\{\n.*?^[ \t]+\};)',
        project, re.M | re.S))
    paths = {}

    def visit(identity, parent):
        body = objects[identity]
        match = re.search(r'\bpath = ("(?:\\.|[^"\\])*"|[^;]+);', body)
        name = match.group(1) if match else ''
        if name.startswith('"'):
            name = json.loads(name)
        path = parent / name
        children = re.search(r'children = \((.*?)\);', body, re.S)
        if children:
            for child in re.findall(r'\b[A-F0-9]{24}\b', children.group(1)):
                visit(child, path)
        else:
            paths[identity] = path

    visit(re.search(r'mainGroup = ([A-F0-9]{24})', project).group(1), ROOT)
    files = re.search(r'files = \((.*?)\);', objects[phase_id], re.S).group(1)
    result = []
    for build_id in re.findall(r'\b[A-F0-9]{24}\b', files):
        reference = re.search(r'fileRef = ([A-F0-9]{24})', objects[build_id]).group(1)
        result.append(paths[reference].relative_to(ROOT).as_posix())
    return result


class ProjectStructureTests(unittest.TestCase):
    def test_each_app_source_is_registered_in_xcode(self):
        project = (ROOT / 'ReYogaSMC.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        sources = project_sources(project, '6F0A987325343357002F9F65')
        expected = [path.relative_to(ROOT).as_posix() for path in (ROOT / 'ReYogaSMCApp').rglob('*.swift')]
        self.assertCountEqual(sources, expected)

    def test_each_kernel_translation_unit_is_registered_in_xcode(self):
        project = (ROOT / 'ReYogaSMC.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        sources = project_sources(project, '6F08ACE024746B8B00681A63')
        expected = [path.relative_to(ROOT).as_posix() for path in (ROOT / 'ReYogaSMC').rglob('*')
                    if path.suffix in ('.cpp', '.c')]
        self.assertCountEqual(sources, expected)

    def test_device_and_view_modules_use_explicit_application_actions(self):
        for directory in ('Hardware', 'Views'):
            for path in (ROOT / 'ReYogaSMCApp' / directory).rglob('*.swift'):
                with self.subTest(source=path.relative_to(ROOT)):
                    self.assertNotIn('NSApp.delegate', path.read_text(encoding='utf-8'))
        driver = (ROOT / 'ReYogaSMCApp/Application/DriverConnection.swift').read_text(encoding='utf-8')
        self.assertIn('private let context = DriverEventContext()', driver)
        self.assertIn('generation == owner.connectionGeneration', driver)
        self.assertIn('owner.context.service == service', driver)

    def test_swift_bridge_imports_and_build_settings_resolve(self):
        bridge = ROOT / 'ReYogaSMCApp/Hardware/Driver/ReYogaSMC-Bridging-Header.h'
        for relative in re.findall(r'^#import "([^"]+)"', bridge.read_text(encoding='utf-8'), re.M):
            self.assertTrue((bridge.parent / relative).resolve().is_file(), relative)
        project = (ROOT / 'ReYogaSMC.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        for relative in re.findall(r'SWIFT_OBJC_BRIDGING_HEADER = "([^"]+)";', project):
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_rgb_service_keeps_presentation_at_the_view_boundary(self):
        source = (ROOT / 'ReYogaSMCApp/Hardware/Lighting/HardwareLightingManager.swift').read_text(encoding='utf-8')
        for ui_dependency in ('NSOpenPanel', 'NSColor', 'import AppKit', 'SavedRGBSettings.hex'):
            self.assertNotIn(ui_dependency, source)
        self.assertIn('color: RGBBytes', source)
        self.assertIn('func importRGBColors(from file: URL)', source)

    def test_hardware_does_not_open_ui_or_render_feedback(self):
        for path in (ROOT / 'ReYogaSMCApp/Hardware').rglob('*.swift'):
            source = path.read_text(encoding='utf-8')
            with self.subTest(source=path.relative_to(ROOT)):
                for dependency in ('NSOpenPanel', 'NSSavePanel', 'NSWorkspace', 'NSColor', 'import SwiftUI',
                                   'showOSD', 'ReYogaBrand', 'controlValueLabel', 'ControlRiskConfirmation'):
                    self.assertNotIn(dependency, source)

        for path in (ROOT / 'ReYogaSMCApp/Diagnostics').rglob('*.swift'):
            source = path.read_text(encoding='utf-8')
            with self.subTest(source=path.relative_to(ROOT)):
                for dependency in ('NSOpenPanel', 'NSSavePanel', 'NSWorkspace', 'showOSD'):
                    self.assertNotIn(dependency, source)

    def test_pr_build_keeps_native_validation_and_skips_publishing(self):
        workflow = (ROOT / '.github/workflows/main.yml').read_text(encoding='utf-8')
        build = workflow.split('  build:\n', 1)[1].split('  release:\n', 1)[0]
        settings = build.split('    steps:', 1)[0]
        self.assertNotIn("github.event_name != 'pull_request'", settings)
        self.assertIn('run: bash Scripts/test-support.sh', build)
        self.assertIn("- name: Package\n        if: github.event_name != 'pull_request'", build)

    def test_brand_generator_updates_shipped_icns(self):
        generator = (ROOT / 'Scripts/render-brand.swift').read_text(encoding='utf-8')
        self.assertIn('"/usr/bin/iconutil"', generator)
        self.assertIn('output.appendingPathComponent("ReYogaSMC.icns")', generator)
        self.assertIn('iconutil.terminationStatus == 0', generator)

    def test_build_and_sign_scripts_reference_existing_app_inputs(self):
        workflow = (ROOT / '.github/workflows/main.yml').read_text(encoding='utf-8')
        self.assertIn('bash Scripts/test-support.sh', workflow)
        support = (ROOT / 'Scripts/test-support.sh').read_text(encoding='utf-8')
        inputs = re.findall(r'^\s+((?:ReYogaSMCApp|Tests)/[^\s]+\.swift)\s*$', support, re.M)
        self.assertTrue(inputs)
        for path in inputs:
            self.assertTrue((ROOT / path).is_file(), path)
        signing = (ROOT / 'Scripts/sign-app.sh').read_text(encoding='utf-8')
        entitlement = re.search(r'\$sign_root/([^"\n]+\.entitlements)', signing).group(1)
        self.assertTrue((ROOT / entitlement).is_file(), entitlement)
        brand = (ROOT / 'Scripts/render-brand.swift').read_text(encoding='utf-8')
        catalogue = re.search(r'root.appendingPathComponent\("([^"\n]+AppIcon.appiconset)"\)', brand).group(1)
        self.assertTrue((ROOT / catalogue / 'Contents.json').is_file(), catalogue)

    def test_typed_localizations_exist_in_both_languages(self):
        catalogue = (ROOT / 'ReYogaSMCApp/Shared/LocalizedKey.swift').read_text(encoding='utf-8')
        keys = set(re.findall(r'case \w+ = "([A-Z_]+)"', catalogue))
        for language in ('en', 'vi'):
            strings = (ROOT / f'{language}.lproj/Localizable.strings').read_text(encoding='utf-8')
            translated = set(re.findall(r'^"([^"\n]+)"\s*=', strings, re.MULTILINE))
            self.assertEqual(keys - translated, set(), language)

    def test_oem_candidates_do_not_select_the_first_matching_model(self):
        source = kernel_sources('IdeaVPC')
        self.assertIn('ReYogaFirmware::select', source)
        matcher = (ROOT / 'ReYogaSMC/FirmwareIdentity.hpp').read_text(encoding='utf-8')
        self.assertIn('strcmp(result.profile->id, profile.id)', matcher)
        self.assertIn('MatchState::ambiguous', matcher)

    def test_build_metadata_runs_after_plist_generation(self):
        project = (ROOT / 'ReYogaSMC.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        phase = project.split('6F89849C254941090016FF59 /* Add Source Revision */ = {', 1)[1].split('\n\t\t};', 1)[0]
        self.assertIn('"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"', phase.split('inputPaths = (', 1)[1].split(');', 1)[0])

    def test_ui_fixture_covers_live_battery_report(self):
        fixture = json.loads((ROOT / 'Tests/ui-fixture.json').read_text(encoding='utf-8'))
        battery = fixture['AppleSmartBattery']
        self.assertGreater(battery['AppleRawMaxCapacity'], 0)
        self.assertLessEqual(battery['AppleRawCurrentCapacity'], battery['AppleRawMaxCapacity'])
