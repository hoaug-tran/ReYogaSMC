import Foundation
import CoreFoundation
import Dispatch
#if canImport(Combine)
import Combine
#else
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
#endif
#if !canImport(CryptoKit)
// Linux has no CryptoKit module. Use installed OpenSSL for the same SHA-256 operation.
enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { bytes in
                _ = systemSHA256(input.baseAddress?.assumingMemoryBound(to: UInt8.self), numericCast(data.count), bytes.baseAddress)
            }
        }
        return output
    }
}
#endif

typealias io_service_t = UInt32
typealias io_connect_t = UInt32
let kIOReturnSuccess: Int32 = 0
let kIOReturnIOError = Int32(bitPattern: 0xe00002ca)
let kRYSMCUCThinkFan = 5, kRYSMCUCThinkFanCurve = 6
func localizedMessage(_ key: String, _ arguments: CVarArg...) -> String { String(format: key, arguments: arguments) }
enum ReYogaConstants { static let hardwareDefaults = Fixture.defaults }
final class ReYogaDiagnostics {
    static let shared = ReYogaDiagnostics()
    var events: [(String, [String: Any])] = []
    func record(_ name: String, _ detail: [String: Any]) { events.append((name, detail)) }
}
enum Fixture {
    static let suite = "ReYogaDeviceFlows-" + UUID().uuidString
    static let defaults = UserDefaults(suiteName: suite)!
    enum Reply { case matched, failed, transportError, wrongID, pending, superseded, pendingNeverCompletes }
    static var reply: Reply = .matched
    static var snapshot: [String: Any] = [:]
    static var requests: [NSDictionary] = []
    static var references = 0, polls = 0
    static var fanRequests: [UInt64] = []
    static var booleanRequests: [(key: String, value: Bool)] = []
    static var fanStatus: Int32 = 0
    static func reset(_ properties: [String: Any]) {
        precondition(references == 0)
        snapshot = properties; requests = []; booleanRequests = []; reply = .matched; polls = 0
        defaults.removePersistentDomain(forName: suite)
    }
}
@discardableResult func IOObjectRetain(_ service: UInt32) -> Int32 { precondition(service == 1); Fixture.references += 1; return 0 }
func fixtureReleaseService(_ service: UInt32) { precondition(service == 1 && Fixture.references > 0); Fixture.references -= 1 }
func getProperties(_ service: UInt32) -> NSDictionary? { precondition(service == 1); return Fixture.snapshot as NSDictionary }
func IORegistryEntrySetCFProperty(_ service: UInt32, _ name: String, _ value: NSDictionary) -> Int32 {
    precondition(service == 1 && name == "ControlRequest")
    Fixture.requests.append(value)
    if Fixture.reply == .transportError { return -1 }
    let key = value["Property"] as! String
    let pending = Fixture.reply == .pending || Fixture.reply == .superseded || Fixture.reply == .pendingNeverCompletes
    if Fixture.reply == .matched {
        Fixture.snapshot[key] = value["Value"]
        let maskKey = ["ConservationMode": "ConservationStateMask", "RapidChargeMode": "RapidChargeStateMask"][key]
        if let maskKey = maskKey, let mask = Fixture.snapshot[maskKey] as? Int, let raw = Fixture.snapshot["BatteryModeRaw"] as? Int {
            let enabled = (value["Value"] as? NSNumber)?.intValue != 0
            Fixture.snapshot["BatteryModeRaw"] = enabled ? raw | mask : raw & ~mask
        }
    }
    Fixture.snapshot["LastControlResult"] = ["RequestID": Fixture.reply == .wrongID ? "other-request" : value["RequestID"]!,
        "Property": key, "Status": Fixture.reply == .matched || Fixture.reply == .pendingNeverCompletes ? 0 : 1,
        "Reason": "Fixture firmware result", "ReadbackPending": pending]
    return 0
}
func sendBoolean(_ key: String, _ value: Bool, _ service: UInt32) -> Int32 {
    precondition(service == 1)
    Fixture.booleanRequests.append((key, value))
    if key == "Update", let request = Fixture.requests.last {
        Fixture.polls += 1
        if Fixture.reply == .superseded {
            Fixture.snapshot["LastControlResult"] = ["RequestID": "new-request", "Status": 1]
        } else if Fixture.reply == .pending && Fixture.polls == 2 {
            Fixture.snapshot[request["Property"] as! String] = request["Value"]
        }
    }
    return 0
}
func IOConnectCallMethod(_ connection: UInt32, _ selector: UInt32,
                         _ input: UnsafePointer<UInt64>?, _ count: UInt32,
                         _ structure: UnsafeRawPointer?, _ structureSize: Int,
                         _ scalarOutput: UnsafeMutablePointer<UInt64>?, _ scalarCount: UnsafeMutablePointer<UInt32>?,
                         _ output: UnsafeMutableRawPointer?, _ size: UnsafeMutablePointer<Int>?) -> Int32 {
    precondition(connection == 1 && count == 2 && (selector == 5 || selector == 6))
    let requested = input![1]
    Fixture.fanRequests.append(requested)
    let raw = UInt8(requested == 0x100 ? 0x84 : requested)
    let bytes: [UInt8] = [0xc4, 0x09, raw]
    for (index, byte) in bytes.enumerated() { output!.storeBytes(of: byte, toByteOffset: index, as: UInt8.self) }
    size!.pointee = 3
    return Fixture.fanStatus
}

