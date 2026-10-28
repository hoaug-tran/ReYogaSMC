"""Replay production RGB discovery/shutdown ordering without AppKit or hardware."""
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
class LightingLifecycleTests(unittest.TestCase):
    def test_discovery_retry_and_shutdown(self):
        source = (ROOT / 'ReYogaSMCApp/Hardware/Lighting/HardwareLightingManager.swift').read_text(encoding='utf-8')
        methods = '\n'.join(function(source, signature) for signature in (
            'func detect(', 'func beginShutdown(', 'private func publish(', 'func shutdownOnHardwareQueue('))
        fixture = r'''
import Foundation
import Dispatch

struct HardwareFeatureStatus: Equatable {
    let available: Bool
    let reason: String
    let backend: String
}
final class ReYogaDiagnostics {
    static let shared = ReYogaDiagnostics()
    func record(_ event: String, _ details: [String: Any]) {}
}
var hudMessages: [String] = []

final class FakeController {
    let queue: DispatchQueue
    var trace: [String] = []
    var status = HardwareFeatureStatus(available: true, reason: "controller ready", backend: "USB HID")
    var matchedProfileID: String? = "fixture-rgb"
    init(queue: DispatchQueue) { self.queue = queue }
    func detect() {
        dispatchPrecondition(condition: .onQueue(queue))
        trace.append("detect")
    }
    func restoreHardwareMode() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        trace.append("restore")
    }
}
final class HardwareLightingManager {
    var rgbStatus = HardwareFeatureStatus(available: false, reason: "RGB discovery pending", backend: "USB HID")
    var rgbApplying = false
    var matchedProfileID: String?
    private var isShutdown = false
    private var discoveryGeneration: UInt64 = 0
    private let hardwareQueue: DispatchQueue
    private let rgbController: FakeController
    private var rgbRestoredProfile: String? = "previous-profile"
    private var hardwareStopped = false
    var restoredSettings = 0
    private let feedback: (HardwareFeedback) -> Void = { event in
        if case let .rgbDiscovery(available, reason) = event { hudMessages.append(available ? "RGB controller ready" : reason) }
    }

    init(queue: DispatchQueue, controller: FakeController) {
        hardwareQueue = queue
        rgbController = controller
    }
    // Timer and persistence are boundaries; lifecycle methods above are production code.
    private func stopRGBEffect() {
        dispatchPrecondition(condition: .onQueue(hardwareQueue))
        rgbController.trace.append("stop")
    }
    private func restoreSavedRGB() {
        dispatchPrecondition(condition: .onQueue(.main))
        restoredSettings += 1
    }
    func enqueuePublication(_ update: @escaping () -> Void) { publish(update) }
    var restoredProfile: String? { rgbRestoredProfile }
    // LIFECYCLE_METHODS
}

// FIFO sentinel drains queued main completions without sleeping or guessing hardware timing.
func drainMainQueue() {
    var drained = false
    DispatchQueue.main.async { drained = true }
    let deadline = Date().addingTimeInterval(2)
    while !drained && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: deadline)
    }
    precondition(drained, "Main queue did not drain")
}

func testQueuedDiscoveryAfterShutdown() {
    let queue = DispatchQueue(label: "test.lighting.pending-shutdown")
    let controller = FakeController(queue: queue)
    let manager = HardwareLightingManager(queue: queue, controller: controller)
    let pending = manager.rgbStatus
    var completions = 0
    var publicationApplied = false
    manager.detect { _ in completions += 1 }
    precondition(manager.rgbApplying)
    // Main remains occupied while the serial queue enqueues discovery completion.
    queue.sync { precondition(controller.trace == ["detect"]) }
    manager.enqueuePublication { publicationApplied = true }
    manager.beginShutdown()
    precondition(!manager.rgbApplying)
    queue.sync { manager.shutdownOnHardwareQueue() }
    drainMainQueue()
    precondition(completions == 0 && manager.restoredSettings == 0, "Late discovery completion restored settings after shutdown")
    precondition(manager.matchedProfileID == nil && manager.rgbStatus == pending && !manager.rgbApplying,
                 "Late discovery completion published state after shutdown")
    precondition(!publicationApplied, "Queued publication ran after shutdown")
    precondition(queue.sync { controller.trace } == ["detect", "stop", "restore"], "Shutdown failed to stop effects before restoring hardware")
    manager.detect { _ in completions += 1 }
    manager.detect(retry: true) { _ in completions += 1 }
    queue.sync {}
    drainMainQueue()
    precondition(completions == 0 && queue.sync { controller.trace } == ["detect", "stop", "restore"],
                 "Discovery restarted after shutdown")
}

func testRetryOrderingAndLivePublication() {
    let queue = DispatchQueue(label: "test.lighting.retry")
    let controller = FakeController(queue: queue)
    let manager = HardwareLightingManager(queue: queue, controller: controller)
    var profiles: [String?] = []
    let previousHUDCount = hudMessages.count
    manager.detect(retry: true) { profiles.append($0) }
    precondition(manager.rgbApplying && manager.restoredProfile == nil, "Retry did not clear prior restore state")
    manager.detect { _ in preconditionFailure("Concurrent discovery was accepted") }
    queue.sync {
        precondition(controller.trace == ["stop", "restore", "detect"], "Retry must stop effects, restore firmware, then detect")
    }
    var livePublication = false
    manager.enqueuePublication { livePublication = true }
    drainMainQueue()
    precondition(profiles.count == 1 && profiles[0] == "fixture-rgb", "Live discovery completion lost its captured profile")
    precondition(manager.rgbStatus == controller.status && manager.matchedProfileID == "fixture-rgb" && !manager.rgbApplying,
                 "Live discovery did not publish captured controller status")
    precondition(manager.restoredSettings == 1 && livePublication, "Live discovery failed to restore saved settings or publish")
    precondition(hudMessages.count == previousHUDCount + 1 && hudMessages.last == "RGB controller ready", "Retry acknowledgement changed")
    manager.beginShutdown()
    queue.sync { manager.shutdownOnHardwareQueue() }
}

func testHardwareQueueTerminalGuard() {
    let queue = DispatchQueue(label: "test.lighting.hardware-stopped")
    let controller = FakeController(queue: queue)
    let manager = HardwareLightingManager(queue: queue, controller: controller)
    queue.sync { manager.shutdownOnHardwareQueue() }
    manager.detect(retry: true) { _ in preconditionFailure("Stopped hardware accepted discovery") }
    queue.sync { precondition(controller.trace == ["stop", "restore"], "Stopped hardware performed discovery or retry operations") }
    manager.beginShutdown()
    drainMainQueue()
}

testQueuedDiscoveryAfterShutdown()
testRetryOrderingAndLivePublication()
testHardwareQueueTerminalGuard()
print("PASS RGB lifecycle: queued completion, retry ordering, publication guards and terminal discovery")
'''
        fixture = fixture.replace('// LIFECYCLE_METHODS', methods)
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            main = folder / 'main.swift'
            main.write_text((ROOT / 'ReYogaSMCApp/Hardware/HardwareFeedback.swift').read_text(encoding='utf-8') + '\n' + fixture, encoding='utf-8')
            executable = folder / 'lighting-lifecycle.exe'
            build = subprocess.run([shutil.which('swiftc'), '-swift-version', '5', str(main), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS RGB lifecycle:', result.stdout)


if __name__ == '__main__':
    unittest.main()
