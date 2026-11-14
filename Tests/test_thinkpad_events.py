"""Verify ThinkPad extended hotkeys, VPC notification unmasking, and event mappings."""
import json
import pathlib
import re
import unittest

try:
    from .source_tools import function
except ImportError:
    from source_tools import function

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";', re.M)


def read_catalog(language):
    text = (ROOT / f'{language}.lproj/Localizable.strings').read_text(encoding='utf-8')
    return dict((json.loads('"' + key + '"'), json.loads('"' + value + '"')) for key, value in ENTRY.findall(text))


class ThinkPadEventsTests(unittest.TestCase):
    def test_think_events_header_defines_extended_hotkeys(self):
        """Verify ThinkEvents.h defines all required extended event codes."""
        header = (ROOT / 'ReYogaSMC/Platform/ThinkEvents.h').read_text(encoding='utf-8')
        self.assertRegex(header, r'TP_HKEY_EV_CLIPPING_TOOL\s*=\s*0x1312')
        self.assertRegex(header, r'TP_HKEY_EV_CALCULATOR\s*=\s*0x1313')
        self.assertRegex(header, r'TP_HKEY_EV_NOTIFICATION_CENTER\s*=\s*0x1317')
        self.assertRegex(header, r'TP_HKEY_EV_ANSWER_CALL\s*=\s*0x1318')
        self.assertRegex(header, r'TP_HKEY_EV_HANGUP_CALL\s*=\s*0x1319')
        self.assertRegex(header, r'TP_HKEY_EV_KEY_FN\s*=\s*0x6005')

    def test_thinkpad_vpc_unmasks_alter_mask_at_boot(self):
        """Verify ThinkVPC::initVPC unmasks hotkey_alter_all_mask with DHKF_MASK_offset."""
        cpp = (ROOT / 'ReYogaSMC/Platform/ThinkVPC.cpp').read_text(encoding='utf-8')
        init_body = function(cpp, 'bool ThinkVPC::initVPC(')

        self.assertIn('DHKN_MASK_offset', init_body)
        self.assertIn('hotkey_all_mask', init_body)
        self.assertIn('DHKF_MASK_offset', init_body)
        self.assertIn('hotkey_alter_all_mask', init_body)
        self.assertRegex(init_body, r'setNotificationMask\([^,]+,\s*hotkey_alter_all_mask,\s*DHKF_MASK_offset\)')

    def test_thinkpad_vpc_restores_alter_mask_on_wake(self):
        """Verify ThinkVPC::setPowerState wake branch unmasks hotkey_alter_all_mask with DHKF_MASK_offset."""
        cpp = (ROOT / 'ReYogaSMC/Platform/ThinkVPC.cpp').read_text(encoding='utf-8')
        power_body = function(cpp, 'IOReturn ThinkVPC::setPowerState(')
        wake_branch = power_body.split('} else {', 1)[1].split('return kIOPMAckImplied;', 1)[0]

        self.assertIn('DHKN_MASK_offset', wake_branch)
        self.assertIn('hotkey_all_mask', wake_branch)
        self.assertIn('DHKF_MASK_offset', wake_branch)
        self.assertIn('hotkey_alter_all_mask', wake_branch)
        self.assertRegex(wake_branch, r'setNotificationMask\([^,]+,\s*hotkey_alter_all_mask,\s*DHKF_MASK_offset\)')

    def test_default_events_maps_thinkpad_extended_hotkeys(self):
        """Verify DefaultEvents.swift registers mappings for 0x1312, 0x1313, 0x6005, and call buttons."""
        source = (ROOT / 'ReYogaSMCApp/Events/DefaultEvents.swift').read_text(encoding='utf-8')
        think_events_block = source.split('let thinkEvents:', 1)[1].split('let HIDDEvents:', 1)[0]

        self.assertIn('TP_HKEY_EV_CLIPPING_TOOL.rawValue', think_events_block)
        self.assertRegex(
            think_events_block,
            r'TP_HKEY_EV_CLIPPING_TOOL\.rawValue:\s*\[\s*0:\s*EventDescriptor\([^,]+,\s*act:\s*\.screenshot'
        )

        self.assertIn('TP_HKEY_EV_CALCULATOR.rawValue', think_events_block)
        self.assertRegex(
            think_events_block,
            r'TP_HKEY_EV_CALCULATOR\.rawValue:\s*\[\s*0:\s*EventDescriptor\([^,]+,\s*act:\s*\.calculator'
        )

        self.assertIn('TP_HKEY_EV_KEY_FN.rawValue', think_events_block)
        self.assertRegex(
            think_events_block,
            r'TP_HKEY_EV_KEY_FN\.rawValue:\s*\[\s*0:\s*EventDescriptor\([^,]+,\s*act:\s*\.thermal'
        )

        self.assertIn('TP_HKEY_EV_NOTIFICATION_CENTER.rawValue', think_events_block)
        self.assertIn('TP_HKEY_EV_ANSWER_CALL.rawValue', think_events_block)
        self.assertIn('TP_HKEY_EV_HANGUP_CALL.rawValue', think_events_block)

    def test_localization_parity_for_extended_events(self):
        """Verify Screenshot, Calculator, and Thermal Profile are localized in en and vi catalogs."""
        en = read_catalog('en')
        vi = read_catalog('vi')

        for key in ['Screenshot', 'Calculator', 'Thermal Profile']:
            self.assertIn(key, en, f'Missing en localization for "{key}"')
            self.assertIn(key, vi, f'Missing vi localization for "{key}"')
            self.assertTrue(en[key], f'Empty en translation for "{key}"')
            self.assertTrue(vi[key], f'Empty vi translation for "{key}"')

        self.assertEqual(en['Screenshot'], 'Screenshot')
        self.assertEqual(vi['Screenshot'], 'Chụp màn hình')
        self.assertEqual(en['Calculator'], 'Calculator')
        self.assertEqual(vi['Calculator'], 'Máy tính')
        self.assertEqual(en['Thermal Profile'], 'Thermal profile')
        self.assertEqual(vi['Thermal Profile'], 'Hồ sơ nhiệt')


if __name__ == '__main__':
    unittest.main()
