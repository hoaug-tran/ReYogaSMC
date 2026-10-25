// SPDX-License-Identifier: GPL-2.0-only
// ReYogaSMC support adapters. Physical addresses and device layouts live in profiles.
import AppKit
import Foundation
import IOKit
import IOKit.hid
import ApplicationServices
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

struct SavedRGBSettings: Codable, Equatable {
    var version = 1
    var profileID: String
    var mode: String
    var colors: [String: String]
    var logoEnabled: Bool
    var perKey: Data?
    var isValid: Bool {
        version == 1 && !profileID.isEmpty && ["Factory", "Static", "Breathing", "Spectrum", "Per-key"].contains(mode)
            && colors.values.allSatisfy { Self.bytes($0) != nil }
            && (mode != "Per-key" || perKey != nil)
    }
    static func bytes(_ text: String) -> (UInt8, UInt8, UInt8)? {
        guard text.count == 7, text.first == "#", let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return (UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255))
    }
    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(max(0, min(255, (c.redComponent * 255).rounded()))),
                      Int(max(0, min(255, (c.greenComponent * 255).rounded()))), Int(max(0, min(255, (c.blueComponent * 255).rounded()))))
    }
    static func color(_ hex: String) -> NSColor {
        let value = bytes(hex) ?? (0, 0, 0)
        return NSColor(deviceRed: CGFloat(value.0)/255, green: CGFloat(value.1)/255, blue: CGFloat(value.2)/255, alpha: 1)
    }
}

struct HardwareSnapshot {
    static func fanRPM(_ value: Any?) -> Int {
        guard let value = value as? Int, (0..<0xffff).contains(value) else { return -1 }
        return value
    }

    static func temperature(_ value: Any?) -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return -1 }
        let celsius = number.doubleValue
        return celsius.isFinite && celsius > 0 && celsius < 125 ? celsius : -1
    }

    static func providerPriority(_ name: String) -> Int {
        switch name {
        case "ThinkVPC": return 3
        case "IdeaVPC": return 2
        case "DYVPC": return 1
        default: return 0
        }
    }

    static func powerRange(_ value: Any?, current: Any?) -> [String: Int]? {
        guard let range = value as? [String: Int], let current = current as? Int,
              let low = range["Min"], let high = range["Max"], let step = range["Step"],
              low >= 0, high >= low, high <= Int(UInt32.max), step > 0,
              current >= low, current <= high else { return nil }
        return ["Min": low, "Max": high, "Step": step]
    }

    static func stale(_ props: NSDictionary, observedAge: TimeInterval, uptime: TimeInterval) -> Bool {
        let interval = props["TelemetryIntervalMS"] as? Int ?? 0
        let threshold = max(2, Double(max(0, interval)) / 1000 * 3)
        if props["SensorSampleTimeMS"] != nil {
            guard let sampleMS = props["SensorSampleTimeMS"] as? Double, sampleMS.isFinite, sampleMS >= 0 else { return true }
            let age = uptime - sampleMS / 1000
            return age < -1 || age > threshold
        }
        return observedAge > threshold
    }

    static func manualFanFeature(_ feature: HardwareFeatureStatus?, key: String,
                                 bridgeVersion: Int, writesValidated: Bool) -> HardwareFeatureStatus {
        let unavailable = HardwareFeatureStatus(available: false,
            reason: "The active driver has no validated manual fan control for this firmware.", backend: feature?.backend ?? "Unavailable")
        guard let feature = feature else { return unavailable }
        // Bridge requirements belong to this adapter, not every fan backend.
        guard feature.backend == "ACPI profile" else { return feature }
        guard feature.available, bridgeVersion >= 2 else { return unavailable }
        if key != "FanControlMode" && !writesValidated {
            return HardwareFeatureStatus(available: false,
                reason: "Manual fan minimums have not been validated for this firmware.", backend: feature.backend)
        }
        return feature
    }
}

// Display identity is independent of firmware control eligibility.
struct LaptopIdentity {
    let name: String
    let source: String

    static func resolve(strings: [String], pciIDs: Set<String>, lenovo: Bool,
                        profiles: [[String: Any]] = HardwareProfiles.all()) -> LaptopIdentity {
        let evidence = strings.map { $0.uppercased() }
        let models = profiles.filter { $0["kind"] as? String == "acpi" }
        let machineMatches = models.filter { profile in
            (profile["machine_types"] as? [String] ?? []).contains { type in
                evidence.contains { value in
                    value.range(of: "(?<![A-Z0-9])" + NSRegularExpression.escapedPattern(for: type.uppercased()) + "[A-Z0-9]*(?![A-Z0-9])", options: .regularExpression) != nil
                }
            }
        }
        let pciMatches = models.filter { profile in
            (profile["pci_subsystem_ids"] as? [String] ?? []).contains { pciIDs.contains($0.lowercased()) }
        }
        let machineNames = Set(machineMatches.compactMap { $0["name"] as? String })
        let pciNames = Set(pciMatches.compactMap { $0["name"] as? String })
        let names = machineNames.union(pciNames)
        if names.count == 1, let name = names.first {
            let source = machineNames.isEmpty ? "PCI subsystem ID" : pciNames.isEmpty ? "Machine type" : "Machine type + PCI subsystem ID"
            return LaptopIdentity(name: name, source: source)
        }
        let isLenovo = lenovo || !machineNames.isEmpty || pciIDs.contains { $0.hasPrefix("17aa:") } ||
            evidence.contains { $0.contains("LENOVO") }
        return LaptopIdentity(name: isLenovo ? "Lenovo Laptop" : "Unknown Laptop", source: "Hardware identity")
    }

    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return String(string.prefix(256)) }
        guard let data = value as? Data, data.count <= 256 else { return nil }
        return String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\0", with: " ")
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

