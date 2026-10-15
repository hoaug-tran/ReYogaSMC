"""Source-level safety regressions; these do not simulate firmware or prove bootability."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding='utf-8')


class BootSafetyTests(unittest.TestCase):
    def test_cpu_power_defaults_to_disabled_and_requires_opt_in(self):
        header = source('ReYogaSMC/ReYogaWMI/IdeaWMI.hpp')
        impl = source('ReYogaSMC/ReYogaWMI/IdeaWMI.cpp')
        self.assertIn('bool cpuPowerAccessEnabled {false}', header)
        self.assertIn('cpuPowerAccessEnabled = PE_parse_boot_argn("-reycpupower"', impl)
        for method in ('getPowerLimit', 'setPowerLimit'):
            body = impl.split(f'bool IdeaWMIGameZone::{method}(', 1)[1]
            body = body.split('\n}', 1)[0]
            self.assertLess(body.index('!cpuPowerAccessEnabled'), body.index('YWMI->'))
        self.assertIn('(query != 3 && query != 5)', impl)
        self.assertIn('(query != 4 && query != 6)', impl)

    def test_feature_refresh_does_not_repeat_power_getters_for_reset(self):
        body = source('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp').split(
            'void IdeaVPC::updateFeatureStatus()', 1)[1].split('\nvoid ', 1)[0]
        self.assertEqual(body.count('getPowerLimit('), 1)  # loop executes at most twice
        self.assertIn('powerAccess && wmig->getPowerLimit', body)
        self.assertIn('powerSupported[0] && powerSupported[1]', body)

    def test_wmi_isolation_covers_alternative_personalities(self):
        for path in ('ReYogaSMC/ReYogaWMI.cpp', 'ReYogaSMC/ReYogaVPC/DYVPC.cpp'):
            text = source(path)
            self.assertIn('PE_parse_boot_argn("-reynowmi"', text)
            self.assertLess(text.index('"-reynowmi"'), text.index('YWMI'))
        idea = source('ReYogaSMC/ReYogaVPC/IdeaVPC.hpp')
        self.assertIn('vendorWMISupport = !safeMode && !PE_parse_boot_argn("-reynowmi"', idea)

    def test_bridge_isolation_precedes_firmware_identity_read(self):
        self.assertIn('legionBridge = !bridgeDisabled && ec->evaluateInteger("RYID"',
                      source('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp'))

    def test_trace_surrounds_wmi_calls_including_success(self):
        text = source('ReYogaSMC/WMI.cpp')
        for method in ('evaluateMethod', 'queryBlock', 'executeMethod'):
            body = text.split(f'WMI::{method}(', 1)[1].split('\n}', 1)[0]
            before, after = body.split('mDevice->evaluateObject(', 1)
            self.assertIn('Firmware begin:', before)
            self.assertIn('Firmware end:', after)


if __name__ == '__main__':
    unittest.main()
