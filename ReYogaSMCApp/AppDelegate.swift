//
//  AppDelegate.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 10/11/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import ApplicationServices
import Carbon
import NotificationCenter
import os.log
import ServiceManagement
import SwiftUI

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let defaults = ReYogaConstants.userDefaults
    var conf = SharedConfig()
    var IOClass = "ReYogaSMC"

    var statusItem: NSStatusItem?
    var controlsWindow: NSWindow?
    private var flagsMonitor: Any?
    private var driverPort: IONotificationPortRef?
    private var driverInterest: io_object_t = 0
    private var thinkWakeObserver: NSObjectProtocol?
    var hide = false

    // MARK: - CapsLock

    var hideCapslock = false
    var capslockTimer: Timer?
    var capslockState = false
    @objc func showCapslock(sender: Timer) {
        let current = GetCurrentKeyModifiers() & UInt32(alphaLock) != 0
        if current != capslockState {
            showOSDRes("Caps Lock", current ? "On" : "Off", current ? .kCapslockOn : .kCapslockOff)
            capslockState = current
        }
    }

    // MARK: - Think

    var fanHelper: ThinkFanHelper?
    var fanHelper2: ThinkFanHelper?

    @objc func thinkWakeup() {
        micMuteLEDHelper(conf.service)
        if defaults.bool(forKey: "ThinkMuteLEDFixup") { muteLEDHelper(conf.service) }

        if fanHelper2 != nil {
            fanHelper2?.setFanLevel()
        }
        if fanHelper != nil {
            fanHelper?.setFanLevel()
        }
    }

    @objc func thinkMuteLEDFixup() {
        muteLEDHelper(conf.service, false)
    }

    // MARK: - Menu

    @IBAction func openAboutPanel(_ sender: NSMenuItem?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(sender)
    }

    @objc func openAppSettings() {
        showSettings()
    }

    @objc func resetShortcutsToDefaults() {
        resetDefaultEvents(&conf, ioClass: IOClass)
        saveEvents(&conf)
    }

    @objc func iconWakeup() {
        statusItem?.button?.image = ReYogaBrand.menuImage()
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "ReYogaSMC"
        HardwareManager.shared.restoreAfterWake()
    }

    // MARK: - Application

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--render-ui") { renderUIReview(); return }
        if CommandLine.arguments.contains("--check-missing-driver") {
            HardwareManager.shared.setDriverState(.missing, message: "ReYogaSMC.kext is required. Install a compatible driver and restart macOS.")
            setupStatusItem(); setupControlsWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let clean = self.conf.service == 0 && self.conf.connect == 0 && HardwareManager.shared.driverState == .missing
                print(clean ? "PASS missing driver: no client; independent sensors and recovery controls available" : "FAIL missing-driver startup")
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        migratePreferences()
        if let icon = Bundle.main.url(forResource: "ReYogaSMC", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        ReYogaPreferences.shared.begin()
        setupStatusItem()
        setupControlsWindow()
        attemptDriverConnection()
        DispatchQueue.main.async { self.showControlsWindow() }

        capslockState = GetCurrentKeyModifiers() & UInt32(alphaLock) != 0
        if capslockState {
            conf.modifier.insert(.capsLock)
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsCallBack)
    }

    func attemptDriverConnection() {
        guard conf.connect == 0 else { return }
        let manager = HardwareManager.shared
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
                    error = props["SafeModeReason"] as? String ?? "Driver safe mode is active; firmware controls are disabled"
                    continue
                }
                let protocolVersion = props["ControlProtocolVersion"] as? Int ?? 0
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
                conf.service = service; conf.connect = connection; IOClass = provider
                manager.setDriverState(.ready, message: "Hardware driver ready")
                watchDriverTermination(service)
                loadConfig()
                initNotification(props["EC Capability"] as? String)
                return
            }
        } else { error = String(format: localizedMessage("IOKit driver discovery failed (0x%08x)."), result) }
        manager.setDriverState(found ? .unavailable : .missing, message: error)
        setupControlsWindow()
    }

    private func watchDriverTermination(_ service: io_service_t) {
        guard let port = IONotificationPortCreate(kIOMasterPortDefault) else { return }
        driverPort = port
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let status = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, message, _ in
            guard message == ReYogaServiceTerminatedMessage(), let context = context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                HardwareManager.shared.service = 0
                delegate.closeDriverConnection()
                HardwareManager.shared.setDriverState(.unavailable, message: "The hardware driver disconnected. Retry the connection or restart with the matching kext.")
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &driverInterest)
        if status != kIOReturnSuccess { IONotificationPortDestroy(port); driverPort = nil }
    }

    func closeDriverConnection() {
        if driverInterest != 0 { IOObjectRelease(driverInterest); driverInterest = 0 }
        if let port = driverPort { IONotificationPortDestroy(port); driverPort = nil }
        if let source = conf.notificationSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port = conf.notificationPort { CFMachPortInvalidate(port) }
        conf.notificationSource = nil; conf.notificationPort = nil
        fanHelper = nil; fanHelper2 = nil
        if let observer = thinkWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        thinkWakeObserver = nil
        NotificationCenter.default.removeObserver(self, name: VolumeObserver.volumeChanged, object: nil)
        DistributedNotificationCenter.default.removeObserver(self, name: NSNotification.Name("com.apple.sound.settingsChangedNotification"), object: nil)
        if conf.connect != 0 {
            _ = IOConnectCallScalarMethod(conf.connect, UInt32(kRYSMCUCClose), nil, 0, nil, nil)
            IOServiceClose(conf.connect); conf.connect = 0
        }
        if conf.service != 0 { IOObjectRelease(conf.service); conf.service = 0 }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlsWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if CommandLine.arguments.contains("--render-ui") { return }
        HardwareManager.shared.refreshPermissions()
    }

    #if DEBUG
    private func renderUIReview() {
        let manager = HardwareManager.shared
        if let path = ProcessInfo.processInfo.environment["REYOGA_UI_FIXTURE"],
           let data = FileManager.default.contents(atPath: path),
           let fixture = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary {
            manager.loadUIFixture(fixture)
        } else {
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IdeaVPC"))
            if service != 0 { manager.loadReadOnlyPreview(service); IOObjectRelease(service) }
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REYOGA_UI_REVIEW_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("ReYogaUIReview")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for dark in [false, true] {
                if let path = ProcessInfo.processInfo.environment["REYOGA_UI_FIXTURE"],
                   let data = FileManager.default.contents(atPath: path),
                   let fixture = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary {
                    manager.loadUIFixture(fixture)
                }
                for (name, prompt, symbol) in [("balanced", "Power profile: Balanced", "speedometer"),
                    ("lighting", "Logo LED: Off", "lightbulb"), ("error", "Conservation: Firmware did not confirm the requested state", "battery.75")] {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isOpaque = false; window.backgroundColor = .clear
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let view = HUDContentView(frame: window.contentLayoutRect)
                    window.contentView = view
                    let size = view.configure(prompt: prompt, image: NSImage(systemSymbolName: symbol, accessibilityDescription: prompt))
                    window.setContentSize(size); view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("hud-\(name)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
                for mode in ["overview", "device", "cooling", "battery", "battery-wide", "lighting", "diagnostics", "rgb", "settings", "missing-driver"] {
                    if mode == "missing-driver" { manager.loadMissingDriverPreview() }
                    let controller = NSHostingController(rootView: ReYogaReviewView(mode: mode, manager: manager))
                    let size = NSSize(width: mode == "rgb" ? 420 : mode.hasSuffix("-wide") ? 1040 : AppTheme.windowWidth, height: mode == "rgb" ? 360 : mode.hasSuffix("-wide") ? 760 : AppTheme.windowHeight)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentViewController = controller
                    controller.view.frame = NSRect(origin: .zero, size: size)
                    controller.view.layoutSubtreeIfNeeded()
                    if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("\(mode)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
            NSApp.terminate(nil)
        }
    }

    #endif

    func applicationWillTerminate(_ aNotification: Notification) {
        if CommandLine.arguments.contains("--render-ui") { return }
        HardwareManager.shared.shutdown()
        saveConfig()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor); flagsMonitor = nil }
        closeDriverConnection()
    }

    private func migratePreferences() {
        // Copy existing settings once when moving to the community bundle identity.
        let standard = UserDefaults.standard
        guard !standard.bool(forKey: "ReYogaIdentityMigration") else { return }
        for (old, destination) in [("org.zhen.YogaSMCNC", standard), ("org.zhen.YogaSMC", defaults)] {
            for (key, value) in standard.persistentDomain(forName: old) ?? [:] {
                if destination.object(forKey: key) == nil { destination.set(value, forKey: key) }
            }
        }
        standard.set(true, forKey: "ReYogaIdentityMigration")
    }

    // MARK: - Configuration

    func setupStatusItem() {
        if hide {
            os_log("Icon hidden", type: .info)
            return
        }

        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = ReYogaBrand.menuImage()
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "ReYogaSMC"
        statusItem?.button?.setAccessibilityLabel("ReYogaSMC")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(iconWakeup), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func toggleControlsWindow(_ sender: AnyObject? = nil) {
        setupControlsWindow()
        guard let window = controlsWindow else { return }
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showControlsWindow()
        }
    }

    @objc func openControlsWindow(_ sender: AnyObject?) {
        toggleControlsWindow(sender)
    }

    private func showControlsWindow() {
        setupControlsWindow()
        HardwareManager.shared.refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        controlsWindow?.makeKeyAndOrderFront(nil)
    }

    func setupControlsWindow() {
        guard controlsWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: AppTheme.windowWidth, height: AppTheme.windowHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ReYogaSMC"
        window.contentMinSize = NSSize(width: AppTheme.width, height: AppTheme.height)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: HardwareControlsView(manager: HardwareManager.shared))
        if #available(macOS 13.0, *) { controller.sizingOptions = [] }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: AppTheme.windowWidth, height: AppTheme.windowHeight))
        window.center()
        window.setFrameAutosaveName("ReYogaMainWorkspace")
        controlsWindow = window
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(openControlsWindow(_:))
            statusItem?.menu = nil
        }
    }

    func showSettings(tab: Int = 0) {
        ReYogaColorPanel.shared.dismiss()
        ReYogaPreferences.shared.refreshLoginStatus()
        defaults.set(tab == 2 ? 5 : -1, forKey: "ControlsPage")
        showControlsWindow()
    }

    func returnToControls() {
        defaults.set(0, forKey: "ControlsPage")
        showControlsWindow()
    }

    func initNotification(_ ECCap: String?) {
        HardwareManager.shared.service = conf.service
        var isOpen = false
        switch IOClass {
        case "IdeaVPC":
            conf.events = ideaEvents
            isOpen = registerNotification(&conf)
            setupControlsWindow()
        case "ThinkVPC":
            conf.events = thinkEvents
            isOpen = registerNotification(&conf)
            thinkWakeup()
            if !hide, !defaults.bool(forKey: "DisableFan") {
                if ECCap == "RW", getNumber("ThinkFanProtocolVersion", conf.service) == 1 {
                    if getBoolean("Dual fan", conf.service), defaults.bool(forKey: "SecondThinkFan") {
                        fanHelper2 = ThinkFanHelper(conf.connect, false)
                        if defaults.bool(forKey: "SaveFanLevel"),
                           let level = defaults.object(forKey: "Fan2Level") as? UInt8 {
                            fanHelper2?.setFanLevel(level)
                        }
                        fanHelper2?.update()
                    }
                    fanHelper = ThinkFanHelper(conf.connect, true)
                    if defaults.bool(forKey: "SaveFanLevel"),
                       let level = defaults.object(forKey: "FanLevel") as? UInt8 {
                        fanHelper?.setFanLevel(level)
                    }
                    fanHelper?.update()
                } else {
                    showOSD("ECAccessUnavailable")
                }
            }

            thinkWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.thinkWakeup() }

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
            conf.events = HIDDEvents
            isOpen = registerNotification(&conf)
            os_log("Skip loadEvents", type: .info)
        default:
            os_log("Unknown class", type: .error)
            if getNumber("ControlProtocolVersion", conf.service) == 1 {
                setupControlsWindow()
            } else {
                HardwareManager.shared.setDriverState(.unavailable, message: "This driver provider has no compatible control protocol.")
                setupControlsWindow()
            }
        }
        if isOpen && IOClass != "ReYogaHIDD" { loadEvents(&conf) }
        else if IOClass != "DYVPC" {
            ReYogaDiagnostics.shared.record("hotkey_unavailable", ["provider": IOClass, "reason": "Notification registration failed"])
        }
    }

    func flagsCallBack(event: NSEvent) {
        if !hideCapslock {
            if event.modifierFlags.contains(.capsLock) != conf.modifier.contains(.capsLock) {
                capslockTimer = Timer.scheduledTimer(
                    timeInterval: 0.05,
                    target: self,
                    selector: #selector(showCapslock(sender:)),
                    userInfo: nil,
                    repeats: false
                )
            }
        }
        conf.modifier = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    func loadConfig() {
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
        if defaults.object(forKey: "AutoBacklight") != nil {
            _ = sendNumber("AutoBacklight", defaults.integer(forKey: "AutoBacklight"), conf.service)
        }
        if defaults.object(forKey: "BacklightTimeout") != nil {
            _ = sendNumber("BacklightTimeout", defaults.integer(forKey: "BacklightTimeout"), conf.service)
        }
    }

    func saveConfig() {
        guard conf.service != 0 else { return }
        if !conf.events.isEmpty,
           Bundle.main.bundlePath.hasPrefix("/Applications"),
           IOClass != "ReYogaHIDD" {
            saveEvents(&conf)
        }

        if defaults.bool(forKey: "SaveFanLevel") {
            if fanHelper2 != nil {
                defaults.setValue(fanHelper2?.savedLevel, forKey: "Fan2Level")
            }
            if fanHelper != nil {
                defaults.setValue(fanHelper?.savedLevel, forKey: "FanLevel")
            }
        }

        // Save driver settings
        defaults.setValue(getNumber("AutoBacklight", conf.service), forKey: "AutoBacklight")
        defaults.setValue(getNumber("BacklightTimeout", conf.service), forKey: "BacklightTimeout")
    }
}