struct HardwareProfiles {
    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("HardwareProfiles", isDirectory: true) }
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
    static func normalizedDSDT(_ source: String) -> String {
        let pattern = #""(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[^\s]"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return source }
        let text = source as NSString
        return expression.matches(in: source, range: NSRange(location: 0, length: text.length)).map {
            text.substring(with: $0.range)
        }.filter { !$0.hasPrefix("/*") && !$0.hasPrefix("//") }.joined()
    }
    static func matchingDSDT(_ source: String) throws -> [String: Any] {
        guard source.utf8.count <= 16 * 1024 * 1024 else { throw SupportError.message("DSDT source exceeds the supported size") }
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
        let matches = all().filter {
            $0["kind"] as? String == "acpi" && $0["offsets"] != nil &&
                ($0["reviewed_aml_hashes"] as? [String])?.contains(digest) == true
        }
        guard matches.count == 1 else {
            throw SupportError.message("No unique reviewed AML fingerprint matches. Export diagnostics for firmware review.")
        }
        return matches[0]
    }

    static func bridgeFilename(_ profile: [String: Any]) -> String {
        let identity = profile["id"] as? String ?? "device"
        let label = identity.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "SSDT-ReYoga-" + String(label.prefix(32)) + ".dsl"
    }
    static func compiler() -> URL? {
        let paths: [String?] = [UserDefaults.standard.string(forKey: "IASLPath"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/iasl").path,
                     "/opt/homebrew/bin/iasl", "/usr/local/bin/iasl"]
        return paths.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static func exportLiveBridge(service: io_service_t) {
        let save = NSSavePanel()
        save.allowedFileTypes = ["dsl"]
        let identity = IORegistryEntryCreateCFProperty(service, "HardwareProfile" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        let namedProfile = all().first { $0["id"] as? String == identity }
        save.nameFieldStringValue = bridgeFilename(namedProfile ?? [:])
        save.message = localizedMessage("The driver exports DSDT locally. Only a reviewed profile can generate an SSDT; it is never installed automatically.")
        guard save.runModal() == .OK, let output = save.url else { return }
        IOObjectRetain(service)
        DispatchQueue.global(qos: .utility).async {
            defer { IOObjectRelease(service) }
            do {
                let transport = IORegistryEntrySetCFProperty(service, "ExportDSDT" as CFString, kCFBooleanTrue)
                let data = IORegistryEntryCreateCFProperty(service, "ExportedDSDT" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
                _ = IORegistryEntrySetCFProperty(service, "ExportDSDT" as CFString, kCFBooleanFalse)
                guard transport == kIOReturnSuccess, let table = data else { throw SupportError.message("The driver could not export DSDT. Check ACPIExportStatus and the kernel log.") }
                let profile = try matchingAML(table)
                let source = try render(profile)
                try source.write(to: output, atomically: true, encoding: .utf8)
                var result = "ACPI bridge source saved. Install iasl to compile it."
                if let compiler = compiler() {
                    let process = Process()
                    process.executableURL = compiler
                    process.arguments = ["-tc", output.path]
                    let logURL = output.deletingPathExtension().appendingPathExtension("compile.log")
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: logURL)
                    defer { try? handle.close() }
                    process.standardOutput = handle; process.standardError = handle
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw SupportError.message("SSDT compilation failed. The source and compile.log are saved for inspection.") }
                    result = "SSDT compiled — review it and add it to OpenCore before rebooting"
                }
                ReYogaDiagnostics.shared.record("live_acpi_generated", ["profile": profile["id"] ?? "unknown", "compiled": compiler() != nil])
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([output]); showOSDRaw(result, duration: 3000) }
            } catch {
                ReYogaDiagnostics.shared.record("live_acpi_generation_failed", ["error": error.localizedDescription])
                DispatchQueue.main.async { showOSDRaw(error.localizedDescription, duration: 3500) }
            }
        }
    }
    static func render(_ profile: [String: Any]) throws -> String {
        guard let directory = directory,
              let offsets = profile["offsets"] as? [String: String] else { throw SupportError.message("Hardware profile is incomplete") }
        var source = try String(contentsOf: directory.appendingPathComponent("SSDT-ReYoga.template.dsl"), encoding: .utf8)
        var values = profile
        for (key, value) in offsets { values[key] = value }
        values["profile_name"] = profile["name"]
        values["verified_writes"] = profile["verified_writes"] as? Int == 1 ? 1 : 0
        for (key, value) in values { source = source.replacingOccurrences(of: "{{\(key)}}", with: String(describing: value)) }
        guard !source.contains("{{") else { throw SupportError.message("ACPI template contains unresolved fields") }
        return source
    }
    static func exportBridge() {
        let chooser = NSOpenPanel()
        chooser.allowedFileTypes = ["dsl"]
        chooser.message = localizedMessage("Select a disassembled DSDT. A bridge is generated only when a reviewed profile matches.")
        guard chooser.runModal() == .OK, let input = chooser.url else { return }
        do {
            let source = try String(contentsOf: input, encoding: .utf8)
            let profile = try matchingDSDT(source)
            let generated = try render(profile)
            let save = NSSavePanel()
            save.nameFieldStringValue = bridgeFilename(profile)
            save.allowedFileTypes = ["dsl"]
            save.message = localizedMessage("Save ACPI source for review and compilation with iasl. It will not be installed.")
            guard save.runModal() == .OK, let output = save.url else { return }
            try generated.write(to: output, atomically: true, encoding: .utf8)
            ReYogaDiagnostics.shared.record("acpi_generated", ["profile": profile["id"] ?? "unknown", "validation": profile["validation"] ?? "unknown"])
            NSWorkspace.shared.activateFileViewerSelecting([output])
            showOSDRaw("ACPI bridge source saved — compile and review before booting", duration: 3000)
        } catch {
            ReYogaDiagnostics.shared.record("acpi_generation_failed", ["error": error.localizedDescription])
            showOSDRaw(error.localizedDescription, duration: 3500)
        }
    }
}

