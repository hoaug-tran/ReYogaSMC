//
//  ThinkFanHelper.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 11/5/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import Foundation
import Combine
import CoreFoundation
#if canImport(IOKit)
import IOKit
#endif

struct ThinkFanReading {
    let rpm: Int?
    let control: UInt8?

    init(_ properties: [String: Any]?) {
        func number(_ key: String) -> Int? {
            guard let value = properties?[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue == Double(value.intValue) else { return nil }
            return value.intValue
        }
        rpm = number("RPM").flatMap { (0..<0xffff).contains($0) ? $0 : nil }
        control = number("Control").flatMap { Self.validControl($0) ? UInt8($0) : nil }
    }

    static func validControl(_ raw: Int) -> Bool {
        (0...7).contains(raw) || (0x40...0x47).contains(raw) || (0x80...0x87).contains(raw)
    }
}

struct ThinkFanSnapshot {
    static let maximumAge: TimeInterval = 3
    let sampledAt: TimeInterval
    let main: ThinkFanReading
    let secondary: ThinkFanReading

    init?(_ properties: [String: Any]?) {
        guard let time = properties?["SensorSampleTimeMS"] as? NSNumber,
              CFGetTypeID(time) != CFBooleanGetTypeID(), time.doubleValue.isFinite, time.doubleValue >= 0 else { return nil }
        sampledAt = time.doubleValue / 1000
        main = ThinkFanReading(properties?["Fan1"] as? [String: Any])
        secondary = ThinkFanReading(properties?["Fan2"] as? [String: Any])
    }

    func isCurrent(at uptime: TimeInterval, after previous: TimeInterval) -> Bool {
        sampledAt >= previous && sampledAt <= uptime && uptime - sampledAt <= Self.maximumAge
    }
}

struct ThinkFanCurvePoint: Codable, Equatable {
    var temperature: Int
    var level: Int
}

struct ThinkFanCurvePolicy {
    static func supported(_ properties: NSDictionary) -> Bool {
        unavailableReason(properties) == nil
    }
    static func unavailableReason(_ properties: NSDictionary) -> String? {
        guard properties["IOClass"] as? String == "ThinkVPC" else { return "Custom Curve is not supported by this driver interface." }
        guard properties["SafeMode"] as? Bool != true else { return "Safe Mode blocks fan control. Disable -reysafe and restart macOS." }
        guard properties["ThinkFanProtocolVersion"] as? Int == 1 else { return "Update the app and kext, then reconnect to enable ThinkPad fan control." }
        guard properties["EC Capability"] as? String == "RW" else { return "Manual fan control needs EC read/write helpers. Open Diagnostics → Generate ThinkPad SSDT… to check and add missing helpers." }
        guard properties["ThinkFanAccessFailed"] as? Bool != true else { return "Fan access is paused pending selector recovery. Try Auto, then export diagnostics if recovery fails." }
        guard properties["ThinkFanCurveVersion"] as? Int == 1 else { return "Custom Curve needs a driver watchdog. Update both the app and kext, then restart macOS." }
        return nil
    }
    static let defaults = [ThinkFanCurvePoint(temperature: 50, level: 4),
        ThinkFanCurvePoint(temperature: 70, level: 5), ThinkFanCurvePoint(temperature: 80, level: 7),
        ThinkFanCurvePoint(temperature: 88, level: 0x47)]
    static func valid(_ points: [ThinkFanCurvePoint]) -> Bool {
        guard (2...8).contains(points.count), points.last?.level == 0x47 else { return false }
        for (index, point) in points.enumerated() {
            guard (30...95).contains(point.temperature), (1...7).contains(point.level) || point.level == 0x47 else { return false }
            if index > 0, points[index - 1].temperature >= point.temperature || points[index - 1].level > point.level { return false }
        }
        return true
    }
    private(set) var target: Int?
    private var lowerSince: TimeInterval?
    mutating func reset() { target = nil; lowerSince = nil }
    mutating func sample(_ temperature: Double, now: TimeInterval, points: [ThinkFanCurvePoint]) -> Int? {
        guard Self.valid(points), temperature.isFinite, temperature > 0, temperature < 125 else { return nil }
        let desired = temperature >= 95 ? 0x47 : points.last(where: { temperature >= Double($0.temperature) })?.level ?? points[0].level
        guard let current = target else { target = desired; return desired }
        if desired >= current { target = desired; lowerSince = nil; return desired }
        let threshold = points.first(where: { $0.level == current })?.temperature ?? 95
        guard temperature < Double(threshold - 3) else { lowerSince = nil; return current }
        if lowerSince == nil { lowerSince = now }
        if now - (lowerSince ?? now) >= 10 { target = desired; lowerSince = nil }
        return target
    }
}

enum CurveStopReason: String, CaseIterable {
    case userOrLifecycle = "user_or_lifecycle"
    case hardwareIdentityChanged = "hardware_identity_changed"
    case temperatureTimeout = "temperature_timeout"
    case fanOrTemperatureUnavailable = "fan_or_temperature_unavailable"
    case writeOrReadbackFailed = "write_or_readback_failed"
    case capabilityOrTemperatureLost = "capability_or_temperature_lost"
    case wakeRequiresRestart = "wake_requires_restart"
    case connectionClosed = "connection_closed"
    case systemSleep = "system_sleep"
    case driverConnectionChanged = "driver_connection_changed"
    case monitoringStopped = "monitoring_stopped"
    case appShutdown = "app_shutdown"
}

class ThinkFanHelper: ObservableObject {
    let connect: io_connect_t
    let main: Bool
    let defaults = ReYogaConstants.hardwareDefaults
    @Published private(set) var enable = false
    @Published private(set) var curveEnabled = false
    @Published private(set) var curveStatus = ""
    @Published private(set) var curveStopReason = ""
    @Published var curvePoints = ThinkFanCurvePolicy.defaults
    private var curvePolicy = ThinkFanCurvePolicy()
    private var curveSampleTime: TimeInterval = 0
    private var curveWriteTime: TimeInterval = 0
    private var lastCurveTarget: Int?
    private var curveRecoveryPending = false
    private let accessQueue = DispatchQueue(label: "org.reyogasmc.think-fan")
    private var curveGeneration: UInt64 = 0
    private(set) var curveRequestPending = false
    var curveStorageKey: String?
    var canRecoverAutomatic: Bool { connect != 0 }

