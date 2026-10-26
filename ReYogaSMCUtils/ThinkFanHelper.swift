//
//  ThinkFanHelper.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 11/5/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation

class ThinkFanHelper {
    let connect: io_connect_t
    let main: Bool
    let defaults = ReYogaConstants.hardwareDefaults
    var enable = false
    var canRecoverAutomatic: Bool { connect != 0 }

    private(set) var level = 4
    private(set) var rpm: Int?
    var minimumLevel: Int { defaults.bool(forKey: "AllowFanStop") ? 0 : 1 }
    private static let automaticLevel: UInt8 = 0x84
    private static let fullSpeedLevel: UInt8 = 0x47
    private static let queryRPMLevel: UInt64 = 0x100

    var savedLevel: UInt8 = 0x80

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
        // A failed sample must not prevent the next poll or an explicit Auto recovery.
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
        let validMode = raw <= 7 || raw & 0xf8 == 0x40 || raw & 0xf8 == 0x80
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
        if raw & 0x40 != 0 { savedLevel = Self.fullSpeedLevel; level = 7 }
        else if raw & 0x80 != 0 { savedLevel = Self.automaticLevel; level = 4 }
        else if raw <= 7 { savedLevel = raw; level = Int(raw) }
        else { enable = false; rpm = nil }
    }

    func update() {
        guard let sample = access() else { return }
        // Keep the restore mode in sync even when the slider is not being refreshed.
        acceptLevel(sample[2])
    }
}
