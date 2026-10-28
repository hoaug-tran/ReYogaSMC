import Foundation
import ApplicationServices
import IOKit

// Borrowed service; export retains it on main before dispatching collection.
struct HardwareDiagnosticSnapshot {
    let service: io_service_t
    let metadata: [String: Any]
}

enum HardwareDiagnosticsExporter {
    static func snapshot(for manager: HardwareManager, cpuSampleTime: TimeInterval) -> HardwareDiagnosticSnapshot {
        let metadata: [String: Any] = ["schemaVersion": 1, "model": manager.modelName, "smbiosModel": manager.smbiosModel, "modelSource": manager.modelSource, "modelWarning": manager.modelWarning, "cpu": manager.cpuBrand,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown", "installationPath": Bundle.main.bundlePath,
            "accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(),
            "rgbReason": manager.rgbStatus.reason, "hotkeyProfile": manager.hotkeyProfileID, "telemetry": manager.telemetryStatus, "battery": manager.batterySummary,
            "batteryProviderFields": manager.liveBattery?.rawFields ?? [:],
            "cpuTemperature": manager.cpuTemp, "cpuTemperatureSource": manager.cpuTemperatureSource,
            "cpuSampleUptime": cpuSampleTime, "thinkFanCurveSupported": manager.thinkFanCurveSupported,
            "thinkFanCurves": [manager.fanHelper, manager.fanHelper2]
                .compactMap { fan -> [String: Any]? in
                    guard let fan = fan else { return nil }
                    return ["fan": fan.main ? 0 : 1, "enabled": fan.curveEnabled, "status": fan.curveStatus, "stopReason": fan.curveStopReason,
                        "accessReady": fan.enable, "requestedControl": fan.savedLevel, "rpm": fan.rpm ?? -1,
                        "points": fan.curvePoints.map { ["temperature": $0.temperature, "level": $0.level] }]
                }]
        return HardwareDiagnosticSnapshot(service: manager.service, metadata: metadata)
    }

    static func export(queue: DispatchQueue, to output: URL, capture: () -> HardwareDiagnosticSnapshot,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        let snapshot = capture()
        let metadata = snapshot.metadata
        let handle = snapshot.service
        if handle != 0 { IOObjectRetain(handle) }
        queue.async {
            defer { if handle != 0 { IOObjectRelease(handle) } }
            let keys = ["DYTC", "Battery 0", "Battery 1", "IOClass", "SafeMode", "NativeTelemetryProfile", "NativeTelemetryReason", "FirmwareDSDTSHA256", "SensorSources", "BatteryIndex", "ChargeStartThreshold", "ChargeStopThreshold", "BatteryModeRaw", "ConservationMode", "RapidChargeMode", "BatteryStateSchemaVersion", "ConservationStateMask", "RapidChargeStateMask", "VersionInfo", "FeatureStatus", "SensorStatus", "LastControlResult", "ControlProtocolVersion",
                        "ACPIBridgeVersion", "ACPIBridgeProfile", "ACPIBridgeProfileName", "ProfileMatchState", "ProfileMatchStage", "ProfileMatchReason", "ProfileMatchProfilesChecked", "ProfileMatchOEMMatches", "FirmwareDSDTOEMTableID", "FirmwareDSDTLength", "FirmwareDSDTChecksum", "FirmwareMachineType", "FirmwareBIOSFamily", "FirmwareIdentityConflict", "ACPIBridgeReason", "ThinkFanProtocolVersion", "ThinkFanStatus", "ThinkFanAccessFailed", "CPUPowerPendingProfile", "CPUPowerRestoreReason", "FanRestoreReason", "HardwareProfile", "HardwareProfileName", "PowerLimitRanges", "YLogoRawState", "YLogoRawBrightness", "PortLightingRawState", "PortLightingRawBrightness", "FanFullSpeedRaw", "FanFullSpeedECResult", "FanFullSpeedCommandBackend", "LightingControlOwner", "LogoLightingCapability", "PortLightingCapability", "LightingCommandStage", "SensorSampleSequence", "SensorSampleTimeMS",
                        "Fan1RPM", "Fan2RPM", "Fan1TargetRPM", "Fan2TargetRPM", "FanControlMode", "CPUTemp", "GPUTemp"]
            let snapshot: NSDictionary = handle != 0 ? getProperties(handle) ?? [:] : [:]
            var driver: [String: Any] = [:]
            for key in keys { if let value = snapshot[key] { driver[key] = value } }
            var report = metadata
            report["driver"] = driver
            report["diagnosticSchemaVersion"] = 2
            report["captureTime"] = ISO8601DateFormatter().string(from: Date())
            report["captureUptimeSeconds"] = ProcessInfo.processInfo.systemUptime
            report["driverConnectionPresent"] = handle != 0
            report["driverRegistry"] = DiagnosticSnapshot.value(snapshot)
            report["expectedDriverFieldsMissing"] = keys.filter { snapshot[$0] == nil }
            report["collectionPolicy"] = "Passive registry snapshot; no EC sweep, MSR writes, or thermal-policy changes. Missing fields are not measured zero."
            report["collectionLimitations"] = ["CPU package power, PL1/PL2 and hardware throttle reasons require a separate supported measurement tool", "ACPI tables can contain device identifiers; review before sharing", "No system-wide log or unrelated user preferences collected"]
            if handle != 0, snapshot["ACPIExportVersion"] as? Int == 1 {
                let status = IORegistryEntrySetCFProperty(handle, "ExportDSDT" as CFString, kCFBooleanTrue)
                let table = IORegistryEntryCreateCFProperty(handle, "ExportedDSDT" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
                _ = IORegistryEntrySetCFProperty(handle, "ExportDSDT" as CFString, kCFBooleanFalse)
                if status == kIOReturnSuccess, let table = table, table.count >= 36, table.count <= 1024 * 1024,
                   table.prefix(4) == Data("DSDT".utf8) {
                    report["DSDT"] = table
                } else {
                    report["ACPIExportError"] = String(format: localizedMessage("DSDT unavailable (0x%08x)"), status)
                }
            }
            ReYogaDiagnostics.shared.export(report, to: output, completion: completion)
        }
    }
}
