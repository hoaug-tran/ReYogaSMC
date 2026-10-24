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

    def test_wmi_methods_always_receive_an_input_argument(self):
        body = source('ReYogaSMC/WMI.cpp').split('IOReturn WMI::evaluateMethod(', 1)[1].split('\n}', 1)[0]
        self.assertIn('OSData::withCapacity(0)', body)
        self.assertIn('evaluateObject(methodName, result, params, 3)', body)
        self.assertNotIn('input ? 3 : 2', body)

    def test_optional_bmf_metadata_does_not_emit_per_item_boot_errors(self):
        parser = source('ReYogaSMC/bmfparser.cpp')
        self.assertNotIn('ReYogaBMF::%s', parser)
        wmi = source('ReYogaSMC/WMI.cpp')
        self.assertIn('WMI BMF metadata incomplete; continuing with _WDG descriptors', wmi)

    def test_app_preserves_hardware_reported_model_name(self):
        manager = source('ReYogaSMCNC/HardwareManager.swift')
        accept = manager.split('private func accept(', 1)[1].split('\n    private func loadHardwareSettings', 1)[0]
        self.assertNotIn('HardwareProfileName', accept)


if __name__ == '__main__':
    unittest.main()
