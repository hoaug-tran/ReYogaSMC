// Run against the real ThinkFanHelper with only IOKit and app services replaced.
typealias io_connect_t = UInt32
let kIOReturnSuccess: Int32 = 0
let kIOReturnIOError = Int32(bitPattern: 0xe00002ca)
let kRYSMCUCThinkFan = 5
let kRYSMCUCThinkFanCurve = 6
let notReady = Int32(bitPattern: 0xe00002d8)
enum ReYogaConstants {
    static let suiteName = "ReYogaFanTests-\(UUID().uuidString)"
    static let hardwareDefaults = UserDefaults(suiteName: suiteName)!
}
final class ReYogaDiagnostics {
    static let shared = ReYogaDiagnostics()
    var events: [[String: Any]] = []
    func record(_ event: String, _ details: [String: Any]) { events.append(details) }
}
func localizedMessage(_ message: String) -> String { message }

func IOConnectCallMethod(_ connection: UInt32, _ selector: UInt32,
                         _ input: UnsafePointer<UInt64>?, _ count: UInt32,
                         _ structure: UnsafeRawPointer?, _ structureSize: Int,
                         _ scalarOutput: UnsafeMutablePointer<UInt64>?, _ scalarCount: UnsafeMutablePointer<UInt32>?,
                         _ output: UnsafeMutableRawPointer?, _ size: UnsafeMutablePointer<Int>?) -> Int32 {
    precondition(connection == 1 && (selector == 5 || selector == 6) && count == 2 && input![0] <= 1)
    FanFixture.requestedFans.append(input![0])
    FanFixture.requests.append(input![1])
    FanFixture.selectors.append(selector)
    precondition(!FanFixture.responses.isEmpty, "Unexpected extra fan transaction")
    let response = FanFixture.responses.removeFirst()
    for (index, value) in response.1.enumerated() { output!.storeBytes(of: value, toByteOffset: index, as: UInt8.self) }
    size!.pointee = response.2
    return response.0
}

// shortcut: transport fixture runs suites serially; use per-connection fixtures before parallel execution.
enum FanFixture {
    static var messages: [String] = []
    static var responses: [(Int32, [UInt8], Int)] = []
    static var requests: [UInt64] = []
    static var selectors: [UInt32] = []
    static var requestedFans: [UInt64] = []

    static func reset() {
        messages.removeAll()
        responses.removeAll()
        requests.removeAll()
        selectors.removeAll()
        requestedFans.removeAll()
        ReYogaDiagnostics.shared.events.removeAll()
        ReYogaConstants.hardwareDefaults.removePersistentDomain(forName: ReYogaConstants.suiteName)
    }

    static func finish() {
        precondition(responses.isEmpty, "Suite left unused fan responses")
        reset()
    }
}

