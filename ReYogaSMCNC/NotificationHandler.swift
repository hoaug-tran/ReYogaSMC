//
//  NotificationHandler.swift
//  ReYogaSMCNC
//
//  Created by Zhen on 12/22/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import os.log

private func applicationURL(_ name: String) -> URL? {
    let workspace = NSWorkspace.shared
    if let url = workspace.urlForApplication(withBundleIdentifier: name) { return url }
    if name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) { return URL(fileURLWithPath: name) }
    let filename = name.hasSuffix(".app") ? name : name + ".app"
    let directories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                       URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                       URL(fileURLWithPath: "/System/Applications/Utilities"),
                       URL(fileURLWithPath: "/System/Library/CoreServices/Applications")]
    return directories.map { $0.appendingPathComponent(filename) }.first { FileManager.default.fileExists(atPath: $0.path) }
}

func registerNotification(_ conf: inout SharedConfig) -> Bool {
    var portContext = CFMachPortContext(version: 0, info: Unmanaged.passUnretained(conf).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
    guard let port = CFMachPortCreate(kCFAllocatorDefault, notificationCallback, &portContext, nil),
          let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
    let ret = IOConnectSetNotificationPort(conf.connect, 0, CFMachPortGetPort(port), 0)
    guard ret == kIOReturnSuccess else {
        CFMachPortInvalidate(port)
        ReYogaDiagnostics.shared.record("notification_registration_failed", ["status": ret])
        return false
    }
    conf.notificationPort = port
    conf.notificationSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    return true
}

func notificationCallback(
    _ port: CFMachPort?,
    _ msg: UnsafeMutableRawPointer?,
    _ size: CFIndex,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info = info, let msg = msg, size >= MemoryLayout<SMCNotificationMessage>.size else {
        if #available(macOS 10.12, *) {
            os_log("Invalid config", type: .error)
        }
        return
    }

    var conf = Unmanaged<SharedConfig>.fromOpaque(info).takeUnretainedValue()
    let notification = msg.load(as: SMCNotificationMessage.self)
    ReYogaDiagnostics.shared.record("ec_notification", ["event": notification.event, "data": notification.data])

    if let events = conf.events[notification.event] {
        let mod = conf.modifier.subtracting(.capsLock)
        if !mod.isEmpty,
           let desc = events[notification.data | UInt32(mod.rawValue)] {
            eventActuator(desc, notification.data, &conf)
        } else if let desc = events[notification.data] {
            eventActuator(desc, notification.data, &conf)
        } else if let desc = events[0] {
            eventActuator(desc, notification.data, &conf)
        } else {
            let value = String(format: "0x%04x:%d", notification.event, notification.data)
            showOSDRaw("\(NSLocalizedString("EventVar", comment: "Event "))\(value)")
            if #available(macOS 10.12, *) {
                os_log("Event %s default data not found", type: .error, value)
            }
        }
    } else {
        let value = String(format: "0x%04x:%d", notification.event, notification.data)
        showOSDRaw("\(NSLocalizedString("EventVar", comment: "Event "))\(value)")
        conf.events[notification.event] = [0: EventDesc("Event \(value)", nil, opt: "Unknown")]
        #if DEBUG
        if #available(macOS 10.12, *) {
            os_log("Event %s", type: .debug, value)
        }
        #endif
    }
}

