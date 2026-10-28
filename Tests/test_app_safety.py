"""Source wiring regressions; macOS/hardware behavior requires native validation."""
import pathlib
import unittest
try:
    from .source_tools import app_sources, kernel_sources, function
except ImportError:
    from source_tools import app_sources, kernel_sources, function
ROOT = pathlib.Path(__file__).resolve().parents[1]
def read(path):
    owner = pathlib.Path(path).stem
    if owner in ('IdeaVPC', 'ThinkVPC', 'ReYogaVPC', 'IdeaWMI') and path.endswith('.cpp'):
        return kernel_sources(owner)
    if path in ('ReYogaSMCApp/Hardware/HardwareManager.swift', 'ReYogaSMCApp/Application/AppDelegate.swift'):
        return app_sources()
    return (ROOT / path).read_text(encoding='utf-8')
class AppSafetyTests(unittest.TestCase):
    def test_thinkpad_refresh_is_throttled_and_bridge_diagnostics_are_scoped(self):
        body = read('ReYogaSMCApp/Hardware/HardwareManager.swift')
        refresh = body.split('let refreshFirmware =', 1)[1].split('hardwareQueue.async', 1)[0]
        self.assertIn('Date().timeIntervalSince(lastFirmwareRefresh) >= 2', refresh)
        self.assertNotIn('full || providerClass == "ThinkVPC"', refresh)
        scope = body.split('if providerClass == "IdeaVPC" {', 1)[1].split('let stateControls', 1)[0]
        self.assertIn('HardwareSnapshot.manualFanFeature', scope)

    def test_hp_bios_response_checks_header_and_requested_payload(self):
        body = read('ReYogaSMC/Platform/DYVPC.cpp').split('bool DYVPC::WMIQuery(', 1)[1]
        guard = body.index('output->getLength() < sizeof(bios_return)')
        self.assertLess(guard, body.index('biosRet->return_code'))
        self.assertIn('output->getLength() - sizeof(bios_return) < outsize', body)

    def test_every_provider_connects_dashboard(self):
        body = function(app_sources(), 'private func initNotification(')
        self.assertLess(body.index('manager.service = context.service'), body.index('switch provider'))
    def test_siri_uses_workspace_not_ui_scripting(self):
        body=read('ReYogaSMCApp/Hardware/Driver/DriverNotifications.swift') + read('ReYogaSMCApp/Events/DriverEventActions.swift')
        self.assertTrue('scriptHelper(siriAS' not in body, 'Siri still executes UI script')
        self.assertTrue('com.apple.Siri' in body, 'Siri Workspace launch missing')
    def test_fan_access_does_not_depend_on_menu_title(self):
        self.assertTrue('menu.items[2]' not in read('ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift'))
    def test_audio_checks_settable_result(self):
        self.assertTrue('error != noErr || !settable.boolValue' in read('ReYogaSMCApp/System/AudioHelper.swift'))
    def test_airplane_reads_power_not_discoverability(self):
        body=read('ReYogaSMCApp/System/WirelessActions.swift').split('func airplaneModeHelper',1)[1]
        self.assertTrue('IOBluetoothPreferenceGetDiscoverableState()' not in body)
    def test_reconnect_clears_pending_controls(self):
        body=read('ReYogaSMCApp/Hardware/HardwareManager.swift').split('var service:',1)[1].split('private var timer',1)[0]
        for value in ('queuedControls.removeAll()', 'pendingFanChecks.removeAll()', 'lastSampleSequence = -1'):
            self.assertTrue(value in body, value)
    def test_fan_index_is_checked_before_label_access(self):
        body=read('ReYogaSMCApp/Hardware/HardwareManager.swift').split('public func setFanMinimum(',1)[1].split('public func resetPowerLimits',1)[0]
        self.assertLess(body.index('fanLabels.indices.contains(fan)'),body.index('fanLabels[fan]'))
    def test_stale_firmware_does_not_discard_smc_cpu(self):
        self.assertTrue('if !cpuUsesSMC { publish(\\.cpuTemp, -1) }' in read('ReYogaSMCApp/Hardware/HardwareManager.swift'))
    def test_microphone_fallback_preserves_unmute_volume(self):
        body = read('ReYogaSMCApp/System/AudioHelper.swift').split('func micMuteHelper(_ service:', 2)[-1]
        unmute = body.split('setMicVolumeAS, muteVolume', 1)[1]
        self.assertTrue('muteVolume = current.int32Value' not in unmute)
    def test_native_telemetry_matches_exact_firmware_before_field_reads(self):
        body = function(kernel_sources('IdeaVPC'), 'void IdeaVPC::initNativeProfile(')
        self.assertLess(body.index('ReYogaFirmware::select'), body.index('nativeProfile = candidate'))
        self.assertTrue('SHA256_Final' in body)
        self.assertTrue('if (checksum)' in body)
        self.assertTrue('if (!candidate)' in body)
    def test_idea_protocol_does_not_require_gamezone(self):
        body = function(kernel_sources('IdeaVPC'), 'bool IdeaVPC::initVPC(')
        self.assertTrue('setProperty("ControlProtocolVersion", 1, 32)' in body)
    def test_polling_starts_after_provider_startup(self):
        body = function(kernel_sources('IdeaVPC'), 'bool IdeaVPC::start(')
        self.assertLess(body.index('super::start(provider)'), body.index('IOTimerEventSource::timerEventSource'))
    def test_async_results_are_bound_to_connection_generation(self):
        body = read('ReYogaSMCApp/Hardware/HardwareManager.swift')
        for signature in ('private func refreshSnapshot(', 'private func apply('):
            completion = function(body, signature).split('DispatchQueue.main.async {', 1)[1]
            guard = completion.split('else { return }', 1)[0]
            for condition in ('!self.isShuttingDown', 'generation == self.connectionGeneration', 'handle == self.service'):
                self.assertIn(condition, guard)

    def test_export_bridge_bounds_size_and_offloads_to_utility_queue(self):
        body = app_sources()
        export = function(body, 'static func exportBridge(')
        self.assertIn('DispatchQueue.global(qos: .utility).async', export)
        self.assertLess(export.index('DispatchQueue.global(qos: .utility).async'), export.index('readDSDTSource(input)'))
        self.assertLess(export.index('DispatchQueue.global(qos: .utility).async'), export.index('matchingDSDT('))

    def test_restore_next_control_uses_rgb_lighting_ownership_predicate(self):
        body = read('ReYogaSMCApp/Hardware/HardwareManager.swift')
        restore = function(body, 'private func restoreNextControl(')
        self.assertIn('lighting.ownsLighting', restore)
        self.assertIn('HardwareProfiles.lightingOwnedByRGB', function(body, 'func ownsLighting('))
        self.assertNotIn('key == "YLogoStatus" || key == "PortLighting"', restore)

if __name__ == '__main__': unittest.main()
