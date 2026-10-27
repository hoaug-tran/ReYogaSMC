import Foundation
import IOKit

let keys = [
    "IOClass", "SafeMode", "SafeModeReason", "ConservationCapability", "RapidChargeCapability", "BatteryCommand", "BatteryCommandResult", "FanCoolingCapability", "BatteryModeRaw", "ConservationMode", "RapidChargeMode", "BatteryStateSchemaVersion", "ConservationStateMask", "RapidChargeStateMask",
    "VersionInfo", "ForkName", "HardwareProfile", "HardwareProfileName", "NativeTelemetryProfile", "NativeTelemetryReason", "ProfileMatchState", "ProfileMatchStage", "ProfileMatchReason", "ProfileMatchProfilesChecked", "ProfileMatchOEMMatches", "FirmwareDSDTSHA256", "FirmwareDSDTOEMTableID", "FirmwareDSDTLength", "FirmwareDSDTChecksum", "FirmwareMachineType", "FirmwareBIOSFamily", "FirmwareIdentityConflict", "ACPIBridgeReason", "ThinkFanProtocolVersion", "ThinkFanStatus", "ThinkFanAccessFailed", "CPUPowerPendingProfile", "CPUPowerRestoreReason", "FanRestoreReason",
    "ControlProtocolVersion", "DiagnosticSchemaVersion", "ACPIBridgeVersion",
    "FeatureStatus", "SensorStatus", "SensorSampleSequence", "SensorSampleTimeMS",
    "TelemetrySource", "TelemetryIntervalMS", "DetailedTelemetry", "LastControlResult",
    "Fan1RPM", "Fan2RPM", "Fan1MaxRPM", "Fan2MaxRPM", "Fan1TargetRPM", "Fan2TargetRPM",
    "FanControlMode", "FanWritesValidated", "FanFullSpeed", "FanFullSpeedRaw",
    "FanFullSpeedECResult", "FanFullSpeedCommandBackend",
    "CPUTemp", "GPUTemp", "CPUBoostPower", "CPUSustainedPower", "CPUPowerModified",
    "DYTC", "LastDYTCCommand", "LastDYTCMutation", "DYTCBusyRejected", "PowerLimitRanges", "SmartFanMode", "YLogoStatus", "YLogoRawState", "YLogoRawBrightness",
    "LightingControlOwner", "LogoLightingCapability", "PortLightingCapability", "LightingCommandStage",
    "PortLighting", "PortLightingRawState", "PortLightingRawBrightness"
]
func jsonValue(_ value: Any) -> Any {
    if let data = value as? Data { return ["encoding": "base64", "data": data.base64EncodedString()] }
    if let dict = value as? [String: Any] { return dict.mapValues(jsonValue) }
    if let array = value as? [Any] { return array.map(jsonValue) }
    return value
}
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty && (arguments.count != 2 || arguments[0] != "--output") {
    fputs("Usage: swift Scripts/diagnose.swift [--output report.json]\n", stderr)
    exit(2)
}
let providers = ["IdeaVPC", "ThinkVPC", "DYVPC", "ReYogaHIDD"]
let service = providers.lazy.map { (provider: String) -> io_service_t in
    provider.withCString { IOServiceGetMatchingService(0, IOServiceMatching($0)) }
}.first { $0 != 0 } ?? 0
var report: [String: Any] = ["schema_version": 1, "time": ISO8601DateFormatter().string(from: Date()),
                           "os": ProcessInfo.processInfo.operatingSystemVersionString,
                           "mode": "Passive registry samples; no firmware commands sent"]
if service == 0 {
    report["driver"] = ["status": "unavailable", "reason": "No supported firmware control service found"]
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
    let data = try JSONSerialization.data(withJSONObject: jsonValue(report), options: [.prettyPrinted, .sortedKeys])
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
