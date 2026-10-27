import Foundation
import Combine
import IOKit
import AppKit
import ApplicationServices
import os.log

public final class HardwareManager: ObservableObject {
    public static let shared = HardwareManager()

    @Published public var modelName: String = ""
    @Published public var smbiosModel: String = ""
    @Published public var modelSource: String = "SMBIOS"
    @Published public var modelWarning: String = ""
    @Published public var cpuBrand: String = ""
    @Published public var driverVersion = "Unavailable"
    @Published public var profileMatchState = "Unavailable"
    @Published public var firmwareProfileID = ""
    public var localizedModelName: String {
        ["Lenovo Laptop", "Unknown Laptop"].contains(modelName) ? localizedMessage(modelName) : modelName
    }
    public var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? localizedMessage("Unknown")
    }
    public var appRevision: String {
        Bundle.main.object(forInfoDictionaryKey: "ReYogaGitRevision") as? String ?? localizedMessage("Unknown revision")
    }
    private var featurePollingSupported = false
    private var lastFirmwareRefresh = Date.distantPast

    @Published public var hasDualFan: Bool = false
    @Published public var hasPowerProfiles: Bool = false
    @Published public var hasConservation: Bool = false
    @Published public var hasRapidCharge: Bool = false
    @Published public var hasOverDrive: Bool = false
    @Published public var hasTouchpadLock: Bool = false
    @Published public var hasYLogo: Bool = false
    @Published public var hasPortLighting: Bool = false
    @Published public var hasAlwaysOnUSB: Bool = false

    @Published public var fan1RPM: Int = -1
    @Published public var fan2RPM: Int = -1
    @Published public var cpuTemp: Double = -1
    @Published public var gpuTemp: Double = -1
    @Published public var powerProfile: Int = 0
    @Published public var alwaysOnUSBState: Int = 0
    @Published public var isConservationOn: Bool = false
    @Published public var isRapidChargeOn: Bool = false
    @Published public var isOverDriveOn: Bool = false
    @Published public var isTouchpadLocked: Bool = false
    @Published public var isYLogoOn: Bool = false
    @Published public var isPortLightingOn: Bool = false
    @Published public var providerClass = ""
    @Published public var isFnLocked = false
    @Published public var keyboardBacklight = -1
    @Published public var chargeStartThreshold = -1
    @Published public var chargeStopThreshold = -1
    @Published public var batteryIndex = 1
    @Published public var batteryIndividualAddressing = false
    @Published public var isConnected: Bool = false
    public enum DriverState: Equatable { case checking, ready, missing, unavailable }
    @Published public var driverState: DriverState = .checking
    @Published public var driverMessage = "Checking the hardware driver…"
    private var cpuUsesSMC = false
    private var gpuUsesSMC = false
    @Published public var cpuTemperatureSource = "Firmware CPU sensor"
    @Published public var cpuTemperatureReason = "Waiting for sensors"
    @Published public var gpuTemperatureSource = "No GPU temperature source"
    @Published public var gpuTemperatureReason = "Waiting for sensors"
    @Published public var cpuPowerModified = false
    @Published public var fanLabels = ["Fan 1", "Fan 2"]
    private let smcTemperatures = SMCTemperatureReader()
    public func setDriverState(_ state: DriverState, message: String) {
        driverState = state; driverMessage = message
        ReYogaDiagnostics.shared.record("driver_state", ["state": String(describing: state), "message": message])
    }

    private var connectionGeneration: UInt64 = 0
    public var service: io_service_t = 0 {
        didSet {
            connectionGeneration &+= 1
            refreshInFlight = false
            isApplying = false; applyingControl = nil
            isConnected = service != 0
            if isConnected {
                detectHardwareInfo()
                refreshAll()
                startMonitoring()
            } else {
                stopMonitoring()
                queuedControls.removeAll(); pendingFanChecks.removeAll()
                lastSampleSequence = -1; lastSampleDate = .distantPast
                powerProfile = 0; powerRanges = [:]; cpuPowerModified = false
                isConservationOn = false; isRapidChargeOn = false; isOverDriveOn = false; isTouchpadLocked = false
                isFnLocked = false; keyboardBacklight = -1
                chargeStartThreshold = -1; chargeStopThreshold = -1; batteryIndex = 1; batteryIndividualAddressing = false
                manualFanMode = false; fan1TargetRPM = -1; fan2TargetRPM = -1; fan1MaxRPM = 0; fan2MaxRPM = 0; fanStepsRPM = [0, 0]
                cpuBoostWatts = 0; cpuSustainedWatts = 0; alwaysOnUSBState = 0
                hotkeysRestoreAttempted = false; hotkeyProfileID = ""
                fan1RPM = -1; fan2RPM = -1; cpuTemp = -1; gpuTemp = -1
                hotkeys.stop(); hotkeysEnabled = false
                batteryDetails = []
                liveBattery = nil
                featureStatus = [:]
                providerClass = ""
                driverVersion = "Unavailable"; profileMatchState = "Unavailable"; firmwareProfileID = ""
                featurePollingSupported = false; lastFirmwareRefresh = .distantPast
                fanLabels = ["Fan 1", "Fan 2"]
                hasDualFan = false; hasPowerProfiles = false; hasConservation = false; hasRapidCharge = false
                hasOverDrive = false; hasTouchpadLock = false; hasYLogo = false; hasPortLighting = false; hasAlwaysOnUSB = false
                preferenceIdentity = ""
                modelName = detectedIdentity.name; modelSource = detectedIdentity.source; modelWarning = ""
                telemetryStatus = "Driver unavailable"
                startMonitoring()
                initialized = false
                controlsRestoreAttempted = false
                restoringControls.removeAll()
            }
        }
    }

    private var timer: Timer?
    public init() {
        detectHardwareInfo()
        if !CommandLine.arguments.contains("--render-ui") && !CommandLine.arguments.contains("--check-missing-driver") { startMonitoring() }
        hotkeys.action = { [weak self] action in self?.performHotkey(action) }
        guard !CommandLine.arguments.contains("--render-ui"), !CommandLine.arguments.contains("--check-missing-driver") else { return }
        hardwareQueue.async {
            self.rgbController.detect()
            DispatchQueue.main.async {
                self.rgbStatus = self.rgbController.status
                self.hasRGBHardware = self.rgbController.matchedProfileID != nil
                if let profile = self.rgbController.matchedProfileID { self.hotkeyProfileID = profile }
                self.refreshPermissions()
                self.restoreSavedRGB()
            }
        }
    }

    private func systemString(_ key: String) -> String {
        var size: size_t = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return "" }
        var data = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(key, &data, &size, nil, 0) == 0 else { return "" }
        return String(cString: data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func detectHardwareInfo() {
        cpuBrand = systemString("machdep.cpu.brand_string")
        smbiosModel = ""
        let platform = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if platform != 0 {
            defer { IOObjectRelease(platform) }
            for key in ["product-name", "model"] {
                let value = IORegistryEntryCreateCFProperty(platform, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                if let name = LaptopIdentity.text(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    smbiosModel = name
                    break
                }
            }
        }
        if smbiosModel.isEmpty { smbiosModel = systemString("hw.model") }
        detectedIdentity = LaptopIdentity.read()
        modelName = detectedIdentity.name
        modelSource = detectedIdentity.source
        modelWarning = ""
    }

    private var detectedIdentity = LaptopIdentity(name: "Unknown Laptop", source: "Hardware identity")

    private let hardwareQueue = DispatchQueue(label: "org.reyogasmc.hardware", qos: .utility)
    private var refreshInFlight = false
    private var lastBackgroundRefresh = Date.distantPast
    private var lastSampleSequence: Int = -1
    private var lastSampleDate = Date.distantPast
    private var initialized = false
    private var preferenceIdentity = ""
    private var controlsRestoreAttempted = false
    private var restoringControls: [(String, SavedControlValue)] = []
    private var pendingFanChecks: [Int: (target: Int, deadline: Date)] = [:]
    @Published public var isApplying = false
    @Published public var applyingControl: String?
    private var queuedControls: [(String, Int, Bool, String, Bool)] = []
    @Published public var telemetryStatus = "Waiting for driver"
    @Published public var batterySummary = ""
    @Published public var liveBattery: LiveBatterySnapshot?
    @Published public var batteryDetails: [BatteryDetail] = []
    @Published public var featureStatus: [String: HardwareFeatureStatus] = [:]
    @Published public var cpuBoostWatts = 0
    @Published public var cpuSustainedWatts = 0
    @Published public var powerRanges: [String: [String: Int]] = [:]
    @Published public var manualFanMode = false
    @Published public var fan1TargetRPM = -1
    @Published public var fan2TargetRPM = -1
    @Published public var fanStepsRPM = [0, 0]
    @Published public var fan1MaxRPM = 0
    @Published public var fan2MaxRPM = 0
    private let rgbController = LegionRGBController()
    private let hotkeys = LegionHotkeys()
    @Published public var rgbStatus = HardwareFeatureStatus(available: false, reason: "RGB discovery pending", backend: "USB HID")
    @Published public var hasRGBHardware = false
    @Published public var rgbApplying = false
    @Published public var hotkeysEnabled = false
    @Published public var hotkeyStatus = "Off — native media keys remain active."
    @Published public var rgbMode = "Factory"
    private var rgbLogoEnabled = true
    private var hotkeysRestoreAttempted = false
    @Published public var hasAccessibilityPermission = false
    @Published public var hasInputMonitoringPermission = false
    @Published public var permissionStatus = ""
    private var rgbEffectTimer: DispatchSourceTimer?
    private var rgbEffectStart = Date()
    private var rgbColors: [String: (UInt8, UInt8, UInt8)] = [:]
    private var rgbEffect = "Factory"
    private var rgbRestoredProfile: String?
    private var rgbPerKey: Data?
    @Published public var hotkeyProfileID = ""
    @Published public var detailedLogging = UserDefaults.standard.bool(forKey: "DetailedLogging")

    public func startMonitoring() {
        stopMonitoring()
        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let delegate = NSApp.delegate as? AppDelegate
            let visible = delegate?.controlsWindow?.isVisible == true
            if visible || !self.pendingFanChecks.isEmpty || Date().timeIntervalSince(self.lastBackgroundRefresh) >= 2 {
                self.lastBackgroundRefresh = Date()
                self.refreshSnapshot(full: false)
            }
        }
        poll.tolerance = 0.05
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func refreshAll() { refreshSnapshot(full: true) }
    public func refreshMetrics() { refreshSnapshot(full: false) }

    private func refreshSnapshot(full: Bool) {
        guard !refreshInFlight else { return }
        if service == 0 { refreshIndependentSensors(); return }
        refreshInFlight = true
        let handle = service
        let generation = connectionGeneration
        IOObjectRetain(handle)
        let refreshFirmware = full ||
            ((providerClass == "ThinkVPC" || !featurePollingSupported) &&
             Date().timeIntervalSince(lastFirmwareRefresh) >= 2)
        if refreshFirmware { lastFirmwareRefresh = Date() }
        hardwareQueue.async {
            if refreshFirmware { _ = sendBoolean("Update", true, handle) }
            let snapshot = getProperties(handle)
            let battery = LiveBatterySnapshot.read()
            let smcCPU = self.smcTemperatures.cpuTemperature()
            let smcGPU = self.smcTemperatures.gpuTemperature()
            let cpuReason = self.smcTemperatures.cpuReason
            let smcReason = self.smcTemperatures.reason
            IOObjectRelease(handle)
            DispatchQueue.main.async {
                guard generation == self.connectionGeneration, handle == self.service else { return }
                self.refreshInFlight = false
                if let snapshot = snapshot {
                    let batteryStatus = battery?.summary ?? ""
                    if self.batterySummary != batteryStatus {
                        self.publish(\.batterySummary, batteryStatus)
                        ReYogaDiagnostics.shared.record("battery_status", ["state": batteryStatus])
                    }
                    var details: [BatteryDetail] = []
                    if let first = snapshot["Battery 0"] as? [String: Any] {
                        let detail = BatteryDetail(index: 0, properties: first)
                        if detail.present { details.append(detail) }
                    }
                    if let second = snapshot["Battery 1"] as? [String: Any] {
                        let detail = BatteryDetail(index: 1, properties: second)
                        if detail.present { details.append(detail) }
                    }
                    self.publish(\.batteryDetails, details)
                    self.publish(\.liveBattery, battery)
                    self.cpuUsesSMC = smcCPU != nil
                    self.gpuUsesSMC = smcGPU != nil
                    self.publish(\.cpuTemp, smcCPU.map { $0.celsius } ?? HardwareSnapshot.temperature(snapshot["CPUTemp"]))
                    self.publish(\.cpuTemperatureSource, smcCPU?.source ?? (snapshot["SensorSources"] as? [String: String])?["CPUTemp"] ?? "Firmware CPU sensor")
                    self.publish(\.cpuTemperatureReason, cpuReason)
                    if let reading = smcGPU {
                        self.publish(\.gpuTemp, reading.celsius)
                        self.publish(\.gpuTemperatureSource, reading.source)
                    }
                    if smcGPU == nil {
                        self.publish(\.gpuTemp, HardwareSnapshot.temperature(snapshot["GPUTemp"]))
                        self.publish(\.gpuTemperatureSource, self.gpuTemp > 0 ? (snapshot["SensorSources"] as? [String: String])?["GPUTemp"] ?? "Firmware GPU sensor" : "No GPU temperature source")
                    }
                    self.publish(\.gpuTemperatureReason, smcReason)
                    self.accept(snapshot)
                } else {
                    self.service = 0
                    self.setDriverState(.unavailable, message: "The hardware driver stopped responding. Retry the connection or check the driver log.")
                    (NSApp.delegate as? AppDelegate)?.closeDriverConnection()
                    self.telemetryStatus = "Driver unavailable"
                    self.featureStatus = [:]
                    ReYogaDiagnostics.shared.record("snapshot_failed", ["reason": "IORegistry read failed"])
                }
            }
        }
    }

    private func refreshIndependentSensors() {
        refreshInFlight = true
        let generation = connectionGeneration
        hardwareQueue.async {
            let battery = LiveBatterySnapshot.read()
            let cpu = self.smcTemperatures.cpuTemperature()
            let gpu = self.smcTemperatures.gpuTemperature()
            let cpuReason = self.smcTemperatures.cpuReason
            let gpuReason = self.smcTemperatures.reason
            DispatchQueue.main.async {
                guard generation == self.connectionGeneration, self.service == 0 else { return }
                self.refreshInFlight = false
                self.publish(\.liveBattery, battery)
                self.publish(\.batterySummary, battery?.summary ?? "")
                self.publish(\.cpuTemp, cpu.map { $0.celsius } ?? -1)
                self.publish(\.gpuTemp, gpu.map { $0.celsius } ?? -1)
                self.publish(\.cpuTemperatureSource, cpu?.source ?? "No CPU temperature source")
                self.publish(\.gpuTemperatureSource, gpu?.source ?? "No GPU temperature source")
                self.publish(\.cpuTemperatureReason, cpuReason)
                self.publish(\.gpuTemperatureReason, gpuReason)
            }
        }
    }

    private func publish<Value: Equatable>(_ path: ReferenceWritableKeyPath<HardwareManager, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func accept(_ props: NSDictionary) {
        publish(\.providerClass, props["IOClass"] as? String ?? "")
        publish(\.driverVersion, props["VersionInfo"] as? String ?? "Unavailable")
        publish(\.profileMatchState, props["ProfileMatchState"] as? String ?? "Not reported")
        publish(\.firmwareProfileID, props["HardwareProfile"] as? String ?? "")
        featurePollingSupported = props["FeaturePollingVersion"] as? Int == 1
        publish(\.isFnLocked, props["FnlockMode"] as? Bool ?? false)
        publish(\.keyboardBacklight, props["BacklightLevel"] as? Int ?? -1)
        publish(\.chargeStartThreshold, props["ChargeStartThreshold"] as? Int ?? -1)
        publish(\.chargeStopThreshold, props["ChargeStopThreshold"] as? Int ?? -1)
        publish(\.batteryIndex, props["BatteryIndex"] as? Int ?? 1)
        publish(\.batteryIndividualAddressing, props["BatteryIndividualAddressing"] as? Bool ?? false)
        publish(\.cpuPowerModified, props["CPUPowerModified"] as? Bool ?? false)
        if let profileID = props["HardwareProfile"] as? String,
           let labels = HardwareProfiles.all().first(where: { $0["id"] as? String == profileID })?["fan_labels"] as? [String], labels.count == 2 {
            publish(\.fanLabels, labels)
        } else { publish(\.fanLabels, ["Fan 1", "Fan 2"]) }
        let descriptors = props["FeatureStatus"] as? [String: [String: Any]] ?? [:]
        if let profile = props["HardwareProfile"] as? String { hotkeyProfileID = profile }
        else { hotkeyProfileID = rgbController.matchedProfileID ?? "" }
        let matchState = props["ProfileMatchState"] as? String ?? ""
        let sequence = props["SensorSampleSequence"] as? Int ?? -1
        let observationAge = sequence != lastSampleSequence ? 0 : Date().timeIntervalSince(lastSampleDate)
        let sampleIsStale = sequence >= 0 && HardwareSnapshot.stale(props,
            observedAge: observationAge, uptime: ProcessInfo.processInfo.systemUptime)
        let firmwareIdentity = props["FirmwareIdentityConflict"] as? Bool == true ? detectedIdentity :
            LaptopIdentity.resolve(strings: [props["FirmwareMachineType"] as? String ?? ""], pciIDs: [],
                                   lenovo: ["IdeaVPC", "ThinkVPC"].contains(props["IOClass"] as? String ?? ""))
        let displayIdentity = firmwareIdentity.name != "Lenovo Laptop" && firmwareIdentity.name != "Unknown Laptop" ? firmwareIdentity : detectedIdentity
        if let driverModelName = props["HardwareProfileName"] as? String, !driverModelName.isEmpty,
           ["exact", "identity_matched", "pci_matched"].contains(matchState) {
            publish(\.modelName, driverModelName)
            publish(\.modelSource, matchState == "pci_matched" ? "PCI subsystem ID" : "Lenovo firmware identity")
            publish(\.modelWarning, "")
        } else {
            let lenovo = ["IdeaVPC", "ThinkVPC"].contains(props["IOClass"] as? String ?? "")
            publish(\.modelName, displayIdentity.name == "Unknown Laptop" && lenovo ? "Lenovo Laptop" : displayIdentity.name)
            publish(\.modelSource, displayIdentity.source)
            let reason = props["ProfileMatchReason"] as? String ?? "Not reported"
            publish(\.modelWarning, ["conflict", "ambiguous"].contains(matchState) ? localizedMessage(reason) : "")
        }
        let protocolVersion = props["ControlProtocolVersion"] as? Int ?? 0
        var availability: [String: HardwareFeatureStatus] = [:]
        for key in HardwareFeatureStatus.catalog.keys {
            if let item = descriptors[key] {
                availability[key] = HardwareFeatureStatus(available: item["Available"] as? Bool == true,
                    reason: item["Reason"] as? String ?? "Driver did not provide a reason",
                    backend: item["Backend"] as? String ?? "Unknown")
            } else {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: protocolVersion == 0 ? "Boot the matching ReYogaSMC driver to verify support" : "No backend for this device",
                    backend: "Unavailable")
            }
        }
        if providerClass == "IdeaVPC" {
            for key in ["FanControlMode", "Fan1TargetRPM", "Fan2TargetRPM"] {
                availability[key] = HardwareSnapshot.manualFanFeature(availability[key], key: key,
                    bridgeVersion: props["ACPIBridgeVersion"] as? Int ?? 0,
                    writesValidated: props["FanWritesValidated"] as? Bool == true)
            }
        }
        let stateControls = ["SmartFanMode", "ConservationMode", "RapidChargeMode", "AlwaysOnUSBState", "FnlockMode", "BacklightLevel", "DisplayOverDrive", "TouchpadLock", "YLogoStatus", "PortLighting", "CPUBoostPower", "CPUSustainedPower", "FanControlMode", "Fan1TargetRPM", "Fan2TargetRPM"]
        for key in stateControls where availability[key]?.available == true && props[key] == nil {
            availability[key] = HardwareFeatureStatus(available: false,
                reason: "The driver did not provide a current value for this control.", backend: availability[key]?.backend ?? "Unavailable")
        }
        let reportedRanges = props["PowerLimitRanges"] as? [String: Any] ?? [:]
        var validatedRanges: [String: [String: Int]] = [:]
        for key in ["CPUBoostPower", "CPUSustainedPower"] {
            if let range = HardwareSnapshot.powerRange(reportedRanges[key], current: props[key]) {
                validatedRanges[key] = range
            } else if availability[key]?.available == true {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: "The driver did not provide a valid current power limit and adjustment range.", backend: availability[key]?.backend ?? "Unavailable")
            }
        }
        let fanSteps = [props["Fan1TargetRPMStep"] as? Int ?? 0, props["Fan2TargetRPMStep"] as? Int ?? 0]
        publish(\.fanStepsRPM, fanSteps)
        for (index, key) in ["Fan1TargetRPM", "Fan2TargetRPM"].enumerated() where availability[key]?.available == true {
            let maximum = HardwareSnapshot.fanRPM(props[index == 0 ? "Fan1MaxRPM" : "Fan2MaxRPM"])
            if maximum <= 0 || fanSteps[index] <= 0 || fanSteps[index] > maximum {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: "The driver did not provide a valid fan adjustment range and step.", backend: availability[key]?.backend ?? "Unavailable")
            }
        }
        if rgbStatus.available && rgbMode != "Factory" {
            availability["YLogoStatus"] = HardwareFeatureStatus(available: true,
                reason: "USB transmission only; the device does not report the physical LED state", backend: "USB HID")
        }
        let batteryProfile = HardwareProfiles.all().first { $0["id"] as? String == props["HardwareProfile"] as? String }
        let conservationMask = batteryProfile?["battery_conservation_mask"] as? Int
        let rapidMask = batteryProfile?["battery_rapidcharge_mask"] as? Int
        if let conservationMask = conservationMask, let rapidMask = rapidMask {
            let mappingMatches = [1, 4].contains(props["BatteryStateSchemaVersion"] as? Int ?? 0) &&
                props["ConservationStateMask"] as? Int == conservationMask && props["RapidChargeStateMask"] as? Int == rapidMask
            if mappingMatches {
                if let raw = props["BatteryModeRaw"] as? Int {
                    publish(\.isConservationOn, raw & conservationMask != 0)
                    publish(\.isRapidChargeOn, raw & rapidMask != 0)
                }
            }
            if !mappingMatches {
                for key in ["ConservationMode", "RapidChargeMode"] {
                    availability[key] = HardwareFeatureStatus(available: false,
                        reason: "The driver battery-state masks do not match the reviewed firmware profile", backend: "ACPI profile")
                }
            }
        }
        if sampleIsStale {
            for key in availability.keys where availability[key]?.available == true && availability[key]?.backend != "USB HID" {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: "The driver snapshot is stale. Refresh the connection before changing firmware controls.",
                    backend: availability[key]?.backend ?? "Unavailable")
            }
        }
        if availability != featureStatus {
            featureStatus = availability
            ReYogaDiagnostics.shared.record("capabilities", availability.mapValues { ["available": $0.available, "reason": $0.reason, "backend": $0.backend] })
        }
        func supported(_ key: String) -> Bool { availability[key]?.available == true }
        func number(_ key: String) -> Int { props[key] as? Int ?? -1 }
        func boolean(_ key: String) -> Bool { props[key] as? Bool ?? false }
        publish(\.hasConservation, supported("ConservationMode"))
        publish(\.hasRapidCharge, supported("RapidChargeMode"))
        publish(\.hasAlwaysOnUSB, supported("AlwaysOnUSBState"))
        publish(\.hasPowerProfiles, supported("SmartFanMode"))
        publish(\.hasOverDrive, supported("DisplayOverDrive"))
        publish(\.hasTouchpadLock, supported("TouchpadLock"))
        publish(\.hasYLogo, supported("YLogoStatus"))
        publish(\.hasPortLighting, supported("PortLighting"))
        publish(\.hasDualFan, number("Fan number") >= 0 ? number("Fan number") >= 2 : HardwareSnapshot.fanRPM(props["Fan2RPM"]) > 0)
        publish(\.fan1RPM, HardwareSnapshot.fanRPM(props["Fan1RPM"]))
        publish(\.fan2RPM, HardwareSnapshot.fanRPM(props["Fan2RPM"]))
        if !cpuUsesSMC { publish(\.cpuTemp, HardwareSnapshot.temperature(props["CPUTemp"])) }
        if !gpuUsesSMC {
            publish(\.gpuTemp, HardwareSnapshot.temperature(props["GPUTemp"]))
            publish(\.gpuTemperatureSource, number("GPUTemp") > 0 ? (props["SensorSources"] as? [String: String])?["GPUTemp"] ?? "Firmware GPU sensor" : "No GPU temperature source")
        }
        for (fan, check) in pendingFanChecks {
            let rpm = fan == 0 ? fan1RPM : fan2RPM
            if rpm >= Int(Double(check.target) * 0.9) {
                pendingFanChecks.removeValue(forKey: fan)
                ReYogaDiagnostics.shared.record("fan_minimum_measured", ["fan": fan, "target": check.target, "actualRPM": rpm])
            } else if Date() >= check.deadline {
                pendingFanChecks.removeValue(forKey: fan)
                let label = fanLabels.indices.contains(fan) ? fanLabels[fan] : localizedMessage("Fan %@", String(describing: fan + 1))
                let message = localizedMessage("%@: requested %@ RPM, measured %@. The minimum has not been reached.", localizedMessage(label), String(check.target), String(rpm))
                ReYogaDiagnostics.shared.record("fan_minimum_not_reached", ["fan": fan, "target": check.target, "actualRPM": rpm])
                showOSDRaw(message, duration: 4000)
            }
        }
        if conservationMask == nil || rapidMask == nil {
            publish(\.isConservationOn, boolean("ConservationMode"))
            publish(\.isRapidChargeOn, boolean("RapidChargeMode"))
        }
        publish(\.isOverDriveOn, number("DisplayOverDrive") == 1)
        publish(\.isTouchpadLocked, number("TouchpadLock") == 1)
        if rgbMode == "Factory" { publish(\.isYLogoOn, boolean("YLogoStatus")) }
        publish(\.isPortLightingOn, boolean("PortLighting"))
        publish(\.alwaysOnUSBState, max(number("AlwaysOnUSBState"), 0))
        publish(\.cpuBoostWatts, number("CPUBoostPower"))
        publish(\.cpuSustainedWatts, number("CPUSustainedPower"))
        publish(\.powerRanges, validatedRanges)
        publish(\.manualFanMode, number("FanControlMode") > 0)
        publish(\.fan1TargetRPM, HardwareSnapshot.fanRPM(props["Fan1TargetRPM"]))
        publish(\.fan2TargetRPM, HardwareSnapshot.fanRPM(props["Fan2TargetRPM"]))
        publish(\.fan1MaxRPM, max(number("Fan1MaxRPM"), 0))
        publish(\.fan2MaxRPM, max(number("Fan2MaxRPM"), 0))
        let mode = number("SmartFanMode")
        if !(1...3).contains(mode) { publish(\.powerProfile, 0) }
        if (1...3).contains(mode) && mode != powerProfile {
            publish(\.powerProfile, mode)
            if initialized && !isApplying { showOSDRaw(localizedMessage("Power Profile: %@", localizedMessage(["Quiet", "Balanced", "Performance"][mode - 1])), symbol: ReYogaBrand.controlSymbol("SmartFanMode", value: mode)) }
        }
        if sequence != lastSampleSequence && sequence >= 0 {
            lastSampleSequence = sequence
            lastSampleDate = Date()
            if detailedLogging {
                ReYogaDiagnostics.shared.record("telemetry", ["sequence": sequence, "fan1RPM": fan1RPM,
                    "fan2RPM": fan2RPM, "cpuC": cpuTemp, "gpuC": gpuTemp,
                    "cpuSource": cpuTemperatureSource, "cpuReason": cpuTemperatureReason,
                    "gpuSource": gpuTemperatureSource, "gpuReason": gpuTemperatureReason,
                    "sensorStatus": props["SensorStatus"] ?? [:]])
            }
        }
        let stale = sampleIsStale
        let interval = props["TelemetryIntervalMS"] as? Int
        let liveStatus = interval.map { $0 > 0 ? localizedMessage("Live • %@ ms", String(describing: $0)) : "Live" } ?? "Live"
        let status = sequence < 0 ? (protocolVersion == 1 ? "Firmware state refreshed" : "Driver update required") :
            stale ? "Telemetry stale — check driver log" : liveStatus
        if stale {
            publish(\.fan1RPM, -1); publish(\.fan2RPM, -1)
            if !cpuUsesSMC { publish(\.cpuTemp, -1) }
            if !gpuUsesSMC { publish(\.gpuTemp, -1) }
        }
        if status != telemetryStatus {
            telemetryStatus = status
            ReYogaDiagnostics.shared.record("telemetry_status", ["status": status])
        }
        initialized = true
        let firmwareDigest = props["FirmwareDSDTSHA256"] as? String ?? ""
        let profileIdentity = props["HardwareProfile"] as? String ?? ""
        preferenceIdentity = firmwareDigest.isEmpty && profileIdentity.isEmpty ? "" :
            profileIdentity + "|" + firmwareDigest + "|" + (props["IOClass"] as? String ?? "driver")
        if !controlsRestoreAttempted && !sampleIsStale {
            controlsRestoreAttempted = true
            refreshPermissions()
            let handle = service
            if handle != 0 {
                IOObjectRetain(handle)
                hardwareQueue.async { _ = sendBoolean("DetailedTelemetry", self.detailedLogging, handle); IOObjectRelease(handle) }
            }
            let saved = preferenceIdentity.isEmpty ? SavedHardwareSettings(identity: "") : loadHardwareSettings()
            let order = ["SmartFanMode", "ConservationMode", "RapidChargeMode", "AlwaysOnUSBState", "FnlockMode", "BacklightLevel", "DisplayOverDrive", "TouchpadLock", "YLogoStatus", "PortLighting", "CPUBoostPower", "CPUSustainedPower", "Fan1TargetRPM", "Fan2TargetRPM"]
            restoringControls = order.compactMap { key in saved.values[key].map { (key, $0) } }
            DispatchQueue.main.async { self.restoreNextControl() }
        }
    }
    private func loadHardwareSettings() -> SavedHardwareSettings {
        let key = SavedHardwareSettings.storageKey(preferenceIdentity)
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(SavedHardwareSettings.self, from: data),
           saved.version == 1, saved.identity == preferenceIdentity { return saved }
        return SavedHardwareSettings(identity: preferenceIdentity)
    }
    private func saveHardwareSetting(_ key: String, target: Int, boolean: Bool) {
        guard !preferenceIdentity.isEmpty, key != "BatteryIndex", !key.hasPrefix("Charge") else { return }
        var saved = loadHardwareSettings()
        saved.record(key, value: SavedControlValue(value: target, boolean: boolean,
            powerProfile: key == "CPUBoostPower" || key == "CPUSustainedPower" || key.contains("TargetRPM") ? powerProfile : nil))
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: SavedHardwareSettings.storageKey(preferenceIdentity)) }
    }
    private func restoreNextControl() {
        guard service != 0, driverState == .ready, !isApplying else { return }
        while !restoringControls.isEmpty {
            let (key, saved) = restoringControls.removeFirst()
            let profileMatches = saved.powerProfile == nil || saved.powerProfile == powerProfile
            let rgbPreference = UserDefaults.standard.data(forKey: "AppliedRGBSettings")
                .flatMap { try? JSONDecoder().decode(SavedRGBSettings.self, from: $0) }
            let lightingOwnedByRGB = (key == "YLogoStatus" || key == "PortLighting") && rgbPreference?.isValid == true &&
                rgbPreference?.profileID == rgbController.matchedProfileID && rgbPreference?.mode != "Factory"
            guard featureStatus[key]?.available == true, profileMatches, !lightingOwnedByRGB else {
                ReYogaDiagnostics.shared.record("preference_restore_skipped", ["property": key, "reason": lightingOwnedByRGB ? "USB RGB owns lighting" : !profileMatches ? "Power profile differs" : featureStatus[key]?.reason ?? "Backend unavailable"])
                continue
            }
            if key == "CPUBoostPower" || key == "CPUSustainedPower" {
                guard let range = powerRanges[key], PowerLimitInput.isValid(String(saved.value), range: range) else { continue }
            }
            apply(key, saved.value, boolean: saved.boolean, title: HardwareFeatureStatus.catalog[key] ?? key, restoring: true)
            return
        }
    }
    public func restoreAfterWake() {
        controlsRestoreAttempted = false
        if rgbStatus.available { retryRGBDiscovery() }
        refreshAll()
    }

    private func apply(_ key: String, _ target: Int, boolean: Bool = false, title: String, restoring: Bool = false) {
        if isApplying { queuedControls.append((key, target, boolean, title, restoring)); return }
        if !restoring { restoringControls.removeAll() }
        guard service != 0, featureStatus[key]?.available == true else {
            let reason = featureStatus[key]?.reason ?? "Driver unavailable"
            showOSDRaw(localizedMessage("%@: %@", localizedMessage(title), localizedMessage(reason)), duration: 3000, symbol: ReYogaBrand.controlSymbol(key, value: target))
            ReYogaDiagnostics.shared.record("control_unavailable", ["property": key, "reason": reason])
            if !queuedControls.isEmpty {
                let next = queuedControls.removeFirst()
                DispatchQueue.main.async { self.apply(next.0, next.1, boolean: next.2, title: next.3, restoring: next.4) }
            }
            return
        }
        isApplying = true
        applyingControl = key
        let handle = service
        let generation = connectionGeneration
        IOObjectRetain(handle)
        let requestID = UUID().uuidString
        let targetValue: Any = boolean ? (target != 0) : target
        ReYogaDiagnostics.shared.record("control_requested", ["id": requestID, "property": key, "target": targetValue])
        hardwareQueue.async {
            let request: NSDictionary = ["Property": key, "Value": targetValue, "RequestID": requestID]
            let transport = IORegistryEntrySetCFProperty(handle, "ControlRequest" as CFString, request)
            var snapshot = getProperties(handle)
            let result = snapshot?["LastControlResult"] as? [String: Any] ?? [:]
            let correlated = result["RequestID"] as? String == requestID
            let status = (result["Status"] as? NSNumber)?.uint32Value ?? UInt32.max
            var confirmed = transport == kIOReturnSuccess && correlated && status == 0
            // EC commands may complete after the AML method returns. Retry only
            // accepted commands, never a failed/unsupported write.
            if transport == kIOReturnSuccess, correlated, result["ReadbackPending"] as? Bool == true {
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 0.1)
                    _ = sendBoolean("Update", true, handle)
                    snapshot = getProperties(handle)
                    guard (snapshot?["LastControlResult"] as? [String: Any])?["RequestID"] as? String == requestID else { break }
                    if let actual = snapshot?[key] as? NSNumber, let requested = targetValue as? NSNumber, actual == requested {
                        confirmed = true
                        break
                    }
                }
            }
            let reason = transport != kIOReturnSuccess ? String(format: localizedMessage("IOKit transport failed (0x%08x)"), transport) :
                !correlated ? "Driver response missing or request ID mismatch" : result["Reason"] as? String ?? "Firmware error"
            ReYogaDiagnostics.shared.record("control_result", ["id": requestID, "property": key, "transport": transport,
                "status": confirmed ? 0 : status, "initialStatus": status, "confirmed": confirmed, "reason": confirmed ? "Firmware readback matched" : reason, "requested": targetValue, "actual": snapshot?[key] ?? NSNull(), "code": result["Code"] ?? "unknown", "stage": result["Stage"] ?? "unknown", "initialCommandStatus": result["CommandStatus"] ?? NSNull()])
            IOObjectRelease(handle)
            DispatchQueue.main.async {
                guard generation == self.connectionGeneration, handle == self.service else { return }
                if let snapshot = snapshot { self.accept(snapshot) }
                self.isApplying = false
                self.applyingControl = nil
                if !self.queuedControls.isEmpty {
                    let next = self.queuedControls.removeFirst()
                    DispatchQueue.main.async { self.apply(next.0, next.1, boolean: next.2, title: next.3, restoring: next.4) }
                }
                if confirmed && !restoring { self.saveHardwareSetting(key, target: target, boolean: boolean) }
                if restoring { DispatchQueue.main.async { self.restoreNextControl() } }
                if confirmed && key.contains("TargetRPM") && target > 0 {
                    let fan = key == "Fan1TargetRPM" ? 0 : 1
                    self.pendingFanChecks[fan] = (target, Date().addingTimeInterval(12))
                }
                let valueLabel = key == "SmartFanMode" ? ([1: "Quiet", 2: "Balanced", 3: "Performance"][target] ?? localizedMessage("Unknown (%@)", String(target))) :
                    key == "AlwaysOnUSBState" ? ([0: "Off", 1: "AC power", 2: "AC + battery"][target] ?? localizedMessage("Unknown (%@)", String(target))) :
                    key.hasPrefix("Charge") ? "\(target)%" : key == "BatteryIndex" ? (target == 1 ? "Primary" : "Secondary") :
                    key == "BacklightLevel" ? String(target) : key == "CPUPowerReset" ? "Restored" : key.contains("TargetRPM") ? localizedMessage("%@ RPM minimum", String(target)) : key == "CPUBoostPower" || key == "CPUSustainedPower" ? "\(target) W" : target == 0 ? "Off" : "On"
                if !restoring || !confirmed { showOSDRaw(confirmed ? localizedMessage("%@: %@", localizedMessage(title), localizedMessage(valueLabel)) : localizedMessage("%@: %@", localizedMessage(title), localizedMessage(reason)), duration: confirmed ? 1500 : 3000, symbol: ReYogaBrand.controlSymbol(key, value: target)) }
            }
        }
    }

    public func toggleFnLock() { apply("FnlockMode", isFnLocked ? 0 : 1, boolean: true, title: "Fn Lock") }
    public func setKeyboardBacklight(_ level: Int) {
        guard (0...2).contains(level) else { return }
        apply("BacklightLevel", level, title: "Keyboard Backlight")
    }
    public func selectBattery(_ index: Int) {
        guard index == 1 || (index == 2 && batteryIndividualAddressing) else { return }
        apply("BatteryIndex", index, title: "Battery")
    }
    public func setChargeThreshold(_ key: String, percent: Int) {
        guard (key == "ChargeStartThreshold" && (0...99).contains(percent)) ||
              (key == "ChargeStopThreshold" && (1...100).contains(percent)) else { return }
        apply(key, percent, title: key == "ChargeStartThreshold" ? "Charge Start" : "Charge Stop")
    }
    public func setPowerProfile(_ mode: Int) {
        guard (1...3).contains(mode) else { return }
        apply("SmartFanMode", mode, title: "Power Profile")
    }
    public func setAlwaysOnUSBState(_ state: Int) {
        guard (0...2).contains(state) else { return }
        apply("AlwaysOnUSBState", state, title: "USB Charging")
    }
    public func setFanMinimum(_ fan: Int, rpm: Int) {
        guard fanLabels.indices.contains(fan), fanStepsRPM.indices.contains(fan), rpm >= 0 else { return }
        let maximum = fan == 0 ? fan1MaxRPM : fan2MaxRPM
        let step = fanStepsRPM[fan]
        guard maximum > 0, step > 0, rpm <= maximum, rpm % step == 0 else { return }
        guard confirmControlRisk("Change fan minimum?", message: "This raises the minimum over the factory cooling curve; it does not set an unrestricted fixed speed. Higher minima increase fan noise and power use. Restore Auto returns control to the factory curve.", preference: "AcknowledgedFanMinimumRisk") else { return }
        apply(fan == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM", rpm, title: fanLabels[fan])
    }
    public func resetPowerLimits() { apply("CPUPowerReset", 0, title: "CPU Power Limits") }
    private func confirmControlRisk(_ title: String, message: String, preference: String) -> Bool {
        if UserDefaults.standard.bool(forKey: preference) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning; alert.messageText = localizedMessage(title); alert.informativeText = localizedMessage(message)
        alert.addButton(withTitle: localizedMessage("Continue")); alert.addButton(withTitle: localizedMessage("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = localizedMessage("Don’t show this explanation again")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: preference) }
        return true
    }
    public func setPowerLimit(_ key: String, watts: Int) {
        guard key == "CPUBoostPower" || key == "CPUSustainedPower" else { return }
        guard confirmControlRisk("Change CPU power limits?", message: "Higher limits can increase heat, fan noise and battery drain. Lower limits can reduce performance. Only firmware-supported values are accepted. Reset restores the values saved before your edits in this power profile.", preference: "AcknowledgedCPUPowerRisk") else { return }
        apply(key, watts, title: key == "CPUBoostPower" ? "CPU Boost Limit" : "CPU Sustained Limit")
    }
    public func restoreAutomaticFans() {
        pendingFanChecks.removeAll()
        apply("FanControlMode", 0, title: "Manual Fan Minimum") }
    public func toggleConservation() { apply("ConservationMode", isConservationOn ? 0 : 1, boolean: true, title: "Conservation") }
    public func toggleRapidCharge() { apply("RapidChargeMode", isRapidChargeOn ? 0 : 1, boolean: true, title: "Rapid Charge") }
    public func toggleOverDrive() { apply("DisplayOverDrive", isOverDriveOn ? 0 : 1, title: "Display Overdrive") }
    public func toggleTouchpad() { apply("TouchpadLock", isTouchpadLocked ? 0 : 1, title: "Touchpad Lock") }
    public func toggleYLogo() {
        guard hasYLogo else { showOSDRaw(featureStatus["YLogoStatus"]?.reason ?? "Logo control unavailable", symbol: "exclamationmark.triangle"); return }
        if rgbMode != "Factory", rgbStatus.available {
            let enabled = !isYLogoOn
            rgbAction("Logo LED") {
                let color = enabled ? (self.rgbColors["Logo"] ?? (255, 255, 255)) : (0, 0, 0)
                try self.rgbController.setZone("Logo", red: color.0, green: color.1, blue: color.2)
                self.rgbLogoEnabled = enabled
                self.saveRGBSettings(mode: self.rgbPerKey != nil ? "Per-key" : self.rgbEffect == "Factory" ? "Static" : self.rgbEffect)
                DispatchQueue.main.async { self.isYLogoOn = enabled }
            }
        } else {
            // Direct mode can survive another app's exit. Release it before a
            // firmware logo request so the two controllers cannot fight.
            if rgbStatus.available {
                hardwareQueue.async {
                    do { try self.rgbController.restoreHardwareMode(force: true) }
                    catch { ReYogaDiagnostics.shared.record("rgb_factory_release_failed", ["error": error.localizedDescription]) }
                }
            }
            apply("YLogoStatus", isYLogoOn ? 0 : 1, boolean: true, title: "Logo Lighting")
        }
    }
    public func togglePortLighting() { apply("PortLighting", isPortLightingOn ? 0 : 1, boolean: true, title: "Port Lighting") }
    public func setDetailedLogging(_ enabled: Bool) {
        detailedLogging = enabled
        UserDefaults.standard.set(enabled, forKey: "DetailedLogging")
        let handle = service
        if handle != 0 {
            IOObjectRetain(handle)
            hardwareQueue.async { _ = sendBoolean("DetailedTelemetry", enabled, handle); IOObjectRelease(handle) }
        }
        ReYogaDiagnostics.shared.record("logging", ["detailed": enabled])
        showOSDRaw(localizedMessage("Detailed Logging: %@", localizedMessage(enabled ? "On" : "Off")))
    }
    public func openDiagnostics() { NSWorkspace.shared.open(ReYogaDiagnostics.shared.directory) }
    public func exportDiagnostics() {
        let save = NSSavePanel()
        save.allowedFileTypes = ["zip"]
        save.nameFieldStringValue = "ReYoga-diagnostics.zip"
        save.message = localizedMessage("Export hardware status and recent app logs locally. Review the archive before attaching it to an issue.")
        guard save.runModal() == .OK, let output = save.url else { return }
        let metadata: [String: Any] = ["schemaVersion": 1, "model": modelName, "smbiosModel": smbiosModel, "modelSource": modelSource, "modelWarning": modelWarning, "cpu": cpuBrand,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown", "installationPath": Bundle.main.bundlePath,
            "accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(),
            "rgbReason": rgbStatus.reason, "hotkeyProfile": hotkeyProfileID, "telemetry": telemetryStatus, "battery": batterySummary,
            "batteryProviderFields": liveBattery?.rawFields ?? [:]]
        let handle = service
        if handle != 0 { IOObjectRetain(handle) }
        hardwareQueue.async {
            defer { if handle != 0 { IOObjectRelease(handle) } }
            let keys = ["Battery 0", "Battery 1", "IOClass", "SafeMode", "NativeTelemetryProfile", "NativeTelemetryReason", "FirmwareDSDTSHA256", "SensorSources", "BatteryIndex", "ChargeStartThreshold", "ChargeStopThreshold", "BatteryModeRaw", "ConservationMode", "RapidChargeMode", "BatteryStateSchemaVersion", "ConservationStateMask", "RapidChargeStateMask", "VersionInfo", "FeatureStatus", "SensorStatus", "LastControlResult", "ControlProtocolVersion",
                        "ACPIBridgeVersion", "ACPIBridgeProfile", "ACPIBridgeProfileName", "ProfileMatchState", "ProfileMatchStage", "ProfileMatchReason", "ProfileMatchProfilesChecked", "ProfileMatchOEMMatches", "FirmwareDSDTOEMTableID", "FirmwareDSDTLength", "FirmwareDSDTChecksum", "FirmwareMachineType", "FirmwareBIOSFamily", "FirmwareIdentityConflict", "ACPIBridgeReason", "ThinkFanProtocolVersion", "ThinkFanStatus", "ThinkFanAccessFailed", "CPUPowerPendingProfile", "CPUPowerRestoreReason", "FanRestoreReason", "HardwareProfile", "HardwareProfileName", "PowerLimitRanges", "YLogoRawState", "YLogoRawBrightness", "PortLightingRawState", "PortLightingRawBrightness", "FanFullSpeedRaw", "FanFullSpeedECResult", "FanFullSpeedCommandBackend", "LightingControlOwner", "LogoLightingCapability", "PortLightingCapability", "LightingCommandStage", "SensorSampleSequence", "SensorSampleTimeMS",
                        "Fan1RPM", "Fan2RPM", "Fan1TargetRPM", "Fan2TargetRPM", "FanControlMode", "CPUTemp", "GPUTemp"]
            let snapshot: NSDictionary = handle != 0 ? getProperties(handle) ?? [:] : [:]
            var driver: [String: Any] = [:]
            for key in keys { if let value = snapshot[key] { driver[key] = value } }
            var report = metadata
            report["driver"] = driver
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
            ReYogaDiagnostics.shared.export(report, to: output)
        }
    }

    public func createSupportIssue() {
        var body = "## Device support request\n\nModel: \(modelName)\nCPU: \(cpuBrand)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        body += "### Feature support\n"
        for key in featureStatus.keys.sorted() {
            let feature = featureStatus[key]!
            body += "- \(key): \(feature.available ? "available" : "unavailable") — \(feature.reason) [\(feature.backend)]\n"
        }
        body += "\nRGB: \(rgbStatus.available ? "ready" : "unavailable") — \(rgbStatus.reason)\nHotkey profile: \(hotkeyProfileID.isEmpty ? "no reviewed match" : hotkeyProfileID)\n"
        body += "\nTelemetry: \(telemetryStatus)\n\nDescribe the failing action and attach events.jsonl after reviewing it.\n"
        let destination = UserDefaults.standard.string(forKey: "SupportRepositoryURL") ?? ReYogaConstants.repositoryURL
        guard let base = URL(string: destination), base.scheme == "https", base.host == "github.com" else {
            showOSDRaw("Support repository URL is invalid"); return
        }
        var components = URLComponents(url: base.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "title", value: localizedMessage("Device support: %@", modelName)), URLQueryItem(name: "body", value: body)]
        let report = ReYogaDiagnostics.shared.directory.appendingPathComponent("support-report.txt")
        do { try body.write(to: report, atomically: true, encoding: .utf8) }
        catch { ReYogaDiagnostics.shared.record("report_write_failed", ["error": error.localizedDescription]) }
        if let url = components.url { NSWorkspace.shared.open(url) }
        showOSDRaw("Support report ready — review and submit the issue")
    }
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    public func openInputMonitoringSettings() { openPrivacySettings() }

    public func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
        showOSDRaw("Grant Accessibility and Input Monitoring. If macOS requests a restart, quit and reopen ReYogaSMC.", duration: 4000)
    }
    public func retryRGBDiscovery() {
        guard !rgbApplying else { return }
        rgbApplying = true
        hardwareQueue.async {
            do { try self.rgbController.restoreHardwareMode() }
            catch { ReYogaDiagnostics.shared.record("rgb_restore_failed", ["error": error.localizedDescription]) }
            self.rgbRestoredProfile = nil
            self.rgbController.detect()
            DispatchQueue.main.async {
                self.rgbApplying = false
                self.rgbStatus = self.rgbController.status
                self.hasRGBHardware = self.rgbController.matchedProfileID != nil
                if let profile = self.rgbController.matchedProfileID { self.hotkeyProfileID = profile }
                self.refreshPermissions()
                self.restoreSavedRGB()
                showOSDRaw(self.rgbStatus.available ? "RGB controller ready" : self.rgbStatus.reason, duration: 3000)
            }
        }
    }
    public var canGenerateACPIBridge: Bool { service == 0 || providerClass == "IdeaVPC" }
    public func generateACPIBridge() {
        guard canGenerateACPIBridge else { return }
        if service != 0, getNumber("ACPIExportVersion", service) == 1 { HardwareProfiles.exportLiveBridge(service: service) }
        else { HardwareProfiles.exportBridge() }
    }
    public func refreshPermissions() {
        let accessibility = AXIsProcessTrusted()
        let input = CGPreflightListenEventAccess()
        hasAccessibilityPermission = accessibility
        hasInputMonitoringPermission = input
        permissionStatus = localizedMessage("Accessibility: %@ - Input Monitoring: %@", localizedMessage(accessibility ? "Granted" : "Required"), localizedMessage(input ? "Granted" : "Required"))
        if hotkeysEnabled && (!accessibility || !input) {
            hotkeys.stop(); hotkeysEnabled = false
            hotkeyStatus = "Hotkey privacy access is missing. Check Accessibility and Input Monitoring, then enable the mapper again."
            showOSDRaw(hotkeyStatus, duration: 3000)
        }
        if driverState == .ready, !CommandLine.arguments.contains("--render-ui"), !hotkeysRestoreAttempted && !hotkeyProfileID.isEmpty {
            hotkeysRestoreAttempted = true
            if UserDefaults.standard.bool(forKey: "LegionHotkeysEnabled") {
                if accessibility && input { setHotkeysEnabled(true) }
                else { hotkeyStatus = "Saved mapping is paused: grant Accessibility and Input Monitoring, then enable it." }
            }
        }
    }
    #if DEBUG
    func loadUIFixture(_ props: NSDictionary) {
        stopMonitoring()
        controlsRestoreAttempted = true
        isConnected = true
        driverState = .ready
        accept(props)
        liveBattery = (props["AppleSmartBattery"] as? [String: Any]).map { LiveBatterySnapshot(properties: $0) }
        batteryDetails = (0...1).compactMap { index in
            guard let values = props["Battery \(index)"] as? [String: Any] else { return nil }
            let detail = BatteryDetail(index: index, properties: values)
            return detail.present ? detail : nil
        }
    }
    func loadMissingDriverPreview() {
        stopMonitoring()
        isConnected = false
        driverState = .missing
        driverMessage = "Firmware driver unavailable. Independent battery, SMC and USB RGB functions remain accessible."
        featureStatus = [:]
        hasDualFan = false; hasPowerProfiles = false; hasConservation = false; hasRapidCharge = false
        hasOverDrive = false; hasTouchpadLock = false; hasYLogo = false; hasPortLighting = false; hasAlwaysOnUSB = false
        fan1RPM = -1; fan2RPM = -1; powerProfile = 0
        telemetryStatus = "Independent sensors"
    }
    func loadReadOnlyPreview(_ handle: io_service_t) {
        controlsRestoreAttempted = true
        if let props = getProperties(handle) {
            isConnected = true; driverState = .ready; accept(props)
            if let reading = smcTemperatures.cpuTemperature() { cpuUsesSMC = true; cpuTemp = reading.celsius; cpuTemperatureSource = reading.source }
            if let reading = smcTemperatures.gpuTemperature() { gpuUsesSMC = true; gpuTemp = reading.celsius; gpuTemperatureSource = reading.source }
            liveBattery = LiveBatterySnapshot.read()
            batterySummary = liveBattery?.summary ?? ""
            batteryDetails = (0...1).compactMap { index in
                guard let values = props["Battery \(index)"] as? [String: Any] else { return nil }
                let detail = BatteryDetail(index: index, properties: values)
                return detail.present ? detail : nil
            }
        }
    }
    #endif

    public func setHotkeysEnabled(_ enabled: Bool) {
        guard !enabled || driverState == .ready else {
            hotkeyStatus = "Connect a compatible hardware driver before enabling keyboard mapping."
            showOSDRaw(hotkeyStatus, duration: 3000); return
        }
        do {
            if enabled { try hotkeys.start(profileID: hotkeyProfileID) } else { hotkeys.stop() }
            hotkeysEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "LegionHotkeysEnabled")
            hotkeyStatus = enabled ? "Mapper active. Native firmware/media keys are unchanged." : "Off — native media keys remain active."
            refreshPermissions()
            showOSDRaw(localizedMessage("Legion Hotkeys: %@", localizedMessage(enabled ? "On" : "Off")))
        } catch {
            hotkeysEnabled = false
            hotkeyStatus = error.localizedDescription
            ReYogaDiagnostics.shared.record("hotkeys_failed", ["error": error.localizedDescription])
            showOSDRaw(error.localizedDescription, duration: 3000)
        }
    }
    public func setRGBZone(_ zone: String, color: NSColor) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return }
        let red = UInt8(max(0, min(255, (rgb.redComponent * 255).rounded())))
        let green = UInt8(max(0, min(255, (rgb.greenComponent * 255).rounded())))
        let blue = UInt8(max(0, min(255, (rgb.blueComponent * 255).rounded())))
        rgbAction(localizedMessage("%@ RGB", localizedMessage(zone))) {
            var colors = self.rgbColors
            colors[zone] = (red, green, blue)
            let logoEnabled = zone == "Logo" ? red != 0 || green != 0 || blue != 0 : self.rgbLogoEnabled
            try self.configureRGB(mode: "Static", colors: colors, logoEnabled: logoEnabled)
            self.saveRGBSettings(mode: "Static")
        }
    }

    public func restoreRGBHardwareMode() {
        rgbAction("RGB factory effects") {
            self.stopRGBEffect()
            try self.rgbController.restoreHardwareMode(force: true)
            self.rgbPerKey = nil
            self.saveRGBSettings(mode: "Factory")
            DispatchQueue.main.async { self.rgbMode = "Factory" }
        }
    }
    private func stopRGBEffect() {
        rgbEffectTimer?.cancel(); rgbEffectTimer = nil; rgbEffect = "Factory"
    }
    public func setRGBEffect(_ mode: String, colors: [String: NSColor]) {
        guard ["Static", "Breathing", "Spectrum", "Factory"].contains(mode) else { return }
        if mode == "Factory" { restoreRGBHardwareMode(); return }
        let bytes = colors.mapValues { SavedRGBSettings.bytes(SavedRGBSettings.hex($0))! }
        rgbAction(localizedMessage("RGB %@", localizedMessage(mode))) {
            try self.configureRGB(mode: mode, colors: bytes, logoEnabled: true)
            self.saveRGBSettings(mode: mode)
        }
    }
    private func configureRGB(mode: String, colors: [String: (UInt8, UInt8, UInt8)], logoEnabled: Bool) throws {
        stopRGBEffect()
        rgbEffect = mode; rgbColors = colors; rgbLogoEnabled = logoEnabled; rgbPerKey = nil; rgbEffectStart = Date()
        try writeRGBFrame()
        if mode != "Static" {
            let timer = DispatchSource.makeTimerSource(queue: hardwareQueue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                do { try self.writeRGBFrame() }
                catch {
                    self.stopRGBEffect()
                    try? self.rgbController.restoreHardwareMode()
                    ReYogaDiagnostics.shared.record("rgb_effect_failed", ["error": error.localizedDescription])
                    DispatchQueue.main.async {
                        self.rgbMode = "Stopped — error"
                        self.rgbStatus = HardwareFeatureStatus(available: false, reason: error.localizedDescription, backend: "USB HID")
                        showOSDRaw(localizedMessage("RGB effect stopped: %@", error.localizedDescription), duration: 3000, symbol: "exclamationmark.triangle")
                    }
                }
            }
            rgbEffectTimer = timer; timer.resume()
        }
        DispatchQueue.main.async { self.rgbMode = mode; self.isYLogoOn = logoEnabled }
    }
    private func saveRGBSettings(mode: String) {
        guard let profile = rgbController.matchedProfileID else { return }
        let colors = rgbColors.mapValues { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) }
        let value = SavedRGBSettings(profileID: profile, mode: mode, colors: colors, logoEnabled: rgbLogoEnabled, perKey: rgbPerKey)
        if let data = try? JSONEncoder().encode(value), value.isValid {
            UserDefaults.standard.set(data, forKey: "AppliedRGBSettings")
            rgbRestoredProfile = profile
        }
    }
    private func restoreSavedRGB() {
        guard rgbStatus.available, !rgbApplying,
              let profile = rgbController.matchedProfileID, rgbRestoredProfile != profile,
              let data = UserDefaults.standard.data(forKey: "AppliedRGBSettings"),
              let saved = try? JSONDecoder().decode(SavedRGBSettings.self, from: data), saved.isValid else { return }
        guard saved.profileID == profile else {
            ReYogaDiagnostics.shared.record("rgb_restore_skipped", ["reason": "Saved RGB device profile differs", "saved": saved.profileID, "current": profile])
            return
        }
        if saved.mode == "Factory" { rgbRestoredProfile = profile; return }
        rgbAction("Restore RGB preferences") {
            if saved.mode == "Per-key", let perKey = saved.perKey {
                self.stopRGBEffect()
                try self.rgbController.importColors(perKey)
                self.rgbPerKey = perKey
                self.rgbLogoEnabled = saved.logoEnabled
                if !saved.logoEnabled { try self.rgbController.setZone("Logo", red: 0, green: 0, blue: 0) }
                DispatchQueue.main.async { self.rgbMode = "Per-key" }
            } else {
                try self.configureRGB(mode: saved.mode, colors: saved.colors.mapValues { SavedRGBSettings.bytes($0)! }, logoEnabled: saved.logoEnabled)
            }
            self.rgbRestoredProfile = profile
            ReYogaDiagnostics.shared.record("rgb_preferences_restored", ["mode": saved.mode, "profile": profile])
        }
    }
    private func writeRGBFrame() throws {
        let elapsed = Date().timeIntervalSince(rgbEffectStart)
        for (zone, base) in rgbColors {
            let color = zone == "Logo" && !rgbLogoEnabled ? (UInt8(0), UInt8(0), UInt8(0)) : LegionRGBController.effectColor(mode: rgbEffect, base: base, elapsed: elapsed)
            try rgbController.setZone(zone, red: color.0, green: color.1, blue: color.2)
        }
    }
    public func importRGBColors() {
        let chooser = NSOpenPanel()
        chooser.allowedFileTypes = ["json"]
        chooser.message = localizedMessage("Select a zone/LED color map. Unknown LEDs are rejected.")
        guard chooser.runModal() == .OK, let file = chooser.url else { return }
        rgbAction("Per-key RGB") {
            let data = try Data(contentsOf: file)
            self.stopRGBEffect()
            try self.rgbController.importColors(data)
            self.rgbPerKey = data
            self.rgbLogoEnabled = true
            self.saveRGBSettings(mode: "Per-key")
            DispatchQueue.main.async { self.rgbMode = "Per-key" }
        }
    }
    private func rgbAction(_ title: String, action: @escaping () throws -> Void) {
        guard rgbStatus.available, !rgbApplying else { showOSDRaw(localizedMessage("RGB: %@", localizedMessage(rgbStatus.reason))); return }
        rgbApplying = true
        hardwareQueue.async {
            var errorText: String?
            do { try action() }
            catch {
                errorText = error.localizedDescription
                self.stopRGBEffect()
                do { try self.rgbController.restoreHardwareMode() }
                catch { errorText = localizedMessage("%@; factory-mode restoration also failed: %@", localizedMessage(errorText ?? "RGB error"), error.localizedDescription) }
            }
            ReYogaDiagnostics.shared.record("rgb_result", ["action": title, "error": errorText ?? "none", "acknowledgement": "USB report transport only"])
            DispatchQueue.main.async {
                self.rgbApplying = false
                showOSDRaw(errorText.map { localizedMessage("%@: %@", localizedMessage(title), $0) } ?? localizedMessage("%@: sent to controller", localizedMessage(title)), duration: errorText == nil ? 1500 : 3000, symbol: "lightbulb")
            }
        }
    }
    private func performHotkey(_ action: String) {
        ReYogaDiagnostics.shared.record("hotkey_action", ["action": action])
        switch action {
        case "mute": postMediaKey(7)
        case "volumeDown": postMediaKey(1)
        case "volumeUp": postMediaKey(0)
        case "brightnessDown": postMediaKey(3)
        case "brightnessUp": postMediaKey(2)
        case "micMute": micMuteHelper(service, "Microphone")
        case "touchpad": toggleTouchpad()
        case "airplane": airplaneModeHelper("Airplane Mode", true)
        case "controlCenter":
            (NSApp.delegate as? AppDelegate)?.openControlsWindow(nil)
            showOSDRaw("ReYogaSMC Controls")
        case "displays":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") { NSWorkspace.shared.open(url) }
            showOSDRaw("Display Settings")
        case "mission":
            CoreDockSendNotification("com.apple.expose.awake" as CFString, nil)
            showOSDRaw("Mission Control")
        case "calculator": launchHotkeyApp("com.apple.calculator", title: "Calculator")
        case "screenshot": launchHotkeyApp("com.apple.Screenshot", title: "Screenshot")
        default:
            ReYogaDiagnostics.shared.record("hotkey_unimplemented", ["action": action])
            showOSDRaw(localizedMessage("Hotkey mapping needs support: %@", action))
        }
    }
    private func launchHotkeyApp(_ bundle: String, title: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            showOSDRaw(localizedMessage("%@: application unavailable", localizedMessage(title))); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            DispatchQueue.main.async { showOSDRaw(error.map { localizedMessage("%@: %@", localizedMessage(title), $0.localizedDescription) } ?? title) }
        }
    }
    private func postMediaKey(_ code: Int) {
        for state in [0xA, 0xB] {
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: code << 16 | state << 8, data2: -1)?.cgEvent else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: 0x52594b)
            event.post(tap: .cghidEventTap)
        }
    }
    public func shutdown() {
        hotkeys.stop()
        hardwareQueue.sync {
            self.stopRGBEffect()
            self.smcTemperatures.close()
            do { try self.rgbController.restoreHardwareMode() }
            catch { ReYogaDiagnostics.shared.record("rgb_restore_failed", ["error": error.localizedDescription]) }
        }
        stopMonitoring()
        if cpuPowerModified && service != 0 && featureStatus["CPUPowerReset"]?.available == true {
            let request: NSDictionary = ["Property": "CPUPowerReset", "Value": 0, "RequestID": UUID().uuidString]
            let status = IORegistryEntrySetCFProperty(service, "ControlRequest" as CFString, request)
            ReYogaDiagnostics.shared.record("power_reset_on_quit", ["transport": status])
        }
        if manualFanMode && service != 0 {
            let request: NSDictionary = ["Property": "FanControlMode", "Value": 0, "RequestID": UUID().uuidString]
            _ = IORegistryEntrySetCFProperty(service, "ControlRequest" as CFString, request)
        }
    }
}