struct LightingBoundary {
    var matchedProfileID: String?
    func ownsLighting(_ key: String, settings: SavedRGBSettings?) -> Bool {
        HardwareProfiles.lightingOwnedByRGB(key: key, settings: settings, activeProfileID: matchedProfileID)
    }
}
final class HardwareManager {
    // These state declarations and every method below come from the shipping manager.
    // PRODUCTION_DECLARATIONS
    enum DriverState { case ready }
    var driverState = DriverState.ready
    var service: UInt32 = 1
    var isShuttingDown = false, connectionGeneration: UInt64 = 0
    var controlsRestoreAttempted = true, initialized = false
    var preferenceIdentity = "", restoreOrigin = "startup"
    var lastControlSnapshot: NSDictionary = [:]
    var restoringControls: [(String, SavedControlValue)] = []
    private var queuedControls: [QueuedControl] = []
    var pendingFanChecks: [Int: (target: Int, deadline: Date)] = [:]
    var lastSampleSequence = -1, lastSampleDate = Date.distantPast
    var lastThinkFanSampleTime: TimeInterval = 0, lastThinkFanCommandTime: TimeInterval = 0
    var featurePollingSupported = false, thinkFanTelemetrySupported = false
    var cpuUsesSMC = false, gpuUsesSMC = false
    var detectedIdentity = LaptopIdentity(name: "Unknown Laptop", source: "Fixture")
    let hardwareQueue = DispatchQueue(label: "device-flow-hardware")
    var lighting = LightingBoundary()
    var feedbackEvents: [HardwareFeedback] = []
    func feedback(_ event: HardwareFeedback) { feedbackEvents.append(event) }
    func refreshPermissions() {} // OS permission discovery is a separate native check.
    func receive(_ properties: [String: Any]) { accept(properties as NSDictionary) }
    func request(_ key: String, _ value: Int, boolean: Bool = false) { apply(key, value, boolean: boolean, title: key) }
    func saved() -> SavedHardwareSettings { loadHardwareSettings() }
    func drain() {
        let deadline = Date().addingTimeInterval(5)
        var idleRounds = 0
        for _ in 0..<100 {
            hardwareQueue.sync {}
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            // dequeueControl removes the item before its main-queue closure starts.
            idleRounds = !isApplying && queuedControls.isEmpty && restoringControls.isEmpty ? idleRounds + 1 : 0
            if idleRounds == 2 { hardwareQueue.sync {}; return }
            precondition(Date() < deadline, "Device flow did not drain")
        }
        preconditionFailure("Device flow did not drain")
    }
    func restartRestore() { controlsRestoreAttempted = false; receive(Fixture.snapshot); drain() }
    // PRODUCTION_METHODS
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
let cases = document["cases"] as! [[String: Any]]
defer { Fixture.defaults.removePersistentDomain(forName: Fixture.suite) }
var flowRows: [[String: Any]] = []
let booleans: Set<String> = ["FnlockMode", "ConservationMode", "RapidChargeMode", "YLogoStatus", "PortLighting"]
let transient: Set<String> = ["ChargeStartThreshold", "ChargeStopThreshold", "BatteryIndex"]
let noRGB = HardwareFeatureStatus(available: false, reason: "No USB controller in replay", backend: "USB HID")
for invalid: Any in [true, "1200", NSNull(), 1.5] {
    check(HardwareSnapshot.fanRPM(invalid) == -1, "Invalid RPM became a measurement")
    check(HardwareSnapshot.powerRange(["Min": 0, "Max": 50, "Step": 5], current: invalid) == nil,
          "Invalid power readback became a writable range")
}
for (key, invalid) in [("SmartFanMode", true as Any), ("BacklightLevel", "bad" as Any),
                       ("ChargeStopThreshold", 101 as Any), ("BatteryIndex", 0 as Any)] {
    let properties: NSDictionary = ["IOClass": "ThinkVPC", "ControlProtocolVersion": 1, key: invalid,
        "FeatureStatus": [key: ["Available": true, "Backend": "ACPI"]]]
    check(HardwareCapabilities(properties, rgbStatus: noRGB, rgbMode: "Factory", sampleIsStale: false)
        .features[key]?.available == false, "Invalid current \(key) enabled writes")
}
for invalid: Any in [true, "bad", -1, 4000] {
    let properties: NSDictionary = ["IOClass": "IdeaVPC", "ControlProtocolVersion": 1,
        "ACPIBridgeVersion": 2, "FanWritesValidated": true, "Fan1TargetRPM": invalid,
        "Fan1MaxRPM": 3000, "Fan1TargetRPMStep": 100,
        "FeatureStatus": ["Fan1TargetRPM": ["Available": true, "Backend": "ACPI profile"]]]
    check(HardwareCapabilities(properties, rgbStatus: noRGB, rgbMode: "Factory", sampleIsStale: false)
        .features["Fan1TargetRPM"]?.available == false, "Invalid fan minimum enabled writes")
}
for entry in cases {
    let id = entry["id"] as! String
    let properties = entry["snapshot"] as! [String: Any]
    Fixture.reset(properties)
    let manager = HardwareManager()
    manager.receive(properties)
    let available = Set(manager.featureStatus.filter { $0.value.available }.map { $0.key })
    let expected = Set(entry["expectedAvailable"] as! [String])
    check(available == expected, "\(id): available \(available.sorted()), expected \(expected.sorted())")
    check(manager.thinkFanCurveSupported == (entry["expectedCurve"] as! Bool), "\(id): curve gate")
    for key in HardwareFeatureStatus.catalog.keys.sorted() {
        let before = Fixture.requests.count
        let target = key == "SmartFanMode" ? 3 : key == "ChargeStartThreshold" ? 40 : key == "ChargeStopThreshold" ? 80 : 1
        manager.request(key, target, boolean: booleans.contains(key))
        manager.drain()
        check(Fixture.requests.count == before + (available.contains(key) ? 1 : 0), "\(id): command gate for \(key)")
        if available.contains(key) {
            check((Fixture.snapshot[key] as? NSNumber)?.intValue == target, "\(id): readback \(key)")
            let displayed = ["SmartFanMode": manager.powerProfile, "BacklightLevel": manager.keyboardBacklight,
                "FnlockMode": manager.isFnLocked ? 1 : 0, "ConservationMode": manager.isConservationOn ? 1 : 0,
                "RapidChargeMode": manager.isRapidChargeOn ? 1 : 0, "BatteryIndex": manager.batteryIndex,
                "ChargeStartThreshold": manager.chargeStartThreshold, "ChargeStopThreshold": manager.chargeStopThreshold,
                "CPUBoostPower": manager.cpuBoostWatts, "CPUSustainedPower": manager.cpuSustainedWatts,
                "AlwaysOnUSBState": manager.alwaysOnUSBState, "Fan1TargetRPM": manager.fan1TargetRPM, "Fan2TargetRPM": manager.fan2TargetRPM]
            if let actual = displayed[key] { check(actual == target, "\(id): published state \(key)") }
            check(transient.contains(key) || manager.saved().values[key]?.value == target, "\(id): persisted \(key)")
        }
    }
    check(Fixture.references == 0, "\(id): retained service leaked")
    // Freshness loss disables firmware writes but keeps feature sections present.
    var stale = Fixture.snapshot
    stale["SensorSampleSequence"] = 1; stale["SensorSampleTimeMS"] = 0
    manager.cpuUsesSMC = true; manager.cpuTemp = 52
    manager.receive(stale)
    check(manager.cpuTemp == 52, "\(id): stale firmware discarded an independent SMC reading")
    check(manager.featureStatus.values.allSatisfy { !$0.available }, "\(id): stale controls enabled")
    let previous = Fixture.requests.count
    manager.request("BacklightLevel", 2); manager.drain()
    check(Fixture.requests.count == previous, "\(id): stale write sent")
    manager.cpuUsesSMC = false; manager.receive(Fixture.snapshot)
    var fanFlow = "unavailable_in_snapshot", curveFlow = "unavailable_in_snapshot"
    if properties["IOClass"] as? String == "ThinkVPC", properties["EC Capability"] as? String == "RW",
       properties["ThinkFanProtocolVersion"] as? Int == 1 {
        Fixture.fanStatus = 0
        let fan = ThinkFanHelper(connection: 1, isMainFan: true)
        fan.update(); check(fan.enable && fan.rpm == 2500, "\(id): fan telemetry")
        fan.setFullSpeed(); check(fan.isFullSpeed, "\(id): Full Speed")
        fan.setManualLevel(4); check(fan.savedLevel == 4 && !fan.isAutomatic, "\(id): Manual")
        Fixture.fanStatus = -1; fan.setManualLevel(5)
        check(!fan.enable && fan.rpm == nil, "\(id): fan failure fabricated state")
        Fixture.fanStatus = 0; fan.setAutomatic()
        check(fan.enable && fan.isAutomatic, "\(id): Auto recovery")
        fan.startCurve(temperature: 75, supported: manager.thinkFanCurveSupported)
        check(fan.curveEnabled == manager.thinkFanCurveSupported, "\(id): curve capability gate")
        if fan.curveEnabled {
            check(fan.persistedLevel == 0x84, "Active curve persisted as a manual startup level")
            fan.stopCurve(reason: .systemSleep)
            for _ in 0..<3 { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            check(!fan.curveEnabled && fan.isAutomatic, "\(id): sleep did not restore Auto")
            curveFlow = "passed"
        }
        fanFlow = "passed"
    }
    flowRows.append(["id": id, "available": available.sorted(), "unavailable": HardwareFeatureStatus.catalog.keys.filter { !available.contains($0) }.sorted(),
                     "controlFlow": "passed", "fanAutoManualFullRecovery": fanFlow, "curveSleep": curveFlow, "hardware": "not_run"])
}

// Transport failures and stale replies must not become saved state.
let baseline = cases.first { $0["id"] as? String == "thinkpad-t490" }!["snapshot"] as! [String: Any]
for reply in [Fixture.Reply.failed, .transportError, .wrongID, .superseded, .pendingNeverCompletes] {
    Fixture.reset(baseline); Fixture.reply = reply
    Fixture.snapshot["BacklightLevel"] = 0
    let manager = HardwareManager(); manager.receive(Fixture.snapshot)
    manager.setKeyboardBacklight(2); manager.drain()
    check(manager.saved().values["BacklightLevel"] == nil, "Failed transaction persisted")
    check(Fixture.references == 0, "Failure leaked service")
}
Fixture.reset(baseline); Fixture.reply = .pending
Fixture.snapshot["BacklightLevel"] = 0
let pending = HardwareManager(); pending.receive(Fixture.snapshot); pending.setKeyboardBacklight(2); pending.drain()
check(pending.saved().values["BacklightLevel"]?.value == 2 && Fixture.polls == 2, "Delayed readback did not complete")

// An old completion with the same numeric handle must not publish in a new generation.
Fixture.reset(baseline)
let reconnected = HardwareManager(); reconnected.receive(baseline)
reconnected.setKeyboardBacklight(2); reconnected.connectionGeneration &+= 1
reconnected.hardwareQueue.sync {}
for _ in 0..<4 { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
check(reconnected.saved().values["BacklightLevel"] == nil, "Reconnected session accepted old completion")
reconnected.isApplying = false
reconnected.isShuttingDown = true
let count = Fixture.requests.count
reconnected.setKeyboardBacklight(1); reconnected.drain()
check(Fixture.requests.count == count && Fixture.references == 0, "Terminal session accepted a write")
let loggingCount = Fixture.booleanRequests.count
reconnected.setDetailedLogging(true); reconnected.drain()
check(Fixture.booleanRequests.count == loggingCount && !reconnected.detailedLogging,
      "Detailed logging accepted new work after shutdown")

// While a request is in flight, only the newest queued value for the same control is sent.
Fixture.reset(baseline)
let coalesced = HardwareManager(); coalesced.receive(baseline)
let releaseQueue = DispatchSemaphore(value: 0)
coalesced.hardwareQueue.async { releaseQueue.wait() }
coalesced.setKeyboardBacklight(0); coalesced.setKeyboardBacklight(1); coalesced.setKeyboardBacklight(2)
releaseQueue.signal(); coalesced.drain()
check(Fixture.requests.count == 2 && coalesced.saved().values["BacklightLevel"]?.value == 2, "Queued writes did not coalesce")

// Execution validates range/step again, independent of a UI dialog or an outdated draft.
var power = baseline
power["CPUBoostPower"] = 20
power["PowerLimitRanges"] = ["CPUBoostPower": ["Min": 10, "Max": 50, "Step": 5]]
var features = power["FeatureStatus"] as! [String: [String: Any]]
features["CPUBoostPower"] = ["Available": true, "Backend": "WMI", "Reason": "Protocol-boundary fixture"]
power["FeatureStatus"] = features
Fixture.reset(power)
let bounded = HardwareManager(); bounded.receive(power)
for watts in [-1, 9, 11, 51, Int.max] { bounded.setPowerLimit("CPUBoostPower", watts: watts) }
bounded.setPowerLimit("UnsupportedProperty", watts: 20)
bounded.setFanMinimum(-1, rpm: 1000)
bounded.drain()
check(Fixture.requests.isEmpty, "Invalid draft reached firmware transport")
bounded.setPowerLimit("CPUBoostPower", watts: 25); bounded.drain()
check(Fixture.requests.count == 1 && bounded.saved().values["CPUBoostPower"]?.value == 25 && bounded.cpuBoostWatts == 25,
      "Valid power draft did not complete")

// Saved explicit Off survives restart and equal-value restore emits no duplicate command.
Fixture.reset(baseline)
let first = HardwareManager(); first.receive(baseline)
first.setDetailedLogging(true); first.drain()
check(Fixture.defaults.bool(forKey: "DetailedLogging"), "Detailed logging preference was not saved")
first.setKeyboardBacklight(0); first.drain()
check(first.saved().values["BacklightLevel"]?.value == 0, "Explicit Off was not saved")
Fixture.snapshot["BacklightLevel"] = 2
let restarted = HardwareManager(); restarted.receive(Fixture.snapshot); restarted.restartRestore()
check(restarted.keyboardBacklight == 0, "Restart did not restore explicit Off")
check(restarted.detailedLogging && Fixture.booleanRequests.contains { $0.key == "DetailedTelemetry" && $0.value },
      "Restart did not restore detailed logging")
let restoredCount = Fixture.requests.count
restarted.restartRestore()
check(Fixture.requests.count == restoredCount, "Equal-value restore repeated a write")
let isolated = HardwareManager(); var other = Fixture.snapshot; other["FirmwareDSDTSHA256"] = "different-firmware"
isolated.receive(other); isolated.controlsRestoreAttempted = false; isolated.receive(other); isolated.drain()
check(isolated.saved().values.isEmpty && Fixture.requests.count == restoredCount, "Preferences crossed firmware identity")

// Every known catalog identity is a name lookup, not permission to write.
let catalogURL = HardwareProfiles.directory!.appendingPathComponent("catalogs/models.json")
let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
let machines = catalog["machine_types"] as! [String: String]
let pcis = catalog["pci_subsystems"] as! [String: String]
for (code, name) in machines {
    check(LaptopIdentity.resolve(strings: [code], pciIDs: [], lenovo: true, profiles: []).name == name, "Catalog machine \(code)")
}
for (pci, name) in pcis {
    check(LaptopIdentity.resolve(strings: [], pciIDs: [pci], lenovo: true, profiles: []).name == name, "Catalog PCI \(pci)")
}
var profileRows: [[String: Any]] = []
for profile in HardwareProfiles.all() {
    for machine in (profile["machine_types"] as? [String]) ?? [] {
        check(LaptopIdentity.resolve(strings: [machine], pciIDs: [], lenovo: true).name == profile["name"] as? String,
              "Profile identity \(profile["id"]!) / \(machine)")
    }
    let properties: NSDictionary = ["IOClass": "IdeaVPC", "ControlProtocolVersion": 1, "HardwareProfile": profile["id"]!]
    let capabilities = HardwareCapabilities(properties, rgbStatus: noRGB, rgbMode: "Factory", sampleIsStale: false)
    check(capabilities.features.values.allSatisfy { !$0.available }, "Profile name enabled unsupported controls")
    profileRows.append(["id": profile["id"]!, "name": profile["name"]!, "kind": profile["kind"]!,
        "writesVerifiedInProfile": (profile["verified_writes"] as? Int) == 1,
        "identityDoesNotAuthorizeWrites": "passed", "hardware": "not_run"])
}
let result: [String: Any] = ["cases": flowRows, "catalogMachineTypes": machines.count, "catalogPCIIDs": pcis.count,
    "profiles": profileRows, "catalogSource": "HardwareProfiles/catalogs/models.json",
    "status": "software_replay_passed", "nativeApp": "not_run", "hardware": "not_run"]
if let report = ProcessInfo.processInfo.environment["REYOGA_DEVICE_FLOW_REPORT"] {
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: .atomic)
}
print("PASS connected production device flows: \(cases.count) snapshots, \(machines.count) machine IDs, \(pcis.count) PCI IDs, \(HardwareProfiles.all().count) profiles")
