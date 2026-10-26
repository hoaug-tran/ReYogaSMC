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

    def test_successful_firmware_trace_is_bounded(self):
        wmi = source('ReYogaSMC/WMI.cpp')
        self.assertIn('while (calls < 128)', wmi)
        self.assertIn('OSCompareAndSwap(calls, calls + 1', wmi)
        self.assertNotIn('GUID %s matched, verifying flag', wmi)
        idea = source('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp')
        self.assertIn('firmwareTrace && sampleSequence < 4', idea)
        self.assertIn('firmwareRefreshTraces < 4', idea)
        self.assertIn('sampleSequence % (detailedTelemetry ? 4 : 20)', idea)
        self.assertNotIn('0x113f sync found', source('ReYogaSMC/bmfdec.c'))

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

    def test_native_profile_uses_shared_identity_selector(self):
        text = source('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp')
        self.assertIn('ProfileMatchState', text)
        self.assertIn('ReYogaFirmware::select', text)
        self.assertIn('candidate->id', text)

    def test_bridge_identity_does_not_override_native_profile(self):
        text = source('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp')
        self.assertIn('ACPIBridgeProfile', text)
        self.assertNotIn('setProperty("HardwareProfile", identity)', text)

    def test_live_bios_hash_remains_unreviewed(self):
        header = source('ReYogaSMC/ReYogaFirmwareProfiles.hpp')
        self.assertNotIn('c803c21a14bd4063c7dd29ff3a11f3ac04c3aeb8552b89c075bbfff9899e1ed1', header)

        text = source('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp')
        for property_name in ('ProfileMatchStage', 'ProfileMatchReason', 'ProfileMatchProfilesChecked',
                              'ProfileMatchOEMMatches', 'FirmwareDSDTSHA256',
                              'FirmwareDSDTOEMTableID', 'FirmwareDSDTLength', 'FirmwareDSDTChecksum'):
            self.assertIn(property_name, text)
        self.assertIn('unsupported firmware is likely', text)

        manager = source('ReYogaSMCApp/HardwareManager.swift')
        accept = manager.split('private func accept(', 1)[1].split('\n    private func loadHardwareSettings', 1)[0]
        identity = accept.split('if let driverModelName =', 1)[1].split('let protocolVersion', 1)[0]
        self.assertIn('["exact", "identity_matched", "pci_matched"].contains(matchState)', identity)
        self.assertNotIn('"Lenovo firmware device"', identity)
        self.assertNotIn('Legion 7', identity)

    def test_parse_dytc_is_read_only_and_supports_psc_profiles(self):
        vpc = source('ReYogaSMC/ReYogaVPC.cpp')
        parse_body = vpc.split('bool ReYogaVPC::parseDYTC(', 1)[1].split('\nbool ReYogaVPC::updateDYTC(', 1)[0]
        self.assertNotIn('dytc_set_cmd', parse_body)
        self.assertNotIn('dytc_reset_cmd', parse_body)
        self.assertIn('case DYTC_FUNCTION_PSC:', parse_body)
        self.assertIn('setPropertyString(DYTCStatus, "PerfMode", "Quiet")', parse_body)
        self.assertIn('setPropertyString(DYTCStatus, "PerfMode", "Balance")', parse_body)
        cql = parse_body.split('switch (result.get.funcmode)', 1)[1].split('case DYTC_FUNCTION_CQL:', 1)[1].split('case DYTC_FUNCTION_MMC:', 1)[0]
        self.assertIn('Unavailable while lap mode masks the thermal profile', cql)
        self.assertNotIn('"PerfMode", "Performance', cql)
        fan_body = vpc.split('IOReturn ReYogaVPC::readThinkFanRPM(', 1)[1].split('\nvoid ReYogaVPC::restoreThinkFans(', 1)[0]
        self.assertIn('ReYogaControl::thinkFanRPM(sample[0], sample[1])', fan_body)
        self.assertNotIn('6000', fan_body)
        header = source('ReYogaSMC/ReYogaVPC.hpp')
        self.assertIn('BIT(DYTC_FUNCTION_MMC) | BIT(DYTC_FUNCTION_PSC)', header)
        think = source('ReYogaSMC/ReYogaVPC/ThinkVPC.cpp')
        self.assertIn('useMMC ? DYTC_FUNCTION_MMC : DYTC_FUNCTION_PSC', think)
        self.assertIn('add("CPUBoostPower", false, "Direct CPU power-limit control is not implemented or validated for this ThinkPad. Firmware-managed performance profiles may be available through DYTC.");', think)

    def test_psc_mapping_tracks_revision_and_does_not_reset(self):
        header = source('ReYogaSMC/ReYogaVPC.hpp')
        self.assertIn('DYTCRevision >= 9', header)
        self.assertIn('profile == 1 ? 1 : profile == 2 ? 3 : 4', header)
        self.assertIn('profile == 1 ? 3 : profile == 2 ? 5 : 7', header)
        setter = source('ReYogaSMC/ReYogaVPC.cpp').split('bool ReYogaVPC::setDYTC(', 1)[1].split('bool ReYogaVPC::dumpECOffset', 1)[0]
        psc = setter.split('if (funcmode == DYTC_FUNCTION_PSC)', 1)[1].split('} else {', 1)[0]
        self.assertNotIn('dytc_reset_cmd', psc)
        self.assertIn('return updateDYTC()', setter)

    def test_app_info_plist_declares_bluetooth_usage_description(self):
        plist = source('ReYogaSMCApp/Info.plist')
        self.assertIn('<key>NSBluetoothAlwaysUsageDescription</key>', plist)

    def test_standalone_ssdtless_and_hotkey_migration(self):
        kext_plist = source('ReYogaSMC/Info.plist')
        self.assertIn('<string>VPC2004</string>', kext_plist)
        vpc = source('ReYogaSMC/ReYogaVPC.cpp')
        self.assertIn('ec->evaluateInteger("HSPD", &raw)', vpc)
        control = source('ReYogaSMC/ControlValidation.hpp')
        self.assertIn('if (hasSelector && !read(0x31, original))', control)
        config = source('ReYogaSMCUtils/Configuration.swift')
        self.assertIn('eid == TP_HKEY_EV_SETTING.rawValue && resolvedAction == .settings', config)
        self.assertIn('resolvedAction = .systemsettings', config)
        self.assertIn('resetDefaultEvents', config)
        notify = source('ReYogaSMCApp/NotificationHandler.swift')
        self.assertIn('com.apple.systempreferences', notify)


if __name__ == '__main__':
    unittest.main()

