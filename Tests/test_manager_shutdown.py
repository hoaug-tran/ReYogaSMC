"""Run production shutdown against a queued sensor job and late main completion."""
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
class ManagerShutdownTests(unittest.TestCase):
    def test_shutdown_invalidates_late_completion_and_new_work(self):
        source = (ROOT / 'ReYogaSMCApp/Hardware/HardwareManager.swift').read_text()
        methods = '\n'.join(function(source, signature) for signature in (
            'public func shutdown(', 'private func refreshIndependentSensors(', 'public func stopMonitoring('))
        fixture = r'''
import Foundation
import Dispatch
let kIOReturnSuccess: Int32 = 0
var writes=0
func IORegistryEntrySetCFProperty(_ service: Int, _ key: CFString, _ value: NSDictionary) -> Int32 { writes += 1; return 0 }
final class ReYogaDiagnostics { static let shared=ReYogaDiagnostics();func record(_ event:String,_ value:[String:Any]){} }
enum StopReason {case appShutdown,monitoringStopped}
final class Fan {func stopCurve(reason:StopReason){} }
final class Hotkeys {func stop(){} }
final class Lighting {func beginShutdown(){};func shutdownOnHardwareQueue(){} }
final class Analysis {func connectionChanged(){} }
struct Feature {let available:Bool}
struct LiveBatterySnapshot:Equatable {let summary="battery";static func read()->LiveBatterySnapshot?{LiveBatterySnapshot()} }
struct Reading {let celsius=42.0;let source="fixture"}
final class Sensors {
    var reads=0,closes=0,reopens=0;var closed=false
    var cpuReason="fixture",reason="fixture"
    func cpuTemperature()->Reading?{if closed{reopens += 1};reads += 1;return Reading()}
    func gpuTemperature()->Reading?{if closed{reopens += 1};reads += 1;return Reading()}
    func close(){closed=true;closes += 1}
}
final class HardwareManager {
    var isShuttingDown=false,refreshInFlight=false,isApplying=true
    var applyingControl:String?="fixture"
    var connectionGeneration:UInt64=0
    var queuedControls=[1],restoringControls=[1],pendingFanChecks=[1]
    let acpiAnalysis=Analysis(),hotkeyManager=Hotkeys(),lighting=Lighting(),smcTemperatures=Sensors()
    var fanHelper:Fan?=Fan(),fanHelper2:Fan?=Fan()
    let hardwareQueue=DispatchQueue(label:"shutdown-test")
    var timer:Timer?
    var service=0,cpuPowerModified=false,manualFanMode=false
    var featureStatus:[String:Feature]=[:]
    var liveBattery:LiveBatterySnapshot?,batterySummary=""
    var cpuTemp = -1.0,gpuTemp = -1.0,cpuTemperatureSource="",gpuTemperatureSource="",cpuTemperatureReason="",gpuTemperatureReason=""
    private func publish<T:Equatable>(_ path:ReferenceWritableKeyPath<HardwareManager,T>,_ value:T){self[keyPath:path]=value}
    func queueRead(){refreshIndependentSensors()}
    // METHODS
}
func drainMain(){
    var drained=false;DispatchQueue.main.async{drained=true}
    let deadline=Date().addingTimeInterval(2)
    while !drained && Date()<deadline{_ = RunLoop.current.run(mode:.default,before:deadline)}
    precondition(drained)
}
let manager=HardwareManager()
manager.queueRead()
manager.shutdown()
let reads=manager.smcTemperatures.reads
drainMain()
precondition(manager.cpuTemp == -1 && manager.liveBattery == nil,"Late completion published after shutdown")
manager.queueRead();manager.hardwareQueue.sync{};drainMain()
precondition(manager.smcTemperatures.reads == reads && manager.smcTemperatures.reopens == 0)
manager.shutdown();precondition(manager.smcTemperatures.closes == 1)
precondition(manager.queuedControls.isEmpty && manager.restoringControls.isEmpty && manager.pendingFanChecks.isEmpty)
precondition(writes == 0)
print("PASS production manager terminal shutdown")
'''.replace('// METHODS', methods).replace('import Dispatch', 'import Dispatch\nimport CoreFoundation')
        # Swift Foundation on Linux does not bridge String to CFString as Darwin does.
        if __import__('sys').platform != 'darwin':
            fixture = fixture.replace('as CFString', 'as String').replace('_ key: CFString', '_ key: String')
        with tempfile.TemporaryDirectory() as directory:
            swift = pathlib.Path(directory) / 'main.swift'
            swift.write_text(fixture)
            executable = swift.with_suffix('.exe')
            build = subprocess.run(['swiftc', '-swift-version', '5', str(swift), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
