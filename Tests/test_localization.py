"""Keep user-facing message catalogs complete and their format arguments safe."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";', re.M)
FORMAT = re.compile(r'%(?!%)(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|ll|h|l|z)?[@diufFeEgGxXosc]')


def catalog(language):
    text = (ROOT / f'{language}.lproj/Localizable.strings').read_text()
    pairs = [(json.loads('"' + key + '"'), json.loads('"' + value + '"')) for key, value in ENTRY.findall(text)]
    return pairs


class LocalizationTests(unittest.TestCase):
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
        for path in (ROOT / 'ReYogaSMCApp').glob('*.swift'):
            for raw in re.findall(r'localizedMessage\("((?:\\.|[^"\\])*)"', path.read_text()):
                if '\\(' in raw:
                    continue  # composed numbers, identifiers, and existing localized labels
                value = json.loads('"' + raw + '"')
                if not re.search(r'[A-Za-z]{2,} ', value) and not re.search(r' [A-Za-z]{2,}', value):
                    continue
                self.assertIn(value, keys, f'{path.name}: missing message template')

    def test_builtin_event_and_legacy_osd_keys_are_localized(self):
        keys = set(dict(catalog('en')))
        paths = list((ROOT / 'ReYogaSMCApp').glob('*.swift')) + list((ROOT / 'ReYogaSMCUtils').glob('*.swift'))
        for path in paths:
            for key in re.findall(r'(?:showOSD(?:Res)?|EventDesc)\("([^"\\]*)"', path.read_text()):
                self.assertIn(key, keys, f'{path.name}: unlocalized event/OSD key')

    def test_support_errors_and_control_labels_have_translations(self):
        keys = set(dict(catalog('en')))
        for path in (ROOT / 'ReYogaSMCApp').glob('*.swift'):
            for raw in re.findall(r'SupportError\.message\("((?:\\.|[^"\\])*)"', path.read_text()):
                if '\\(' not in raw:
                    self.assertIn(json.loads('"' + raw + '"'), keys)
        source = (ROOT / 'ReYogaSMCApp/HardwareManager.swift').read_text().split('public static let catalog:', 1)[1].split('    ]', 1)[0]
        for label in re.findall(r'"[^"\n]+": "([^"\n]+)"', source):
            self.assertIn(label, keys)

    def test_localization_does_not_modify_registry_keys(self):
        source = (ROOT / 'ReYogaSMCApp/HardwareManager.swift').read_text()
        self.assertNotRegex(source, r'props\[localizedMessage\(')
        for key in ('Battery 0', 'Battery 1', 'HardwareProfile', 'FeatureStatus'):
            self.assertIn('"' + key + '"', source)
