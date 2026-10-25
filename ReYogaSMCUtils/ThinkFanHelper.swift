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

    private(set) var level = 4
    private(set) var rpm: Int?
    var minimumLevel: Int { defaults.bool(forKey: "AllowFanStop") ? 0 : 1 }
    private static let automaticLevel: UInt8 = 0x84
    private static let fullSpeedLevel: UInt8 = 0x47

    var savedLevel: UInt8 = 0x80

    init(_ connect: io_connect_t, _ main: Bool) {
        self.connect = connect
        self.main = main
        enable = connect != 0
    }

    func setAutomatic() {
        setFanLevel(Self.automaticLevel)
    }

    func setFullSpeed() {
        setFanLevel(Self.fullSpeedLevel)
    }

    func setManualLevel(_ target: Int) {
        guard (minimumLevel...7).contains(target) else { return }
        setFanLevel(UInt8(target))
    }

    private func access(level requested: UInt64 = 0x100) -> [UInt8]? {
        guard enable, connect != 0 else { return nil }
        let input: [UInt64] = [main ? 0 : 1, requested]
        var output = [UInt8](repeating: 0, count: 3)
        var size = output.count
        let status = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBytes { bytes in
                IOConnectCallMethod(connect, UInt32(kRYSMCUCThinkFan), values.baseAddress, 2,
                                    nil, 0, nil, nil, bytes.baseAddress, &size)
            }
        }
        guard status == kIOReturnSuccess, size == 3 else {
            rpm = nil
            enable = false
            showOSDRaw(String(format: localizedMessage("ThinkPad fan access failed (0x%08x). Retry the driver connection."), status))
            return nil
        }
        rpm = Int(output[0]) | Int(output[1]) << 8
        return output
    }

    func setFanLevel(_ requested: UInt8? = nil) {
        let target = requested ?? savedLevel
        guard (1...7).contains(target) || target == 0x47 || target == 0x80 || target == 0x84 ||
              (target == 0 && defaults.bool(forKey: "AllowFanStop")) else {
            showOSDRaw("Fan level is invalid; use Auto or a supported level")
            return
        }
        guard let sample = access(level: UInt64(target)) else { return }
        savedLevel = target
        acceptLevel(sample[2])
    }

    private func acceptLevel(_ raw: UInt8) {
        if raw & 0x40 != 0 { savedLevel = Self.fullSpeedLevel; level = 7 }
        else if raw & 0x80 != 0 { savedLevel = Self.automaticLevel; level = 4 }
        else if raw <= 7 { savedLevel = raw; level = Int(raw) }
        else { enable = false; rpm = nil }
    }

    func update(_ updateLevel: Bool = false) {
        guard let sample = access() else { return }
        if updateLevel { acceptLevel(sample[2]) }
    }
}
