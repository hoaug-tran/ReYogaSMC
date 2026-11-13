"""Source-level safety regressions; these do not simulate firmware or prove bootability."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
try:
    from .source_tools import app_sources, kernel_sources, function, read_sources
except ImportError:
    from source_tools import app_sources, kernel_sources, function, read_sources

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(path):
    owner = pathlib.Path(path).stem
    if owner in ('IdeaVPC', 'ThinkVPC', 'ReYogaVPC', 'IdeaWMI') and path.endswith('.cpp'):
        return kernel_sources(owner)
    if path == 'ReYogaSMCApp/Hardware/HardwareManager.swift':
        return app_sources()
    return (ROOT / path).read_text(encoding='utf-8')


class BootSafetyTests(unittest.TestCase):
    def test_cpu_power_defaults_to_disabled_and_requires_opt_in(self):
        header = source('ReYogaSMC/WMI/IdeaWMI.hpp')
        impl = source('ReYogaSMC/WMI/IdeaWMI.cpp')
        self.assertRegex(header, r'bool\s+cpuPowerAccessEnabled\s*\{\s*false\s*\}')
        self.assertIn('cpuPowerAccessEnabled = PE_parse_boot_argn("-reycpupower"', impl)
        for method in ('getPowerLimit', 'setPowerLimit'):
            body = impl.split(f'bool IdeaWMIGameZone::{method}(', 1)[1]
            body = body.split('\n}', 1)[0]
            self.assertLess(body.index('!cpuPowerAccessEnabled'), body.index('YWMI->'))
        self.assertIn('(query != 3 && query != 5)', impl)
        self.assertIn('(query != 4 && query != 6)', impl)

    def test_feature_refresh_does_not_repeat_power_getters_for_reset(self):
        body = source('ReYogaSMC/Platform/IdeaVPC.cpp').split(
            'void IdeaVPC::updateFeatureStatus()', 1)[1].split('\nvoid ', 1)[0]
        self.assertEqual(body.count('getPowerLimit('), 1)  # loop executes at most twice
        self.assertIn('powerAccess && wmig->getPowerLimit', body)
        self.assertIn('powerSupported[0] && powerSupported[1]', body)

    def test_wmi_isolation_covers_alternative_personalities(self):
        for path in ('ReYogaSMC/ReYogaWMI.cpp', 'ReYogaSMC/Platform/DYVPC.cpp'):
            text = source(path)
            self.assertIn('"-reynowmi"', text)
            self.assertTrue('PE_parse_boot_argn("-reynowmi"' in text or 'hasBootArgument("-reynowmi")' in text)
            self.assertLess(text.index('"-reynowmi"'), text.index('YWMI'))
        idea = source('ReYogaSMC/Platform/IdeaVPC.hpp')
        self.assertIn('vendorWMISupport = !safeMode && !PE_parse_boot_argn("-reynowmi"', idea)

    def test_bridge_isolation_precedes_firmware_identity_read(self):
        self.assertIn('legionBridge = !bridgeDisabled && ec->evaluateInteger("RYID"',
                      source('ReYogaSMC/Platform/IdeaVPC.cpp'))

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
        idea = source('ReYogaSMC/Platform/IdeaVPC.cpp')
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
        text = source('ReYogaSMC/Platform/IdeaVPC.cpp')
        self.assertIn('ProfileMatchState', text)
        self.assertIn('ReYogaFirmware::select', text)
        self.assertIn('candidate->id', text)

    def test_bridge_identity_does_not_override_native_profile(self):
        text = source('ReYogaSMC/Platform/IdeaVPC.cpp')
        self.assertIn('ACPIBridgeProfile', text)
        self.assertNotIn('setProperty("HardwareProfile", identity)', text)

    def test_live_bios_review_is_limited_to_named_reads(self):
        header = source('ReYogaSMC/ReYogaFirmwareProfiles.hpp')
        import json
        profile = json.loads(source('HardwareProfiles/legion7-16achg6.json'))
        self.assertEqual(profile.get('bridge_kind', 'named-fields-readonly'), 'named-fields-readonly')
        self.assertEqual(profile['verified_writes'], 0)
        self.assertIn('17aa:3a58', header)
        self.assertIn('legionBridgeVersion > nativeProfile->bridgeVersion', source('ReYogaSMC/Platform/IdeaVPCIdentity.cpp'))
        template = source('HardwareProfiles/SSDT-ReYoga-readonly.template.dsl')
        for unsafe in ('OperationRegion', 'RYFS', 'RYFA', 'RYFF'):
            self.assertNotIn(unsafe, template)

        text = source('ReYogaSMC/Platform/IdeaVPC.cpp')
        for property_name in ('ProfileMatchStage', 'ProfileMatchReason', 'ProfileMatchProfilesChecked',
                              'ProfileMatchOEMMatches', 'FirmwareDSDTSHA256',
                              'FirmwareDSDTOEMTableID', 'FirmwareDSDTLength', 'FirmwareDSDTChecksum'):
            self.assertIn(property_name, text)
        self.assertIn('unsupported firmware is likely', text)

        manager = source('ReYogaSMCApp/Hardware/HardwareManager.swift')
        accept = function(manager, 'private func acceptHardwareIdentity(')
        identity = accept.split('if let driverModelName =', 1)[1].split('let protocolVersion', 1)[0]
        self.assertIn('["exact", "identity_matched", "pci_matched"].contains(matchState)', identity)
        self.assertNotIn('"Lenovo firmware device"', identity)
        self.assertNotIn('Legion 7', identity)

    def test_parse_dytc_is_read_only_and_supports_psc_profiles(self):
        vpc = source('ReYogaSMC/ReYogaVPC.cpp')
        parse_body = function(vpc, 'bool ReYogaVPC::parseDYTC(')
        self.assertNotIn('dytc_set_cmd', parse_body)
        self.assertNotIn('dytc_reset_cmd', parse_body)
        self.assertIn('case DYTC_FUNCTION_PSC:', parse_body)
        self.assertIn('ReYogaProperty::setString(DYTCStatus, "PerfMode", "Quiet")', parse_body)
        self.assertIn('ReYogaProperty::setString(DYTCStatus, "PerfMode", "Balance")', parse_body)
        cql = parse_body.split('switch (readbackFunction)', 1)[1].split('case DYTC_FUNCTION_CQL:', 1)[1].split('case DYTC_FUNCTION_MMC:', 1)[0]
        self.assertIn('Unavailable while lap mode masks the thermal profile', cql)
        self.assertNotIn('"PerfMode", "Performance', cql)
        fan_body = function(source('ReYogaSMC/Platform/ThinkVPC.cpp'), 'IOReturn ThinkVPC::readPlatformFanRPM(')
        self.assertIn('ReYogaControl::thinkFanRPM(sample[0], sample[1])', fan_body)
        self.assertNotIn('6000', fan_body)
        header = source('ReYogaSMC/ReYogaVPC.hpp')
        self.assertIn('BIT(DYTC_FUNCTION_MMC) | BIT(DYTC_FUNCTION_PSC)', header)
        think = source('ReYogaSMC/Platform/ThinkVPC.cpp')
        self.assertIn('status = setThermalProfile(target)', think)
        self.assertIn('const bool useMMC = supportsMMCThermal();', vpc)
        self.assertIn('add("CPUBoostPower", false, "Direct CPU power-limit control is not implemented or validated for this ThinkPad. Firmware-managed performance profiles may be available through DYTC.");', think)

    def test_psc_mapping_tracks_revision_and_does_not_reset(self):
        header = ' '.join(source('ReYogaSMC/ReYogaVPC.hpp').split())
        self.assertIn('DYTCRevision >= 9', header)
        self.assertIn('profile == 1 ? 1 : profile == 2 ? 3 : 4', header)
        self.assertIn('profile == 1 ? 3 : profile == 2 ? 5 : 7', header)
        setter = function(source('ReYogaSMC/ReYogaVPC.cpp'), 'bool ReYogaVPC::setDYTC(')
        self.assertNotIn('dytc_reset_cmd', setter)
        self.assertIn('funcmode == DYTC_FUNCTION_MMC && perfmode == DYTC_MODE_BALANCE', setter)
        self.assertIn('return updateDYTC()', setter)

    def test_app_info_plist_declares_bluetooth_usage_description(self):
        plist = source('ReYogaSMCApp/Info.plist')
        self.assertIn('<key>NSBluetoothAlwaysUsageDescription</key>', plist)

    def test_wake_stp_recovery_and_thinkpad_power_state_wiring(self):
        think = source('ReYogaSMC/Platform/ThinkVPC.cpp')
        power_body = function(think, 'IOReturn ThinkVPC::setPowerState(')
        wake_branch = power_body.split('} else {', 1)[1].split('return kIOPMAckImplied;', 1)[0]
        self.assertIn('restoreThermalOnWake()', wake_branch)
        self.assertIn('commandGate->runAction', wake_branch)

        vpc = source('ReYogaSMC/ReYogaVPC.cpp')
        clear_body = function(vpc, 'bool ReYogaVPC::clearSTP(')
        self.assertIn('DYTCCap & BIT(DYTC_FUNCTION_STP)', clear_body)
        self.assertIn('DYTCCommand(dytc_set_cmd, &result, DYTC_FUNCTION_STP, 0xF, false)', clear_body)

        restore_body = function(vpc, 'bool ReYogaVPC::restoreThermalOnWake(')
        self.assertIn('if (!DYTCCap)', restore_body)
        self.assertIn('if (DYTCCap & BIT(DYTC_FUNCTION_STP))', restore_body)
        self.assertIn('clearedSTP = clearSTP()', restore_body)
        self.assertIn('supportsThermalProfiles()', restore_body)
        self.assertIn('setThermalProfile(', restore_body)
        self.assertIn('setProperty("LastThermalWakeRecovery", diagnostic)', restore_body)

    def test_standalone_ssdtless_and_hotkey_migration(self):
        kext_plist = source('ReYogaSMC/Info.plist')
        self.assertIn('<string>VPC2004</string>', kext_plist)
        vpc = source('ReYogaSMC/ReYogaVPC.cpp')
        self.assertIn('ec->evaluateInteger("HSPD", &raw)', source('ReYogaSMC/Platform/ThinkVPC.cpp'))
        control = source('ReYogaSMC/ControlValidation.hpp')
        self.assertIn('if (hasSelector && !read(kThinkFanSelectorOffset, original))', control)
        config = app_sources()
        self.assertIn('eid == TP_HKEY_EV_SETTING.rawValue && resolvedAction == .settings', config)
        self.assertIn('resolvedAction = .systemsettings', config)
        self.assertIn('resetDefaultEvents', config)
        notify = source('ReYogaSMCApp/Hardware/Driver/DriverNotifications.swift') + source('ReYogaSMCApp/Events/DriverEventActions.swift')
        self.assertIn('com.apple.systempreferences', notify)

    def test_thinkpad_speaker_mute_led_gating_and_readback_masks(self):
        header = source('ReYogaSMC/Platform/ThinkVPC.hpp')
        self.assertRegex(header, r'bool\s+muteLEDSupport\s*\{\s*false\s*\}')

        controls = kernel_sources('ThinkVPC')
        init_vpc = function(controls, 'bool ThinkVPC::initVPC(')
        self.assertIn('muteLEDSupport = (vpc->validateObject(setAudioMuteLED) == kIOReturnSuccess)', init_vpc)
        self.assertIn('setProperty("MuteLEDSupport", muteLEDSupport)', init_vpc)

        update_fn = function(controls, 'bool ThinkVPC::updateMuteLEDStatus(')
        self.assertIn('vpc->validateObject(getAudioMuteLED)', update_fn)
        self.assertIn('TPACPI_AML_MUTE_ERROR_STATE_MASK', update_fn)
        self.assertIn('muteLEDstate = (raw & TPACPI_AML_MUTE_READ_MASK) ? 1 : 0', update_fn)
        self.assertIn('setProperty(muteLEDPrompt, muteLEDstate != 0)', update_fn)

        set_fn = function(controls, 'bool ThinkVPC::setMuteLEDStatus(')
        self.assertIn('if (!muteLEDSupport || !vpc)', set_fn)
        self.assertIn('TPACPI_AML_MUTE_ERROR_STATE_MASK', set_fn)
        self.assertIn('muteLEDstate = status ? 1 : 0', set_fn)
        self.assertIn('setProperty(muteLEDPrompt, status)', set_fn)

    @unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
    def test_thinkpad_speaker_mute_led_host_behavior(self):
        controls = kernel_sources('ThinkVPC')
        update_fn = function(controls, 'bool ThinkVPC::updateMuteLEDStatus(')
        set_fn = function(controls, 'bool ThinkVPC::setMuteLEDStatus(')
        harness = f'''
#include <cassert>
#include <cstdint>

using UInt32 = uint32_t;
using IOReturn = int;
constexpr IOReturn kIOReturnSuccess = 0;
constexpr IOReturn kIOReturnUnsupported = -1;
constexpr UInt32 TPACPI_AML_MUTE_READ_MASK = 0x01;
constexpr UInt32 TPACPI_AML_MUTE_ERROR_STATE_MASK = 0x80000000u;

#define AlwaysLog(...) ((void)0)
#define DebugLog(...) ((void)0)

struct VPCStub {{
    IOReturn validateGet = kIOReturnSuccess;
    IOReturn validateObject(const char *) const {{ return validateGet; }}
}};

struct ThinkVPC {{
    VPCStub stub;
    VPCStub *vpc = &stub;
    bool muteLEDSupport = false;
    int muteLEDstate = 0;
    IOReturn evalRet = kIOReturnSuccess;
    UInt32 evalResult = 0;
    UInt32 lastParam = 99;
    bool propSet = false;
    bool propBool = false;

    static constexpr const char *getAudioMuteLED = "GSMS";
    static constexpr const char *setAudioMuteLED = "SSMS";
    static constexpr const char *muteLEDPrompt = "MuteLED";
    static constexpr const char *updateFailure = "";
    static constexpr const char *updateSuccess = "";
    static constexpr const char *toggleError = "";
    static constexpr const char *toggleSuccess = "";

    IOReturn evaluateIntegerParam(const char *, UInt32 *out, UInt32 param) {{
        lastParam = param;
        if (out) *out = evalResult;
        return evalRet;
    }}
    void setProperty(const char *, bool value) {{
        propSet = true;
        propBool = value;
    }}

    bool updateMuteLEDStatus(bool logChanges);
    bool setMuteLEDStatus(bool status);
}};

{update_fn}
{set_fn}

int main() {{
    ThinkVPC dev;
    dev.muteLEDSupport = false;
    assert(!dev.setMuteLEDStatus(true));
    assert(dev.lastParam == 99);

    // Firmware returns hardware state bit 8 (0x100) for OFF, 0x101 for ON.
    dev.evalResult = 0x100;
    assert(dev.updateMuteLEDStatus(false));
    assert(dev.muteLEDstate == 0);
    assert(dev.propSet && !dev.propBool);

    dev.evalResult = 0x101;
    assert(dev.updateMuteLEDStatus(true));
    assert(dev.muteLEDstate == 1);
    assert(dev.propSet && dev.propBool);

    // Firmware error bit must be rejected without corrupting muteLEDstate.
    dev.evalResult = 0x80000001u;
    assert(!dev.updateMuteLEDStatus(false));
    assert(dev.muteLEDstate == 1);

    dev.muteLEDSupport = true;
    dev.evalResult = 0x100;
    assert(dev.setMuteLEDStatus(false));
    assert(dev.lastParam == 0 && dev.muteLEDstate == 0 && !dev.propBool);

    assert(dev.setMuteLEDStatus(true));
    assert(dev.lastParam == 1 && dev.muteLEDstate == 1 && dev.propBool);

    dev.evalResult = 0x80000000u;
    assert(!dev.setMuteLEDStatus(false));
    assert(dev.muteLEDstate == 1);
    return 0;
}}
'''
        compiler = shutil.which('g++') or shutil.which('clang++')
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            src = folder / 'mute_led_test.cpp'
            exe = folder / 'mute_led_test.exe'
            src.write_text(harness, encoding='utf-8')
            abi = ['-mno-ms-bitfields'] if sys.platform == 'win32' else []
            build = subprocess.run([compiler, *abi, '-std=c++14', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
