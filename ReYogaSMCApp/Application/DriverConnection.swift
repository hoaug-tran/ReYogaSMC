import AppKit
import Foundation
import IOKit
import os.log

// Main-thread owner; callback contexts borrow this owner and its stable DriverEventContext.
final class DriverConnection: NSObject {
    private let context = DriverEventContext()
    private let manager: HardwareManager
    private let defaults = ReYogaConstants.userDefaults
    private let prepareControls: () -> Void
    private var provider = "ReYogaSMC"
    private(set) var hide = false
    private(set) var hideCapslock = false
    private var driverPort: IONotificationPortRef?
    private var driverInterest: io_object_t = 0
    private var connectionGeneration: UInt64 = 0
    private var thinkWakeObserver: NSObjectProtocol?
    private var thinkSleepObserver: NSObjectProtocol?
    private var fanHelper: ThinkFanHelper?
    private var fanHelper2: ThinkFanHelper?

    init(manager: HardwareManager, prepareControls: @escaping () -> Void) {
        self.manager = manager
        self.prepareControls = prepareControls
        super.init()
    }

    var hasConnection: Bool { context.service != 0 || context.connect != 0 }
    var modifierFlags: NSEvent.ModifierFlags { context.modifier }

    func updateModifierFlags(_ flags: NSEvent.ModifierFlags) { context.modifier = flags }

    func configureEventActions(showSettings: @escaping () -> Void, toggleControls: @escaping () -> Void,
                               refreshHardware: @escaping () -> Void) {
        context.showSettings = showSettings
        context.toggleControls = toggleControls
        context.refreshHardware = refreshHardware
    }

