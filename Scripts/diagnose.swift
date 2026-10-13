import Foundation
import IOKit

let keys = [
    "VersionInfo", "ForkName", "HardwareProfile", "HardwareProfileName",
    "ControlProtocolVersion", "DiagnosticSchemaVersion", "ACPIBridgeVersion",
    "FeatureStatus", "SensorStatus", "SensorSampleSequence", "SensorSampleTimeMS",
    "TelemetrySource", "TelemetryIntervalMS", "DetailedTelemetry", "LastControlResult",
    "Fan1RPM", "Fan2RPM", "Fan1MaxRPM", "Fan2MaxRPM", "Fan1TargetRPM", "Fan2TargetRPM",
    "FanControlMode", "FanWritesValidated", "FanFullSpeed", "FanFullSpeedRaw",
    "FanFullSpeedECResult", "FanFullSpeedCommandBackend",
    "CPUTemp", "GPUTemp", "CPUBoostPower", "CPUSustainedPower", "CPUPowerModified",
    "PowerLimitRanges", "SmartFanMode", "YLogoStatus", "YLogoRawState", "YLogoRawBrightness",
    "PortLighting", "PortLightingRawState", "PortLightingRawBrightness"
]
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty && (arguments.count != 2 || arguments[0] != "--output") {
    fputs("Usage: swift Scripts/diagnose.swift [--output report.json]\n", stderr)
    exit(2)
}
let service = IOServiceGetMatchingService(0, IOServiceMatching("IdeaVPC"))
var report: [String: Any] = ["schema_version": 1, "time": ISO8601DateFormatter().string(from: Date()),
                           "os": ProcessInfo.processInfo.operatingSystemVersionString,
                           "mode": "Passive registry samples; no firmware commands sent"]
if service == 0 {
    report["driver"] = ["status": "unavailable", "reason": "IdeaVPC service not found"]
} else {
    defer { IOObjectRelease(service) }
    var samples: [[String: Any]] = []
    for index in 0..<3 {
        var properties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        var sample: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "registry_status": status]
        if status == kIOReturnSuccess, let properties = properties,
           let values = properties.takeRetainedValue() as NSDictionary as? [String: Any] {
            for key in keys { sample[key] = values[key] }
        } else {
            sample["reason"] = "Driver properties could not be read"
        }
        samples.append(sample)
        if index < 2 { Thread.sleep(forTimeInterval: 2) }
    }
    report["driver"] = ["status": "connected", "samples": samples]
}
do {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if arguments.count == 2 {
        let path = URL(fileURLWithPath: arguments[1])
        guard !FileManager.default.fileExists(atPath: path.path) else {
            fputs("Output exists; choose a new filename\n", stderr); exit(2)
        }
        try data.write(to: path, options: .withoutOverwriting)
        print("Report: \(path.path)")
    } else {
        FileHandle.standardOutput.write(data)
        print()
    }
} catch {
    fputs("Report failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