    @Published private(set) var level = 4
    @Published private(set) var rpm: Int?
    var minimumLevel: Int { defaults.bool(forKey: "AllowFanStop") ? 0 : 1 }
    private static let automaticLevel: UInt8 = 0x84
    private static let fullSpeedLevel: UInt8 = 0x40 | 7
    private static let queryRPMLevel: UInt64 = 0x100

    @Published private(set) var savedLevel: UInt8 = 0x80
    var persistedLevel: UInt8 { curveEnabled || curveRecoveryPending ? Self.automaticLevel : savedLevel }
    var isAutomatic: Bool { savedLevel & 0x80 != 0 }
    var isFullSpeed: Bool { savedLevel & 0x40 != 0 }

    private let feedback: (HardwareFeedback) -> Void
    init(connection: io_connect_t, isMainFan: Bool, feedback: @escaping (HardwareFeedback) -> Void = { _ in }) {
        self.feedback = feedback
        self.connect = connection
        self.main = isMainFan
        enable = connect != 0
    }

    func setAutomatic() {
        stopCurve()
        setFanLevel(Self.automaticLevel, operation: "auto")
    }

    func setFullSpeed() {
        stopCurve()
        setFanLevel(Self.fullSpeedLevel, operation: "full")
    }

    func setManualLevel(_ target: Int) {
        guard !curveEnabled else { return }
        guard (minimumLevel...7).contains(target) else { return }
        setFanLevel(UInt8(target), operation: "manual")
    }

    private func access(level requested: UInt64 = queryRPMLevel, operation: String = "poll", curve: Bool = false) -> [UInt8]? {
        guard connect != 0 else { return nil }
        let result = accessQueue.sync { Self.transaction(connect: connect, main: main, requested: requested, curve: curve) }
        return acceptAccess(result, requested: requested, operation: operation)
    }

    private static func transaction(connect: io_connect_t, main: Bool, requested: UInt64, curve: Bool) -> (Int32, Int, [UInt8]) {
        let input: [UInt64] = [main ? 0 : 1, requested]
        var output = [UInt8](repeating: 0, count: 3)
        var size = output.count
        let status = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBytes { bytes in
                IOConnectCallMethod(connect, UInt32(curve ? kRYSMCUCThinkFanCurve : kRYSMCUCThinkFan), values.baseAddress, 2,
                                    nil, 0, nil, nil, bytes.baseAddress, &size)
            }
        }
        return (status, size, output)
    }

