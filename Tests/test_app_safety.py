"""Source wiring regressions; macOS/hardware behavior requires native validation."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
def read(path): return (ROOT / path).read_text(encoding='utf-8')
class AppSafetyTests(unittest.TestCase):
    def test_every_provider_connects_dashboard(self):
        body=read('ReYogaSMCNC/AppDelegate.swift').split('func initNotification(',1)[1].split('func flagsCallBack',1)[0]
        self.assertLess(body.index('HardwareManager.shared.service = conf.service'),body.index('switch IOClass'))
    def test_siri_uses_workspace_not_ui_scripting(self):
        body=read('ReYogaSMCNC/NotificationHandler.swift')
        self.assertTrue('scriptHelper(siriAS' not in body, 'Siri still executes UI script')
        self.assertTrue('com.apple.Siri' in body, 'Siri Workspace launch missing')
    def test_fan_access_does_not_depend_on_menu_title(self):
        self.assertTrue('menu.items[2]' not in read('ReYogaSMCUtils/ThinkFanHelper.swift'))
    def test_audio_checks_settable_result(self):
        self.assertTrue('error != noErr || !settable.boolValue' in read('ReYogaSMCUtils/AudioHelper.swift'))
    def test_airplane_reads_power_not_discoverability(self):
        body=read('ReYogaSMCUtils/RFHelper.swift').split('func airplaneModeHelper',1)[1]
        self.assertTrue('IOBluetoothPreferenceGetDiscoverableState()' not in body)
    def test_reconnect_clears_pending_controls(self):
        body=read('ReYogaSMCNC/HardwareManager.swift').split('public var service:',1)[1].split('private var timer',1)[0]
        for value in ('queuedControls.removeAll()', 'pendingFanChecks.removeAll()', 'lastSampleSequence = -1'):
            self.assertTrue(value in body, value)
    def test_fan_index_is_checked_before_label_access(self):
        body=read('ReYogaSMCNC/HardwareManager.swift').split('public func setFanMinimum(',1)[1].split('public func resetPowerLimits',1)[0]
        self.assertLess(body.index('fanLabels.indices.contains(fan)'),body.index('fanLabels[fan]'))
    def test_stale_firmware_does_not_discard_smc_cpu(self):
        self.assertTrue('if !cpuUsesSMC { publish(\\.cpuTemp, -1) }' in read('ReYogaSMCNC/HardwareManager.swift'))
    def test_microphone_fallback_preserves_unmute_volume(self):
        body = read('ReYogaSMCUtils/AudioHelper.swift').split('func micMuteHelper(_ service:', 2)[-1]
        unmute = body.split('setMicVolumeAS, muteVolume', 1)[1]
        self.assertTrue('muteVolume = current.int32Value' not in unmute)
    def test_native_telemetry_matches_exact_firmware_before_field_reads(self):
        body = read('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp').split('void IdeaVPC::initNativeProfile()', 1)[1].split('bool IdeaVPC::examineWMI', 1)[0]
        self.assertLess(body.index('strcmp(hex, profile.digest)'), body.index('nativeProfile = &profile'))
        self.assertTrue('if (checksum) return;' in body)
    def test_idea_protocol_does_not_require_gamezone(self):
        body = read('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp').split('bool IdeaVPC::initVPC()', 1)[1].split('void IdeaVPC::brightnessAction', 1)[0]
        self.assertTrue('setProperty("ControlProtocolVersion", 1, 32)' in body)
    def test_polling_starts_after_provider_startup(self):
        body = read('ReYogaSMC/ReYogaVPC/IdeaVPC.cpp').split('bool IdeaVPC::start(', 1)[1].split('bool IdeaVPC::initVPC()', 1)[0]
        self.assertLess(body.index('super::start(provider)'), body.index('IOTimerEventSource::timerEventSource'))
    def test_async_results_are_bound_to_connection_generation(self):
        body = read('ReYogaSMCNC/HardwareManager.swift')
        self.assertEqual(body.count('guard generation == self.connectionGeneration, handle == self.service'), 2)
if __name__ == '__main__': unittest.main()