enum SupportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return localizedMessage(text) }; return nil }
}

// Wire format derived from OpenRGB's LenovoUSBController (Cooper Hall/geobot19,
// GPL-2.0-or-later). Each supported USB VID/PID and LED map is data, not a guess.
final class LegionRGBController {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var profile: [String: Any]?
    private var softwareMode = false
    private(set) var matchedProfileID: String?
    private var layout = "Keyboard ANSI"
    private(set) var status = HardwareFeatureStatus(available: false, reason: "No reviewed RGB USB profile matched", backend: "USB HID")

    func detect() {
        if let device = device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager = manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil; manager = nil; profile = nil; matchedProfileID = nil; softwareMode = false
        status = HardwareFeatureStatus(available: false, reason: "No reviewed RGB USB profile matched", backend: "USB HID")
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let profiles = HardwareProfiles.all().filter { $0["kind"] as? String == "rgb" }
        let matchers = profiles.compactMap { profile -> NSDictionary? in
            guard let vendor = profile["vendorID"] as? Int, let product = profile["productID"] as? Int,
                  let page = profile["usagePage"] as? Int else { return nil }
            return [kIOHIDVendorIDKey: vendor, kIOHIDProductIDKey: product, kIOHIDPrimaryUsagePageKey: page]
        }
        guard !matchers.isEmpty else { return }
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == kIOReturnSuccess {
            defer { IOObjectRelease(iterator) }
            while true {
                let entry = IOIteratorNext(iterator)
                if entry == 0 { break }
                defer { IOObjectRelease(entry) }
                func number(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                }
                if let match = profiles.first(where: { $0["vendorID"] as? Int == number(kIOHIDVendorIDKey) &&
                    $0["productID"] as? Int == number(kIOHIDProductIDKey) && $0["usagePage"] as? Int == number(kIOHIDPrimaryUsagePageKey) }) {
                    matchedProfileID = match["id"] as? String
                    break
                }
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchers as CFArray)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            status = HardwareFeatureStatus(available: false, reason: opened == kIOReturnNotPermitted ? "macOS denied HID access. Enable Input Monitoring for ReYogaSMC, then retry discovery." : String(format: localizedMessage("HID discovery failed: 0x%08x"), opened), backend: "USB HID")
            return
        }
        self.manager = manager
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let candidates = devices.filter { candidate in
            let vendor = IOHIDDeviceGetProperty(candidate, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let product = IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let page = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let size = IOHIDDeviceGetProperty(candidate, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? -1
            return profiles.contains { $0["vendorID"] as? Int == vendor && $0["productID"] as? Int == product &&
                $0["usagePage"] as? Int == page && $0["reportSize"] as? Int == size }
        }
        guard candidates.count <= 1 else {
            matchedProfileID = nil
            status = HardwareFeatureStatus(available: false, reason: "Multiple matching RGB controllers found; disconnect additional controllers and retry", backend: "USB HID")
            return
        }
        for candidate in candidates {
            let vendor = IOHIDDeviceGetProperty(candidate, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let product = IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let page = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let size = IOHIDDeviceGetProperty(candidate, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? -1
            guard let match = profiles.first(where: { $0["vendorID"] as? Int == vendor && $0["productID"] as? Int == product && $0["usagePage"] as? Int == page }),
                  match["reportSize"] as? Int == size else { continue }
            matchedProfileID = match["id"] as? String
            let ret = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            guard ret == kIOReturnSuccess else {
                status = HardwareFeatureStatus(available: false, reason: ret == kIOReturnNotPermitted ? "RGB access denied. Check Input Monitoring permission." : ret == kIOReturnExclusiveAccess ? "Another application owns the RGB HID device. Close it and retry." : String(format: localizedMessage("RGB HID open failed: 0x%08x"), ret), backend: "USB HID")
                continue
            }
            device = candidate
            profile = match
            do { _ = try inspectLayout() }
            catch {
                status = HardwareFeatureStatus(available: false, reason: error.localizedDescription, backend: "USB HID")
                IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                device = nil
                continue
            }
            status = HardwareFeatureStatus(available: true, reason: "Direct colors have transport acknowledgement; color readback is unavailable", backend: localizedMessage("USB HID • %@", String(describing: match["id"] ?? "unknown")))
            ReYogaDiagnostics.shared.record("rgb_detected", ["vendor": vendor, "product": product, "reportSize": size, "profile": match["id"] ?? "unknown"])
            break
        }
    }
    private func send(_ bytes: [UInt8]) throws {
        guard let device = device, let profile = profile,
              let report = profile["reportID"] as? Int,
              bytes.count == profile["reportSize"] as? Int else { throw SupportError.message("RGB device disconnected or profile invalid") }
        let ret = bytes.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(report), $0.baseAddress!, bytes.count) }
        guard ret == kIOReturnSuccess else { throw SupportError.message(String(format: localizedMessage("RGB feature report failed: 0x%08x"), ret)) }
    }
    private func instruction(_ code: Int) throws {
        guard let profile = profile, let size = profile["reportSize"] as? Int, let report = profile["reportID"] as? Int else { throw SupportError.message("RGB profile unavailable") }
        var data = [UInt8](repeating: 0, count: size)
        data[0] = UInt8(report); data[1] = UInt8(code)
        try send(data)
    }
    // Read-only device information request; no software-mode or LED-state change.
    func inspectLayout() throws -> Int {
        guard let profile = profile, let device = device, let query = profile["layoutQuery"] as? Int,
              let report = profile["reportID"] as? Int, let size = profile["reportSize"] as? Int else { throw SupportError.message("RGB information interface unavailable") }
        try instruction(query)
        var response = [UInt8](repeating: 0, count: size)
        response[0] = UInt8(report)
        var length = size
        let ret = response.withUnsafeMutableBufferPointer { IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(report), $0.baseAddress!, &length) }
        guard ret == 0, length > 4, response[0] == UInt8(report), response[4] <= 41 else {
            throw SupportError.message(String(format: localizedMessage("RGB layout query failed (0x%08x); no LED map will be guessed"), ret))
        }
        layout = response[4] == 41 ? "Keyboard Japan" : (16...40).contains(response[4]) ? "Keyboard ISO" : "Keyboard ANSI"
        return Int(response[4])
    }
    private func enterSoftwareMode() throws {
        guard !softwareMode else { return }
        guard let profile = profile, let mode = profile["softwareMode"] as? Int else { throw SupportError.message("RGB mode missing") }
        try instruction(mode)
        softwareMode = true
    }
    func setZone(_ name: String, red: UInt8, green: UInt8, blue: UInt8) throws {
        try enterSoftwareMode()
        guard let profile = profile, let zones = profile["zones"] as? [String: [String: Any]],
              let zone = zones[name == "Keyboard" ? layout : name], let bank = zone["bank"] as? Int,
              let leds = zone["leds"] as? [[String: Any]] else { throw SupportError.message("RGB zone not defined for this layout") }
        let colors = leds.compactMap { ($0["id"] as? Int).map { ($0, red, green, blue) } }
        try setLEDs(bank: bank, colors: colors)
    }
    static func reports(profile: [String: Any], bank: Int, colors: [(Int, UInt8, UInt8, UInt8)]) throws -> [[UInt8]] {
        guard let size = profile["reportSize"] as? Int, size >= 4, size <= 4096,
              let limit = profile["maxLEDsPerPacket"] as? Int, limit > 0, limit <= (size - 4) / 4,
              let base = profile["instructionBase"] as? Int, (0...255).contains(base),
              bank >= 0, bank <= 255 - base,
              let report = profile["reportID"] as? Int, (0...255).contains(report),
              colors.allSatisfy({ (0...255).contains($0.0) }) else { throw SupportError.message("Invalid RGB packet profile or LED ID") }
        var packets: [[UInt8]] = []
        for start in stride(from: 0, to: colors.count, by: limit) {
            let part = Array(colors[start..<min(start + limit, colors.count)])
            var data = [UInt8](repeating: 0, count: size)
            data[0] = UInt8(report); data[1] = UInt8(base + bank); data[2] = UInt8(part.count)
            for (index, color) in part.enumerated() {
                let offset = 4 + index * 4
                data[offset] = UInt8(color.0); data[offset + 1] = color.1; data[offset + 2] = color.2; data[offset + 3] = color.3
            }
            packets.append(data)
        }
        return packets
    }
    static func effectColor(mode: String, base: (UInt8, UInt8, UInt8), elapsed: Double) -> (UInt8, UInt8, UInt8) {
        if mode == "Breathing" {
            let scale = 0.1 + 0.9 * (1 + cos(elapsed * .pi / 2)) / 2
            return (UInt8((Double(base.0) * scale).rounded()), UInt8((Double(base.1) * scale).rounded()), UInt8((Double(base.2) * scale).rounded()))
        }
        if mode == "Spectrum" {
            let position = max(0, elapsed).truncatingRemainder(dividingBy: 12) / 2
            let sector = Int(position)
            let fraction = position - Double(sector)
            let rising = UInt8((fraction * 255).rounded())
            let falling = UInt8(((1 - fraction) * 255).rounded())
            switch sector {
            case 0: return (255, rising, 0)
            case 1: return (falling, 255, 0)
            case 2: return (0, 255, rising)
            case 3: return (0, falling, 255)
            case 4: return (rising, 0, 255)
            default: return (255, 0, falling)
            }
        }
        return base
    }
    private func setLEDs(bank: Int, colors: [(Int, UInt8, UInt8, UInt8)]) throws {
        guard let profile = profile else { throw SupportError.message("RGB profile unavailable") }
        for packet in try Self.reports(profile: profile, bank: bank, colors: colors) { try send(packet) }
    }
    func importColors(_ data: Data) throws {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]],
              let zones = profile?["zones"] as? [String: [String: Any]] else { throw SupportError.message("Expected JSON: zone -> LED name or ID -> #RRGGBB") }
        // Validate the complete input before issuing any LED write.
        var batches: [(Int, [(Int, UInt8, UInt8, UInt8)])] = []
        for (name, colors) in values {
            guard let zone = zones[name == "Keyboard" ? layout : name], let bank = zone["bank"] as? Int,
                  let leds = zone["leds"] as? [[String: Any]] else { throw SupportError.message(localizedMessage("Unknown RGB zone: %@", name)) }
            var batch: [(Int, UInt8, UInt8, UInt8)] = []
            for (name, value) in colors {
                let allowed = leds.first { String($0["id"] as? Int ?? -1) == name || $0["name"] as? String == name }
                guard let id = allowed?["id"] as? Int, value.count == 7, value.first == "#",
                      let color = UInt32(value.dropFirst(), radix: 16) else { throw SupportError.message(localizedMessage("Unknown LED or invalid color: %@", name)) }
                batch.append((id, UInt8((color >> 16) & 255), UInt8((color >> 8) & 255), UInt8(color & 255)))
            }
            batches.append((bank, batch))
        }
        try enterSoftwareMode()
        for (bank, colors) in batches { try setLEDs(bank: bank, colors: colors) }
    }
    func restoreHardwareMode(force: Bool = false) throws {
        guard softwareMode || force else { return }
        guard let mode = profile?["hardwareMode"] as? Int else { throw SupportError.message("RGB factory mode interface unavailable") }
        try instruction(mode)
        softwareMode = false
    }
    deinit {
        try? restoreHardwareMode()
        if let device = device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager = manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }
}

