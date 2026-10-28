"""Replay production ACPI analysis callbacks across reconnect and shutdown."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class ACPILifecycleTests(unittest.TestCase):
    def test_stale_completion_cannot_clear_or_replace_new_session_state(self):
        source = (ROOT / 'ReYogaSMCApp/Hardware/ACPI/HardwareACPIAnalysis.swift').read_text(encoding='utf-8')
        source = source.replace('import IOKit', '').replace('import Combine', '')
        fixture = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
typealias io_service_t = UInt32
enum ACPIExport {
    static var callbacks: [(Result<URL, Error>) -> Void] = []
    static var verifications: [(String) -> Void] = []
    static func exportThinkPadSSDT(service: UInt32, output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        callbacks.append(completion)
    }
    static func verifyThinkPadSSDT(service: UInt32, completion: @escaping (String) -> Void) {
        verifications.append(completion)
    }
}
// PRODUCTION
let analysis = HardwareACPIAnalysis()
var displays: [URL] = []
let output = URL(fileURLWithPath: "/fixture.dsl")
analysis.generateThinkPadSSDT(service: 1, output: output) { if case .success(let url) = $0 { displays.append(url) } }
precondition(analysis.busy && ACPIExport.callbacks.count == 1)
analysis.generateThinkPadSSDT(service: 1, output: output) { if case .success(let url) = $0 { displays.append(url) } }
precondition(ACPIExport.callbacks.count == 1, "Busy analysis accepted a duplicate request")
analysis.connectionChanged()
precondition(!analysis.busy && analysis.status.isEmpty)
analysis.generateThinkPadSSDT(service: 1, output: output) { if case .success(let url) = $0 { displays.append(url) } }
let current = analysis.status
ACPIExport.callbacks[0](.success(output))
precondition(analysis.busy && analysis.status == current && displays.isEmpty)
ACPIExport.callbacks[1](.success(output))
precondition(!analysis.busy && analysis.status.hasPrefix("SSDT compiled.") && displays == [output])
analysis.verifyThinkPadSSDT(service: 1)
analysis.connectionChanged()
ACPIExport.verifications[0]("late verification")
precondition(!analysis.busy && analysis.status.isEmpty && displays == [output])
print("PASS production ACPI connection generations and stale completions")
'''.replace('// PRODUCTION', source)
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / 'main.swift'
            main.write_text(fixture, encoding='utf-8')
            executable = main.with_suffix('.exe')
            build = subprocess.run(['swiftc', '-swift-version', '5', str(main), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
