"""Execute the real Swift helper with deterministic IOKit responses."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ThinkFanTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_transient_failure_and_auto_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            source = directory / 'main.swift'
            # The helper uses no AppKit APIs; stub only the hardware/app boundary.
            helper = (ROOT / 'ReYogaSMCUtils/ThinkFanHelper.swift').read_text(encoding='utf-8')
            source.write_text(helper.replace('import AppKit', '') + '\n' +
                              (ROOT / 'Tests/think_fan.swift').read_text(encoding='utf-8'), encoding='utf-8')
            executable = directory / 'think-fan'
            build = subprocess.run(['swiftc', '-swift-version', '5', str(source), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS real ThinkFanHelper', result.stdout)

    def test_auto_recovery_is_not_disabled_with_manual_controls(self):
        view = (ROOT / 'ReYogaSMCApp/HardwareViews.swift').read_text(encoding='utf-8')
        controls = view.split('Button(loc(.fanAuto))', 1)[1].split('private struct ThinkPadBatteryControls', 1)[0]
        auto = controls.split('Button(loc(.fanFullSpeed))', 1)[0]
        self.assertIn('.disabled(helper(index)?.connect == 0 || helper(index) == nil)', auto)
        self.assertNotIn('disabled(!enabled[index])', auto)
        self.assertNotIn('}.disabled(!enabled[index])\n                    Slider', controls)
        command = controls.split('private func command(', 1)[1].split('private func refresh(', 1)[0]
        self.assertNotIn('fan.enable', command)