final class LegionHotkeys {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var manager: IOHIDManager?
    private var mapping: [String: String] = [:]
    private var consumer: [String: String] = [:]
    private var printKeys: [Int] = []
    private var physicalFnKeycode: Int?
    private var physicalFnDown = false
    private var consumedKeys: Set<Int> = []
    private var repeatableActions: Set<String> = []
    static func rawAction(keycode: Int, physicalFnDown: Bool, mapping: [String: String]) -> String? {
        physicalFnDown ? mapping[String(keycode)] : nil
    }
    var action: ((String) -> Void)?
    func start(profileID: String) throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw SupportError.message("Enable Accessibility for ReYogaSMC to map Fn hotkeys")
        }
        guard let profile = HardwareProfiles.hotkeys(for: profileID) else { throw SupportError.message("No hotkey profile available") }
        mapping = profile["keycodes"] as? [String: String] ?? [:]
        consumer = profile["consumerUsages"] as? [String: String] ?? [:]
        printKeys = profile["printScreenKeycodes"] as? [Int] ?? []
        physicalFnKeycode = profile["physicalFnKeycode"] as? Int
        repeatableActions = Set(profile["repeatableActions"] as? [String] ?? [])
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<LegionHotkeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == 0x52594b { return Unmanaged.passUnretained(event) }
                let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if type == .flagsChanged {
                    if key == controller.physicalFnKeycode { controller.physicalFnDown = event.flags.contains(.maskSecondaryFn) }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyUp && controller.consumedKeys.remove(key) != nil { return nil }
                let mapped = controller.printKeys.contains(key) ? "screenshot" :
                    LegionHotkeys.rawAction(keycode: key, physicalFnDown: controller.physicalFnDown, mapping: controller.mapping)
                guard let action = mapped else {
                    if UserDefaults.standard.bool(forKey: "DetailedLogging") && (event.flags.contains(.maskSecondaryFn) || controller.mapping[String(key)] != nil) {
                        ReYogaDiagnostics.shared.record("unmapped_key", ["keycode": key, "flags": event.flags.rawValue, "type": type.rawValue])
                    }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    controller.consumedKeys.insert(key)
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || controller.repeatableActions.contains(action) {
                        DispatchQueue.main.async { controller.action?(action) }
                    }
                }
                return nil
            }, userInfo: context), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { throw SupportError.message("macOS denied the hotkey event tap") }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == 0, let context = context, IOHIDValueGetIntegerValue(value) != 0 else { return }
            let controller = Unmanaged<LegionHotkeys>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_Consumer) else { return }
            let usage = IOHIDElementGetUsage(element)
            guard usage > 0, usage <= 0xffff else { return }
            ReYogaDiagnostics.shared.record("consumer_key", ["usage": usage])
            if let action = controller.consumer[String(usage)] { DispatchQueue.main.async { controller.action?(action) } }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        if opened != kIOReturnSuccess {
            stop()
            throw SupportError.message(String(format: localizedMessage("Consumer hotkeys unavailable (0x%08x); check Input Monitoring permission"), opened))
        }
        ReYogaDiagnostics.shared.record("hotkeys_started", ["profile": profile["id"] ?? "unknown", "consumerStatus": opened])
    }
    func stop() {
        if let tap = tap { CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        tap = nil; source = nil; manager = nil
        physicalFnDown = false
        consumedKeys.removeAll()
    }
    deinit { stop() }
}