func eventActuator(_ desc: EventDesc, _ data: UInt32, _ conf: inout SharedConfig) {
    switch desc.action {
    case .nothing:
        #if DEBUG
        if #available(macOS 10.12, *) {
            os_log("%s: Do nothing", type: .info, desc.name)
        }
        #endif
        if !desc.display { return }
        if desc.name.hasPrefix("Event ") {
            let prompt = NSLocalizedString("EventVar", comment: "Event ") + desc.name.dropFirst("Event ".count)
            showOSDRaw(prompt, desc.image)
        } else {
            showOSD(desc.name, desc.image)
        }
    case .script:
        if let scpt = desc.option {
            _ = scriptHelper(scpt, desc.name, desc.display ? desc.image : nil)
        } else {
            if #available(macOS 10.12, *) {
                os_log("%s: script not found", type: .error, desc.name)
            }
        }
    case .launchapp:
        guard let name = desc.option,
              let url = applicationURL(name) else {
            os_log("%s: app name not found", type: .error, desc.name)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            DispatchQueue.main.async {
                if let error = error { showOSDRaw("Could not open \(name): \(error.localizedDescription)") }
                else if desc.display { showOSD(desc.name, desc.image) }
            }
        }
    case .launchbundle:
        guard let identifier = desc.option else {
            if #available(macOS 10.12, *) {
                os_log("%s: bundle not found", type: .error)
            }
            return
        }
        let collection = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        if collection.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                os_log("%s: app url not found", type: .error, desc.name)
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                if let error = error {
                    DispatchQueue.main.async { showOSDRaw("Could not open \(desc.name): \(error.localizedDescription)") }
                }
            }
        } else {
            var hide = false
            for app in collection where !app.isHidden {
                hide = true
                break
            }
            for app in collection {
                if hide {
                    app.hide()
                } else {
                    app.activate(options: .activateIgnoringOtherApps)
                }
            }
            if hide { return }
        }
        if desc.display { showOSD(desc.name, desc.image) }
    case .airplane:
        airplaneModeHelper(desc.name, desc.display)
    case .bluetooth:
        bluetoothHelper(desc.name, desc.display)
    case .bluetoothdiscoverable:
        bluetoothDiscoverableHelper(desc.name, desc.display)
    case .backlight:
        if !desc.display { return }
        if getNumber("BacklightLevel", conf.service) < 0 && getBoolean("LenovoLightingMethod", conf.service) {
            showOSDRaw("Lighting changed")
            return
        }
        if (data & 0x10 != 0) { return }
        switch data & 0x0f {
        case 0:
            showOSDRes("Backlight", "Off", .kBacklightOff)
        case 1:
            showOSDRes("Backlight", "Low", .kBacklightLow)
        case 2:
            showOSDRes("Backlight", "High", .kBacklightHigh)
        default:
            showOSDRes("Backlight", "\(data)", .kBacklightHigh)
        }
    case .fnlock:
        if !desc.display { return }
        switch data {
        case 0:
            showOSDRes("FnKey", "Disabled", .kFunctionKeyOff)
        case 1:
            showOSDRes("FnKey", "Enabled", .kFunctionKeyOn)
        default:
            // reserved for media keyboard
            showOSDRes("FnKey", "\(data)", .kFunctionKeyOn)
        }
    case .keyboard:
        if !desc.display { return }
        showOSDRes("Keyboard", (data != 0) ? "Enabled" : "Disabled", (data != 0) ? .kKeyboard : .kKeyboardOff)
    case .micmute:
        micMuteHelper(conf.service, desc.name)
    case .desktop:
        CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, nil)
    case .expose:
        CoreDockSendNotification("com.apple.expose.front.awake" as CFString, nil)
    case .mission:
        CoreDockSendNotification("com.apple.expose.awake" as CFString, nil)
    case .launchpad:
        CoreDockSendNotification("com.apple.launchpad.toggle" as CFString, nil)
    case .settings:
        (NSApp.delegate as? AppDelegate)?.showSettings()
    case .sleep:
        if desc.display {
            showOSDRes(desc.name, .kSleep)
            sleep(1)
        }
        _ = scriptHelper(sleepAS, desc.name)
    case .search:
        _ = scriptHelper(searchAS, desc.name)
    case .spotlight:
        _ = scriptHelper(spotlightAS, desc.name)
    case .controls:
        (NSApp.delegate as? AppDelegate)?.toggleGamingPopover(nil)
        showOSD(desc.name)
    case .calculator, .screenshot, .siri:
        let bundle = desc.action == .siri ? "com.apple.Siri" : desc.action == .calculator ? "com.apple.calculator" : "com.apple.Screenshot"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                if let error = error { ReYogaDiagnostics.shared.record("hotkey_launch_failed", ["bundle": bundle, "error": error.localizedDescription]) }
            }
            showOSD(desc.name)
        } else { showOSDRaw("\(desc.name): application unavailable") }
    case .displaysettings, .mirror:
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") { NSWorkspace.shared.open(url) }
        showOSDRaw("Display Settings")
    case .thermal:
        if #available(macOS 11.0, *) { HardwareManager.shared.refreshAll() }
        showOSD(desc.name, desc.image)
        if #available(macOS 10.12, *) {
            os_log("%s: thermal event", type: .info, desc.name)
        }
    case .wireless:
        wirelessHelper(desc.name, desc.display)
    default:
        #if DEBUG
        if #available(macOS 10.12, *) {
            os_log("%s: Not implmented", type: .info, desc.name)
        }
        #endif
        if desc.display {
            showOSD(desc.name, desc.image)
        }
    }
}