public struct HardwareFeatureStatus: Equatable {
    public let available: Bool
    public let reason: String
    public let backend: String
    public static let catalog: [String: String] = [
        "ChargeStartThreshold": "Charge Start", "ChargeStopThreshold": "Charge Stop", "BatteryIndex": "Battery",
        "SmartFanMode": "Power Profile", "ConservationMode": "Conservation", "RapidChargeMode": "Rapid Charge",
        "DisplayOverDrive": "Display Overdrive", "TouchpadLock": "Touchpad Lock",
        "AlwaysOnUSBState": "Always-On USB", "FnlockMode": "Fn Lock", "BacklightLevel": "Keyboard Backlight",
        "YLogoStatus": "Logo Lighting", "PortLighting": "Port Lighting", "FanControlMode": "Manual Fan Control",
        "Fan1TargetRPM": "Fan 1 Minimum", "Fan2TargetRPM": "Fan 2 Minimum",
        "CPUBoostPower": "CPU Boost Power Limit", "CPUSustainedPower": "CPU Sustained Power Limit",
        "CPUPowerReset": "Reset CPU Power Limits", "GPUPowerLimit": "GPU Power Limit", "CPUOverclock": "CPU Overclock", "GPUOverclock": "GPU Overclock", "HybridGraphics": "Hybrid / Discrete Graphics"
    ]
}

