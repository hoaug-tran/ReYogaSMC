"""Replay queued production hotkeys across stop, restart and owner release."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

try:
    from .source_tools import function
except ImportError:
    from source_tools import function

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class HotkeyLifecycleTests(unittest.TestCase):
    def test_queued_events_belong_to_the_active_session(self):
        production = (ROOT / 'ReYogaSMCApp/Hardware/Input/LegionHotkeys.swift').read_text(encoding='utf-8')
        methods = '\n'.join(function(production, signature) for signature in (
            'private func enqueueAction(', 'func stop('))
        source = r'''
import Foundation
import Dispatch

enum CFRunLoopMode { case commonModes; var rawValue: Int { 0 } }
typealias IOOptionBits = UInt32
let kIOHIDOptionsTypeNone = 0
func CFMachPortInvalidate(_ port: Int) {}
func CFRunLoopGetMain() -> Int { 0 }
func CFRunLoopRemoveSource(_ loop: Int, _ source: Int, _ mode: CFRunLoopMode) {}
func IOHIDManagerUnscheduleFromRunLoop(_ manager: Int, _ loop: Int, _ mode: Int) {}
func IOHIDManagerClose(_ manager: Int, _ options: UInt32) {}

final class Hotkeys {
    private var generation: UInt64 = 0
    private var tap: Int? = 1
    private var source: Int?
    private var manager: Int?
    private var physicalFnDown = false
    private var consumedKeys: Set<Int> = []
    var action: ((String) -> Void)?
    func receive(_ action: String) { enqueueAction(action) }
    func restart() { tap = 1 }
    // PRODUCTION
}

var received: [String] = []
let hotkeys = Hotkeys()
hotkeys.action = { received.append($0) }
hotkeys.receive("before-stop")
hotkeys.stop()
hotkeys.restart()
hotkeys.receive("after-restart")
var released: Hotkeys? = Hotkeys()
released?.action = { received.append($0) }
released?.receive("after-release")
released = nil
DispatchQueue.main.async {
    assert(received == ["after-restart"], "stale hotkey escaped its session")
    hotkeys.receive("while-stopped")
    hotkeys.stop()
    DispatchQueue.main.async {
        assert(received == ["after-restart"])
        print("PASS hotkey stop, restart and owner release")
        exit(0)
    }
}
dispatchMain()
'''.replace('// PRODUCTION', methods)
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            path = directory / 'main.swift'
            path.write_text(source, encoding='utf-8')
            executable = directory / 'hotkey-lifecycle'
            build = subprocess.run(['swiftc', '-swift-version', '5', str(path), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
