//
//  AppDelegate.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 10/11/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Carbon
import os.log
import SwiftUI

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let defaults = ReYogaConstants.userDefaults
    private lazy var driver = DriverConnection(manager: .shared, prepareControls: { [weak self] in
        self?.setupControlsWindow()
    })

    var statusItem: NSStatusItem?
    var controlsWindow: NSWindow?
    private var flagsMonitor: Any?

    // MARK: - CapsLock

    var capslockTimer: Timer?
    var capslockState = false
    @objc func showCapslock(sender: Timer) {
        let current = GetCurrentKeyModifiers() & UInt32(alphaLock) != 0
        if current != capslockState {
            showOSDRes("Caps Lock", current ? "On" : "Off", current ? .kCapslockOn : .kCapslockOff)
            capslockState = current
        }
    }

    func attemptDriverConnection() { driver.connect() }
    func closeDriverConnection() { driver.close() }
    @objc func resetShortcutsToDefaults() { driver.resetShortcutsToDefaults() }

    // MARK: - Menu

    @IBAction func openAboutPanel(_ sender: NSMenuItem?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(sender)
    }


    @objc func iconWakeup() {
        statusItem?.button?.image = ReYogaBrand.menuImage()
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "ReYogaSMC"
        HardwareManager.shared.restoreAfterWake()
    }

    // MARK: - Application

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        for item in NSApp.mainMenu?.items.first?.submenu?.items ?? [] {
            if item.action == #selector(openAboutPanel(_:)) { item.title = loc(.sidebarAboutApp) }
            if item.action == #selector(NSApplication.terminate(_:)) { item.title = loc(.sidebarQuitApp) }
        }
        #if DEBUG
        if ApplicationReviewHarness.startIfRequested(manager: .shared,
            hasDriverConnection: { [weak self] in
                guard let self = self else { return false }
                return self.driver.hasConnection
            }, setupWindows: { [weak self] in self?.setupStatusItem(); self?.setupControlsWindow() }) { return }
        #endif
        HardwareManager.shared.configureFeedback(HardwareFeedbackPresenter.show)
        HardwareManager.shared.configureApplicationActions(
            isControlsWindowVisible: { [weak self] in self?.controlsWindow?.isVisible == true },
            closeDriverConnection: { [weak self] in self?.closeDriverConnection() },
            performHotkeyAction: { [weak self] action in
                guard let self = self else { return }
                SystemHotkeyActions.perform(action, service: HardwareManager.shared.service,
                    toggleTouchpad: { HardwareManager.shared.toggleTouchpad() },
                    openControls: { [weak self] in self?.openControlsWindow(nil) })
            })
        ReYogaPreferences.shared.migrateLegacySettings()
        if let icon = Bundle.main.url(forResource: "ReYogaSMC", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        ReYogaPreferences.shared.begin()
        setupStatusItem()
        setupControlsWindow()
        driver.configureEventActions(
            showSettings: { [weak self] in self?.showSettings() },
            toggleControls: { [weak self] in self?.toggleControlsWindow(nil) },
            refreshHardware: { HardwareManager.shared.refreshAll() })
        attemptDriverConnection()
        DispatchQueue.main.async { self.showControlsWindow() }

        capslockState = GetCurrentKeyModifiers() & UInt32(alphaLock) != 0
        if capslockState {
            driver.updateModifierFlags(driver.modifierFlags.union(.capsLock))
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsCallBack)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlsWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        #if DEBUG
        if ApplicationReviewHarness.isRendering { return }
        #endif
        HardwareManager.shared.refreshPermissions()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        #if DEBUG
        if ApplicationReviewHarness.isRendering { return }
        #endif
        HardwareManager.shared.shutdown()
        driver.saveConfig()
        ReYogaPreferences.shared.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor); flagsMonitor = nil }
        capslockTimer?.invalidate(); capslockTimer = nil
        closeDriverConnection()
    }

    // MARK: - Configuration

    func setupStatusItem() {
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(iconWakeup), name: NSWorkspace.didWakeNotification, object: nil)
        if driver.hide {
            os_log("Icon hidden", type: .info)
            return
        }

        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = ReYogaBrand.menuImage()
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "ReYogaSMC"
        statusItem?.button?.setAccessibilityLabel("ReYogaSMC")
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
        let actions = HardwareControlsActions(
            showAbout: { [weak self] in self?.openAboutPanel(nil) },
            retryDriverConnection: { [weak self] in self?.attemptDriverConnection() },
            resetShortcuts: { [weak self] in self?.resetShortcutsToDefaults() })
        let controller = NSHostingController(rootView: HardwareControlsView(manager: HardwareManager.shared, actions: actions))
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
        defaults.set((tab == 2 ? ControlsPage.diagnostics : .settings).rawValue, forKey: "ControlsPage")
        showControlsWindow()
    }


    func flagsCallBack(event: NSEvent) {
        if !driver.hideCapslock {
            if event.modifierFlags.contains(.capsLock) != driver.modifierFlags.contains(.capsLock) {
                capslockTimer = Timer.scheduledTimer(
                    timeInterval: 0.05,
                    target: self,
                    selector: #selector(showCapslock(sender:)),
                    userInfo: nil,
                    repeats: false
                )
            }
        }
        driver.updateModifierFlags(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

}