func testFanAccessAndSnapshots() {
    FanFixture.reset()
    defer { FanFixture.finish() }
    let fan = ThinkFanHelper(connection: 1, isMainFan: true, feedback: { event in
        if case .fanAccessFailed = event { FanFixture.messages.append("access failed") }
    })
    #if canImport(Combine)
    var publishedUpdates = 0
    let subscription = fan.objectWillChange.sink { publishedUpdates += 1 }
    #endif
    FanFixture.responses = [(notReady, [0, 0, 0], 3)]
    fan.setManualLevel(4)
    precondition(!fan.enable && fan.rpm == nil && FanFixture.messages.count == 1)
    FanFixture.responses = [(notReady, [0, 0, 0], 3), (0, [0x28, 0x1a, 0x84], 3)]
    fan.update()
    precondition(!fan.enable && FanFixture.messages.count == 1, "Failed polls must stay quiet")
    fan.update()
    precondition(fan.enable && fan.rpm == 6696 && fan.savedLevel == 0x84, "Polling must recover without restarting the app")
    precondition(fan.isAutomatic && !fan.isFullSpeed && fan.canRecoverAutomatic)

    FanFixture.responses = [(notReady, [0, 0, 0], 3), (0, [0x7f, 0x09, 0x84], 3)]
    fan.setManualLevel(4)
    let beforeRecovery = FanFixture.requests.count
    fan.setManualLevel(4)
    precondition(FanFixture.requests.count == beforeRecovery, "Manual writes stay blocked until recovery")
    fan.setAutomatic()
    precondition(fan.enable && fan.savedLevel == 0x84 && fan.rpm == 2431)
    precondition(FanFixture.requests.last == 0x84, "Auto must never be converted to manual level 4")
    precondition(ReYogaDiagnostics.shared.events.last?["operation"] as? String == "auto")

    FanFixture.responses = [(0, [0xff, 0xff, 0x84], 3)]
    fan.setAutomatic()
    precondition(fan.enable && fan.rpm == nil, "Unavailable tachometer must not disable control")
    FanFixture.responses = [(0, [0, 0, 0x84], 3)]
    fan.update()
    precondition(fan.enable && fan.rpm == 0, "Stopped fan is measured zero, not unavailable")

    FanFixture.responses = [(0, [0, 0, 0x84], 2), (0, [0, 0, 0xc4], 3), (0, [0x28, 0x1a, 0x84], 3)]
    fan.update()
    precondition(!fan.enable && fan.rpm == nil, "Reject short replies")
    fan.update()
    precondition(!fan.enable && fan.rpm == nil, "Reject conflicting mode bits")
    fan.setAutomatic()
    precondition(fan.enable && fan.savedLevel == 0x84)

    FanFixture.responses = [(0, [0x28, 0x1a, 0x47], 3), (0, [0x28, 0x1a, 0x47], 3)]
    fan.setFullSpeed()
    fan.setFanLevel()
    precondition(Array(FanFixture.requests.suffix(2)) == [0x47, 0x47], "Restore must preserve full-speed mode")
    precondition(fan.savedLevel == 0x47 && fan.level == 4, "Full Speed must not replace the manual level")
    precondition(fan.isFullSpeed && !fan.isAutomatic)
    FanFixture.responses = [(0, [0x28, 0x1a, 0x04], 3), (0, [0x28, 0x1a, 0x84], 3)]
    fan.setAutomatic()
    precondition(!fan.enable && fan.savedLevel == 0x47, "A successful transport cannot confirm a mismatched Auto readback")
    precondition(ReYogaDiagnostics.shared.events.last?["confirmed"] as? Bool == false)
    fan.setAutomatic()
    precondition(fan.enable && fan.savedLevel == 0x84)
    let disconnected = ThinkFanHelper(connection: 0, isMainFan: true)
    let beforeDisconnect = FanFixture.requests.count
    disconnected.update()
    disconnected.setAutomatic()
    precondition(FanFixture.requests.count == beforeDisconnect && !disconnected.enable)
    precondition(FanFixture.responses.isEmpty)
    FanFixture.responses = [(0, [0, 0, 0x07], 3), (0, [0x58, 0x1b, 0x40], 3), (0, [0x58, 0x1b, 0x84], 3)]
    fan.setManualLevel(7)
    precondition(FanFixture.requests.last == 0x07 && fan.level == 7 && !fan.isFullSpeed && !fan.isAutomatic)
    fan.setFullSpeed()
    precondition(FanFixture.requests.last == 0x47 && fan.isFullSpeed && !fan.isAutomatic, "Full Speed is a mode bit, not manual level 7")
    fan.setAutomatic()
    precondition(FanFixture.requests.last == 0x84 && fan.level == 7 && fan.isAutomatic && !fan.isFullSpeed)

    let synchronized = ThinkFanSnapshot(["SensorSampleTimeMS": 100_000,
        "Fan1": ["RPM": 7000, "Control": 0x47], "Fan2": ["RPM": 0, "Control": 0x84]])!
    precondition(synchronized.isCurrent(at: 100.5, after: 100))
    precondition(!synchronized.isCurrent(at: 104, after: 0), "Stale readings cannot be presented as live")
    precondition(!synchronized.isCurrent(at: 100.5, after: 100.2), "A pre-command poll cannot replace newer readback")
    precondition(!synchronized.isCurrent(at: 99, after: 0), "Future samples must be rejected")
    fan.acceptSnapshot(synchronized.main)
    precondition(fan.enable && fan.rpm == 7000 && fan.isFullSpeed && fan.level == 7)
    fan.acceptSnapshot(synchronized.secondary)
    precondition(fan.enable && fan.rpm == 0 && fan.isAutomatic && fan.level == 7)
    fan.acceptSnapshot(ThinkFanReading(["RPM": 6696]))
    precondition(!fan.enable && fan.rpm == 6696, "Read-only RPM does not grant control permission")
    fan.acceptSnapshot(ThinkFanReading(["RPM": 0xffff, "Control": 0x84]))
    precondition(fan.enable && fan.rpm == nil, "A missing tachometer does not disable a valid control mode")
    for control in [-1, 8, 0x38, 0xc4, 256] {
        fan.acceptSnapshot(ThinkFanReading(["RPM": 7000, "Control": control]))
        precondition(!fan.enable, "Invalid control state was accepted")
    }
    precondition(ThinkFanReading(["RPM": true, "Control": true]).rpm == nil)
    precondition(ThinkFanReading(["RPM": true, "Control": true]).control == nil)
    precondition(ThinkFanReading(["RPM": 7000.5, "Control": 4.5]).rpm == nil)
    precondition(ThinkFanReading(["RPM": 7000.5, "Control": 4.5]).control == nil)
    precondition(ThinkFanSnapshot(["SensorSampleTimeMS": Double.nan]) == nil)
    precondition(ThinkFanSnapshot(["SensorSampleTimeMS": true]) == nil)
    fan.acceptSnapshot(ThinkFanReading(nil))
    precondition(!fan.enable && fan.rpm == nil && fan.canRecoverAutomatic)
    precondition(FanFixture.responses.isEmpty)
    #if canImport(Combine)
    withExtendedLifetime(subscription) {}
    precondition(publishedUpdates > 0, "Fan UI must observe helper status changes")
    #endif
    var storedModes: [UInt8] = []
    let persistent = ThinkFanHelper(connection: 1, isMainFan: true, saveStartupMode: { storedModes.append($0) })
    FanFixture.responses = [(notReady, [0, 0, 0], 3)]
    persistent.setFullSpeed()
    precondition(storedModes.isEmpty, "Failed writes must not change the startup preference")
    FanFixture.responses = [(0, [0, 0, 0x84], 3), (0, [0, 0, 5], 3), (0, [0, 0, 0x84], 3)]
    persistent.update()
    persistent.setManualLevel(5)
    persistent.update()
    precondition(storedModes == [5] && persistent.persistedLevel == 5 && persistent.isAutomatic,
                 "Telemetry and firmware Auto recovery must not overwrite confirmed startup intent")
    FanFixture.responses = [(0, [0, 0, 0x47], 3), (0, [0, 0, 0x84], 3)]
    persistent.setFullSpeed()
    persistent.setAutomatic()
    precondition(storedModes == [5, 0x47, 0x84], "Confirmed modes must persist before app exit")
    precondition(FanFixture.responses.isEmpty)
    print("PASS real ThinkFanHelper: transient failure, polling recovery, Auto, missing RPM, invalid replies, restore")
}

testFanAccessAndSnapshots()