final class ReYogaDiagnostics {
    static let shared = ReYogaDiagnostics()
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ReYogaSMC", isDirectory: true)
    private let queue = DispatchQueue(label: "org.reyogasmc.diagnostics", qos: .utility)
    private let log = OSLog(subsystem: "org.reyogasmc", category: "hardware")
    func export(_ report: [String: Any], to output: URL) {
        queue.async {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReYoga-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var metadata = report
                if let table = metadata.removeValue(forKey: "DSDT") as? Data {
                    try table.write(to: folder.appendingPathComponent("DSDT.aml"))
                }
                let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                try data.write(to: folder.appendingPathComponent("report.plist"))
                // Include only our bounded logs; no system-wide log collection.
                for name in ["events.jsonl", "events.1.jsonl", "events.2.jsonl", "events.3.jsonl"] {
                    let source = self.directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                    }
                }
                let signingLog = folder.appendingPathComponent("signing.txt")
                FileManager.default.createFile(atPath: signingLog.path, contents: nil)
                let logHandle = try FileHandle(forWritingTo: signingLog)
                defer { try? logHandle.close() }
                let signing = Process()
                signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                signing.arguments = ["-d", "-r-", "--verbose=4", Bundle.main.bundlePath]
                signing.standardOutput = logHandle; signing.standardError = logHandle
                try signing.run(); signing.waitUntilExit()
                let temporaryArchive = folder.appendingPathExtension("zip")
                defer { try? FileManager.default.removeItem(at: temporaryArchive) }
                let zip = Process()
                zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                zip.arguments = ["-c", "-k", "--keepParent", folder.path, temporaryArchive.path]
                zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
                try zip.run(); zip.waitUntilExit()
                guard zip.terminationStatus == 0 else { throw SupportError.message("Could not package diagnostics. Open Logs to inspect the local files.") }
                let archive = try Data(contentsOf: temporaryArchive)
                try archive.write(to: output, options: .atomic)
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([output]); showOSDRaw("Diagnostic report saved locally", duration: 2500) }
            } catch {
                DispatchQueue.main.async { showOSDRaw(localizedMessage("Report export: %@", error.localizedDescription), duration: 3500) }
            }
        }
    }
    func record(_ event: String, _ details: [String: Any]) {
        os_log("%{public}@", log: log, type: .info, event)
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let file = self.directory.appendingPathComponent("events.jsonl")
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 2 * 1024 * 1024 {
                    for index in stride(from: 3, through: 1, by: -1) {
                        let source = self.directory.appendingPathComponent(index == 1 ? "events.jsonl" : "events.\(index - 1).jsonl")
                        let target = self.directory.appendingPathComponent("events.\(index).jsonl")
                        try? FileManager.default.removeItem(at: target)
                        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: target) }
                    }
                }
                let record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "event": event, "details": details]
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                data.append(0x0a)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                os_log("Diagnostic write failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }
}
