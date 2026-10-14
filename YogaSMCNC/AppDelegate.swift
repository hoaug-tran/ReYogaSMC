//
//  AppDelegate.swift
//  YogaSMCNC
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
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults(suiteName: "org.zhen.YogaSMC")!
    var conf = SharedConfig()
    var IOClass = "YogaSMC"

    var statusItem: NSStatusItem?
    var gamingPopover: NSPopover?
    var settingsWindow: NSWindow?
    private var flagsMonitor: Any?
    private var driverPort: IONotificationPortRef?
    private var driverInterest: io_object_t = 0
    @IBOutlet weak var appMenu: NSMenu!
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
    var fanTimer: Timer?

    @objc func thinkWakeup() {
        micMuteLEDHelper(conf.service)
        muteLEDHelper(conf.service)

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

    @IBAction func openAboutPanel(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(sender)
    }

    @objc func toggleStartAtLogin(_ sender: NSMenuItem) {
        let identifier = "\(Bundle.main.bundleIdentifier!)Helper" as CFString
        if SMLoginItemSetEnabled(identifier, sender.state == .off) {
            sender.state = (sender.state == .on) ? .off : .on
            defaults.setValue((sender.state == .on), forKey: "StartAtLogin")
        } else {
            if #available(macOS 10.12, *) {
                os_log("Toggle start at login failed", type: .error)
            }
        }
    }

    @objc func openAppSettings() {
        showSettings()
    }

    @objc func iconWakeup() {
        statusItem?.button?.image = ReYogaBrand.menuImage()
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "ReYogaSMC"
        GamingManager.shared.restoreAfterWake()
    }

    @objc func update () {
        DispatchQueue.main.async {
            if self.fanHelper2 != nil {
                self.fanHelper2!.update()
            }
            if self.fanHelper != nil {
                self.fanHelper!.update()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        update()
        DispatchQueue.global(qos: .default).async {
            self.fanTimer = Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(self.update),
                userInfo: nil,
                repeats: true
            )

            if self.fanTimer == nil {
                return
            }
            self.fanTimer?.tolerance = 0.2
            let currentRunLoop = RunLoop.current
            currentRunLoop.add(self.fanTimer!, forMode: .common)
            currentRunLoop.run()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        self.fanTimer?.invalidate()
    }

    // MARK: - Application

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if CommandLine.arguments.contains("--render-ui") { renderUIReview(); return }
        #if DEBUG
        if CommandLine.arguments.contains("--check-missing-driver") {
            GamingManager.shared.setDriverState(.missing, message: "ReYogaSMC.kext is required. Install a compatible driver and restart macOS.")
            initMenu("Driver required"); setupGamingPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let clean = self.conf.service == 0 && self.conf.connect == 0 && GamingManager.shared.driverState == .missing
                print(clean ? "PASS missing driver: no client, no device dashboard; recovery screen active" : "FAIL missing-driver startup")
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        ReYogaPreferences.shared.begin()
        initMenu("ReYogaSMC")
        attemptDriverConnection()
        if CommandLine.arguments.contains("--show-controls") {
            DispatchQueue.main.async { self.toggleGamingPopover(nil) }
        }

        capslockState = GetCurrentKeyModifiers() & UInt32(alphaLock) != 0
        if capslockState {
            conf.modifier.insert(.capsLock)
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsCallBack)
    }

    @available(macOS 11.0, *)
    func attemptDriverConnection() {
        guard conf.connect == 0 else { return }
        let manager = GamingManager.shared
        manager.setDriverState(.checking, message: "Checking the hardware driver…")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("YogaVPC"), &iterator)
        defer { if iterator != 0 { IOObjectRelease(iterator) } }
        var found = false
        var error = "ReYogaSMC.kext is required. Install the driver and its required dependencies in your bootloader, then restart macOS."
        if result == kIOReturnSuccess {
            while let service = IOIteratorNextOptional(iterator) {
                found = true
                guard let props = getProperties(service), let provider = props["IOClass"] as? String else {
                    error = "The driver was found but its properties could not be read. Check the driver log."
                    IOObjectRelease(service); continue
                }
                let protocolVersion = props["ControlProtocolVersion"] as? Int ?? 0
                if provider == "IdeaVPC" && protocolVersion != 1 {
                    error = "The loaded driver does not provide a compatible control protocol. Boot the matching ReYogaSMC driver and retry."
                    IOObjectRelease(service); continue
                }
                var connection: io_connect_t = 0
                let openStatus = IOServiceOpen(service, mach_task_self_, 0, &connection)
                guard openStatus == kIOReturnSuccess else {
                    error = String(format: "Cannot open the hardware driver (0x%08x). Check permissions and the driver log.", openStatus)
                    IOObjectRelease(service); continue
                }
                let claim = IOConnectCallScalarMethod(connection, UInt32(kYSMCUCOpen), nil, 0, nil, nil)
                guard claim == kIOReturnSuccess else {
                    error = String(format: "The driver rejected the connection (0x%08x). Another copy of this app may already be running.", claim)
                    IOServiceClose(connection); IOObjectRelease(service); continue
                }
                conf.service = service; conf.connect = connection; IOClass = provider
                manager.setDriverState(.ready, message: "Hardware driver ready")
                watchDriverTermination(service)
                loadConfig()
                initNotification(props["EC Capability"] as? String)
                return
            }
        } else { error = String(format: "IOKit driver discovery failed (0x%08x).", result) }
        manager.setDriverState(found ? .unavailable : .missing, message: error)
        setupGamingPopover()
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
                GamingManager.shared.service = 0
                delegate.closeDriverConnection()
                GamingManager.shared.setDriverState(.unavailable, message: "The hardware driver disconnected. Retry the connection or restart with the matching kext.")
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
        if conf.connect != 0 {
            _ = IOConnectCallScalarMethod(conf.connect, UInt32(kYSMCUCClose), nil, 0, nil, nil)
            IOServiceClose(conf.connect); conf.connect = 0
        }
        if conf.service != 0 { IOObjectRelease(conf.service); conf.service = 0 }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if CommandLine.arguments.contains("--render-ui") { return }
        if #available(macOS 11.0, *) { GamingManager.shared.refreshPermissions() }
    }

    @available(macOS 11.0, *)
    private func renderUIReview() {
        let manager = GamingManager.shared
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IdeaVPC"))
        if service != 0 { manager.loadReadOnlyPreview(service); IOObjectRelease(service) }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REYOGA_UI_REVIEW_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("ReYogaUIReview")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for dark in [false, true] {
                for (name, prompt, symbol) in [("balanced", "Power profile: Balanced", "speedometer"),
                    ("lighting", "Logo LED: Off", "lightbulb"), ("error", "Maximum fan speed: The EC command did not confirm the requested state", "wind")] {
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
                for mode in ["device", "cooling", "rgb", "settings", "missing-driver"] {
                    let controller = NSHostingController(rootView: ReYogaReviewView(mode: mode, manager: manager))
                    let size = mode == "settings" ? NSSize(width: 560, height: 480) : NSSize(width: 420, height: mode == "rgb" ? 360 : 640)
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

    func applicationWillTerminate(_ aNotification: Notification) {
        if CommandLine.arguments.contains("--render-ui") { return }
        if #available(macOS 11.0, *) { GamingManager.shared.shutdown() }
        saveConfig()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor); flagsMonitor = nil }
        closeDriverConnection()
    }

    // MARK: - Configuration

    func initMenu(_ version: String) {
        if hide {
            if #available(macOS 10.12, *) {
                os_log("Icon hidden", type: .info)
            }
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = appMenu
        statusItem?.button?.image = ReYogaBrand.menuImage()
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "ReYogaSMC"
        statusItem?.button?.setAccessibilityLabel("ReYogaSMC")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(iconWakeup), name: NSWorkspace.didWakeNotification, object: nil)

        appMenu.delegate = self

        let classPrompt = NSLocalizedString("ClassVar", comment: "Class: ") + IOClass
        appMenu.insertItem(NSMenuItem.separator(), at: 1)
        appMenu.insertItem(withTitle: classPrompt, action: nil, keyEquivalent: "", at: 2)
        appMenu.insertItem(withTitle: version, action: nil, keyEquivalent: "", at: 3)

        let loginPrompt = NSLocalizedString("Start at Login", comment: "")
        let login = NSMenuItem(title: loginPrompt, action: #selector(toggleStartAtLogin), keyEquivalent: "s")
        login.state = defaults.bool(forKey: "StartAtLogin") ? .on : .off
        appMenu.insertItem(NSMenuItem.separator(), at: 4)
        appMenu.insertItem(login, at: 5)

        let prefPrompt = NSLocalizedString("Preferences", comment: "")
        let pref = NSMenuItem(title: prefPrompt, action: #selector(openAppSettings), keyEquivalent: "p")
        appMenu.insertItem(NSMenuItem.separator(), at: 6)
        appMenu.insertItem(pref, at: 7)
    }

    @objc func toggleGamingPopover(_ sender: AnyObject?) {
        guard let popover = gamingPopover else { return }
        if popover.isShown { popover.performClose(sender) }
        else { showControlsWhenAnchored() }
    }

    private func showControlsWhenAnchored(attempt: Int = 0) {
        guard let button = statusItem?.button, let popover = gamingPopover else { return }
        if let window = button.window, let screen = window.screen, window.isVisible {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            if screen.frame.intersects(anchor), anchor.midY > screen.frame.maxY - NSStatusBar.system.thickness * 2 {
                if #available(macOS 11.0, *) { GamingManager.shared.refreshAll() }
                ReYogaDiagnostics.shared.record("popover_shown", ["anchor": NSStringFromRect(anchor), "screen": NSStringFromRect(screen.frame)])
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                DispatchQueue.main.async { popover.contentViewController?.view.window?.makeKey() }
                return
            }
        }
        guard attempt < 20 else {
            ReYogaDiagnostics.shared.record("popover_anchor_failed", ["attempts": attempt])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.showControlsWhenAnchored(attempt: attempt + 1) }
    }

    @available(macOS 11.0, *)
    func setupGamingPopover() {
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 420, height: 640)
        pop.behavior = .transient
        pop.animates = false
        let controller = NSHostingController(rootView: GamingPopoverView(manager: GamingManager.shared))
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 12
        controller.view.layer?.masksToBounds = true
        pop.contentViewController = controller
        self.gamingPopover = pop

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(toggleGamingPopover(_:))
            statusItem?.menu = nil
        }
    }

    @available(macOS 11.0, *)
    func showSettings(tab: Int = 0) {
        NSColorPanel.shared.orderOut(nil)
        gamingPopover?.performClose(nil)
        ReYogaPreferences.shared.selectedTab = tab
        ReYogaPreferences.shared.refreshLoginStatus()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "ReYogaSMC Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ReYogaSettingsView(manager: GamingManager.shared, preferences: ReYogaPreferences.shared))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @available(macOS 11.0, *)
    func returnToControls() {
        settingsWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.showControlsWhenAnchored() }
    }

    func initNotification(_ ECCap: String?) {
        var isOpen = false
        switch IOClass {
        case "IdeaVPC":
            conf.events = ideaEvents
            isOpen = registerNotification(&conf)
            if #available(macOS 11.0, *) {
                GamingManager.shared.service = conf.service
                setupGamingPopover()
            }
        case "ThinkVPC":
            conf.events = thinkEvents
            isOpen = registerNotification(&conf)
            thinkWakeup()
            if !hide, !defaults.bool(forKey: "DisableFan") {
                if ECCap == "RW" {
                    if !getBoolean("Dual fan", conf.service), defaults.bool(forKey: "SecondThinkFan") {
                        fanHelper2 = ThinkFanHelper(appMenu, conf.connect, false, false)
                        if defaults.bool(forKey: "SaveFanLevel"),
                           let level = defaults.object(forKey: "Fan2Level") as? UInt8 {
                            fanHelper2?.setFanLevel(level)
                        }
                        fanHelper2?.update(true)
                    }
                    fanHelper = ThinkFanHelper(appMenu, conf.connect, true, fanHelper2 == nil)
                    if defaults.bool(forKey: "SaveFanLevel"),
                       let level = defaults.object(forKey: "FanLevel") as? UInt8 {
                        fanHelper?.setFanLevel(level)
                    }
                    fanHelper?.update(true)
                } else {
                    showOSD("ECAccessUnavailable")
                }
            }

            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(thinkWakeup),
                name: NSWorkspace.didWakeNotification,
                object: nil
            )

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
        case "YogaHIDD":
            conf.events = HIDDEvents
            _ = registerNotification(&conf)
            if #available(macOS 10.12, *) {
                os_log("Skip loadEvents", type: .info)
            }
        default:
            if #available(macOS 10.12, *) {
                os_log("Unknown class", type: .error)
            }
            if getNumber("ControlProtocolVersion", conf.service) == 1 {
                GamingManager.shared.service = conf.service
                setupGamingPopover()
            } else {
                GamingManager.shared.setDriverState(.unavailable, message: "This driver provider has no compatible control protocol.")
                setupGamingPopover()
            }
        }
        if isOpen { loadEvents(&conf) }
    }

    func flagsCallBack(event: NSEvent) {
//        print(event.keyCode)
//        switch event.keyCode {
//        case 0x36:
//            os_log("left_option", type: .debug)
//        case 0x37:
//            os_log("right_option", type: .debug)
//        case 0x39:
//            os_log("caps_lock", type: .debug)
//        case 0x3b:
//            os_log("left_control", type: .debug)
//        case 0x3d:
//            os_log("left_command", type: .debug)
//        case 0x3e:
//            os_log("right_control", type: .debug)
//        default:
//            os_log("Unknown %x", type: .debug, event.keyCode)
//        }
        // 1 << 16
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
        // 1 << 17
//        if conf.modifier.contains(.shift) {
//            os_log("Shift", type: .debug)
//            flags.remove(.shift)
//        }
        // 1 << 18
//        if conf.modifier.contains(.control) {
//            os_log("Control", type: .debug)
//            flags.remove(.control)
//        }
        // 1 << 19
//        if conf.modifier.contains(.option) {
//            os_log("Option", type: .debug)
//            flags.remove(.option)
//        }
        // 1 << 20
//        if conf.modifier.contains(.command) {
//            os_log("Command", type: .debug)
//            flags.remove(.command)
//        }
//        if !flags.isEmpty {
//            print(flags)
//        }
    }

    func loadConfig() {
        if defaults.object(forKey: "StartAtLogin") == nil {
            if #available(macOS 10.12, *) {
                os_log("First launch", type: .info)
            }
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
           IOClass != "YogaHIDD" {
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

// Login state is obtained from the OS. Updates use published releases, never
// silent EFI edits or unsigned replacement of a running kernel extension.
@available(macOS 11.0, *)
final class ReYogaPreferences: ObservableObject {
    static let shared = ReYogaPreferences()
    private let defaults = UserDefaults(suiteName: "org.zhen.YogaSMC")!
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
            showOSDRaw(loginStatus.isEmpty ? "Start with macOS: \(startAtLogin ? "On" : "Off")" : loginStatus)
        } catch {
            refreshLoginStatus()
            loginStatus = error.localizedDescription
            showOSDRaw("Login item: \(error.localizedDescription)", duration: 3000)
        }
    }
    func setAutomaticUpdates(_ enabled: Bool) {
        automaticUpdates = enabled
        defaults.set(enabled, forKey: "AutomaticUpdateChecks")
        showOSDRaw("Automatic update checks: \(enabled ? "On" : "Off")")
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
            if let error = error { message = "Update check failed: \(error.localizedDescription)" }
            else if (response as? HTTPURLResponse)?.statusCode == 404 { message = "No public release is available for this fork yet." }
            else if (response as? HTTPURLResponse)?.statusCode != 200 { message = "GitHub update service returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)." }
            else if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tag = json["tag_name"] as? String, let link = json["html_url"] as? String,
                    let url = URL(string: link), url.scheme == "https", url.host == "github.com", url.pathComponents.count >= 5, url.pathComponents[3] == "releases" {
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let components = version.split(separator: ".", omittingEmptySubsequences: false)
                let numeric = !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }
                if numeric && version.compare(current, options: .numeric) == .orderedDescending {
                    message = "Update available: \(tag)."; release = url
                } else if numeric { message = "No newer published version. Installed: \(current)." }
                else { message = "Published release: \(tag). Review its compatibility before installing."; release = url }
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
