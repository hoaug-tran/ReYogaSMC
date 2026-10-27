"""Keep user-facing message catalogs complete and their format arguments safe."""
import io
import json
import pathlib
import plistlib
import re
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";', re.M)
FORMAT = re.compile(r'%(?!%)(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|ll|h|l|z)?[@diufFeEgGxXosc]')


def catalog(language):
    text = (ROOT / f'{language}.lproj/Localizable.strings').read_text(encoding='utf-8')
    pairs = [(json.loads('"' + key + '"'), json.loads('"' + value + '"')) for key, value in ENTRY.findall(text)]
    return pairs


class LocalizationTests(unittest.TestCase):
    def test_permission_prompts_are_localized_and_included_in_app_resources(self):
        info = plistlib.loads((ROOT / 'ReYogaSMCApp/Info.plist').read_bytes())
        expected = {key for key in info if key.endswith('UsageDescription')}
        project = (ROOT / 'ReYogaSMC.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        self.assertIn('InfoPlist.strings in Resources', project)
        for language in ('en', 'vi'):
            path = f'{language}.lproj/InfoPlist.strings'
            pairs = [(json.loads('"' + key + '"'), json.loads('"' + value + '"'))
                     for key, value in ENTRY.findall((ROOT / path).read_text(encoding='utf-8'))]
            values = dict(pairs)
            self.assertEqual(len(pairs), len(values))
            self.assertEqual(set(values), expected)
            self.assertIn(path, project)
            for key, value in values.items():
                self.assertTrue(value.strip())
                if language == 'en':
                    self.assertEqual(value, info[key])
                else:
                    self.assertNotEqual(value, info[key])

    def test_vietnamese_catalog_with_windows_default_encoding(self):
        original_open = io.open

        def legacy_open(file, mode='r', buffering=-1, encoding=None, errors=None,
                        newline=None, closefd=True, opener=None):
            if 'b' not in mode and encoding in (None, 'locale'):
                encoding = 'cp1252'
            return original_open(file, mode, buffering, encoding, errors, newline, closefd, opener)

        with patch('io.open', legacy_open):
            self.assertEqual(dict(catalog('vi'))['SIDEBAR_TAB_OVERVIEW'], 'Tổng quan')

    def test_languages_have_identical_keys_without_duplicates(self):
        english, vietnamese = catalog('en'), catalog('vi')
        for entries in (english, vietnamese):
            self.assertEqual(len(entries), len(dict(entries)), 'Duplicate localization key')
        self.assertEqual(set(dict(english)), set(dict(vietnamese)))

    def test_translations_preserve_format_arguments(self):
        vietnamese = dict(catalog('vi'))
        for key, english in catalog('en'):
            with self.subTest(key=key):
                self.assertEqual(FORMAT.findall(english.replace('%%', '')), FORMAT.findall(vietnamese[key].replace('%%', '')))

    def test_literal_app_message_templates_exist_in_both_catalogs(self):
        keys = set(dict(catalog('en')))
        for path in list((ROOT / 'ReYogaSMCApp').glob('*.swift')) + list((ROOT / 'ReYogaSMCUtils').glob('*.swift')):
            for raw in re.findall(r'localizedMessage\("((?:\\.|[^"\\])*)"', path.read_text(encoding='utf-8')):
                if '\\(' in raw:
                    continue  # composed numbers, identifiers, and existing localized labels
                value = json.loads('"' + raw + '"')
                if not re.search(r'[A-Za-z]{2,} ', value) and not re.search(r' [A-Za-z]{2,}', value):
                    continue
                self.assertIn(value, keys, f'{path.name}: missing message template')

    def test_osd_and_async_acpi_completion_messages_are_translated(self):
        keys = set(dict(catalog('en')))
        paths = list((ROOT / 'ReYogaSMCApp').glob('*.swift')) + list((ROOT / 'ReYogaSMCUtils').glob('*.swift'))
        for path in paths:
            source = path.read_text(encoding='utf-8')
            for raw in re.findall(r'(?:showOSDRaw|completion)\("((?:\\.|[^"\\])*)"', source):
                if '\\(' not in raw and raw:
                    self.assertIn(json.loads('"' + raw + '"'), keys, f'{path.name}: raw display message missing from catalogs')

    def test_fan_availability_and_recovery_keys_are_translated(self):
        keys = set(dict(catalog('en')))
        source = (ROOT / 'ReYogaSMCUtils/ThinkFanHelper.swift').read_text(encoding='utf-8')
        policy = source.split('struct ThinkFanCurvePolicy', 1)[1].split('static let defaults', 1)[0]
        reasons = re.findall(r'return "([^"\n]+)"', policy)
        reasons += re.findall(r'(?:curveStatus|curveStopReason)\s*=\s*"([^"\n]+)"', source)
        reasons += re.findall(r'explainCurveUnavailable\("([^"\n]+)"', source)
        for reason in reasons:
            self.assertIn(reason, keys, f'Fan UI reason missing from catalogs: {reason}')

    def test_builtin_event_and_legacy_osd_keys_are_localized(self):
        keys = set(dict(catalog('en')))
        paths = list((ROOT / 'ReYogaSMCApp').glob('*.swift')) + list((ROOT / 'ReYogaSMCUtils').glob('*.swift'))
        for path in paths:
            for key in re.findall(r'(?:showOSD(?:Res)?|EventDesc)\("([^"\\]*)"', path.read_text(encoding='utf-8')):
                self.assertIn(key, keys, f'{path.name}: unlocalized event/OSD key')

    def test_support_errors_and_control_labels_have_translations(self):
        keys = set(dict(catalog('en')))
        for path in (ROOT / 'ReYogaSMCApp').glob('*.swift'):
            for raw in re.findall(r'SupportError\.message\("((?:\\.|[^"\\])*)"', path.read_text(encoding='utf-8')):
                if '\\(' not in raw:
                    self.assertIn(json.loads('"' + raw + '"'), keys)
        source = (ROOT / 'ReYogaSMCApp/HardwareManager.swift').read_text(encoding='utf-8').split('public static let catalog:', 1)[1].split('    ]', 1)[0]
        for label in re.findall(r'"[^"\n]+": "([^"\n]+)"', source):
            self.assertIn(label, keys)

    def test_localization_does_not_modify_registry_keys(self):
        source = (ROOT / 'ReYogaSMCApp/HardwareManager.swift').read_text(encoding='utf-8')
        self.assertNotRegex(source, r'props\[localizedMessage\(')
        for key in ('Battery 0', 'Battery 1', 'HardwareProfile', 'FeatureStatus'):
            self.assertIn('"' + key + '"', source)
