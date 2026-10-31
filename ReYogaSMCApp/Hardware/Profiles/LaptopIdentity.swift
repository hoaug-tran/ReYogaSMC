import Foundation
import IOKit

struct LaptopIdentity {
    let name: String
    let source: String

    private static let catalog: (machineTypes: [String: String], pciSubsystems: [String: String]) = loadCatalog()

    private static func loadCatalog() -> (machineTypes: [String: String], pciSubsystems: [String: String]) {
        let directory = HardwareProfiles.directory ?? URL(fileURLWithPath: "HardwareProfiles")
        let url = directory.appendingPathComponent("catalogs").appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ([:], [:])
        }
        let machines = (json["machine_types"] as? [String: String]) ?? [:]
        let pcis = (json["pci_subsystems"] as? [String: String]) ?? [:]
        return (machines, pcis)
    }

    static func resolve(strings: [String], pciIDs: Set<String>, lenovo: Bool,
                        profiles: [[String: Any]] = HardwareProfiles.all()) -> LaptopIdentity {
        let evidence = strings.map { $0.uppercased() }
        let machineTypes = Set(evidence.flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 4 }.map { String($0.prefix(4)) })
        let pciIDs = Set(pciIDs.map { $0.lowercased() })
        let models = profiles.filter { $0["kind"] as? String == "acpi" }
        let machineMatches = models.filter { profile in
            ((profile["machine_types"] as? [String]) ?? []).contains { machineTypes.contains($0.uppercased()) }
        }
        let pciMatches = models.filter { profile in
            ((profile["pci_subsystem_ids"] as? [String]) ?? []).contains { pciIDs.contains($0.lowercased()) }
        }
        var machineNames = Set(machineMatches.compactMap { $0["name"] as? String })
        var pciNames = Set(pciMatches.compactMap { $0["name"] as? String })
        // Reviewed profiles supply canonical names for their catalog identifiers.
        let profiledTypes = Set(machineMatches.flatMap { ($0["machine_types"] as? [String]) ?? [] }.map { $0.uppercased() })
        let profiledPCI = Set(pciMatches.flatMap { ($0["pci_subsystem_ids"] as? [String]) ?? [] }.map { $0.lowercased() })
        for type in machineTypes.subtracting(profiledTypes) {
            if let name = catalog.machineTypes[type] { machineNames.insert(name) }
        }
        for pci in pciIDs.subtracting(profiledPCI) {
            if let name = catalog.pciSubsystems[pci] { pciNames.insert(name) }
        }
        let names = machineNames.union(pciNames)
        if names.count == 1, let name = names.first {
            let source = machineNames.isEmpty ? "PCI subsystem ID" : pciNames.isEmpty ? "Machine type" : "Machine type + PCI subsystem ID"
            return LaptopIdentity(name: name, source: source)
        }
        if names.count > 1 {
            return LaptopIdentity(name: "Lenovo Laptop", source: "Hardware identity")
        }
        let ignoredPrefixes = ["MACBOOK", "IMAC", "MACMINI", "MACPRO", "APPLE"]
        let ignoredExact: Set<String> = ["DEFAULT STRING", "NONE", "TO BE FILLED BY O.E.M.", "SYSTEM PRODUCT NAME", "SYSTEM MANUFACTURER", "LENOVO", "UNKNOWN"]
        let validCandidates = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { str in
            let upper = str.uppercased()
            if upper.isEmpty || ignoredExact.contains(upper) { return false }
            if ignoredPrefixes.contains(where: { upper.hasPrefix($0) }) { return false }
            return true
        }
        for str in validCandidates {
            let upper = str.uppercased()
            if upper.contains("THINKPAD") || upper.contains("LEGION") || upper.contains("IDEAPAD") ||
               upper.contains("YOGA") || upper.contains("THINKBOOK") || upper.contains("LOQ") || upper.contains("XIAOXIN") {
                return LaptopIdentity(name: str, source: "Firmware identity")
            }
        }
        for str in validCandidates {
            let upper = str.uppercased()
            if let match = upper.range(of: "(?<![A-Z0-9])(2[01][A-Z0-9]{2})[A-Z0-9]*(?![A-Z0-9])", options: .regularExpression) {
                let code = String(upper[match].prefix(4))
                return LaptopIdentity(name: "ThinkPad (\(code))", source: "Machine type")
            }
            if let match = upper.range(of: "(?<![A-Z0-9])(8[0-4][A-Z0-9]{2})[A-Z0-9]*(?![A-Z0-9])", options: .regularExpression) {
                let code = String(upper[match].prefix(4))
                return LaptopIdentity(name: "Lenovo (\(code))", source: "Machine type")
            }
        }
        let isLenovo = lenovo || !machineNames.isEmpty || pciIDs.contains { $0.hasPrefix("17aa:") } ||
            evidence.contains { $0.contains("LENOVO") }
        if isLenovo {
            return LaptopIdentity(name: "Lenovo Laptop", source: "Hardware identity")
        }
        return LaptopIdentity(name: "Unknown Laptop", source: "Hardware identity")
    }

    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return String(string.prefix(256)) }
        guard let data = value as? Data, data.count <= 256 else { return nil }
        return String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\0", with: " ")
    }

    static func parseSMBIOS(data: Data) -> [String] {
        guard data.count >= 4 else { return [] }
        let bytes = [UInt8](data)
        var result: [String] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            if bytes[offset] == 127 { break }
            let structureType = bytes[offset]
            let length = Int(bytes[offset + 1])
            if length < 4 || offset + length > bytes.count { break }
            var strings: [String] = []
            var stringOffset = offset + length
            while stringOffset < bytes.count {
                if bytes[stringOffset] == 0 {
                    if stringOffset == offset + length {
                        stringOffset += (stringOffset + 1 < bytes.count && bytes[stringOffset + 1] == 0) ? 2 : 1
                    } else {
                        stringOffset += 1
                    }
                    break
                }
                var end = stringOffset
                while end < bytes.count && bytes[end] != 0 { end += 1 }
                if let str = String(bytes: bytes[stringOffset..<end], encoding: .utf8) ??
                             String(bytes: bytes[stringOffset..<end], encoding: .ascii) {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    strings.append(trimmed)
                }
                stringOffset = end + 1
            }
            let allowedOffsets: [Int]
            switch structureType {
            case 1: allowedOffsets = [0x04, 0x05, 0x06, 0x1A]
            case 2: allowedOffsets = [0x04, 0x05, 0x06]
            default: allowedOffsets = []
            }
            for fieldOffset in allowedOffsets where fieldOffset < length {
                let strIdx = Int(bytes[offset + fieldOffset])
                if strIdx > 0 && strIdx <= strings.count {
                    let candidate = strings[strIdx - 1]
                    if !candidate.isEmpty && !result.contains(candidate) {
                        result.append(candidate)
                    }
                }
            }
            guard stringOffset > offset else { break }
            offset = stringOffset
        }
        return result
    }

    static func read() -> LaptopIdentity {
        var strings: [String] = []
        var pciIDs = Set<String>()
        func collect(_ entry: io_registry_entry_t) {
            for key in ["product-name", "model", "manufacturer", "board-product", "OEMProduct", "OEMVendor", "OEMBoard", "machine-type"] {
                let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                if let string = text(value) { strings.append(string) }
            }
        }
        for path in ["IODeviceTree:/", "IODeviceTree:/efi/platform"] {
            let entry = IORegistryEntryFromPath(kIOMasterPortDefault, path)
            if entry != 0 { collect(entry); IOObjectRelease(entry) }
        }
        let options = IORegistryEntryFromPath(kIOMasterPortDefault, "IODeviceTree:/options")
        if options != 0 {
            defer { IOObjectRelease(options) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(options, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = properties?.takeRetainedValue() as? [String: Any] {
                for (key, value) in props where ["OEMProduct", "OEMVendor"].contains(String(key.split(separator: ":").last ?? "")) {
                    if let string = text(value) { strings.append(string) }
                }
            }
        }
        var iterator: io_iterator_t = 0
        if IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                if IOObjectConformsTo(entry, "IOPlatformExpertDevice") != 0 { collect(entry) }
                if IOObjectConformsTo(entry, "AppleSMBIOS") != 0 {
                    if let value = IORegistryEntryCreateCFProperty(entry, "SMBIOS" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                        strings.append(contentsOf: parseSMBIOS(data: value))
                    }
                }
                guard IOObjectConformsTo(entry, "IOPCIDevice") != 0 else { continue }
                func number(_ key: String) -> UInt32? {
                    let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                    if let value = value as? NSNumber { return value.uint32Value }
                    guard let data = value as? Data, data.count == 4 else { return nil }
                    return data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                }
                if let vendor = number("subsystem-vendor-id"), let device = number("subsystem-id"), vendor <= 0xffff, device <= 0xffff {
                    pciIDs.insert(String(format: "%04x:%04x", vendor, device))
                }
            }
        }
        return resolve(strings: strings, pciIDs: pciIDs, lenovo: false)
    }
}
