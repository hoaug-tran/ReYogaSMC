import Foundation
import Darwin
import Combine
import IOKit

public final class HardwareManager: ObservableObject {
    private var feedback: (HardwareFeedback) -> Void = { _ in }

    func configureFeedback(_ handler: @escaping (HardwareFeedback) -> Void) {
        feedback = handler
    }

    public static let shared = HardwareManager()

    @Published public private(set) var modelName: String = ""
    @Published public private(set) var smbiosModel: String = ""
    @Published public private(set) var modelSource: String = "SMBIOS"
    @Published public private(set) var modelWarning: String = ""
    @Published public private(set) var cpuBrand: String = ""
    @Published public private(set) var driverVersion = "Unavailable"
    @Published public private(set) var profileMatchState = "Unavailable"
    @Published public private(set) var firmwareProfileID = ""
    public var localizedModelName: String {
        ["Lenovo Laptop", "Unknown Laptop"].contains(modelName) ? localizedMessage(modelName) : modelName
    }
    public var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? localizedMessage("Unknown")
    }
    public var appRevision: String {
        (Bundle.main.object(forInfoDictionaryKey: "ReYogaGitRevision") as? String) ?? localizedMessage("Unknown revision")
    }
    private var featurePollingSupported = false
    private var thinkFanTelemetrySupported = false
    private var lastThinkFanSampleTime: TimeInterval = 0
    private var lastThinkFanCommandTime: TimeInterval = 0
    private var lastFirmwareRefresh = Date.distantPast

    @Published public private(set) var hasDualFan: Bool = false
    @Published public private(set) var hasPowerProfiles: Bool = false
    @Published public private(set) var powerProfilesReady: Bool = false
    @Published public private(set) var powerProfileError = ""
    @Published public private(set) var thinkFanCurveSupported = false
    @Published public private(set) var thinkFanCurveReason = ""
    @Published public private(set) var thinkFanECNeedsHelpers = false
    private var cpuSampleTime: TimeInterval = 0
    @Published public private(set) var hasConservation: Bool = false
    @Published public private(set) var hasRapidCharge: Bool = false
    @Published public private(set) var hasOverDrive: Bool = false
    @Published public private(set) var hasTouchpadLock: Bool = false
    @Published public private(set) var hasYLogo: Bool = false
    @Published public private(set) var hasPortLighting: Bool = false
    @Published public private(set) var hasAlwaysOnUSB: Bool = false

    @Published public private(set) var fan1RPM: Int = -1
    @Published public private(set) var fan2RPM: Int = -1
    @Published public private(set) var cpuTemp: Double = -1
    @Published public private(set) var gpuTemp: Double = -1
    @Published public private(set) var powerProfile: Int = 0
    @Published public private(set) var alwaysOnUSBState: Int = 0
    @Published public private(set) var isConservationOn: Bool = false
    @Published public private(set) var isRapidChargeOn: Bool = false
    @Published public private(set) var isOverDriveOn: Bool = false
    @Published public private(set) var isTouchpadLocked: Bool = false
    @Published public private(set) var isYLogoOn: Bool = false
    @Published public private(set) var isPortLightingOn: Bool = false
    @Published public private(set) var providerClass = ""
    @Published public private(set) var acpiECPath = ""
    @Published public private(set) var acpiHKEYPath = ""
    @Published public private(set) var acpiAnalysisBusy = false
    @Published public private(set) var acpiAnalysisStatus = ""
    @Published public private(set) var acpiAnalysisSupported = false
    @Published public private(set) var isFnLocked = false
    @Published public private(set) var keyboardBacklight = -1
    @Published public private(set) var chargeStartThreshold = -1
    @Published public private(set) var chargeStopThreshold = -1
    @Published public private(set) var batteryIndex = 1
    @Published public private(set) var batteryIndividualAddressing = false
    @Published public private(set) var isConnected: Bool = false
    public enum DriverState: Equatable { case checking, ready, missing, unavailable }
    @Published public private(set) var driverState: DriverState = .checking
    @Published public private(set) var driverMessage = "Checking the hardware driver…"
    private var cpuUsesSMC = false
    private var gpuUsesSMC = false
    @Published public private(set) var cpuTemperatureSource = "Firmware CPU sensor"
    @Published public private(set) var cpuTemperatureReason = "Waiting for sensors"
    @Published public private(set) var gpuTemperatureSource = "No GPU temperature source"
    @Published public private(set) var gpuTemperatureReason = "Waiting for sensors"
    @Published public private(set) var cpuPowerModified = false
    @Published public private(set) var fanLabels = ["Fan 1", "Fan 2"]
    private let smcTemperatures = SMCTemperatureReader()
    private let acpiAnalysis = HardwareACPIAnalysis()
    public func setDriverState(_ state: DriverState, message: String) {
        driverState = state; driverMessage = message
        ReYogaDiagnostics.shared.record("driver_state", ["state": String(describing: state), "message": message])
    }

    @Published private(set) var fanHelper: ThinkFanHelper?
    @Published private(set) var fanHelper2: ThinkFanHelper?
    @Published private(set) var thinkFanAuthorizationBusy = false
    @Published private(set) var thinkFanAuthorizationError = ""
    private var requestThinkFanAuthorization: () -> Void = {}

    func configureThinkFanAuthorization(_ action: @escaping () -> Void) {
        requestThinkFanAuthorization = action
    }

    func authorizeThinkFanControls() { requestThinkFanAuthorization() }

    func setThinkFanAuthorization(busy: Bool, error: String = "") {
        thinkFanAuthorizationBusy = busy
        thinkFanAuthorizationError = error
    }

    func installFanHelpers(_ main: ThinkFanHelper?, secondary: ThinkFanHelper?) {
        fanHelper = main
        fanHelper2 = secondary
    }

    private var isControlsWindowVisible: () -> Bool = { false }
    private var closeDriverConnection: () -> Void = {}
    private var performHotkeyAction: (String) -> Void = { _ in }

    func configureApplicationActions(isControlsWindowVisible: @escaping () -> Bool,
                                     closeDriverConnection: @escaping () -> Void,
                                     performHotkeyAction: @escaping (String) -> Void) {
        self.isControlsWindowVisible = isControlsWindowVisible
        self.closeDriverConnection = closeDriverConnection
        self.performHotkeyAction = performHotkeyAction
    }

    private var connectionGeneration: UInt64 = 0
    var connectionIdentity: UInt64 { connectionGeneration }
    private(set) var isShuttingDown = false
    private var restoreOrigin = "startup"
    private var lastControlSnapshot: NSDictionary = [:]
    public internal(set) var service: io_service_t = 0 {
        didSet {
            if isShuttingDown { connectionGeneration &+= 1; isConnected = false; return }
            restoreOrigin = "startup"
            lastControlSnapshot = [:]
            fanHelper?.stopCurve(reason: .driverConnectionChanged); fanHelper2?.stopCurve(reason: .driverConnectionChanged)
            thinkFanCurveSupported = false; cpuSampleTime = 0
            thinkFanCurveReason = ""; thinkFanECNeedsHelpers = false
            powerProfileError = ""
            acpiAnalysisSupported = false
            acpiAnalysis.connectionChanged()
            connectionGeneration &+= 1
            queuedControls.removeAll()
            thinkFanTelemetrySupported = false
            lastThinkFanSampleTime = 0; lastThinkFanCommandTime = 0
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
                hotkeyProfileID = ""
                fan1RPM = -1; fan2RPM = -1; cpuTemp = -1; gpuTemp = -1
                hotkeyManager.disconnect()
                batteryDetails = []
                liveBattery = nil
                featureStatus = [:]
                providerClass = ""
                acpiECPath = ""
                acpiHKEYPath = ""
                driverVersion = "Unavailable"; profileMatchState = "Unavailable"; firmwareProfileID = ""
                featurePollingSupported = false; lastFirmwareRefresh = .distantPast
                fanLabels = ["Fan 1", "Fan 2"]
                hasDualFan = false; hasPowerProfiles = false; powerProfilesReady = false; hasConservation = false; hasRapidCharge = false
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
        acpiAnalysis.$busy.sink { [weak self] in self?.acpiAnalysisBusy = $0 }.store(in: &subscriptions)
        acpiAnalysis.$status.sink { [weak self] in self?.acpiAnalysisStatus = $0 }.store(in: &subscriptions)
        detectHardwareInfo()
        if !CommandLine.arguments.contains("--render-ui") && !CommandLine.arguments.contains("--check-missing-driver") { startMonitoring() }
        hotkeyManager.$hotkeysEnabled.sink { [weak self] in self?.hotkeysEnabled = $0 }.store(in: &subscriptions)
        hotkeyManager.$hotkeyStatus.sink { [weak self] in self?.hotkeyStatus = $0 }.store(in: &subscriptions)
        hotkeyManager.$hasAccessibilityPermission.sink { [weak self] in self?.hasAccessibilityPermission = $0 }.store(in: &subscriptions)
        hotkeyManager.$hasInputMonitoringPermission.sink { [weak self] in self?.hasInputMonitoringPermission = $0 }.store(in: &subscriptions)
        hotkeyManager.$permissionStatus.sink { [weak self] in self?.permissionStatus = $0 }.store(in: &subscriptions)
        guard !CommandLine.arguments.contains("--render-ui"), !CommandLine.arguments.contains("--check-missing-driver") else { return }
        lighting.$rgbStatus.sink { [weak self] in self?.rgbStatus = $0 }.store(in: &subscriptions)
        lighting.$rgbApplying.sink { [weak self] in self?.rgbApplying = $0 }.store(in: &subscriptions)
        lighting.$rgbMode.sink { [weak self] in self?.rgbMode = $0 }.store(in: &subscriptions)
        lighting.$logoState.compactMap { $0 }.sink { [weak self] in self?.isYLogoOn = $0 }.store(in: &subscriptions)
        lighting.detect { [weak self] profile in self?.acceptRGBDiscovery(profile) }
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
    @Published public private(set) var isApplying = false
    @Published public private(set) var applyingControl: String?
    private struct QueuedControl {
        let key: String
        let target: Int
        let boolean: Bool
        let title: String
        let restoring: Bool
    }
    private var queuedControls: [QueuedControl] = []
    @Published public private(set) var telemetryStatus = "Waiting for driver"
    @Published public private(set) var batterySummary = ""
    @Published public private(set) var liveBattery: LiveBatterySnapshot?
    @Published public private(set) var batteryDetails: [BatteryDetail] = []
    @Published public private(set) var featureStatus: [String: HardwareFeatureStatus] = [:]
    @Published public private(set) var cpuBoostWatts = 0
    @Published public private(set) var cpuSustainedWatts = 0
    @Published public private(set) var powerRanges: [String: [String: Int]] = [:]
    @Published public private(set) var manualFanMode = false
    @Published public private(set) var fan1TargetRPM = -1
    @Published public private(set) var fan2TargetRPM = -1
    @Published public private(set) var fanStepsRPM = [0, 0]
    @Published public private(set) var fan1MaxRPM = 0
    @Published public private(set) var fan2MaxRPM = 0
    private lazy var lighting = HardwareLightingManager(queue: hardwareQueue, feedback: { [weak self] in self?.feedback($0) })
    private var subscriptions = Set<AnyCancellable>()
    private lazy var hotkeyManager = HardwareHotkeyManager(feedback: { [weak self] in self?.feedback($0) }) { [weak self] action in
        guard let self = self else { return }
        self.performHotkeyAction(action)
    }
    @Published public private(set) var rgbStatus = HardwareFeatureStatus(available: false, reason: "RGB discovery pending", backend: "USB HID")
    @Published public private(set) var hasRGBHardware = false
    @Published public private(set) var rgbApplying = false
    @Published public private(set) var hotkeysEnabled = false
    @Published public private(set) var hotkeyStatus = "Off - native media keys remain active."
    @Published public private(set) var rgbMode = "Factory"
    @Published public private(set) var hasAccessibilityPermission = false
    @Published public private(set) var hasInputMonitoringPermission = false
    @Published public private(set) var permissionStatus = ""
    @Published public private(set) var hotkeyProfileID = ""
    @Published public private(set) var detailedLogging = UserDefaults.standard.bool(forKey: "DetailedLogging")

}

// MARK: - Telemetry
extension HardwareManager {
    public func startMonitoring() {
        guard !isShuttingDown else { return }
        stopMonitoring()
        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.thinkFanTelemetrySupported, self.lastThinkFanSampleTime > 0,
               ProcessInfo.processInfo.systemUptime - self.lastThinkFanSampleTime > ThinkFanSnapshot.maximumAge {
                self.publishThinkFans(ThinkFanReading(nil), ThinkFanReading(nil))
            }
            self.fanHelper?.checkCurveFreshness(); self.fanHelper2?.checkCurveFreshness()
            let curveActive = self.fanHelper?.curveEnabled == true || self.fanHelper2?.curveEnabled == true
            let visible = self.isControlsWindowVisible()
            if curveActive || visible || !self.pendingFanChecks.isEmpty || Date().timeIntervalSince(self.lastBackgroundRefresh) >= 2 {
                self.lastBackgroundRefresh = Date()
                self.refreshSnapshot(full: false)
            }
        }
        poll.tolerance = 0.05
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    public func stopMonitoring() {
        fanHelper?.stopCurve(reason: .monitoringStopped); fanHelper2?.stopCurve(reason: .monitoringStopped)
        timer?.invalidate()
        timer = nil
    }

    public func refreshAll() { refreshSnapshot(full: true) }
    public func refreshMetrics() { refreshSnapshot(full: false) }

    private func refreshSnapshot(full: Bool) {
        guard !isShuttingDown else { return }
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
        let refreshThinkFans = providerClass == "ThinkVPC" && thinkFanTelemetrySupported
        let refreshLegacyThinkFans = providerClass == "ThinkVPC" && !thinkFanTelemetrySupported && refreshFirmware
        hardwareQueue.async {
            if refreshFirmware { _ = sendBoolean("Update", true, handle) }
            else if refreshThinkFans { _ = sendBoolean("UpdateFans", true, handle) }
            let snapshot = getProperties(handle)
            let battery = LiveBatterySnapshot.read()
            let smcCPU = self.smcTemperatures.cpuTemperature()
            let smcGPU = self.smcTemperatures.gpuTemperature()
            let cpuReason = self.smcTemperatures.cpuReason
            let smcReason = self.smcTemperatures.reason
            let sampledAt = ProcessInfo.processInfo.systemUptime
            let firmwareSampleTime = (snapshot?["SensorSampleTimeMS"] as? NSNumber)?.doubleValue ?? 0
            let firmwareSampleSeconds = firmwareSampleTime / 1000
            let cpuSampleTime = smcCPU != nil ? sampledAt :
                (firmwareSampleSeconds.isFinite && firmwareSampleSeconds > 0 && firmwareSampleSeconds <= sampledAt ? firmwareSampleSeconds : 0)
            IOObjectRelease(handle)
            DispatchQueue.main.async {
                guard !self.isShuttingDown, generation == self.connectionGeneration, handle == self.service else { return }
                self.refreshInFlight = false
                if let snapshot = snapshot {
                    // Older kexts have no combined snapshot; keep their recovery polling on the shared clock.
                    if refreshLegacyThinkFans, snapshot["ThinkFanTelemetryVersion"] as? Int != 1 {
                        self.fanHelper?.update(); self.fanHelper2?.update()
                    }
                    self.acceptBatterySnapshot(snapshot, live: battery)
                    self.cpuUsesSMC = smcCPU != nil
                    self.gpuUsesSMC = smcGPU != nil
                    self.publish(\.cpuTemp, smcCPU.map { $0.celsius } ?? HardwareSnapshot.temperature(snapshot["CPUTemp"]))
                    self.publish(\.cpuTemperatureSource, smcCPU?.source ?? ((snapshot["SensorSources"] as? [String: String])?["CPUTemp"]) ?? "Firmware CPU sensor")
                    self.publish(\.cpuTemperatureReason, cpuReason)
                    if let reading = smcGPU {
                        self.publish(\.gpuTemp, reading.celsius)
                        self.publish(\.gpuTemperatureSource, reading.source)
                    }
                    if smcGPU == nil {
                        self.publish(\.gpuTemp, HardwareSnapshot.temperature(snapshot["GPUTemp"]))
                        self.publish(\.gpuTemperatureSource, self.gpuTemp > 0 ? ((snapshot["SensorSources"] as? [String: String])?["GPUTemp"]) ?? "Firmware GPU sensor" : "No GPU temperature source")
                    }
                    self.publish(\.gpuTemperatureReason, smcReason)
                    if self.detailedLogging {
                        ReYogaDiagnostics.shared.record("driver_snapshot", ["registry": snapshot,
                            "cpuSensorReason": cpuReason, "gpuSensorReason": smcReason,
                            "cpuC": self.cpuTemp, "gpuC": self.gpuTemp, "cpuSource": self.cpuTemperatureSource])
                    }
                    self.cpuSampleTime = cpuSampleTime
                    self.accept(snapshot)
                    for (index, fan) in [self.fanHelper, self.fanHelper2].enumerated() {
                        guard let fan = fan else { continue }
                        if !self.preferenceIdentity.isEmpty {
                            fan.loadCurve(key: SavedHardwareSettings.storageKey(self.preferenceIdentity) + ".ThinkFanCurve.\(index)")
                        }
                        if self.thinkFanCurveSupported && cpuSampleTime > 0 && ProcessInfo.processInfo.systemUptime - cpuSampleTime <= 3 {
                            fan.updateCurve(temperature: self.cpuTemp)
                        }
                        else { fan.stopCurve(reason: .capabilityOrTemperatureLost) }
                    }
                } else {
                    self.service = 0
                    self.setDriverState(.unavailable, message: "The hardware driver stopped responding. Retry the connection or check the driver log.")
                    self.closeDriverConnection()
                    self.telemetryStatus = "Driver unavailable"
                    self.featureStatus = [:]
                    ReYogaDiagnostics.shared.record("snapshot_failed", ["reason": "IORegistry read failed"])
                }
            }
        }
    }

    private func refreshIndependentSensors() {
        guard !isShuttingDown else { return }
        refreshInFlight = true
        let generation = connectionGeneration
        hardwareQueue.async {
            let battery = LiveBatterySnapshot.read()
            let cpu = self.smcTemperatures.cpuTemperature()
            let gpu = self.smcTemperatures.gpuTemperature()
            let cpuReason = self.smcTemperatures.cpuReason
            let gpuReason = self.smcTemperatures.reason
            DispatchQueue.main.async {
                guard !self.isShuttingDown, generation == self.connectionGeneration, self.service == 0 else { return }
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

    private func acceptBatterySnapshot(_ snapshot: NSDictionary, live: LiveBatterySnapshot?) {
        let batteryStatus = live?.summary ?? ""
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
        self.publish(\.liveBattery, live)
    }

    private func publish<Value: Equatable>(_ path: ReferenceWritableKeyPath<HardwareManager, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func acceptHardwareIdentity(_ props: NSDictionary, matchState: String) {
        let firmwareIdentity = props["FirmwareIdentityConflict"] as? Bool == true ? detectedIdentity :
            LaptopIdentity.resolve(strings: [(props["FirmwareMachineType"] as? String) ?? ""], pciIDs: [],
                                   lenovo: ["IdeaVPC", "ThinkVPC"].contains((props["IOClass"] as? String) ?? ""))
        let displayIdentity = firmwareIdentity.name != "Lenovo Laptop" && firmwareIdentity.name != "Unknown Laptop" ? firmwareIdentity : detectedIdentity
        if let driverModelName = props["HardwareProfileName"] as? String, !driverModelName.isEmpty,
           ["exact", "identity_matched", "pci_matched"].contains(matchState) {
            publish(\.modelName, driverModelName)
            publish(\.modelSource, matchState == "pci_matched" ? "PCI subsystem ID" : "Lenovo firmware identity")
            publish(\.modelWarning, "")
        } else {
            let lenovo = ["IdeaVPC", "ThinkVPC"].contains((props["IOClass"] as? String) ?? "")
            let isThinkPad = props["IOClass"] as? String == "ThinkVPC"
            let fallbackName = isThinkPad ? "ThinkPad" : "Lenovo Laptop"
            let name = (displayIdentity.name == "Unknown Laptop" || (displayIdentity.name == "Lenovo Laptop" && isThinkPad)) && lenovo ? fallbackName : displayIdentity.name
            publish(\.modelName, name)
            publish(\.modelSource, displayIdentity.source)
            let reason = (props["ProfileMatchReason"] as? String) ?? "Not reported"
            publish(\.modelWarning, ["conflict", "ambiguous"].contains(matchState) ? localizedMessage(reason) : "")
        }
    }

    private func acceptFanAndThermalSnapshot(_ props: NSDictionary) {
        func number(_ key: String) -> Int { (props[key] as? Int) ?? -1 }
        let declaredDualFan = providerClass == "ThinkVPC" ? props["Dual fan"] as? Bool : nil
        publish(\.hasDualFan, declaredDualFan ?? (number("Fan number") >= 0 ?
            number("Fan number") >= 2 : HardwareSnapshot.fanRPM(props["Fan2RPM"]) >= 0))
        if thinkFanTelemetrySupported {
            acceptThinkFanSnapshot(props["ThinkFanTelemetry"] as? [String: Any])
        } else {
            publish(\.fan1RPM, HardwareSnapshot.fanRPM(props["Fan1RPM"]))
            publish(\.fan2RPM, HardwareSnapshot.fanRPM(props["Fan2RPM"]))
        }
        if !cpuUsesSMC { publish(\.cpuTemp, HardwareSnapshot.temperature(props["CPUTemp"])) }
        if !gpuUsesSMC {
            publish(\.gpuTemp, HardwareSnapshot.temperature(props["GPUTemp"]))
            publish(\.gpuTemperatureSource, number("GPUTemp") > 0 ? ((props["SensorSources"] as? [String: String])?["GPUTemp"]) ?? "Firmware GPU sensor" : "No GPU temperature source")
        }
        for (fan, check) in pendingFanChecks {
            let rpm = fan == 0 ? fan1RPM : fan2RPM
            if rpm >= Int(Double(check.target) * 0.9) {
                pendingFanChecks.removeValue(forKey: fan)
                ReYogaDiagnostics.shared.record("fan_minimum_measured", ["fan": fan, "target": check.target, "actualRPM": rpm])
            } else if Date() >= check.deadline {
                pendingFanChecks.removeValue(forKey: fan)
                let label = fanLabels.indices.contains(fan) ? fanLabels[fan] : localizedMessage("Fan %@", String(describing: fan + 1))
                ReYogaDiagnostics.shared.record("fan_minimum_not_reached", ["fan": fan, "target": check.target, "actualRPM": rpm])
                feedback(.fanMinimumNotReached(label: label, targetRPM: check.target, actualRPM: rpm))
            }
        }
    }

    private func acceptControlReadback(_ props: NSDictionary, conservationMask: Int?, rapidMask: Int?, powerRanges: [String: [String: Int]]) {
        func number(_ key: String) -> Int { (props[key] as? Int) ?? -1 }
        func boolean(_ key: String) -> Bool { (props[key] as? Bool) ?? false }
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
        publish(\.powerRanges, powerRanges)
        publish(\.manualFanMode, number("FanControlMode") > 0)
        publish(\.fan1TargetRPM, HardwareSnapshot.fanRPM(props["Fan1TargetRPM"]))
        publish(\.fan2TargetRPM, HardwareSnapshot.fanRPM(props["Fan2TargetRPM"]))
        publish(\.fan1MaxRPM, max(number("Fan1MaxRPM"), 0))
        publish(\.fan2MaxRPM, max(number("Fan2MaxRPM"), 0))
        let mode = number("SmartFanMode")
        if !(1...3).contains(mode) { publish(\.powerProfile, 0) }
        if (1...3).contains(mode) && mode != powerProfile {
            publish(\.powerProfile, mode)
            if initialized && !isApplying { feedback(.powerProfile(mode)) }
        }
    }

    private func acceptTelemetryStatus(_ props: NSDictionary, sequence: Int, stale: Bool, protocolVersion: Int) {
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
        let interval = props["TelemetryIntervalMS"] as? Int
        let liveStatus = interval.map { $0 > 0 ? localizedMessage("Live • %@ ms", String(describing: $0)) : "Live" } ?? "Live"
        let status = sequence < 0 ? (protocolVersion == 1 ? "Firmware state refreshed" : "Driver update required") :
            stale ? "Telemetry stale - check driver log" : liveStatus
        if stale {
            publish(\.fan1RPM, -1); publish(\.fan2RPM, -1)
            if !cpuUsesSMC { publish(\.cpuTemp, -1) }
            if !gpuUsesSMC { publish(\.gpuTemp, -1) }
        }
        if status != telemetryStatus {
            telemetryStatus = status
            ReYogaDiagnostics.shared.record("telemetry_status", ["status": status])
        }
    }

    private func restoreSavedControlsIfNeeded(_ props: NSDictionary, sampleIsStale: Bool) {
        guard !isShuttingDown else { return }
        let firmwareDigest = (props["FirmwareDSDTSHA256"] as? String) ?? ""
        let profileIdentity = (props["HardwareProfile"] as? String) ?? ""
        preferenceIdentity = firmwareDigest.isEmpty && profileIdentity.isEmpty ? "" :
            profileIdentity + "|" + firmwareDigest + "|" + ((props["IOClass"] as? String) ?? "driver")
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

    private func accept(_ props: NSDictionary) {
        guard !isShuttingDown else { return }
        lastControlSnapshot = props
        publish(\.providerClass, (props["IOClass"] as? String) ?? "")
        publish(\.acpiECPath, (props["ACPIECPath"] as? String) ?? "")
        publish(\.acpiHKEYPath, (props["ACPIHKEYPath"] as? String) ?? "")
        publish(\.acpiAnalysisSupported, props["ThinkPadACPIAnalysisVersion"] as? Int == 1 && props["SafeMode"] as? Bool != true)
        publish(\.driverVersion, (props["VersionInfo"] as? String) ?? "Unavailable")
        publish(\.profileMatchState, (props["ProfileMatchState"] as? String) ?? "Not reported")
        publish(\.firmwareProfileID, (props["HardwareProfile"] as? String) ?? "")
        featurePollingSupported = props["FeaturePollingVersion"] as? Int == 1
        thinkFanTelemetrySupported = providerClass == "ThinkVPC" && props["ThinkFanTelemetryVersion"] as? Int == 1
        publish(\.thinkFanCurveSupported, ThinkFanCurvePolicy.supported(props))
        publish(\.thinkFanCurveReason, ThinkFanCurvePolicy.unavailableReason(props) ?? "")
        publish(\.thinkFanECNeedsHelpers, providerClass == "ThinkVPC" && props["ThinkFanProtocolVersion"] as? Int == 1 &&
            props["SafeMode"] as? Bool != true && props["EC Capability"] as? String != "RW")
        publish(\.isFnLocked, (props["FnlockMode"] as? Bool) ?? false)
        publish(\.keyboardBacklight, (props["BacklightLevel"] as? Int) ?? -1)
        publish(\.chargeStartThreshold, (props["ChargeStartThreshold"] as? Int) ?? -1)
        publish(\.chargeStopThreshold, (props["ChargeStopThreshold"] as? Int) ?? -1)
        publish(\.batteryIndex, (props["BatteryIndex"] as? Int) ?? 1)
        publish(\.batteryIndividualAddressing, (props["BatteryIndividualAddressing"] as? Bool) ?? false)
        publish(\.cpuPowerModified, (props["CPUPowerModified"] as? Bool) ?? false)
        if let profileID = props["HardwareProfile"] as? String,
           let labels = HardwareProfiles.all().first(where: { $0["id"] as? String == profileID })?["fan_labels"] as? [String], labels.count == 2 {
            publish(\.fanLabels, labels)
        } else { publish(\.fanLabels, ["Fan 1", "Fan 2"]) }
        let descriptors = (props["FeatureStatus"] as? [String: [String: Any]]) ?? [:]
        if let profile = props["HardwareProfile"] as? String { hotkeyProfileID = profile }
        else { hotkeyProfileID = lighting.matchedProfileID ?? "" }
        let matchState = (props["ProfileMatchState"] as? String) ?? ""
        let sequence = (props["SensorSampleSequence"] as? Int) ?? -1
        let observationAge = sequence != lastSampleSequence ? 0 : Date().timeIntervalSince(lastSampleDate)
        let sampleIsStale = sequence >= 0 && HardwareSnapshot.stale(props,
            observedAge: observationAge, uptime: ProcessInfo.processInfo.systemUptime)
        acceptHardwareIdentity(props, matchState: matchState)
        let protocolVersion = (props["ControlProtocolVersion"] as? Int) ?? 0
        let capabilities = HardwareCapabilities(props, rgbStatus: rgbStatus, rgbMode: rgbMode, sampleIsStale: sampleIsStale)
        let availability = capabilities.features
        publish(\.fanStepsRPM, capabilities.fanStepsRPM)
        if let state = capabilities.conservationState { publish(\.isConservationOn, state) }
        if let state = capabilities.rapidChargeState { publish(\.isRapidChargeOn, state) }
        if availability != featureStatus {
            featureStatus = availability
            ReYogaDiagnostics.shared.record("capabilities", availability.mapValues { ["available": $0.available, "reason": $0.reason, "backend": $0.backend] })
        }
        func supported(_ key: String) -> Bool { availability[key]?.available == true }
        publish(\.hasConservation, supported("ConservationMode"))
        publish(\.hasRapidCharge, supported("RapidChargeMode"))
        publish(\.hasAlwaysOnUSB, supported("AlwaysOnUSBState"))
        publish(\.hasPowerProfiles, descriptors["SmartFanMode"]?["Available"] as? Bool == true)
        publish(\.powerProfilesReady, supported("SmartFanMode"))
        let profileResult = props["LastControlResult"] as? [String: Any]
        let profileFailed = profileResult?["Property"] as? String == "SmartFanMode" &&
            ((profileResult?["Status"] as? Int) ?? 0) != 0
        publish(\.powerProfileError, profileFailed ? (profileResult?["Reason"] as? String) ?? "Firmware call failed" : "")
        publish(\.hasOverDrive, supported("DisplayOverDrive"))
        publish(\.hasTouchpadLock, supported("TouchpadLock"))
        publish(\.hasYLogo, supported("YLogoStatus"))
        publish(\.hasPortLighting, supported("PortLighting"))
        acceptFanAndThermalSnapshot(props)
        acceptControlReadback(props, conservationMask: capabilities.conservationMask, rapidMask: capabilities.rapidChargeMask, powerRanges: capabilities.powerRanges)
        acceptTelemetryStatus(props, sequence: sequence, stale: sampleIsStale, protocolVersion: protocolVersion)
        initialized = true
        restoreSavedControlsIfNeeded(props, sampleIsStale: sampleIsStale)
    }
}

// MARK: - ThinkPad fans
extension HardwareManager {
    func startThinkFanCurve(_ fan: ThinkFanHelper, points: [ThinkFanCurvePoint]? = nil) {
        guard !isShuttingDown, points.map(ThinkFanCurvePolicy.valid) ?? true else { return }
        guard service != 0, driverState == .ready else {
            ReYogaDiagnostics.shared.record("think_fan_curve_rejected", ["reason": "driver_not_ready",
                "driverState": String(describing: driverState), "servicePresent": service != 0])
            fan.explainCurveUnavailable("The driver connection is unavailable. Reconnect before starting Custom Curve.")
            feedback(.curveRejected(fan.curveStatus))
            return
        }
        guard cpuSampleTime > 0, ProcessInfo.processInfo.systemUptime - cpuSampleTime <= 3 else {
            ReYogaDiagnostics.shared.record("think_fan_curve_rejected", ["reason": "temperature_not_fresh",
                "source": cpuTemperatureSource, "sampleAgeSeconds": ProcessInfo.processInfo.systemUptime - cpuSampleTime])
            fan.explainCurveUnavailable("CPU temperature is unavailable or stale. Wait for a fresh reading before starting Custom Curve.")
            feedback(.curveRejected(fan.curveStatus))
            return
        }
        performThinkFanCommand(fan) {
            if let points = points { fan.stopCurve(); fan.curvePoints = points }
            fan.startCurve(temperature: self.cpuTemp, supported: self.thinkFanCurveSupported)
        }
    }

    private func publishThinkFans(_ main: ThinkFanReading, _ secondary: ThinkFanReading) {
        publish(\.fan1RPM, main.rpm ?? -1); publish(\.fan2RPM, secondary.rpm ?? -1)
        fanHelper?.acceptSnapshot(main); fanHelper2?.acceptSnapshot(secondary)
    }

    private func acceptThinkFanSnapshot(_ properties: [String: Any]?) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let sample = ThinkFanSnapshot(properties) else {
            publishThinkFans(ThinkFanReading(nil), ThinkFanReading(nil))
            return
        }
        let previous = max(lastThinkFanSampleTime, lastThinkFanCommandTime)
        guard sample.sampledAt >= previous else { return }
        guard sample.isCurrent(at: uptime, after: previous) else {
            publishThinkFans(ThinkFanReading(nil), ThinkFanReading(nil))
            return
        }
        lastThinkFanSampleTime = sample.sampledAt
        publishThinkFans(sample.main, sample.secondary)
    }

    func performThinkFanCommand(_ fan: ThinkFanHelper, action: () -> Void) {
        guard !isShuttingDown else { return }
        guard !CommandLine.arguments.contains("--render-ui"), service != 0, driverState == .ready,
              fan === (fan.main ? fanHelper : fanHelper2) else { return }
        action()
        lastThinkFanCommandTime = ProcessInfo.processInfo.systemUptime
        lastThinkFanSampleTime = lastThinkFanCommandTime
        publish(fan.main ? \.fan1RPM : \.fan2RPM, fan.rpm ?? -1)
        refreshMetrics()
    }

}

// MARK: - Control requests and restore
extension HardwareManager {
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
        guard !isShuttingDown, service != 0, driverState == .ready, !isApplying else { return }
        while !restoringControls.isEmpty {
            let (key, saved) = restoringControls.removeFirst()
            let profileMatches = saved.powerProfile == nil || saved.powerProfile == powerProfile
            let rgbPreference: SavedRGBSettings? = UserDefaults.standard.data(forKey: "AppliedRGBSettings")
                .flatMap { data in
                    guard data.count <= SavedRGBSettings.maximumSavedBytes else { return nil }
                    return try? JSONDecoder().decode(SavedRGBSettings.self, from: data)
                }
            let lightingOwnedByRGB = lighting.ownsLighting(key, settings: rgbPreference)
            guard featureStatus[key]?.available == true, profileMatches, !lightingOwnedByRGB else {
                ReYogaDiagnostics.shared.record("preference_restore_skipped", ["property": key, "reason": lightingOwnedByRGB ? "USB RGB owns lighting" : !profileMatches ? "Power profile differs" : featureStatus[key]?.reason ?? "Backend unavailable"])
                continue
            }
            if key == "CPUBoostPower" || key == "CPUSustainedPower" {
                guard let range = powerRanges[key], PowerLimitInput.isValid(String(saved.value), range: range) else { continue }
            }
            if let actual = lastControlSnapshot[key] as? NSNumber,
               actual == (saved.boolean ? NSNumber(value: saved.value != 0) : NSNumber(value: saved.value)) {
                continue
            }
            apply(key, saved.value, boolean: saved.boolean, title: HardwareFeatureStatus.catalog[key] ?? key, restoring: true)
            return
        }
    }
    public func restoreAfterWake() {
        guard !isShuttingDown else { return }
        restoreOrigin = "wake"
        ReYogaDiagnostics.shared.record("restore_after_wake", ["generation": connectionGeneration])
        controlsRestoreAttempted = false
        if rgbStatus.available { retryRGBDiscovery() }
        refreshAll()
    }

    private func dequeueControl() {
        guard !queuedControls.isEmpty else { return }
        let next = queuedControls.removeFirst()
        let generation = connectionGeneration
        DispatchQueue.main.async {
            guard generation == self.connectionGeneration else { return }
            self.apply(next.key, next.target, boolean: next.boolean, title: next.title, restoring: next.restoring)
        }
    }

    private func apply(_ key: String, _ target: Int, boolean: Bool = false, title: String, restoring: Bool = false) {
        guard !isShuttingDown else { return }
        if !restoring {
            restoringControls.removeAll()
            queuedControls.removeAll { $0.restoring }
        }
        if isApplying {
            queuedControls.removeAll { $0.key == key }
            guard queuedControls.count < 32 else {
                ReYogaDiagnostics.shared.record("control_queue_full", ["property": key])
                return
            }
            queuedControls.append(QueuedControl(key: key, target: target, boolean: boolean, title: title, restoring: restoring))
            return
        }
        guard service != 0, featureStatus[key]?.available == true else {
            let reason = featureStatus[key]?.reason ?? "Driver unavailable"
            feedback(.control(key: key, target: target, title: title, failure: reason))
            ReYogaDiagnostics.shared.record("control_unavailable", ["property": key, "reason": reason])
            dequeueControl()
            return
        }
        isApplying = true
        applyingControl = key
        let handle = service
        let generation = connectionGeneration
        IOObjectRetain(handle)
        let requestID = UUID().uuidString
        let targetValue: Any = boolean ? (target != 0) : target
        ReYogaDiagnostics.shared.record("control_requested", ["id": requestID, "property": key, "target": targetValue,
            "origin": restoring ? restoreOrigin : "user", "generation": generation])
        hardwareQueue.async {
            let result = DriverControlTransport.perform(key: key, targetValue: targetValue, requestID: requestID, service: handle)
            IOObjectRelease(handle)
            DispatchQueue.main.async {
                guard !self.isShuttingDown, generation == self.connectionGeneration, handle == self.service else { return }
                if let snapshot = result.snapshot { self.accept(snapshot) }
                self.isApplying = false
                self.applyingControl = nil
                self.dequeueControl()
                if result.confirmed && !restoring { self.saveHardwareSetting(key, target: target, boolean: boolean) }
                if restoring { DispatchQueue.main.async { self.restoreNextControl() } }
                if result.confirmed && key.contains("TargetRPM") && target > 0 {
                    let fan = key == "Fan1TargetRPM" ? 0 : 1
                    self.pendingFanChecks[fan] = (target, Date().addingTimeInterval(12))
                }
                if !restoring || !result.confirmed {
                    self.feedback(.control(key: key, target: target, title: title, failure: result.confirmed ? nil : result.reason))
                }
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
        apply(fan == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM", rpm, title: fanLabels[fan])
    }
    public func resetPowerLimits() { apply("CPUPowerReset", 0, title: "CPU Power Limits") }
    public func setPowerLimit(_ key: String, watts: Int) {
        guard key == "CPUBoostPower" || key == "CPUSustainedPower" else { return }
        guard let range = powerRanges[key], PowerLimitInput.isValid(String(watts), range: range) else { return }
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
        guard hasYLogo else { feedback(.logoUnavailable(featureStatus["YLogoStatus"]?.reason ?? "Logo control unavailable")); return }
        if rgbMode != "Factory", rgbStatus.available {
            lighting.setLogoEnabled(!isYLogoOn)
        } else {
            if rgbStatus.available { lighting.releaseFactoryLighting() }
            apply("YLogoStatus", isYLogoOn ? 0 : 1, boolean: true, title: "Logo Lighting")
        }
    }
    public func togglePortLighting() { apply("PortLighting", isPortLightingOn ? 0 : 1, boolean: true, title: "Port Lighting") }
    public func setDetailedLogging(_ enabled: Bool) {
        guard !isShuttingDown else { return }
        detailedLogging = enabled
        UserDefaults.standard.set(enabled, forKey: "DetailedLogging")
        let handle = service
        if handle != 0 {
            IOObjectRetain(handle)
            hardwareQueue.async { _ = sendBoolean("DetailedTelemetry", enabled, handle); IOObjectRelease(handle) }
        }
        ReYogaDiagnostics.shared.record("logging", ["detailed": enabled])
        feedback(.detailedLogging(enabled))
    }
}

// MARK: - Diagnostics
extension HardwareManager {
    public func exportDiagnostics(to output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isShuttingDown else { return }
        HardwareDiagnosticsExporter.export(queue: hardwareQueue, to: output, capture: {
            HardwareDiagnosticsExporter.snapshot(for: self, cpuSampleTime: self.cpuSampleTime)
        }, completion: completion)
    }
}

// MARK: - ACPI export
extension HardwareManager {
    public var isThinkPadDevice: Bool {
        if providerClass == "ThinkVPC" { return true }
        if providerClass == "IdeaVPC" { return false }
        let name = modelName.isEmpty ? detectedIdentity.name : modelName
        return name.contains("ThinkPad")
    }
    public var canGenerateACPIBridge: Bool {
        if providerClass == "ThinkVPC" { return false }
        if providerClass == "IdeaVPC" { return true }
        return !isThinkPadDevice
    }
    public var canGenerateThinkPadSSDT: Bool {
        service != 0 && providerClass == "ThinkVPC" && acpiAnalysisSupported && !acpiAnalysisBusy &&
            ACPIExport.acpiNamespacePath(acpiECPath) != nil &&
            ACPIExport.acpiNamespacePath(acpiHKEYPath) != nil
    }
    public func generateThinkPadSSDT(to output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard canGenerateThinkPadSSDT else { return }
        acpiAnalysis.generateThinkPadSSDT(service: service, output: output, completion: completion)
    }
    public func verifyThinkPadSSDT() {
        guard canGenerateThinkPadSSDT else { return }
        acpiAnalysis.verifyThinkPadSSDT(service: service)
    }
}

// MARK: - UI review fixtures
#if DEBUG
extension HardwareManager {
    func loadUIFixture(_ props: NSDictionary) {
        stopMonitoring()
        controlsRestoreAttempted = true
        let snapshot = props.mutableCopy() as! NSMutableDictionary
        let reviewState = props["UIReview"] as? [String: Any] ?? [:]
        snapshot["SensorSampleTimeMS"] = reviewState["Stale"] as? Bool == true ? 0 : ProcessInfo.processInfo.systemUptime * 1000
        applyPreview(HardwarePreviewSnapshot.fixture(snapshot))
        // Review metadata is consumed only by the DEBUG fixture entry point.
        guard CommandLine.arguments.contains("--render-ui"), let review = props["UIReview"] as? [String: Any] else { return }
        if let rgb = review["RGBAvailable"] as? Bool {
            rgbStatus = HardwareFeatureStatus(available: rgb, reason: review["RGBReason"] as? String ?? "", backend: "USB HID")
        }
        if providerClass == "ThinkVPC" {
            let main = ThinkFanHelper(connection: 0, isMainFan: true)
            let secondary = ThinkFanHelper(connection: 0, isMainFan: false)
            main.loadUIReview(rpm: fan1RPM, curve: review["ThinkCurve"] as? Bool == true)
            secondary.loadUIReview(rpm: fan2RPM, curve: review["ThinkCurve"] as? Bool == true)
            installFanHelpers(main, secondary: hasDualFan ? secondary : nil)
        }
        rgbMode = review["RGBMode"] as? String ?? "Factory"
        isApplying = review["Applying"] as? Bool ?? false
        applyingControl = review["ApplyingControl"] as? String
        acpiAnalysisStatus = review["ACPIStatus"] as? String ?? ""
        if review["MissingDriver"] as? Bool == true { loadMissingDriverPreview() }
        if let message = review["DriverError"] as? String {
            driverState = .unavailable; isConnected = false; driverMessage = message
        }
    }

    private func applyPreview(_ preview: HardwarePreviewSnapshot) {
        isConnected = true
        driverState = .ready
        accept(preview.properties)
        if let reading = preview.cpu { cpuUsesSMC = true; cpuTemp = reading.celsius; cpuTemperatureSource = reading.source }
        if let reading = preview.gpu { gpuUsesSMC = true; gpuTemp = reading.celsius; gpuTemperatureSource = reading.source }
        liveBattery = preview.liveBattery
        batteryDetails = preview.batteryDetails
    }

    func loadMissingDriverPreview() {
        stopMonitoring()
        isConnected = false
        driverState = .missing
        driverMessage = "Firmware driver unavailable. Independent battery, SMC and USB RGB functions remain accessible."
        featureStatus = [:]
        hasDualFan = false; hasPowerProfiles = false; powerProfilesReady = false; hasConservation = false; hasRapidCharge = false
        hasOverDrive = false; hasTouchpadLock = false; hasYLogo = false; hasPortLighting = false; hasAlwaysOnUSB = false
        fan1RPM = -1; fan2RPM = -1; powerProfile = 0
        telemetryStatus = "Independent sensors"
    }
    func loadReadOnlyPreview(_ handle: io_service_t) {
        controlsRestoreAttempted = true
        guard let preview = HardwarePreviewSnapshot.readOnly(handle, temperatures: smcTemperatures) else { return }
        applyPreview(preview)
        batterySummary = liveBattery?.summary ?? ""
    }
}
#endif

// MARK: - Hotkey permissions
extension HardwareManager {
    public func refreshPermissions() { hotkeyManager.refreshPermissions(profileID: hotkeyProfileID, driverReady: driverState == .ready) }
    public func setHotkeysEnabled(_ enabled: Bool) { hotkeyManager.setEnabled(enabled, profileID: hotkeyProfileID, driverReady: driverState == .ready) }
}

// MARK: - RGB lighting
extension HardwareManager {
    public func retryRGBDiscovery() {
        lighting.detect(retry: true) { [weak self] profile in self?.acceptRGBDiscovery(profile) }
    }
    private func acceptRGBDiscovery(_ profile: String?) {
        hasRGBHardware = profile != nil
        if let profile = profile { hotkeyProfileID = profile }
        refreshPermissions()
    }
    public func setRGBZone(_ zone: String, color: RGBBytes) { lighting.setRGBZone(zone, color: color) }
    public func restoreRGBHardwareMode() { lighting.restoreRGBHardwareMode() }
    public func setRGBEffect(_ mode: String, colors: [String: RGBBytes]) { lighting.setRGBEffect(mode, colors: colors) }
    public func importRGBColors(from file: URL) { lighting.importRGBColors(from: file) }
}

// MARK: - Shutdown
extension HardwareManager {
    public func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        connectionGeneration &+= 1
        queuedControls.removeAll(); restoringControls.removeAll(); pendingFanChecks.removeAll()
        refreshInFlight = false; isApplying = false; applyingControl = nil
        acpiAnalysis.connectionChanged()
        fanHelper?.stopCurve(reason: .appShutdown); fanHelper2?.stopCurve(reason: .appShutdown)
        hotkeyManager.stop()
        lighting.beginShutdown()
        hardwareQueue.sync {
            self.lighting.shutdownOnHardwareQueue()
            self.smcTemperatures.close()
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