    func connect() {
        guard !manager.isShuttingDown else { return }
        guard context.connect == 0 else { return }
        manager.setDriverState(.checking, message: "Checking the hardware driver…")
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOService") as NSMutableDictionary? else {
            manager.setDriverState(.unavailable, message: "Cannot allocate driver discovery request")
            return
        }
        matching[kIOPropertyMatchKey] = ["ForkName": "ReYogaSMC"]
        let result = IOServiceGetMatchingServices(kIOMasterPortDefault, matching as CFDictionary, &iterator)
        defer { if iterator != 0 { IOObjectRelease(iterator) } }
        var found = false
        var error = "ReYogaSMC.kext is required. Install the driver and its required dependencies in your bootloader, then restart macOS."
        if result == kIOReturnSuccess {
            var candidates: [io_service_t] = []
            while let service = IOIteratorNextOptional(iterator) { candidates.append(service) }
            defer { candidates.forEach { IOObjectRelease($0) } }
            candidates.sort {
                HardwareSnapshot.providerPriority(getProperties($0)?["IOClass"] as? String ?? "") >
                    HardwareSnapshot.providerPriority(getProperties($1)?["IOClass"] as? String ?? "")
            }
            for service in candidates {
                found = true
                guard let props = getProperties(service), let provider = props["IOClass"] as? String,
                      ["IdeaVPC", "ThinkVPC", "DYVPC", "ReYogaHIDD"].contains(provider) else {
                    if error.hasPrefix("ReYogaSMC.kext is required") {
                        error = "The kext is loaded, but no supported Lenovo firmware control interface is available. Independent SMC sensors and USB RGB remain available."
                    }
                    continue
                }
                if props["SafeMode"] as? Bool == true {
                    error = (props["SafeModeReason"] as? String) ?? "Driver safe mode is active; firmware controls are disabled"
                    continue
                }
                let protocolVersion = (props["ControlProtocolVersion"] as? Int) ?? 0
                if ["IdeaVPC", "ThinkVPC"].contains(provider) && protocolVersion != 1 {
                    error = "The loaded driver does not provide a compatible control protocol. Boot the matching ReYogaSMC driver and retry."
                    continue
                }
                var connection: io_connect_t = 0
                let openStatus = IOServiceOpen(service, mach_task_self_, 0, &connection)
                guard openStatus == kIOReturnSuccess else {
                    error = String(format: localizedMessage("Cannot open the hardware driver (0x%08x). Check permissions and the driver log."), openStatus)
                    continue
                }
                let claim = IOConnectCallScalarMethod(connection, UInt32(kRYSMCUCOpen), nil, 0, nil, nil)
                guard claim == kIOReturnSuccess else {
                    error = String(format: localizedMessage("The driver rejected the connection (0x%08x). Another copy of this app may already be running."), claim)
                    IOServiceClose(connection); continue
                }
                IOObjectRetain(service)
                context.service = service; context.connect = connection; self.provider = provider
                manager.setDriverState(.ready, message: "Hardware driver ready")
                watchDriverTermination(service)
                loadConfig()
                initNotification(props["EC Capability"] as? String)
                return
            }
        } else { error = String(format: localizedMessage("IOKit driver discovery failed (0x%08x)."), result) }
        manager.setDriverState(found ? .unavailable : .missing, message: error)
        prepareControls()
    }

    private func watchDriverTermination(_ service: io_service_t) {
        guard let port = IONotificationPortCreate(kIOMasterPortDefault) else { return }
        driverPort = port
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let status = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, service, message, _ in
            guard message == ReYogaServiceTerminatedMessage(), let context = context else { return }
            let owner = Unmanaged<DriverConnection>.fromOpaque(context).takeUnretainedValue()
            let generation = owner.connectionGeneration
            DispatchQueue.main.async {
                guard generation == owner.connectionGeneration, owner.context.service == service else { return }
                owner.manager.service = 0
                owner.close()
                owner.manager.setDriverState(.unavailable, message: "The hardware driver disconnected. Retry the connection or restart with the matching kext.")
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &driverInterest)
        if status != kIOReturnSuccess { IONotificationPortDestroy(port); driverPort = nil }
    }

    func close() {
        connectionGeneration &+= 1
        if manager.service != 0 { manager.service = 0 }
        fanHelper?.stopCurve(reason: .connectionClosed); fanHelper2?.stopCurve(reason: .connectionClosed)
        if driverInterest != 0 { IOObjectRelease(driverInterest); driverInterest = 0 }
        if let port = driverPort { IONotificationPortDestroy(port); driverPort = nil }
        if let source = context.notificationSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port = context.notificationPort { CFMachPortInvalidate(port) }
        context.notificationSource = nil; context.notificationPort = nil
        manager.installFanHelpers(nil, secondary: nil)
        fanHelper = nil; fanHelper2 = nil
        if let observer = thinkWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        thinkWakeObserver = nil
        if let observer = thinkSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        thinkSleepObserver = nil
        NotificationCenter.default.removeObserver(self, name: VolumeObserver.volumeChanged, object: nil)
        DistributedNotificationCenter.default.removeObserver(self, name: NSNotification.Name("com.apple.sound.settingsChangedNotification"), object: nil)
        if context.connect != 0 {
            _ = IOConnectCallScalarMethod(context.connect, UInt32(kRYSMCUCClose), nil, 0, nil, nil)
            IOServiceClose(context.connect); context.connect = 0
        }
        if context.service != 0 { IOObjectRelease(context.service); context.service = 0 }
    }

    private func initNotification(_ ECCap: String?) {
        manager.service = context.service
        var isOpen = false
        switch provider {
        case "IdeaVPC":
            context.events = ideaEvents
            isOpen = registerNotification(context)
            prepareControls()
        case "ThinkVPC":
            context.events = thinkEvents
            isOpen = registerNotification(context)
            thinkWakeup()
            if !defaults.bool(forKey: "DisableFan") {
                if ECCap == "RW", getNumber("ThinkFanProtocolVersion", context.service) == 1 {
                    if getBoolean("Dual fan", context.service), defaults.bool(forKey: "SecondThinkFan") {
                        fanHelper2 = ThinkFanHelper(connection: context.connect, isMainFan: false, feedback: HardwareFeedbackPresenter.show)
                        fanHelper2?.update()
                        if defaults.bool(forKey: "SaveFanLevel"),
                           let key = fanPreferenceKey("Fan2Level"), let level = defaults.object(forKey: key) as? UInt8 {
                            fanHelper2?.setFanLevel(level)
                        }
                    }
                    fanHelper = ThinkFanHelper(connection: context.connect, isMainFan: true, feedback: HardwareFeedbackPresenter.show)
                    fanHelper?.update()
                    if defaults.bool(forKey: "SaveFanLevel"),
                       let key = fanPreferenceKey("FanLevel"), let level = defaults.object(forKey: key) as? UInt8 {
                        fanHelper?.setFanLevel(level)
                    }
                } else {
                    showOSD("ECAccessUnavailable")
                }
            }

            thinkWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.thinkWakeup() }
            thinkSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.fanHelper?.stopCurve(reason: .systemSleep)
                self?.fanHelper2?.stopCurve(reason: .systemSleep)
            }

            if defaults.bool(forKey: "ThinkMuteLEDFixup") {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(thinkMuteLEDFixup),
                    name: VolumeObserver.volumeChanged,
                    object: nil
                )

                DistributedNotificationCenter.default.addObserver(
                    self,
                    selector: #selector(thinkMuteLEDFixup),
                    name: NSNotification.Name(rawValue: "com.apple.sound.settingsChangedNotification"),
                    object: nil
                )
            }
        case "ReYogaHIDD":
            context.events = HIDDEvents
            isOpen = registerNotification(context)
            os_log("Skip loadEvents", type: .info)
        default:
            os_log("Unknown class", type: .error)
            if getNumber("ControlProtocolVersion", context.service) == 1 {
                prepareControls()
            } else {
                manager.setDriverState(.unavailable, message: "This driver provider has no compatible control protocol.")
                prepareControls()
            }
        }
        manager.installFanHelpers(fanHelper, secondary: fanHelper2)
        if isOpen && provider != "ReYogaHIDD" { loadEvents(&context.events) }
        else if provider != "DYVPC" {
            ReYogaDiagnostics.shared.record("hotkey_unavailable", ["provider": provider, "reason": "Notification registration failed"])
        }
    }

    private func loadConfig() {
        if defaults.object(forKey: "StartAtLogin") == nil {
            os_log("First launch", type: .info)
            defaults.setValue(false, forKey: "StartAtLogin")
        }

        hide = defaults.bool(forKey: "HideIcon")
        hideCapslock = defaults.bool(forKey: "HideCapsLock")

        if !Bundle.main.bundlePath.hasPrefix("/Applications") {
            showOSD("MoveApp")
        }

        // Load driver settings
        for (key, upperBound) in [("AutoBacklight", 0x1f), ("BacklightTimeout", 3600)] {
            guard defaults.object(forKey: key) != nil else { continue }
            if let value = defaults.object(forKey: key) as? Int, (0...upperBound).contains(value) {
                _ = sendNumber(key, value, context.service)
            } else {
                defaults.removeObject(forKey: key)
                ReYogaDiagnostics.shared.record("preference_restore_skipped", ["property": key, "reason": "Invalid saved value"])
            }
        }
    }

    private func fanPreferenceKey(_ name: String) -> String? {
        guard let digest = getString("FirmwareDSDTSHA256", context.service), digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "ThinkFanSettings.\(digest).\(name)"
    }

    func saveConfig() {
        guard context.service != 0 else { return }
        if !context.events.isEmpty,
           Bundle.main.bundlePath.hasPrefix("/Applications"),
           provider != "ReYogaHIDD" {
            saveEvents(context.events)
        }

        if defaults.bool(forKey: "SaveFanLevel") {
            if let fan = fanHelper2, let key = fanPreferenceKey("Fan2Level") {
                defaults.set(fan.persistedLevel, forKey: key)
            }
            if let fan = fanHelper, let key = fanPreferenceKey("FanLevel") {
                defaults.set(fan.persistedLevel, forKey: key)
            }
        }

        // Save driver settings
        for (key, upperBound) in [("AutoBacklight", 0x1f), ("BacklightTimeout", 3600)] {
            let value = getNumber(key, context.service)
            if (0...upperBound).contains(value) { defaults.set(value, forKey: key) }
        }
    }

    @objc private func thinkWakeup() {
        micMuteLEDHelper(context.service)
        if defaults.bool(forKey: "ThinkMuteLEDFixup") { muteLEDHelper(context.service) }

        for fan in [fanHelper, fanHelper2].compactMap({ $0 }) {
            if fan.curveEnabled { fan.stopCurve(reason: .wakeRequiresRestart) }
            else { fan.setFanLevel() }
        }
    }

    @objc private func thinkMuteLEDFixup() {
        muteLEDHelper(context.service, false)
    }

    func resetShortcutsToDefaults() {
        resetDefaultEvents(&context.events, ioClass: provider)
        saveEvents(context.events)
    }

}
