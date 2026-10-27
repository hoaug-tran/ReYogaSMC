// Execute the manager's actual fan publication and command methods without AppKit or IOKit.
final class FanTestApplication { var delegate: Any? }
let NSApp = FanTestApplication()
final class AppDelegate {
    var fanHelper: ThinkFanHelper?
    var fanHelper2: ThinkFanHelper?
}
final class HardwareManager {
    var fan1RPM = -1
    var fan2RPM = -1
    var service = 1
    enum DriverState { case ready, missing }
    var driverState: DriverState = .ready
    private var lastThinkFanSampleTime: TimeInterval = 0
    private var lastThinkFanCommandTime: TimeInterval = 0
    var refreshes = 0
    func refreshMetrics() { refreshes += 1 }
    private func publish<Value: Equatable>(_ path: ReferenceWritableKeyPath<HardwareManager, Value>, _ value: Value) {
        self[keyPath: path] = value
    }
    // MANAGER_IMPLEMENTATION

    func acceptTestSnapshot(_ sample: [String: Any]) { acceptThinkFanSnapshot(sample) }
}

let owner = AppDelegate()
owner.fanHelper = fan
NSApp.delegate = owner
let manager = HardwareManager()
let poll: [String: Any] = ["SensorSampleTimeMS": ProcessInfo.processInfo.systemUptime * 1000,
    "Fan1": ["RPM": 7000, "Control": 0x47], "Fan2": ["RPM": 0, "Control": 0x84]]
let beforeSharedSample = requests.count
manager.acceptTestSnapshot(poll)
precondition(manager.fan1RPM == 7000 && manager.fan2RPM == 0 && fan.rpm == 7000 && fan.isFullSpeed)
precondition(requests.count == beforeSharedSample, "Publishing shared telemetry must not perform a second hardware read")

responses = [(0, [0x7f, 0x09, 0x84], 3)]
manager.performThinkFanCommand(fan) { fan.setAutomatic() }
precondition(manager.fan1RPM == 2431 && fan.rpm == 2431 && fan.isAutomatic && manager.refreshes == 1)
manager.acceptTestSnapshot(poll)
precondition(manager.fan1RPM == 2431 && fan.isAutomatic, "An older poll replaced newer command readback")
manager.acceptTestSnapshot(["SensorSampleTimeMS": 0, "Fan1": ["RPM": 3500, "Control": 7]])
precondition(manager.fan1RPM == 2431 && fan.isAutomatic, "An old snapshot cleared a current command result")

manager.acceptTestSnapshot(["SensorSampleTimeMS": ProcessInfo.processInfo.systemUptime * 1000,
    "Fan1": ["RPM": 3500, "Control": 7]])
precondition(manager.fan1RPM == 3500 && fan.rpm == 3500 && !fan.isAutomatic && !fan.isFullSpeed && fan.level == 7)
manager.acceptTestSnapshot(["SensorSampleTimeMS": Double.nan])
precondition(manager.fan1RPM == -1 && fan.rpm == nil && !fan.enable && fan.canRecoverAutomatic)

let beforeDisconnectedCommand = requests.count
manager.service = 0
manager.performThinkFanCommand(fan) { fan.setAutomatic() }
precondition(requests.count == beforeDisconnectedCommand && responses.isEmpty)
print("PASS shared fan telemetry, zero RPM, mode separation, immediate readback, stale poll rejection and disconnect")