struct PowerLimitInput {
    static func digits(_ input: String) -> String { String(input.filter { $0 >= "0" && $0 <= "9" }.prefix(5)) }
    static func isValid(_ input: String, range: [String: Int]) -> Bool {
        guard !input.isEmpty, input == digits(input), let value = Int(input),
              let low = range["Min"], let high = range["Max"], let step = range["Step"],
              low >= 0, high >= low, step > 0 else { return false }
        return value >= low && value <= high && (value - low) % step == 0
    }
}

// Read-only AppleSMC user-client adapter. Wire offsets describe its 80-byte
// ABI, not any laptop's EC layout. Key names are discovered from the service.
final class SMCTemperatureReader {
    struct Reading { let celsius: Double; let key: String; let source: String }
    private var connection: io_connect_t = 0
    private var keys: [String] = []
    private var cpuKeys: [String] = []
    private var cpuProvider = "SMC"
    private var gpuProvider = "SMC"
    private var info: [String: (size: Int, type: String)] = [:]
    private var nextDiscovery = Date.distantPast
    private(set) var reason = "SMC discovery pending"
    private(set) var cpuReason = "SMC discovery pending"
    private func providerExists(_ name: String) -> Bool {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(name))
        if service != 0 { IOObjectRelease(service); return true }
        let resources = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOResources"))
        guard resources != 0 else { return false }
        defer { IOObjectRelease(resources) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(resources, kIOServicePlane, &iterator) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            let matches = IOObjectConformsTo(child, name)
            IOObjectRelease(child)
            if matches != 0 { return true }
        }
        return false
    }
    static func cpuTemperatureKeys(available: [String], amd: Bool) -> [String] {
        let order = amd ? ["TC0E", "TC0F", "TC0P", "TC0T"] : ["TC0P", "TC0D", "TC0E", "TC0F", "TC0T"]
        return order.filter { available.contains($0) }
    }
    private func uint32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }
    private func write(_ value: UInt32, into data: inout [UInt8], at offset: Int) {
        for n in 0..<4 { data[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
    }
    private func fourCC(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func string(_ value: UInt32) -> String {
        String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) }, encoding: .ascii) ?? ""
    }
    private func call(key: String = "", command: UInt8, index: UInt32 = 0, size: Int = 0) throws -> [UInt8] {
        guard connection != 0 else { throw SupportError.message("AppleSMC service is unavailable") }
        var input = [UInt8](repeating: 0, count: 80)
        write(fourCC(key), into: &input, at: 0); write(UInt32(size), into: &input, at: 28)
        input[42] = command; write(index, into: &input, at: 44)
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let status = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { result in
                IOConnectCallStructMethod(connection, 2, bytes.baseAddress, bytes.count, result.baseAddress, &outputSize)
            }
        }
        guard status == kIOReturnSuccess, outputSize == 80, output[40] == 0 else {
            throw SupportError.message(String(format: localizedMessage("SMC read failed: transport=0x%08x result=%u bytes=%u"), status, output[40], outputSize))
        }
        return output
    }
    private func read(_ key: String) throws -> (String, [UInt8]) {
        if info[key] == nil {
            let result = try call(key: key, command: 9)
            let size = Int(uint32(result, 28))
            guard (1...32).contains(size) else { throw SupportError.message(localizedMessage("Invalid SMC value length for %@", key)) }
            info[key] = (size, string(uint32(result, 32)))
        }
        guard let descriptor = info[key] else { throw SupportError.message("SMC key descriptor unavailable") }
        let result = try call(key: key, command: 5, size: descriptor.size)
        return (descriptor.type, Array(result[48..<(48 + descriptor.size)]))
    }
    static func decodeTemperature(type: String, bytes: [UInt8]) -> Double? {
        guard type == "sp78", bytes.count == 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        let value = Double(raw) / 256
        return value > 0 && value < 150 ? value : nil
    }
    private func discover() throws {
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { throw SupportError.message("AppleSMC service is missing") }
            defer { IOObjectRelease(service) }
            let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
            guard status == kIOReturnSuccess else { throw SupportError.message(String(format: localizedMessage("AppleSMC access denied: 0x%08x"), status)) }
        }
        let countData = try read("#KEY").1
        guard countData.count == 4 else { throw SupportError.message("Invalid SMC key count") }
        let count = countData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 4096 else { throw SupportError.message("SMC key count exceeds discovery limit") }
        keys = []
        var available: [String] = []
        for index in 0..<count {
            let key = string(uint32(try call(command: 8, index: index), 0))
            available.append(key)
            if key.range(of: "^TG[0-9A-F][DP]$", options: .regularExpression) != nil { keys.append(key) }
        }
        keys.sort()
        // Multiple GPU indices need an explicit identity association. Never
        // silently label the first GPU as the active iGPU on a multi-GPU host.
        let amd = providerExists("SMCProcessorAMD")
        cpuProvider = amd ? "SMCProcessorAMD" : "SMC"
        gpuProvider = providerExists("SMCRadeonSensors") ? "SMCRadeonSensors" : "SMC"
        cpuKeys = Self.cpuTemperatureKeys(available: available, amd: amd)
        if Set(keys.filter { $0 != "TGDD" }.map { Array($0)[2] }).count > 1 {
            keys = []
            reason = "Multiple SMC GPUs found; sensor identity needs a reviewed mapping"
        } else { reason = keys.isEmpty ? "No GPU temperature keys published by the SMC plugins" : "GPU temperature keys discovered" }
        cpuReason = cpuKeys.isEmpty ? "No CPU temperature keys published by the SMC plugins" : "CPU temperature keys discovered"
    }
    func gpuTemperature() -> Reading? {
        do {
            if Date() >= nextDiscovery {
                nextDiscovery = Date().addingTimeInterval(30)
                try discover()
            }
            for key in keys {
                guard let value = try? read(key) else { continue }
                if let temperature = Self.decodeTemperature(type: value.0, bytes: value.1) {
                    reason = localizedMessage("Reading %@ published by %@", key, gpuProvider)
                    return Reading(celsius: temperature, key: key, source: "\(gpuProvider) / \(key)")
                }
            }
            if !keys.isEmpty { reason = "GPU SMC sensor returned zero, an invalid value or an unsupported encoding" }
        } catch {
            reason = error.localizedDescription
            close(); nextDiscovery = Date().addingTimeInterval(30)
        }
        return nil
    }
    func cpuTemperature() -> Reading? {
        do {
            if Date() >= nextDiscovery {
                nextDiscovery = Date().addingTimeInterval(30)
                try discover()
            }
            for key in cpuKeys {
                guard let value = try? read(key) else { continue }
                if let temperature = Self.decodeTemperature(type: value.0, bytes: value.1) {
                    cpuReason = localizedMessage("Reading %@ published by %@", key, cpuProvider)
                    return Reading(celsius: temperature, key: key, source: "\(cpuProvider) / \(key)")
                }
            }
            if !cpuKeys.isEmpty { cpuReason = "CPU SMC sensor returned an invalid value or unsupported encoding" }
        } catch {
            cpuReason = error.localizedDescription
            close(); nextDiscovery = Date().addingTimeInterval(30)
        }
        return nil
    }
    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0; keys = []; cpuKeys = []; info = [:]
    }
    deinit { close() }
}

