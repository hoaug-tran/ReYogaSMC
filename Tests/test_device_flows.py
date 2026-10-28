"""Run connected production app flows against sanitized registry snapshots; no hardware access."""
import json
import ctypes.util
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    from .source_tools import function
except ImportError:
    from source_tools import function

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc') and sys.platform in ('darwin', 'linux'), 'Swift compiler on macOS or Linux required')
class DeviceFlowTests(unittest.TestCase):
    def test_registry_controls_readback_restore_and_connection_lifecycle(self):
        manager = (ROOT / 'ReYogaSMCApp/Hardware/HardwareManager.swift').read_text(encoding='utf-8')
        signatures = (
            'private func publish<', 'private func accept(', 'private func acceptHardwareIdentity(',
            'private func acceptFanAndThermalSnapshot(', 'private func acceptControlReadback(',
            'private func acceptTelemetryStatus(', 'private func publishThinkFans(', 'private func acceptThinkFanSnapshot(',
            'private func loadHardwareSettings(', 'private func saveHardwareSetting(', 'private func restoreNextControl(',
            'private func restoreSavedControlsIfNeeded(', 'private func dequeueControl(', 'private func apply(',
            'public func setKeyboardBacklight(', 'public func setPowerProfile(', 'public func setChargeThreshold(',
            'public func setAlwaysOnUSBState(', 'public func selectBattery(',
            'public func setPowerLimit(', 'public func setFanMinimum(',
            'public func setDetailedLogging(',
        )
        methods = '\n'.join(function(manager, signature) for signature in signatures)
        # Replace only persistence and IOKit boundaries, not the rules being exercised.
        methods = methods.replace('UserDefaults.standard', 'Fixture.defaults').replace(' as CFString', '')
        declarations = []
        for line in manager.splitlines():
            match = re.match(r'    @Published.*?\bvar (\w+)(.*)', line)
            if match and match[1] not in ('liveBattery', 'batteryDetails', 'driverState'):
                declarations.append('    var ' + match[1] + match[2].replace('UserDefaults.standard', 'Fixture.defaults'))
        declarations.append(function(manager, 'private struct QueuedControl'))
        identity = (ROOT / 'ReYogaSMCApp/Hardware/Profiles/LaptopIdentity.swift').read_text(encoding='utf-8')
        # The resolver/catalog loader is production code; live IORegistry discovery is a separate native gate.
        identity = identity[:identity.index('    static func text(')].replace('import IOKit', '') + '\n}\n'
        modules = [
            'Shared/SupportError.swift', 'Hardware/HardwareFeedback.swift',
            'Hardware/Controls/HardwareFeatureStatus.swift', 'Hardware/Controls/HardwareSnapshot.swift',
            'Hardware/Controls/HardwareCapabilities.swift', 'Hardware/Controls/SavedHardwareSettings.swift',
            'Hardware/Controls/PowerLimitInput.swift', 'Hardware/Profiles/HardwareProfiles.swift',
            'Hardware/Lighting/SavedRGBSettings.swift', 'Hardware/Fans/ThinkFanHelper.swift',
            'Hardware/Driver/DriverControlTransport.swift',
        ]
        sources = [identity]
        for path in modules:
            source = (ROOT / 'ReYogaSMCApp' / path).read_text(encoding='utf-8')
            source = source.replace('import IOKit', '').replace(' as CFString', '')
            if sys.platform != 'darwin':
                source = source.replace('import CryptoKit', '').replace('import Combine', '')
            sources.append(source)
        fixture = (ROOT / 'Tests/device_flows.swift').read_text(encoding='utf-8')
        fixture = fixture.replace('// PRODUCTION_DECLARATIONS', '\n'.join(declarations))
        fixture = fixture.replace('// PRODUCTION_METHODS', methods)
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / 'main.swift'
            main.write_text('\n'.join(sources) + '\n' + fixture, encoding='utf-8')
            executable = main.with_suffix('.exe')
            flags = []
            if sys.platform.startswith('linux'):
                crypto = ctypes.util.find_library('crypto')
                self.assertIsNotNone(crypto, 'OpenSSL is required for the Linux CryptoKit boundary')
                header = pathlib.Path(directory) / 'crypto.h'
                header.write_text('#include <stddef.h>\n'
                                  'unsigned char *systemSHA256(const unsigned char *, size_t, unsigned char *) __asm__("SHA256");\n', encoding='utf-8')
                flags = ['-import-objc-header', str(header), '-Xlinker', '-l:' + crypto]
            build = subprocess.run(['swiftc', '-swift-version', '5', *flags, str(main), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable), str(ROOT / 'Tests/Fixtures/device_flows.json')],
                                    cwd=ROOT, capture_output=True, text=True, timeout=90, env=os.environ.copy())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS connected production device flows', result.stdout)
            print(result.stdout.strip())

class DeviceFixtureTests(unittest.TestCase):
    def test_fixture_provenance_and_expected_features_are_explicit(self):
        fixture = json.loads((ROOT / 'Tests/Fixtures/device_flows.json').read_text(encoding='utf-8'))
        self.assertEqual(fixture['schemaVersion'], 1)
        identities = {case['id'] for case in fixture['cases']}
        self.assertEqual(len(identities), len(fixture['cases']))
        self.assertTrue({'thinkpad-t490', 'thinkpad-x1c7', 'thinkpad-t480s', 'thinkpad-t480', 'legion7-gkcn'} <= identities)
        for case in fixture['cases']:
            with self.subTest(device=case['id']):
                self.assertIn('expectedAvailable', case)
                self.assertIn(case['provenance']['kind'], ('public-issue-diagnostic', 'synthetic-ui-fixture'))
                for forbidden in ('SerialNumber', 'IOPlatformUUID', 'installationPath', 'batteryProviderFields'):
                    self.assertNotIn(forbidden, case['snapshot'])
