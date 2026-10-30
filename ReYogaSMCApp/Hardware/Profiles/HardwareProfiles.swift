import Foundation
import CryptoKit

struct HardwareProfiles {
    static var directory: URL? {
        if let bundleDir = Bundle.main.resourceURL?.appendingPathComponent("HardwareProfiles", isDirectory: true),
           FileManager.default.fileExists(atPath: bundleDir.path) {
            return bundleDir
        }
        let fallback = URL(fileURLWithPath: "HardwareProfiles")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
    private static let cachedProfiles = loadProfiles()
    static func all() -> [[String: Any]] { cachedProfiles }
    private static func loadProfiles() -> [[String: Any]] {
        guard let directory = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0), data.count <= 1024 * 1024 else { return nil }
            guard let profile = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  profile["schema_version"] as? Int == 1 else { return nil }
            return profile
        }
    }
    static func hotkeys(for profileID: String) -> [String: Any]? {
        all().compactMap { $0["hotkeys"] as? [String: Any] }.first {
            ($0["matchProfiles"] as? [String])?.contains(profileID) == true
        }
    }
    static func lightingOwnedByRGB(key: String, settings: SavedRGBSettings?, activeProfileID: String?, profiles: [[String: Any]] = HardwareProfiles.all()) -> Bool {
        guard let zone = ["YLogoStatus": "Logo", "PortLighting": "PortLighting"][key],
              let settings = settings,
              settings.isValid,
              settings.mode != "Factory",
              let activeID = activeProfileID,
              !activeID.isEmpty,
              settings.profileID == activeID,
              let profile = profiles.first(where: { $0["id"] as? String == activeID && $0["kind"] as? String == "rgb" }),
              let zones = profile["zones"] as? [String: Any],
              zones[zone] != nil else {
            return false
        }
        return true
    }
    static func hasRGBHardware(profileID: String?) -> Bool {
        guard let id = profileID, !id.isEmpty else { return false }
        let profiles = all()
        if let profile = profiles.first(where: { ($0["id"] as? String) == id }) {
            if profile["kind"] as? String == "rgb" { return true }
            if let hotkeys = profile["hotkeys"] as? [String: Any],
               let matches = hotkeys["matchProfiles"] as? [String] {
                if matches.contains(where: { matchID in
                    profiles.contains { ($0["id"] as? String) == matchID && ($0["kind"] as? String) == "rgb" }
                }) { return true }
            }
            if let name = profile["name"] as? String,
               name.contains("Legion") || name.contains("LOQ") || name.contains("Gaming") {
                return true
            }
        }
        return false
    }
    static let maxDSDTFileSize = 16 * 1024 * 1024
    static func readDSDTSource(_ input: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0, size <= Int64(maxDSDTFileSize) else {
            throw SupportError.message("DSDT source exceeds the supported size")
        }
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, maxDSDTFileSize + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maxDSDTFileSize else { throw SupportError.message("DSDT source exceeds the supported size") }
        }
        guard let source = String(data: data, encoding: .utf8) else { throw SupportError.message("DSDT source is not valid UTF-8") }
        return source
    }
    static func normalizedDSDT(_ source: String) -> String {
        let pattern = #""(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[^\s]"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return source }
        let text = source as NSString
        var normalized = ""
        normalized.reserveCapacity(source.utf8.count)
        expression.enumerateMatches(in: source, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match = match else { return }
            let token = text.substring(with: match.range)
            if !token.hasPrefix("/*") && !token.hasPrefix("//") { normalized.append(token) }
        }
        return normalized
    }
    static func matchingDSDT(_ source: String) throws -> [String: Any] {
        guard source.utf8.count <= maxDSDTFileSize else { throw SupportError.message("DSDT source exceeds the supported size") }
        let normalized = normalizedDSDT(source)
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        let exactMatches = all().filter { item in
            item["kind"] as? String == "acpi" && item["offsets"] != nil &&
                (item["reviewed_dsdt_hashes"] as? [String])?.contains(digest) == true
        }
        if exactMatches.count == 1 { return exactMatches[0] }

        throw SupportError.message("No reviewed DSDT fingerprint matches. Export diagnostics for firmware review.")
    }
    static func matchingAML(_ data: Data) throws -> [String: Any] {
        guard data.count >= 36, data.count <= 1024 * 1024, data.prefix(4) == Data("DSDT".utf8) else {
            throw SupportError.message("Exported ACPI table is not a valid DSDT")
        }
        let bytes = [UInt8](data)
        let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << (8 * $1) }
        guard Int(length) == data.count, bytes.reduce(UInt8(0), { $0 &+ $1 }) == 0 else {
            throw SupportError.message("DSDT length or checksum is invalid")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let oemTableID = String(bytes: bytes[16..<24], encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matches = all().filter {
            guard $0["kind"] as? String == "acpi", $0["offsets"] != nil else { return false }
            if ($0["reviewed_aml_hashes"] as? [String])?.contains(digest) == true {
                return true
            }
            let isReadOnly = ($0["bridge_kind"] as? String == "named-fields-readonly") ||
                (($0["verified_writes"] as? Int ?? 0) == 0 && $0["native_telemetry"] != nil)
            if isReadOnly, let oemIDs = $0["oem_table_ids"] as? [String], oemIDs.contains(oemTableID) {
                return true
            }
            return false
        }
        guard matches.count == 1 else {
            throw SupportError.message("No unique reviewed AML fingerprint matches. Export diagnostics for firmware review.")
        }
        return matches[0]
    }

    static func bridgeFilename(_ profile: [String: Any]) -> String {
        let identity = (profile["id"] as? String) ?? "device"
        let label = identity.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "SSDT-ReYoga-" + String(label.prefix(32)) + ".dsl"
    }
    static func render(_ profile: [String: Any]) throws -> String {
        guard let directory = directory,
              let offsets = profile["offsets"] as? [String: String] else { throw SupportError.message("Hardware profile is incomplete") }
        let kind = (profile["bridge_kind"] as? String) ??
            (profile["native_telemetry"] != nil ? "named-fields-readonly" : "raw-offsets")
        let template: String
        switch kind {
        case "raw-offsets": template = "SSDT-ReYoga.template.dsl"
        case "named-fields-readonly":
            guard (profile["verified_writes"] as? Int ?? 0) == 0 else {
                throw SupportError.message("Read-only bridge cannot validate writes")
            }
            template = "SSDT-ReYoga-readonly.template.dsl"
        default: throw SupportError.message("Unsupported bridge kind")
        }
        var source = try String(contentsOf: directory.appendingPathComponent(template), encoding: .utf8)
        var values = profile
        for (key, value) in offsets { values[key] = value }
        values["profile_name"] = profile["name"]
        values["verified_writes"] = profile["verified_writes"] as? Int == 1 ? 1 : 0
        for (key, value) in values { source = source.replacingOccurrences(of: "{{\(key)}}", with: String(describing: value)) }
        guard !source.contains("{{") else { throw SupportError.message("ACPI template contains unresolved fields") }
        return source
    }
}
