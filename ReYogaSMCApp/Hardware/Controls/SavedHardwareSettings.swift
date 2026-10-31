import Foundation
import CryptoKit

struct SavedControlValue: Codable, Equatable {
    var value: Int
    var boolean: Bool
    var powerProfile: Int?
}
struct SavedHardwareSettings: Codable, Equatable {
    var version = 1
    var identity: String
    var values: [String: SavedControlValue] = [:]
    static func storageKey(_ identity: String) -> String {
        "AppliedHardwareSettings." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    mutating func record(_ key: String, value: SavedControlValue) {
        if key == "CPUPowerReset" { values.removeValue(forKey: "CPUBoostPower"); values.removeValue(forKey: "CPUSustainedPower"); return }
        if key == "FanControlMode", value.value == 0 { values.removeValue(forKey: "Fan1TargetRPM"); values.removeValue(forKey: "Fan2TargetRPM"); return }
        values[key] = value
        if value.value == 1 && (key == "ConservationMode" || key == "RapidChargeMode") {
            values[key == "ConservationMode" ? "RapidChargeMode" : "ConservationMode"] = SavedControlValue(value: 0, boolean: true)
        }
    }
}