public struct BatteryDetail: Identifiable, Equatable {
    public let id: Int
    let label: String
    let present: Bool
    let cycleCount: Int?
    let temperature: String?
    let manufactureDate: String?
    let identifier: String?
    let critical: Bool
    let source: String

    init(index: Int, properties: [String: Any], source: String = "Lenovo ACPI") {
        id = index
        label = localizedMessage("Battery %@", String(index + 1))
        cycleCount = (properties["Cycle count"] as? String).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        temperature = properties["Temperature"] as? String
        manufactureDate = properties["Manufacture date"] as? String
        let rawIdentifier = properties["ID"] as? String
        identifier = rawIdentifier.flatMap { value in
            let compact = value.replacingOccurrences(of: " ", with: "")
            return compact.isEmpty || Set(compact) == ["0"] ? nil : value
        }
        critical = properties["Critical"] as? Bool ?? false
        present = cycleCount != nil || temperature != nil || identifier != nil || critical
        self.source = source
    }

    static func fallback(index: Int, snapshot: LiveBatterySnapshot) -> BatteryDetail {
        BatteryDetail(index: index, properties: [:], source: snapshot.source)
    }
}

public struct LiveBatterySnapshot: Equatable {
    let percent: Int?
    let currentCapacity: Int?
    let maximumCapacity: Int?
    let designCapacity: Int?
    let externalPower: Bool?
    let charging: Bool?
    let fullyCharged: Bool?
    let installed: Bool?
    let milliamps: Int?
    let voltage: Double?
    let temperatureCelsius: Double?
    let cycleCount: Int?
    let health: String?
    let manufacturer: String?
    let deviceName: String?
    let serial: String?
    let timeToEmpty: Int?
    let timeToFull: Int?
    let adapterWatts: Double?
    let updatedAt: Date?
    let rawFields: [String: String]
    let source: String

