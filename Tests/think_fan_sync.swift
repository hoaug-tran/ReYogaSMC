final class HardwareManager {
    var isShuttingDown = false
    var fanHelper: ThinkFanHelper?
    var fanHelper2: ThinkFanHelper?
    func installFanHelpers(_ main: ThinkFanHelper?, secondary: ThinkFanHelper?) {
        fanHelper = main
        fanHelper2 = secondary
    }
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

final class ProfileStateTest {
    var hasPowerProfiles = false
    var powerProfilesReady = false
    var powerProfileError = ""
    private func publish<Value: Equatable>(_ path: ReferenceWritableKeyPath<ProfileStateTest, Value>, _ value: Value) {
        self[keyPath: path] = value
    }
    func accept(_ props: NSDictionary, ready: Bool) {
        let descriptors = (props["FeatureStatus"] as? [String: [String: Any]]) ?? [:]
        func supported(_ key: String) -> Bool { ready }
        // PROFILE_IMPLEMENTATION
    }
}
func testPowerProfileState() {
    let profileState = ProfileStateTest()
    let profileSupported: [String: [String: Any]] = ["SmartFanMode": ["Available": true]]
    profileState.accept(["FeatureStatus": profileSupported, "LastControlResult":
        ["Property": "SmartFanMode", "Status": 1, "Reason": "DPTF unavailable"]], ready: false)
    precondition(profileState.hasPowerProfiles && !profileState.powerProfilesReady && profileState.powerProfileError == "DPTF unavailable",
                 "Firmware failure and missing mode must retain the profile section and error for retry")
    profileState.accept(["FeatureStatus": profileSupported, "SmartFanMode": 3], ready: true)
    precondition(profileState.hasPowerProfiles && profileState.powerProfilesReady && profileState.powerProfileError.isEmpty)
    profileState.accept([:], ready: false)
    precondition(!profileState.hasPowerProfiles && !profileState.powerProfilesReady)
}

func testFanTelemetrySynchronization() {
    FanFixture.reset()
    defer { FanFixture.finish() }
    let fan = ThinkFanHelper(connection: 1, isMainFan: true)
    let manager = HardwareManager()
    manager.installFanHelpers(fan, secondary: nil)
    let poll: [String: Any] = ["SensorSampleTimeMS": ProcessInfo.processInfo.systemUptime * 1000,
        "Fan1": ["RPM": 7000, "Control": 0x47], "Fan2": ["RPM": 0, "Control": 0x84]]
    let beforeSharedSample = FanFixture.requests.count
    manager.acceptTestSnapshot(poll)
    precondition(manager.fan1RPM == 7000 && manager.fan2RPM == 0 && fan.rpm == 7000 && fan.isFullSpeed)
    precondition(FanFixture.requests.count == beforeSharedSample, "Publishing shared telemetry must not perform a second hardware read")

    FanFixture.responses = [(0, [0x7f, 0x09, 0x84], 3)]
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

    let beforeDisconnectedCommand = FanFixture.requests.count
    manager.service = 0
    manager.performThinkFanCommand(fan) { fan.setAutomatic() }
    precondition(FanFixture.requests.count == beforeDisconnectedCommand && FanFixture.responses.isEmpty)
    print("PASS shared fan telemetry, zero RPM, mode separation, immediate readback, stale poll rejection and disconnect")
}

testPowerProfileState()
testFanTelemetrySynchronization()