    private func acceptAccess(_ result: (Int32, Int, [UInt8]), requested: UInt64, operation: String) -> [UInt8]? {
        let (status, size, output) = result
        let raw = output[2]
        let validMode = ThinkFanReading.validControl(Int(raw))
        let automatic = requested == 0x80 || requested == 0x84
        let matched = requested == Self.queryRPMLevel ||
            (automatic ? raw & 0x80 != 0 : requested == 0x47 ? raw & 0x40 != 0 : UInt64(raw) == requested)
        let confirmed = status == kIOReturnSuccess && size == 3 && validMode && matched
        if requested != Self.queryRPMLevel || enable != confirmed {
            ReYogaDiagnostics.shared.record("think_fan_access", [
                "operation": operation, "fan": main ? 0 : 1, "requested": requested,
                "transportStatus": status, "outputBytes": size, "raw": output,
                "manualEnabledBefore": enable, "automaticRecovery": automatic, "confirmed": confirmed
            ])
        }
        guard confirmed else {
            rpm = nil
            enable = false
            if requested != Self.queryRPMLevel {
                let failure = status == kIOReturnSuccess ? kIOReturnIOError : status
                feedback(.fanAccessFailed(failure))
            }
            return nil
        }
        enable = true
        let measuredRPM = Int(output[0]) | Int(output[1]) << 8
        rpm = measuredRPM == 0xffff ? nil : measuredRPM
        return output
    }

    func setFanLevel(_ requested: UInt8? = nil, operation: String = "restore") {
        guard !curveEnabled else { return }
        let target = requested ?? savedLevel
        guard enable || target == 0x80 || target == Self.automaticLevel else { return }
        guard (1...7).contains(target) || target == 0x47 || target == 0x80 || target == 0x84 ||
              (target == 0 && defaults.bool(forKey: "AllowFanStop")) else {
            feedback(.invalidFanLevel)
            return
        }
        guard let sample = access(level: UInt64(target), operation: operation) else { return }
        curveRecoveryPending = false
        curveStopReason = ""
        if !curveStatus.isEmpty { curveStatus = target & 0x80 != 0 ? "BIOS Auto" : "" }
        savedLevel = target
        acceptLevel(sample[2])
    }

    func loadCurve(key: String) {
        guard curveStorageKey != key else { return }
        stopCurve(reason: .hardwareIdentityChanged)
        curveStorageKey = key
        curvePoints = ThinkFanCurvePolicy.defaults
        curvePoints = savedCurveDraft
    }

    func startCurve(temperature: Double, supported: Bool) {
        guard !curveEnabled, !curveRecoveryPending, !curveRequestPending else { return }
        guard supported, enable, ThinkFanCurvePolicy.valid(curvePoints), temperature.isFinite,
              temperature > 0, temperature < 125 else {
            ReYogaDiagnostics.shared.record("think_fan_curve_rejected", ["fan": main ? 0 : 1,
                "supported": supported, "fanReady": enable, "validCurve": ThinkFanCurvePolicy.valid(curvePoints),
                "temperature": temperature.isFinite ? temperature : -1])
            if !supported {
                explainCurveUnavailable("Custom Curve is not supported by this driver interface.")
            } else if !enable {
                explainCurveUnavailable("Fan status is unavailable. Try Auto or reconnect the driver.")
            } else if !ThinkFanCurvePolicy.valid(curvePoints) {
                explainCurveUnavailable("Use increasing temperatures and fan levels, ending in Full Speed by 95°C.")
            } else {
                explainCurveUnavailable("CPU temperature is unavailable or stale. Wait for a fresh reading before starting Custom Curve.")
            }
            return
        }
        if let key = curveStorageKey, let data = try? JSONEncoder().encode(curvePoints) { defaults.set(data, forKey: key) }
        curvePolicy.reset(); curveWriteTime = 0; lastCurveTarget = nil
        curveSampleTime = ProcessInfo.processInfo.systemUptime
        curveEnabled = true
        curveStopReason = ""
        curveRecoveryPending = false
        ReYogaDiagnostics.shared.record("think_fan_curve_started", ["fan": main ? 0 : 1,
            "points": curvePoints.map { ["temperature": $0.temperature, "level": $0.level] },
            "temperature": temperature, "decreaseDelaySeconds": 10, "hysteresisC": 3])
        updateCurve(temperature: temperature)
    }

    func saveCurveDraft(_ points: [ThinkFanCurvePoint]) {
        guard ThinkFanCurvePolicy.valid(points), let key = curveStorageKey,
              let data = try? JSONEncoder().encode(points) else { return }
        defaults.set(data, forKey: key)
    }

    var savedCurveDraft: [ThinkFanCurvePoint] {
        guard let key = curveStorageKey, let data = defaults.data(forKey: key), data.count <= 4096,
              let points = try? JSONDecoder().decode([ThinkFanCurvePoint].self, from: data),
              ThinkFanCurvePolicy.valid(points) else { return curvePoints }
        return points
    }

