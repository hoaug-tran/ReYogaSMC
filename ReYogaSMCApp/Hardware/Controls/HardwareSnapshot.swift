import Foundation

struct HardwareSnapshot {
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    static func fanRPM(_ value: Any?) -> Int {
        guard let value = integer(value), (0..<0xffff).contains(value) else { return -1 }
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
        guard let range = value as? [String: Any], let current = integer(current),
              let low = integer(range["Min"]), let high = integer(range["Max"]), let step = integer(range["Step"]),
              low >= 0, high >= low, high <= Int(UInt32.max), step > 0,
              current >= low, current <= high else { return nil }
        return ["Min": low, "Max": high, "Step": step]
    }

    static func stale(_ props: NSDictionary, observedAge: TimeInterval, uptime: TimeInterval) -> Bool {
        let interval = (props["TelemetryIntervalMS"] as? Int) ?? 0
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

        guard feature.backend == "ACPI profile" else { return feature }
        guard feature.available, bridgeVersion >= 2 else { return unavailable }
        if key != "FanControlMode" && !writesValidated {
            return HardwareFeatureStatus(available: false,
                reason: "Manual fan minimums have not been validated for this firmware.", backend: feature.backend)
        }
        return feature
    }
}