    var healthPercent: Double? {
        guard let maximum = maximumCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(maximum) / Double(design) * 100
    }
    var watts: Double? {
        guard let voltage = voltage, let current = milliamps else { return nil }
        return voltage * Double(current) / 1000
    }
    var state: String {
        if installed == false { return "Not installed" }
        if charging == true { return "Charging" }
        if let current = milliamps, current < 0 { return "Discharging" }
        if fullyCharged == true { return "Fully charged" }
        if externalPower == true && charging == false { return "Connected - not charging" }
        return "Unavailable"
    }
    init(properties: [String: Any]) {
        let nested = properties["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? {
            guard let n = (properties[key] ?? nested[key]) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let value = n.doubleValue
            return value.isFinite ? value : nil
        }
        func capacity(_ key: String) -> Int? {
            guard let value = number(key), value >= 0, value <= 1_000_000 else { return nil }
            return Int(value.rounded())
        }
        func text(_ key: String) -> String? {
            guard let value = (properties[key] ?? nested[key]) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        // MaxCapacity=100 may be a normalized percentage, not a physical mAh value.
        let rawCurrent = capacity("AppleRawCurrentCapacity")
        let rawMaximum = capacity("AppleRawMaxCapacity").flatMap { $0 > 0 ? $0 : nil }
        let normalCurrent = capacity("CurrentCapacity")
        let normalMaximum = capacity("MaxCapacity").flatMap { $0 > 0 ? $0 : nil }
        currentCapacity = rawCurrent ?? (normalMaximum != 100 ? normalCurrent : nil)
        maximumCapacity = rawMaximum ?? (normalMaximum != 100 ? normalMaximum : nil)
        if let current = rawCurrent, let maximum = rawMaximum {
            percent = Int(min(100, max(0, (Double(current) / Double(maximum) * 100).rounded())))
        } else if let current = normalCurrent, let maximum = normalMaximum {
            percent = Int(min(100, max(0, (Double(current) / Double(maximum) * 100).rounded())))
        } else { percent = nil }
        designCapacity = capacity("DesignCapacity").flatMap { $0 > 0 ? $0 : nil }
        externalPower = properties["ExternalConnected"] as? Bool
        charging = properties["IsCharging"] as? Bool
        fullyCharged = properties["FullyCharged"] as? Bool
        installed = properties["BatteryInstalled"] as? Bool
        let amperage = number("InstantAmperage") ?? number("Amperage")
        // Some providers encode a signed current in an unsigned 16/32-bit register.
        let signed = amperage.map { value -> Double in
            if (32768.0...65535.0).contains(value) { return value - 65536 }
            if (2147483648.0...4294967295.0).contains(value) { return value - 4294967296 }
            return value
        }
        milliamps = signed.flatMap { (-100_000...100_000).contains($0) ? Int($0) : nil }
        voltage = number("Voltage").flatMap { (1...100_000).contains($0) ? $0 / 1000 : nil }
        // Smart Battery Temperature uses tenths of a kelvin.
        temperatureCelsius = number("Temperature").flatMap { value in
            let celsius = value / 10 - 273.15
            return (-40...120).contains(celsius) ? celsius : nil
        }
        cycleCount = capacity("CycleCount").flatMap { $0 <= 100_000 ? $0 : nil }
        health = text("Health") ?? text("BatteryHealth")
        manufacturer = text("Manufacturer")
        deviceName = text("DeviceName")
        serial = text("Serial") ?? text("BatterySerialNumber")
        func minutes(_ key: String) -> Int? {
            guard let value = number(key), value >= 0, value < 0x8000 else { return nil }
            return Int(value)
        }
        timeToEmpty = minutes("AvgTimeToEmpty") ?? minutes("TimeRemaining")
        timeToFull = minutes("AvgTimeToFull")
        let adapter = properties["AdapterDetails"] as? [String: Any]
        adapterWatts = ((adapter?["Watts"] as? NSNumber)?.doubleValue).flatMap { $0 > 0 && $0 < 2000 ? $0 : nil }
        updatedAt = number("UpdateTime").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        rawFields = properties.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
            else if let value = pair.value as? NSNumber { result[pair.key] = value.stringValue }
            else if pair.key == "BatteryData" || pair.key == "AdapterDetails" || pair.key == "ChargerData" {
                result[pair.key] = String(describing: pair.value)
            }
        }
        source = "AppleSmartBattery"
    }

    var summary: String {
        var parts: [String] = []
        if let percent = percent { parts.append("\(percent)%") }
        if let external = externalPower { parts.append(external ? "AC power" : "Battery power") }
        if charging == true { parts.append("Charging") }
        else if let milliamps = milliamps, milliamps < 0 { parts.append("Discharging") }
        else if charging == false && externalPower == true { parts.append("Not charging") }
        if let milliamps = milliamps { parts.append(localizedMessage("%@ mA", String(milliamps))) }
        return parts.map { localizedMessage($0) }.joined(separator: " - ")
    }

    static func read() -> LiveBatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var values: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &values, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let properties = values?.takeRetainedValue() as NSDictionary? as? [String: Any] else { return nil }
        return LiveBatterySnapshot(properties: properties)
    }
}
