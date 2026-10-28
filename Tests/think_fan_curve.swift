func testFanCurvePolicy() {
    // The production policy, helper and IOKit stub are compiled before this file.
    var policy = ThinkFanCurvePolicy()
    let curve = ThinkFanCurvePolicy.defaults
    let capability: [String: Any] = ["IOClass": "ThinkVPC", "ThinkFanCurveVersion": 1,
        "ThinkFanProtocolVersion": 1, "EC Capability": "RW"]
    precondition(ThinkFanCurvePolicy.supported(capability as NSDictionary))
    var missingHelpers = capability
    missingHelpers["EC Capability"] = "RO"
    precondition(ThinkFanCurvePolicy.unavailableReason(missingHelpers as NSDictionary)?.contains("Generate ThinkPad SSDT") == true)
    var oldDriver = capability
    oldDriver["ThinkFanCurveVersion"] = 0
    precondition(ThinkFanCurvePolicy.unavailableReason(oldDriver as NSDictionary)?.contains("watchdog") == true)
    var safeDriver = missingHelpers
    safeDriver["SafeMode"] = true
    precondition(ThinkFanCurvePolicy.unavailableReason(safeDriver as NSDictionary)?.hasPrefix("Safe Mode") == true,
                 "Safe Mode must not send the user to install an unnecessary SSDT")
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

    precondition(CurveStopReason.allCases.map { $0.rawValue } == [
        "user_or_lifecycle", "hardware_identity_changed", "temperature_timeout",
        "fan_or_temperature_unavailable", "write_or_readback_failed", "capability_or_temperature_lost",
        "wake_requires_restart", "connection_closed", "system_sleep", "driver_connection_changed",
        "monitoring_stopped", "app_shutdown"
    ], "Curve stop diagnostics changed raw values")
}

func testFanCurveRecovery() {
    FanFixture.reset()
    defer { FanFixture.finish() }
    let curveFan = ThinkFanHelper(connection: 1, isMainFan: true)
    let draftKey = "ThinkFanDraftTest-" + UUID().uuidString
    curveFan.loadCurve(key: draftKey)
    var draft = curveFan.curvePoints
    draft[0].temperature = 51
    let beforeDraft = FanFixture.requests.count
    curveFan.saveCurveDraft(draft)
    precondition(curveFan.savedCurveDraft == draft, "Saved draft was lost when reopening the editor")
    precondition(curveFan.curvePoints == ThinkFanCurvePolicy.defaults && FanFixture.requests.count == beforeDraft,
                 "Editing draft mutated active policy or wrote hardware")
    let reloaded = ThinkFanHelper(connection: 1, isMainFan: true)
    reloaded.loadCurve(key: draftKey)
    precondition(reloaded.curvePoints == draft && !reloaded.curveEnabled)
    curveFan.defaults.removeObject(forKey: draftKey)
    func waitForCurve(_ helper: ThinkFanHelper) {
        let deadline = Date().addingTimeInterval(2)
        while helper.curveRequestPending && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(!helper.curveRequestPending, "Curve transaction timed out")
    }
    FanFixture.responses = [(0, [0x88, 0x13, 0x84], 3)]
    curveFan.update()
    FanFixture.responses = [(0, [0x88, 0x13, 0x07], 3)]
    curveFan.startCurve(temperature: 82, supported: true)
    waitForCurve(curveFan)
    precondition(curveFan.curveEnabled && FanFixture.requests.last == 7 && FanFixture.selectors.last == 6)
    precondition(curveFan.persistedLevel == 0x84, "Do not persist a transient curve level as a manual startup setting")
    let previousCount = FanFixture.requests.count
    curveFan.setFanLevel(3)
    curveFan.setManualLevel(3)
    precondition(FanFixture.requests.count == previousCount, "Manual and wake restores must not overwrite an active curve")
    FanFixture.responses = [(0, [0x88, 0x13, 0x84], 3)]
    curveFan.updateCurve(temperature: .nan)
    precondition(!curveFan.curveEnabled && FanFixture.requests.last == 0x84)
    precondition(!curveFan.curveStopReason.isEmpty, "Show why the curve stopped even after Auto recovers")
    curveFan.startCurve(temperature: 82, supported: false)
    precondition(!curveFan.curveEnabled)

    // Failed manual writes may have reached the EC; failed Auto must stay visibly pending.
    FanFixture.responses = [(notReady, [0, 0, 0], 3), (notReady, [0, 0, 0], 3)]
    curveFan.startCurve(temperature: 90, supported: true)
    waitForCurve(curveFan)
    precondition(!curveFan.curveEnabled && curveFan.curveStatus == "Curve stopped; automatic recovery pending")
    precondition(curveFan.persistedLevel == 0x84)
    FanFixture.responses = [(0, [0x88, 0x13, 0x84], 3)]
    curveFan.update()
    precondition(curveFan.curveStatus == "BIOS Auto")

    let secondFan = ThinkFanHelper(connection: 1, isMainFan: false)
    FanFixture.responses = [(0, [0x88, 0x13, 0x47], 3)]
    secondFan.startCurve(temperature: 96, supported: true)
    waitForCurve(secondFan)
    precondition(secondFan.curveEnabled && FanFixture.requestedFans.last == 1 && FanFixture.requests.last == 0x47)
    FanFixture.responses = [(0, [0x88, 0x13, 0x84], 3)]
    secondFan.stopCurve(reason: .systemSleep)
    precondition(!secondFan.curveEnabled && !curveFan.curveEnabled)

    let key = "curve-test-\(UUID().uuidString)"
    curveFan.defaults.set(Data("invalid".utf8), forKey: key)
    curveFan.loadCurve(key: key)
    precondition(curveFan.curvePoints == ThinkFanCurvePolicy.defaults)
    curveFan.defaults.removeObject(forKey: key)

    FanFixture.responses = [(0, [0x88, 0x13, 7], 3), (0, [0x88, 0x13, 0x84], 3)]
    curveFan.startCurve(temperature: 82, supported: true)
    curveFan.stopCurve(reason: .userOrLifecycle)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    precondition(!curveFan.curveEnabled && curveFan.isAutomatic, "Late curve completion cannot overwrite Auto")

    FanFixture.responses = [(0, [0x88, 0x13, 7], 3)]
    curveFan.startCurve(temperature: 82, supported: true)
    waitForCurve(curveFan)
    FanFixture.responses = [(0, [0x88, 0x13, 0x84], 3)]
    curveFan.checkCurveFreshness(now: ProcessInfo.processInfo.systemUptime + 4)
    precondition(!curveFan.curveEnabled && curveFan.isAutomatic, "Missing temperature must return to Auto")
    precondition(curveFan.curveStopReason == "Curve stopped: CPU temperature updates timed out.")
    precondition(ReYogaDiagnostics.shared.events.last?["reason"] as? String == "temperature_timeout",
                 "Curve stop diagnostics must serialize the original raw reason")
    print("PASS real ThinkFan curve policy and recovery")
}

testFanCurvePolicy()
testFanCurveRecovery()
