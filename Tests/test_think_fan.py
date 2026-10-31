"""Execute the real Swift helper with deterministic IOKit responses."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
try:
    from .source_tools import app_sources, function
except ImportError:
    from source_tools import app_sources, function

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ThinkFanTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_transient_failure_and_auto_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            source = directory / 'main.swift'
            # The helper uses no AppKit APIs; stub only the hardware/app boundary.
            helper = (ROOT / 'ReYogaSMCApp/Hardware/Fans/ThinkFanHelper.swift').read_text(encoding='utf-8')
            if sys.platform != 'darwin':
                helper = helper.replace('import Combine', '''protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
}''')
            manager = app_sources()
            methods = '\n'.join(function(manager, 'func ' + name + '(') for name in (
                'publishThinkFans', 'acceptThinkFanSnapshot', 'performThinkFanCommand'))
            synchronization = (ROOT / 'Tests/think_fan_sync.swift').read_text(encoding='utf-8').replace('// MANAGER_IMPLEMENTATION', methods)
            profile_state = manager[manager.index('        publish(\\.hasPowerProfiles,'):manager.index('        publish(\\.hasOverDrive,')]
            synchronization = synchronization.replace('// PROFILE_IMPLEMENTATION', profile_state)
            source.write_text((ROOT / 'ReYogaSMCApp/Hardware/HardwareFeedback.swift').read_text(encoding='utf-8') + '\n' + helper.replace('import AppKit', '') + '\n' +
                              (ROOT / 'Tests/think_fan.swift').read_text(encoding='utf-8') + '\n' + synchronization + '\n' +
                              (ROOT / 'Tests/think_fan_curve.swift').read_text(encoding='utf-8'), encoding='utf-8')
            executable = directory / 'think-fan'
            build = subprocess.run(['swiftc', '-swift-version', '5', str(source), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS real ThinkFanHelper', result.stdout)
            self.assertIn('PASS shared fan telemetry', result.stdout)
            self.assertIn('PASS real ThinkFan curve policy and recovery', result.stdout)
