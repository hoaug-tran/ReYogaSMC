import Foundation
import IOKit
import IOKit.hid

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
        let profiles = HardwareProfiles.all().filter { $0["kind"] as? String == "rgb" }.compactMap(RGBMatchProfile.init)
        guard !profiles.isEmpty else { return }
        let matchers: [NSDictionary] = profiles.flatMap { profile in
            [
                [kIOHIDVendorIDKey: profile.vendorID, kIOHIDProductIDKey: profile.productID,
                 kIOHIDDeviceUsagePageKey: profile.usagePage, kIOHIDDeviceUsageKey: profile.usage],
                [kIOHIDVendorIDKey: profile.vendorID, kIOHIDProductIDKey: profile.productID,
                 kIOHIDPrimaryUsagePageKey: profile.usagePage, kIOHIDPrimaryUsageKey: profile.usage],
                [kIOHIDVendorIDKey: profile.vendorID, kIOHIDProductIDKey: profile.productID]
            ]
        }
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == kIOReturnSuccess {
            defer { IOObjectRelease(iterator) }
            while true {
                let entry = IOIteratorNext(iterator)
                if entry == 0 { break }
                defer { IOObjectRelease(entry) }
                func number(_ keys: String...) -> Int? {
                    for key in keys {
                        if let val = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                            return val
                        }
                    }
                    return nil
                }
                let page = number(kIOHIDPrimaryUsagePageKey, kIOHIDDeviceUsagePageKey)
                let usage = number(kIOHIDPrimaryUsageKey, kIOHIDDeviceUsageKey)
                // Registry identity is useful even when macOS later denies opening HID.
                if let match = profiles.first(where: { $0.matches(vendorID: number(kIOHIDVendorIDKey),
                    productID: number(kIOHIDProductIDKey), usagePage: page,
                    usage: usage) }) {
                    matchedProfileID = match.profile["id"] as? String
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
        let candidates: [(device: IOHIDDevice, profile: RGBMatchProfile)] = devices.compactMap { candidate in
            let vendor = IOHIDDeviceGetProperty(candidate, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let product = IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let primaryPage = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            let devicePage = IOHIDDeviceGetProperty(candidate, kIOHIDDeviceUsagePageKey as CFString) as? Int
            let primaryUsage = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsageKey as CFString) as? Int
            let deviceUsage = IOHIDDeviceGetProperty(candidate, kIOHIDDeviceUsageKey as CFString) as? Int
            let size = IOHIDDeviceGetProperty(candidate, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? -1
            guard let match = profiles.first(where: { profile in
                guard profile.vendorID == vendor && profile.productID == product else { return false }
                let pageMatches = profile.usagePage == primaryPage || profile.usagePage == devicePage
                let usageMatches = profile.usage == primaryUsage || profile.usage == deviceUsage
                let sizeMatches = profile.reportSize == nil || size == -1 || profile.reportSize == size || profile.reportSize! + 1 == size
                return pageMatches && usageMatches && sizeMatches
            }) else { return nil }
            return (device: candidate, profile: match)
        }
        let uniqueProfiles = Set(candidates.compactMap { $0.profile.profile["id"] as? String })
        guard uniqueProfiles.count <= 1 else {
            matchedProfileID = nil
            status = HardwareFeatureStatus(available: false, reason: "Multiple matching RGB controllers found; disconnect additional controllers and retry", backend: "USB HID")
            return
        }
        for matched in candidates {
            let candidate = matched.device
            let match = matched.profile.profile
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
            ReYogaDiagnostics.shared.record("rgb_detected", ["vendor": matched.profile.vendorID, "product": matched.profile.productID, "reportSize": matched.profile.reportSize ?? -1, "profile": match["id"] ?? "unknown"])
            break
        }
    }
    private func send(_ bytes: [UInt8]) throws {
        guard let device = device, let profile = profile,
              let report = profile["reportID"] as? Int,
              bytes.count == profile["reportSize"] as? Int else { throw SupportError.message("RGB device disconnected or profile invalid") }
        let ret = bytes.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(report), $0.baseAddress!, bytes.count) }
        if ret != kIOReturnSuccess || UserDefaults.standard.bool(forKey: "DetailedLogging") {
            ReYogaDiagnostics.shared.record("rgb_transport", ["reportID": report, "bytes": bytes.count,
                "command": bytes.count > 1 ? Int(bytes[1]) : -1, "status": ret,
                "profile": matchedProfileID ?? "unmatched", "acknowledgement": "Transport only; not physical color readback"])
        }
        guard ret == kIOReturnSuccess else { throw SupportError.message(String(format: localizedMessage("RGB feature report failed: 0x%08x"), ret)) }
    }
    private func instruction(_ code: Int) throws {
        guard let profile = profile, let size = profile["reportSize"] as? Int, let report = profile["reportID"] as? Int else { throw SupportError.message("RGB profile unavailable") }
        var data = [UInt8](repeating: 0, count: size)
        data[0] = UInt8(report); data[1] = UInt8(code)
        try send(data)
    }

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
        guard data.count <= SavedRGBSettings.maximumImportBytes else { throw SupportError.message("RGB JSON exceeds 256 KiB") }
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]],
              let zones = profile?["zones"] as? [String: [String: Any]] else { throw SupportError.message("Expected JSON: zone -> LED name or ID -> #RRGGBB") }

        var batches: [(Int, [(Int, UInt8, UInt8, UInt8)])] = []
        for (name, colors) in values {
            guard let zone = zones[name == "Keyboard" ? layout : name], let bank = zone["bank"] as? Int,
                  let leds = zone["leds"] as? [[String: Any]] else { throw SupportError.message(localizedMessage("Unknown RGB zone: %@", name)) }
            var batch: [(Int, UInt8, UInt8, UInt8)] = []
            for (name, value) in colors {
                let allowed = leds.first { String(($0["id"] as? Int) ?? -1) == name || $0["name"] as? String == name ||
                    ($0["legacyNames"] as? [String])?.contains(name) == true }
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