    func explainCurveUnavailable(_ reason: String) {
        curveStatus = reason
    }

    func stopCurve(reason: CurveStopReason = .userOrLifecycle) {
        guard curveEnabled else { return }
        switch reason {
        case .temperatureTimeout: curveStopReason = "Curve stopped: CPU temperature updates timed out."
        case .fanOrTemperatureUnavailable: curveStopReason = "Curve stopped: fan status or CPU temperature is unavailable."
        case .writeOrReadbackFailed: curveStopReason = "Curve stopped: a fan command or its readback failed."
        case .capabilityOrTemperatureLost: curveStopReason = "Curve stopped: fan capability or fresh temperature is unavailable."
        case .userOrLifecycle, .hardwareIdentityChanged, .wakeRequiresRestart, .connectionClosed,
             .systemSleep, .driverConnectionChanged, .monitoringStopped, .appShutdown: curveStopReason = ""
        }
        curveEnabled = false
        curveGeneration &+= 1
        curveRequestPending = false
        curvePolicy.reset(); lastCurveTarget = nil
        let restored = access(level: UInt64(Self.automaticLevel), operation: "curve_stop")
        curveRecoveryPending = restored == nil
        ReYogaDiagnostics.shared.record("think_fan_curve_stopped", ["fan": main ? 0 : 1,
            "reason": reason.rawValue, "automaticConfirmed": restored != nil])
        if let sample = restored { acceptLevel(sample[2]) }
        curveStatus = restored == nil ? "Curve stopped; automatic recovery pending" : "BIOS Auto"
    }

    func checkCurveFreshness(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if curveEnabled && now - curveSampleTime > 3 { stopCurve(reason: .temperatureTimeout) }
    }

    func updateCurve(temperature: Double) {
        guard curveEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - curveSampleTime <= 3 else { stopCurve(reason: .temperatureTimeout); return }
        guard enable, let target = curvePolicy.sample(temperature, now: now, points: curvePoints) else {
            stopCurve(reason: .fanOrTemperatureUnavailable); return
        }
        curveSampleTime = now
        guard !curveRequestPending, lastCurveTarget != target || now - curveWriteTime >= 1 else { return }
        curveRequestPending = true
        let generation = curveGeneration
        let connection = connect, isMain = main
        accessQueue.async {
            let result = Self.transaction(connect: connection, main: isMain, requested: UInt64(target), curve: true)
            DispatchQueue.main.async {
                guard self.curveEnabled, self.curveGeneration == generation else { return }
                self.curveRequestPending = false
                self.acceptCurveResult(result, target: target, temperature: temperature)
            }
        }
    }

    private func acceptCurveResult(_ result: (Int32, Int, [UInt8]), target: Int, temperature: Double) {
        guard let sample = acceptAccess(result, requested: UInt64(target), operation: "curve") else {
            stopCurve(reason: .writeOrReadbackFailed); return
        }
        if lastCurveTarget != target {
            ReYogaDiagnostics.shared.record("think_fan_curve_target", ["fan": main ? 0 : 1,
                "temperature": temperature, "previousLevel": lastCurveTarget ?? -1, "level": target,
                "actualControl": sample[2], "rpm": rpm ?? -1])
        }
        acceptLevel(sample[2])
        lastCurveTarget = target; curveWriteTime = ProcessInfo.processInfo.systemUptime
        curveStatus = target == 0x47 ? localizedMessage("Full Speed") : String(format: localizedMessage("Level %d"), target)
    }

    private func acceptLevel(_ raw: UInt8) {
        if curveRecoveryPending && raw & 0x80 != 0 {
            curveRecoveryPending = false
            curveStatus = "BIOS Auto"
            ReYogaDiagnostics.shared.record("think_fan_curve_recovered", ["fan": main ? 0 : 1, "raw": raw])
        }
        if raw & 0x40 != 0 { savedLevel = Self.fullSpeedLevel }
        else if raw & 0x80 != 0 { savedLevel = Self.automaticLevel }
        else if raw <= 7 { savedLevel = raw; level = Int(raw) }
        else { enable = false; rpm = nil }
    }

    func update() {
        guard let sample = access() else { return }
        acceptLevel(sample[2])
    }

    func acceptSnapshot(_ reading: ThinkFanReading) {
        rpm = reading.rpm
        enable = connect != 0 && reading.control != nil
        if enable, let control = reading.control { acceptLevel(control) }
    }
}
