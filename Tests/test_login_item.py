"""Replay production login-item policy; SMAppService and legacy APIs are OS boundaries."""
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
class LoginItemTests(unittest.TestCase):
    def test_registration_approval_error_recovery_and_legacy(self):
        source = (ROOT / 'ReYogaSMCApp/Preferences/ReYogaPreferences.swift').read_text(encoding='utf-8')
        methods = '\n'.join(function(source, signature) for signature in ('func refreshLoginStatus(', 'func setStartAtLogin('))
        methods = methods.replace('if #available(macOS 13.0, *)', 'if Fixture.modern')
        methods = methods.replace('Bundle.main.bundleIdentifier', 'Fixture.bundleID').replace(' as CFString', '')
        fixture = r'''
import Foundation
enum Failure: LocalizedError { case denied; var errorDescription: String? { "Registration denied" } }
enum Fixture {
    static let suite = "ReYogaLoginTests-" + UUID().uuidString
    static let defaults = UserDefaults(suiteName: suite)!
    static var modern = true, denied = false, approval = false
    static var bundleID: String? = "org.fixture.ReYogaSMC"
    static var legacyCalls = 0
}
final class FakeService {
    enum Status { case enabled, requiresApproval, notRegistered }
    var status = Status.notRegistered
    func register() throws { if Fixture.denied { throw Failure.denied }; status = Fixture.approval ? .requiresApproval : .enabled }
    func unregister() throws { if Fixture.denied { throw Failure.denied }; status = .notRegistered }
}
enum SMAppService { static let mainApp = FakeService() }
func SMLoginItemSetEnabled(_ identifier: String, _ enabled: Bool) -> Bool {
    precondition(identifier == "org.fixture.ReYogaSMCHelper"); Fixture.legacyCalls += 1; return !Fixture.denied
}
func localizedMessage(_ text: String, _ args: CVarArg...) -> String { String(format: text, arguments: args) }
func showOSDRaw(_ text: String, duration: UInt32 = 1000) {}
enum SupportError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }
final class ReYogaPreferences {
    let defaults = Fixture.defaults
    var startAtLogin = false, loginStatus = ""
    // PRODUCTION
}
defer { Fixture.defaults.removePersistentDomain(forName: Fixture.suite) }
let prefs = ReYogaPreferences()
prefs.refreshLoginStatus(); precondition(!prefs.startAtLogin && prefs.loginStatus.isEmpty)
prefs.setStartAtLogin(true); precondition(prefs.startAtLogin && prefs.loginStatus.isEmpty)
prefs.setStartAtLogin(false); precondition(!prefs.startAtLogin)
Fixture.approval = true
prefs.setStartAtLogin(true); precondition(prefs.startAtLogin && prefs.loginStatus.contains("Approve"))
Fixture.approval = false
prefs.setStartAtLogin(false)
Fixture.denied = true
prefs.setStartAtLogin(true); precondition(!prefs.startAtLogin && prefs.loginStatus == "Registration denied")
Fixture.denied = false
prefs.setStartAtLogin(true); precondition(prefs.startAtLogin && prefs.loginStatus.isEmpty)
Fixture.modern = false
Fixture.denied = true
prefs.setStartAtLogin(false); precondition(prefs.startAtLogin && !prefs.loginStatus.isEmpty)
Fixture.denied = false
prefs.setStartAtLogin(false); precondition(!prefs.startAtLogin && prefs.loginStatus.isEmpty, "Successful legacy retry retained an old error")
Fixture.bundleID = nil
let calls = Fixture.legacyCalls
prefs.setStartAtLogin(true); precondition(!prefs.startAtLogin && Fixture.legacyCalls == calls && !prefs.loginStatus.isEmpty)
print("PASS production login registration/approval/denial/recovery/legacy policy")
'''.replace('// PRODUCTION', methods)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'main.swift'
            path.write_text(fixture, encoding='utf-8')
            executable = path.with_suffix('.exe')
            build = subprocess.run(['swiftc', '-swift-version', '5', str(path), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
