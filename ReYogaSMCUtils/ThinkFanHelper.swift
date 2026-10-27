//
//  ThinkFanHelper.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 11/5/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation
import Combine
import CoreFoundation

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

class ThinkFanHelper: ObservableObject {
    let connect: io_connect_t
    let main: Bool
    let defaults = ReYogaConstants.hardwareDefaults
    @Published private(set) var enable = false
    var canRecoverAutomatic: Bool { connect != 0 }

    @Published private(set) var level = 4
    @Published private(set) var rpm: Int?
    var minimumLevel: Int { defaults.bool(forKey: "AllowFanStop") ? 0 : 1 }
    private static let automaticLevel: UInt8 = 0x84
    private static let fullSpeedLevel: UInt8 = 0x40 | 7
    private static let queryRPMLevel: UInt64 = 0x100

    @Published private(set) var savedLevel: UInt8 = 0x80
    var isAutomatic: Bool { savedLevel & 0x80 != 0 }
    var isFullSpeed: Bool { savedLevel & 0x40 != 0 }

    init(_ connect: io_connect_t, _ main: Bool) {
        self.connect = connect
        self.main = main
        enable = connect != 0
    }

    func setAutomatic() {
        setFanLevel(Self.automaticLevel, operation: "auto")
    }

    func setFullSpeed() {
        setFanLevel(Self.fullSpeedLevel, operation: "full")
    }

    func setManualLevel(_ target: Int) {
        guard (minimumLevel...7).contains(target) else { return }
        setFanLevel(UInt8(target), operation: "manual")
    }

    private func access(level requested: UInt64 = queryRPMLevel, operation: String = "poll") -> [UInt8]? {
        guard connect != 0 else { return nil }
        let input: [UInt64] = [main ? 0 : 1, requested]
        var output = [UInt8](repeating: 0, count: 3)
        var size = output.count
        let status = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBytes { bytes in
                IOConnectCallMethod(connect, UInt32(kRYSMCUCThinkFan), values.baseAddress, 2,
                                    nil, 0, nil, nil, bytes.baseAddress, &size)
            }
        }
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
                showOSDRaw(String(format: localizedMessage("ThinkPad fan access failed (0x%08x). Retry the driver connection."), failure))
            }
            return nil
        }
        enable = true
        let measuredRPM = Int(output[0]) | Int(output[1]) << 8
        rpm = measuredRPM == 0xffff ? nil : measuredRPM
        return output
    }

    func setFanLevel(_ requested: UInt8? = nil, operation: String = "restore") {
        let target = requested ?? savedLevel
        guard enable || target == 0x80 || target == Self.automaticLevel else { return }
        guard (1...7).contains(target) || target == 0x47 || target == 0x80 || target == 0x84 ||
              (target == 0 && defaults.bool(forKey: "AllowFanStop")) else {
            showOSDRaw("Fan level is invalid; use Auto or a supported level")
            return
        }
        guard let sample = access(level: UInt64(target), operation: operation) else { return }
        savedLevel = target
        acceptLevel(sample[2])
    }

    private func acceptLevel(_ raw: UInt8) {
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
