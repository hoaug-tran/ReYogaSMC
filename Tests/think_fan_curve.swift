// The production policy, helper and IOKit stub are compiled before this file.
var policy = ThinkFanCurvePolicy()
let curve = ThinkFanCurvePolicy.defaults
let capability: [String: Any] = ["IOClass": "ThinkVPC", "ThinkFanCurveVersion": 1,
    "ThinkFanProtocolVersion": 1, "EC Capability": "RW"]
precondition(ThinkFanCurvePolicy.supported(capability as NSDictionary))
for (key, value) in [("IOClass", "IdeaVPC" as Any), ("IOClass", "UnknownVPC" as Any),
                     ("ThinkFanCurveVersion", 0 as Any), ("ThinkFanProtocolVersion", 0 as Any),
                     ("EC Capability", "RO" as Any), ("EC Capability", "Basic" as Any),
                     ("SafeMode", true as Any), ("ThinkFanAccessFailed", true as Any)] {
    var unsupported = capability
    unsupported[key] = value
    precondition(!ThinkFanCurvePolicy.supported(unsupported as NSDictionary))
}
precondition(ThinkFanCurvePolicy.valid(curve))
precondition(!ThinkFanCurvePolicy.valid([]))
precondition(!ThinkFanCurvePolicy.valid([.init(temperature: 70, level: 7), .init(temperature: 60, level: 0x47)]))
precondition(!ThinkFanCurvePolicy.valid([.init(temperature: 50, level: 5), .init(temperature: 80, level: 4)]))
precondition(policy.sample(60, now: 1, points: curve) == 4)
precondition(policy.sample(89, now: 2, points: curve) == 0x47)
precondition(policy.sample(87, now: 3, points: curve) == 0x47)
precondition(policy.sample(82, now: 4, points: curve) == 0x47)
precondition(policy.sample(82, now: 13, points: curve) == 0x47)
precondition(policy.sample(82, now: 14, points: curve) == 7)
precondition(policy.sample(96, now: 15, points: curve) == 0x47)
precondition(policy.sample(.nan, now: 16, points: curve) == nil)
precondition(policy.sample(-1, now: 17, points: curve) == nil)

let curveFan = ThinkFanHelper(1, true)
func waitForCurve(_ helper: ThinkFanHelper) {
    let deadline = Date().addingTimeInterval(2)
    while helper.curveRequestPending && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(!helper.curveRequestPending, "Curve transaction timed out")
}
responses = [(0, [0x88, 0x13, 0x84], 3)]
curveFan.update()
responses = [(0, [0x88, 0x13, 0x07], 3)]
curveFan.startCurve(temperature: 82, supported: true)
waitForCurve(curveFan)
precondition(curveFan.curveEnabled && requests.last == 7 && selectors.last == 6)
precondition(curveFan.persistedLevel == 0x84, "Do not persist a transient curve level as a manual startup setting")
let previousCount = requests.count
curveFan.setFanLevel(3)
curveFan.setManualLevel(3)
precondition(requests.count == previousCount, "Manual and wake restores must not overwrite an active curve")
responses = [(0, [0x88, 0x13, 0x84], 3)]
curveFan.updateCurve(temperature: .nan)
precondition(!curveFan.curveEnabled && requests.last == 0x84)
curveFan.startCurve(temperature: 82, supported: false)
precondition(!curveFan.curveEnabled)

// Failed manual writes may have reached the EC; failed Auto must stay visibly pending.
responses = [(notReady, [0, 0, 0], 3), (notReady, [0, 0, 0], 3)]
curveFan.startCurve(temperature: 90, supported: true)
waitForCurve(curveFan)
precondition(!curveFan.curveEnabled && curveFan.curveStatus == "Curve stopped; automatic recovery pending")
precondition(curveFan.persistedLevel == 0x84)
responses = [(0, [0x88, 0x13, 0x84], 3)]
curveFan.update()
precondition(curveFan.curveStatus == "BIOS Auto")

let secondFan = ThinkFanHelper(1, false)
responses = [(0, [0x88, 0x13, 0x47], 3)]
secondFan.startCurve(temperature: 96, supported: true)
waitForCurve(secondFan)
precondition(secondFan.curveEnabled && requestedFans.last == 1 && requests.last == 0x47)
responses = [(0, [0x88, 0x13, 0x84], 3)]
secondFan.stopCurve(reason: "test_sleep")
precondition(!secondFan.curveEnabled && !curveFan.curveEnabled)

let key = "curve-test-\(UUID().uuidString)"
curveFan.defaults.set(Data("invalid".utf8), forKey: key)
curveFan.loadCurve(key: key)
precondition(curveFan.curvePoints == ThinkFanCurvePolicy.defaults)
curveFan.defaults.removeObject(forKey: key)

responses = [(0, [0x88, 0x13, 7], 3), (0, [0x88, 0x13, 0x84], 3)]
curveFan.startCurve(temperature: 82, supported: true)
curveFan.stopCurve(reason: "test_cancel_in_flight")
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
precondition(!curveFan.curveEnabled && curveFan.isAutomatic, "Late curve completion cannot overwrite Auto")

responses = [(0, [0x88, 0x13, 7], 3)]
curveFan.startCurve(temperature: 82, supported: true)
waitForCurve(curveFan)
responses = [(0, [0x88, 0x13, 0x84], 3)]
curveFan.checkCurveFreshness(now: ProcessInfo.processInfo.systemUptime + 4)
precondition(!curveFan.curveEnabled && curveFan.isAutomatic, "Missing temperature must return to Auto")
print("PASS real ThinkFan curve policy and recovery")