final class ReYogaPreferences: ObservableObject {
    static let shared = ReYogaPreferences()
    private let defaults = ReYogaConstants.userDefaults
    @Published var selectedTab = 0 { didSet { defaults.set(selectedTab, forKey: "SettingsTab") } }
    @Published var startAtLogin = false
    @Published var loginStatus = ""
    @Published var automaticUpdates = false
    @Published var checking = false
    @Published var updateStatus = ""
    @Published var releaseURL: URL?
    private var timer: Timer?
    func begin() {
        selectedTab = min(2, max(0, defaults.integer(forKey: "SettingsTab")))
        automaticUpdates = defaults.bool(forKey: "AutomaticUpdateChecks")
        refreshLoginStatus()
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }
    func refreshLoginStatus() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            startAtLogin = status == .enabled || status == .requiresApproval
            loginStatus = status == .requiresApproval ? "Approve ReYogaSMC in System Settings → Login Items." : ""
        } else {
            startAtLogin = defaults.bool(forKey: "StartAtLogin")
        }
    }
    func setStartAtLogin(_ enabled: Bool) {
        do {
            if #available(macOS 13.0, *) {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                refreshLoginStatus()
            } else {
                guard let id = Bundle.main.bundleIdentifier, SMLoginItemSetEnabled((id + "Helper") as CFString, enabled) else {
                    throw SupportError.message("macOS could not change the login item. Install the app in Applications and retry.")
                }
                startAtLogin = enabled
            }
            defaults.set(startAtLogin, forKey: "StartAtLogin")
            showOSDRaw(loginStatus.isEmpty ? localizedMessage("Start with macOS: %@", localizedMessage(startAtLogin ? "On" : "Off")) : loginStatus)
        } catch {
            refreshLoginStatus()
            loginStatus = error.localizedDescription
            showOSDRaw(localizedMessage("Login item: %@", error.localizedDescription), duration: 3000)
        }
    }
    func setAutomaticUpdates(_ enabled: Bool) {
        automaticUpdates = enabled
        defaults.set(enabled, forKey: "AutomaticUpdateChecks")
        showOSDRaw(localizedMessage("Automatic update checks: %@", localizedMessage(enabled ? "On" : "Off")))
        if enabled { checkIfDue() }
    }
    private func checkIfDue() {
        let last = defaults.object(forKey: "LastUpdateCheck") as? Date ?? .distantPast
        if automaticUpdates && Date().timeIntervalSince(last) >= 86400 { checkForUpdates(manual: false) }
    }
    func checkForUpdates(manual: Bool) {
        guard !checking else { return }
        guard let repository = Bundle.main.object(forInfoDictionaryKey: "ReYogaRepositoryID") as? String,
              UInt64(repository) != nil else {
            updateStatus = "The release repository is not configured in this app build."
            return
        }
        checking = true; updateStatus = "Checking published releases…"; releaseURL = nil
        // GitHub's repository ID survives a rename; release checks do not depend on the old slug.
        var request = URLRequest(url: URL(string: "https://api.github.com/repositories/\(repository)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ReYogaSMC", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            var message: String
            var release: URL?
            if let error = error { message = localizedMessage("Update check failed: %@", error.localizedDescription) }
            else if (response as? HTTPURLResponse)?.statusCode == 404 { message = "No public release is available for this fork yet." }
            else if (response as? HTTPURLResponse)?.statusCode != 200 { message = localizedMessage("GitHub update service returned HTTP %@.", String(describing: (response as? HTTPURLResponse)?.statusCode ?? 0)) }
            else if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tag = json["tag_name"] as? String, let link = json["html_url"] as? String,
                    let url = URL(string: link), url.scheme == "https", url.host == "github.com", url.pathComponents.count >= 5, url.pathComponents[3] == "releases" {
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let components = version.split(separator: ".", omittingEmptySubsequences: false)
                let numeric = !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }
                if numeric && version.compare(current, options: .numeric) == .orderedDescending {
                    message = localizedMessage("Update available: %@.", tag); release = url
                } else if numeric { message = localizedMessage("No newer published version. Installed: %@.", current) }
                else { message = localizedMessage("Published release: %@. Review its compatibility before installing.", tag); release = url }
            } else { message = "Invalid release response from GitHub." }
            ReYogaDiagnostics.shared.record("update_check", ["result": message, "manual": manual])
            DispatchQueue.main.async {
                self.checking = false; self.updateStatus = message; self.releaseURL = release
                self.defaults.set(Date(), forKey: "LastUpdateCheck")
                if manual || release != nil { showOSDRaw(message, duration: 3000) }
            }
        }.resume()
    }
}
