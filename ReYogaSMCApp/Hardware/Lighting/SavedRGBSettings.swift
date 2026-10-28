import Foundation

public typealias RGBBytes = (red: UInt8, green: UInt8, blue: UInt8)

struct SavedRGBSettings: Codable, Equatable {
    static let maximumImportBytes = 256 * 1024
    static let maximumSavedBytes = 512 * 1024
    var version = 1
    var profileID: String
    var mode: String
    var colors: [String: String]
    var logoEnabled: Bool
    var perKey: Data?
    var isValid: Bool {
        version == 1 && !profileID.isEmpty && ["Factory", "Static", "Breathing", "Spectrum", "Per-key"].contains(mode)
            && colors.values.allSatisfy { Self.bytes($0) != nil }
            && (perKey?.count ?? 0) <= Self.maximumImportBytes
            && (mode != "Per-key" || perKey != nil)
    }
    static func bytes(_ text: String) -> RGBBytes? {
        guard text.count == 7, text.first == "#", let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return (UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255))
    }
}
