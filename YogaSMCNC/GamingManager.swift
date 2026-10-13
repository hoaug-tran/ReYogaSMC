import Foundation
import Combine
import IOKit

@available(macOS 11.0, *)
public final class GamingManager: ObservableObject {
    public static let shared = GamingManager()

    @Published public var modelName: String = ""
    @Published public var cpuBrand: String = ""

    @Published public var hasDualFan: Bool = false
    @Published public var hasThermalProfiles: Bool = false
    @Published public var hasConservation: Bool = true
    @Published public var hasRapidCharge: Bool = true
    @Published public var hasFullFan: Bool = false
    @Published public var hasOverDrive: Bool = false
    @Published public var hasWinKeyLock: Bool = false
    @Published public var hasTouchpadLock: Bool = false
    @Published public var hasYLogo: Bool = false
    @Published public var hasPortLighting: Bool = false
    @Published public var hasAlwaysOnUSB: Bool = false

    @Published public var cpuFanRPM: Int = 0
    @Published public var gpuFanRPM: Int = 0
    @Published public var cpuTemp: Int = 0
    @Published public var gpuTemp: Int = 0
    @Published public var thermalMode: Int = 2
    @Published public var alwaysOnUSBState: Int = 0
    @Published public var isConservationOn: Bool = false
    @Published public var isRapidChargeOn: Bool = false
    @Published public var isFullFanOn: Bool = false
    @Published public var isOverDriveOn: Bool = false
    @Published public var isWinKeyLocked: Bool = false
    @Published public var isTouchpadLocked: Bool = false
    @Published public var isYLogoOn: Bool = false
    @Published public var isPortLightingOn: Bool = false
    @Published public var isConnected: Bool = false

