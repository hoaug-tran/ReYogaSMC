import Foundation
import IOKit

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
        critical = (properties["Critical"] as? Bool) ?? false
        present = cycleCount != nil || temperature != nil || identifier != nil || critical
        self.source = source
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
        let nested = (properties["BatteryData"] as? [String: Any]) ?? [:]
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

        let signed = amperage.map { value -> Double in
            if (32768.0...65535.0).contains(value) { return value - 65536 }
            if (2147483648.0...4294967295.0).contains(value) { return value - 4294967296 }
            return value
        }
        milliamps = signed.flatMap { (-100_000...100_000).contains($0) ? Int($0) : nil }
        voltage = number("Voltage").flatMap { (1...100_000).contains($0) ? $0 / 1000 : nil }

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
