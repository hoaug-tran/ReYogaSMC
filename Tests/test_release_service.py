"""Compile the production release policy without networking or app UI."""
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
class ReleaseServiceTests(unittest.TestCase):
    def test_failed_attempt_retry_and_stop_cancel_late_publication(self):
        source = (ROOT / 'ReYogaSMCApp/Preferences/ReYogaPreferences.swift').read_text()
        policy = (ROOT / 'ReYogaSMCApp/Preferences/Services/ReleaseService.swift').read_text()
        methods = '\n'.join(function(source, signature) for signature in
            ('func stop(', 'private func checkIfDue(', 'func checkForUpdates('))
        fixture = r'''
import Foundation
import Dispatch
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
ENUM
final class FakeTask {var cancelled=false;func cancel(){cancelled=true}}
final class ReYogaDiagnostics {static let shared=ReYogaDiagnostics();func record(_ e:String,_ d:[String:Any]){}}
var hud=0
func localizedMessage(_ key:String,_ args:CVarArg...)->String{String(format:key,arguments:args)}
func showOSDRaw(_ message:String,duration:UInt32){hud += 1}
enum ReleaseService {
    static var completions:[(ReleaseCheckResult)->Void]=[]
    static func request(repository:String?)->URLRequest?{URLRequest(url:URL(string:"https://fixture.invalid")!)}
    static func check(request:URLRequest,currentVersion:String,completion:@escaping(ReleaseCheckResult)->Void)->FakeTask{
        completions.append(completion);return FakeTask()
    }
}
final class ReYogaPreferences {
    let defaults:UserDefaults
    var timer:Timer?,updateTask:FakeTask?,releaseURL:URL?
    var updateGeneration:UInt64=0
    var stopped=false,checking=false,automaticUpdates=true
    var updateStatus=""
    init(_ defaults:UserDefaults){self.defaults=defaults}
    func due(){checkIfDue()}
    // METHODS
}
func drainMain(){var drained=false;DispatchQueue.main.async{drained=true};let deadline=Date().addingTimeInterval(2)
while !drained && Date()<deadline{_ = RunLoop.current.run(mode:.default,before:deadline)};precondition(drained)}
do {
    let name="ReYogaUpdateTest-"+UUID().uuidString
    let defaults=UserDefaults(suiteName:name)!
    defer{defaults.removePersistentDomain(forName:name)}
    let prefs=ReYogaPreferences(defaults)
    prefs.due();precondition(ReleaseService.completions.count==1)
    ReleaseService.completions[0](.httpFailure(503));drainMain()
    precondition(defaults.object(forKey:"LastUpdateCheck")==nil,"Failed attempt suppressed retry for a day")
    prefs.due();precondition(ReleaseService.completions.count==1,"Failure retry ignored cooldown")
    defaults.set(Date.distantPast,forKey:"LastUpdateAttempt")
    prefs.due();precondition(ReleaseService.completions.count==2)
    let task=prefs.updateTask!;let oldStatus=prefs.updateStatus
    prefs.stop();precondition(task.cancelled)
    ReleaseService.completions[1](.available(tag:"v9.9.9",url:URL(string:"https://github.com/fixture/release")!));drainMain()
    precondition(prefs.releaseURL==nil && prefs.updateStatus==oldStatus && hud==0,"Stopped request published or showed HUD")
}
print("PASS production update retry and cancellation")
'''.replace('ENUM', function(policy, 'enum ReleaseCheckResult')).replace('// METHODS', methods)
        with tempfile.TemporaryDirectory() as directory:
            source_path = pathlib.Path(directory) / 'main.swift'
            source_path.write_text(fixture)
            executable = source_path.with_suffix('.exe')
            build = subprocess.run(['swiftc', '-swift-version', '5', str(source_path), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_request_and_response_boundaries(self):
        fixture = r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

for repository: String? in [nil, "", "invalid", "-1"] {
    assert(ReleaseService.request(repository: repository) == nil)
}
let request = ReleaseService.request(repository: "123")!
assert(request.url!.absoluteString == "https://api.github.com/repositories/123/releases/latest")
assert(request.timeoutInterval == 20)
assert(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")

func result(status: Int = 200, tag: String = "v2.2.0",
            link: String = "https://github.com/example/project/releases/tag/v2.2.0",
            error: Error? = nil) -> ReleaseCheckResult {
    let data = try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": link])
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return ReleaseService.parse(data: data, response: response, error: error, currentVersion: "2.1.1")
}
if case .available(let tag, _) = result() { assert(tag == "v2.2.0") } else { fatalError("new release lost") }
for tag in ["v2.1.1", "2.0.9"] {
    guard case .upToDate = result(tag: tag) else { fatalError("older release offered") }
}
guard case .available = result(tag: "2.10.0") else { fatalError("numeric ordering lost") }
guard case .unversioned = result(tag: "v2.2.0-beta") else { fatalError("prerelease policy changed") }
guard case .noPublicRelease = result(status: 404) else { fatalError("404 policy lost") }
guard case .httpFailure(503) = result(status: 503) else { fatalError("HTTP error hidden") }
guard case .transportFailure = result(error: URLError(.timedOut)) else { fatalError("transport failure hidden") }
for link in ["http://github.com/example/project/releases/tag/v3", "https://github.com.evil.test/a/b/releases/tag/v3",
             "https://github.com/example/project/issues/1", "not a URL"] {
    guard case .invalidResponse = result(link: link) else { fatalError("untrusted release URL accepted") }
}
let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
for data: Data? in [nil, Data("not JSON".utf8), Data("{}".utf8)] {
    guard case .invalidResponse = ReleaseService.parse(data: data, response: response, error: nil,
        currentVersion: "2.1.1") else { fatalError("invalid response accepted") }
}
print("PASS release request, versions, failures and URL boundaries")
'''
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            path = directory / 'main.swift'
            path.write_text(fixture, encoding='utf-8')
            executable = directory / 'release-policy'
            build = subprocess.run(['swiftc', '-swift-version', '5',
                                    str(ROOT / 'ReYogaSMCApp/Preferences/Services/ReleaseService.swift'),
                                    str(path), '-o', str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