    public var service: io_service_t = 0 {
        didSet {
            isConnected = service != 0
            if isConnected {
                detectHardwareInfo()
                refreshAll()
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    private var timer: Timer?

    public init() {
        detectHardwareInfo()
    }

    public func detectHardwareInfo() {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var data = [CChar](repeating: 0, count: Int(size))
            sysctlbyname("machdep.cpu.brand_string", &data, &size, nil, 0)
            cpuBrand = String(cString: data).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if platformExpert != 0 {
            defer { IOObjectRelease(platformExpert) }
            if let prodData = IORegistryEntryCreateCFProperty(platformExpert, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
               let name = String(data: prodData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !name.isEmpty {
                modelName = name
            } else if let modelData = IORegistryEntryCreateCFProperty(platformExpert, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
                      let name = String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !name.isEmpty {
                modelName = name
            }
        }
        if modelName.isEmpty {
            sysctlbyname("hw.model", nil, &size, nil, 0)
            if size > 0 {
                var data = [CChar](repeating: 0, count: Int(size))
                sysctlbyname("hw.model", &data, &size, nil, 0)
                modelName = String(cString: data).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if modelName.isEmpty {
            modelName = "Lenovo Laptop"
        }
    }

    public func startMonitoring() {
        stopMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshMetrics()
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func refreshAll() {
        guard service != 0 else { return }
        refreshMetrics()

        let mode = getNumber("SmartFanMode", service)
        hasThermalProfiles = (mode > 0)
        if mode > 0 { thermalMode = mode }

        let fans = getNumber("Fan number", service)
        let hasFanMethod = getBoolean("LenovoFanMethod", service)
        hasDualFan = (fans >= 2) || hasFanMethod || (gpuFanRPM > 0)

        let usbState = getNumber("AlwaysOnUSBState", service)
        let usbMode = getBoolean("AlwaysOnUSBMode", service)
        hasAlwaysOnUSB = (usbState >= 0) || usbMode
        if usbState >= 0 {
            alwaysOnUSBState = usbState
        } else {
            alwaysOnUSBState = usbMode ? 1 : 0
        }

        isConservationOn = getBoolean("ConservationMode", service)
        isRapidChargeOn = getBoolean("RapidChargeMode", service)

        let od = getNumber("DisplayOverDrive", service)
        hasOverDrive = (od >= 0)
        isOverDriveOn = (od == 1)

        let wk = getNumber("WinKeyLock", service)
        hasWinKeyLock = (wk >= 0)
        isWinKeyLocked = (wk == 1)

        let tp = getNumber("TouchpadLock", service)
        hasTouchpadLock = (tp >= 0)
        isTouchpadLocked = (tp == 1)

        let full = getBoolean("FanFullSpeed", service)
        hasFullFan = hasFanMethod
        isFullFanOn = full

        let hasLighting = getBoolean("LenovoLightingMethod", service)
        hasYLogo = hasLighting
        hasPortLighting = hasLighting
        isYLogoOn = getBoolean("YLogoStatus", service)
        isPortLightingOn = getBoolean("PortLighting", service)
    }

    public func refreshMetrics() {
        guard service != 0 else { return }

        let r1 = getNumber("Fan1RPM", service)
        let r2 = getNumber("Fan2RPM", service)
        if r1 >= 0 { cpuFanRPM = r1 }
        if r2 >= 0 { gpuFanRPM = r2 }

        let t1 = getNumber("CPUTemp", service)
        let t2 = getNumber("GPUTemp", service)
        if t1 >= 0 { cpuTemp = t1 }
        if t2 >= 0 { gpuTemp = t2 }

        let mode = getNumber("SmartFanMode", service)
        if mode > 0 && mode != thermalMode { thermalMode = mode }

        let full = getBoolean("FanFullSpeed", service)
        if full != isFullFanOn { isFullFanOn = full }
    }

    public func setThermalMode(_ mode: Int) {
        guard service != 0 else { return }
        if sendNumber("SmartFanMode", mode, service) {
            thermalMode = mode
        }
    }

    public func setAlwaysOnUSBState(_ state: Int) {
        guard service != 0 else { return }
        if sendNumber("AlwaysOnUSBState", state, service) {
            alwaysOnUSBState = state
        }
    }

    public func toggleConservation() {
        guard service != 0 else { return }
        let target = !isConservationOn
        if sendBoolean("ConservationMode", target, service) {
            isConservationOn = target
            if target && isRapidChargeOn {
                isRapidChargeOn = false
            }
        }
    }

    public func toggleRapidCharge() {
        guard service != 0 else { return }
        let target = !isRapidChargeOn
        if sendBoolean("RapidChargeMode", target, service) {
            isRapidChargeOn = target
            if target && isConservationOn {
                isConservationOn = false
            }
        }
    }

    public func toggleFullFan() {
        guard service != 0 else { return }
        let target = !isFullFanOn
        if sendBoolean("FanFullSpeed", target, service) {
            isFullFanOn = target
        }
    }

    public func toggleOverDrive() {
        guard service != 0 else { return }
        let target = !isOverDriveOn
        if sendNumber("DisplayOverDrive", target ? 1 : 0, service) {
            isOverDriveOn = target
        }
    }

    public func toggleWinKey() {
        guard service != 0 else { return }
        let target = !isWinKeyLocked
        if sendNumber("WinKeyLock", target ? 1 : 0, service) {
            isWinKeyLocked = target
        }
    }

    public func toggleTouchpad() {
        guard service != 0 else { return }
        let target = !isTouchpadLocked
        if sendNumber("TouchpadLock", target ? 1 : 0, service) {
            isTouchpadLocked = target
        }
    }

    public func toggleYLogo() {
        guard service != 0 else { return }
        let target = !isYLogoOn
        if sendBoolean("YLogoStatus", target, service) {
            isYLogoOn = target
        }
    }

    public func togglePortLighting() {
        guard service != 0 else { return }
        let target = !isPortLightingOn
        if sendBoolean("PortLighting", target, service) {
            isPortLightingOn = target
        }
    }
}
